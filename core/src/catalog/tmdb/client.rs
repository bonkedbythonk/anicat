//! TMDB's REST client.
//!
//! Deliberately thinner than `anilist::client`: TMDB is a plain REST API with
//! generous limits and no GraphQL envelope, so there is no query batching to
//! model. What it does share is the credential living behind a lock, so
//! Settings can paste a new one in without a restart.
//!
//! **Two ways to reach TMDB, and the key only exists in one of them.** With a
//! proxy configured, requests go to it and carry no credential at all: the
//! key lives on the proxy, which is the only arrangement where a key shipped
//! to every install cannot be read back out of the app -- an Info.plist entry
//! is plain text (`plutil -p`) and a constant in the binary is `strings`.
//! Without a proxy the client talks to TMDB directly with whatever key it was
//! given, which is what a viewer's own key in Settings does: their quota,
//! their request, no reason to route it through anyone.

use std::sync::Mutex;
use std::time::{Duration, Instant};

use serde::de::DeserializeOwned;

const TMDB_URL: &str = "https://api.themoviedb.org/3";

pub struct TmdbClient {
    client: reqwest::Client,
    token: Mutex<Option<String>>,
    /// Base URL of a proxy that holds the key, when there is one. Requests
    /// to it are unauthenticated -- see this module's header.
    proxy: Mutex<Option<String>>,
    /// When the next request may go out, after TMDB answered 429.
    ///
    /// Shared across every caller rather than kept per request: a cinema home
    /// fires eight rows at once, so without this the first 429 would be
    /// followed by seven more requests already in flight into the same closed
    /// door, and the retry below would make it fifteen. Anicat ships one API
    /// key for everyone, which makes being throttled everybody's problem at
    /// once and this the difference between backing off and hammering.
    rate_limited_until: Mutex<Option<Instant>>,
}

impl Clone for TmdbClient {
    fn clone(&self) -> Self {
        Self {
            client: self.client.clone(),
            token: Mutex::new(self.token.lock().unwrap().clone()),
            proxy: Mutex::new(self.proxy.lock().unwrap().clone()),
            rate_limited_until: Mutex::new(None),
        }
    }
}

/// Longest a 429 parks requests for, however large a `Retry-After` says.
/// TMDB's documented ceiling is around 40 requests a second and a cooldown is
/// normally a second or two; a header asking for ten minutes would otherwise
/// freeze every cinema page in the app behind one bad answer.
const MAX_COOLDOWN: Duration = Duration::from_secs(60);

/// Waited when a 429 arrives with no `Retry-After` at all.
const DEFAULT_COOLDOWN: Duration = Duration::from_secs(2);

/// TMDB issues two kinds of credential, and the account page offers both
/// without explaining that they authenticate differently. Rather than make the
/// user work out which box to paste where, tell them apart by shape: a v4 read
/// token is a JWT and goes in the Authorization header, while a v3 key is a
/// 32-character hex string and goes in the query string.
fn is_v4_token(token: &str) -> bool {
    token.starts_with("eyJ")
}

impl TmdbClient {
    pub fn new(client: reqwest::Client, token: Option<String>, proxy: Option<String>) -> Self {
        Self {
            client,
            token: Mutex::new(token.filter(|t| !t.trim().is_empty())),
            proxy: Mutex::new(clean_proxy(proxy)),
            rate_limited_until: Mutex::new(None),
        }
    }

    pub fn set_proxy(&self, proxy: Option<String>) {
        if let Ok(mut p) = self.proxy.lock() {
            *p = clean_proxy(proxy);
        }
    }

    pub fn set_token(&self, token: Option<String>) {
        if let Ok(mut t) = self.token.lock() {
            *t = token.filter(|t| !t.trim().is_empty());
        }
    }

    /// Whether there is any way to reach TMDB at all: a proxy, or a key of
    /// our own. Cinema mode is hidden when there is neither.
    pub fn has_token(&self) -> bool {
        let keyed = self.token.lock().map(|t| t.is_some()).unwrap_or(false);
        keyed || self.proxy.lock().map(|p| p.is_some()).unwrap_or(false)
    }

    /// A viewer's own key goes straight to TMDB. Routing it through the proxy
    /// would spend the proxy's key instead of theirs, which is the opposite
    /// of what pasting a key in Settings asks for.
    fn route(&self) -> Route {
        if let Some(token) = self.token.lock().ok().and_then(|t| t.clone()) {
            return Route::Direct(token);
        }
        match self.proxy.lock().ok().and_then(|p| p.clone()) {
            Some(base) => Route::Proxy(base),
            None => Route::Nothing,
        }
    }

    /// GET a TMDB endpoint. `path` is everything after /3, starting with a
    /// slash; `query` is appended after the language parameter.
    pub async fn get<T: DeserializeOwned>(
        &self,
        path: &str,
        query: &[(&str, String)],
    ) -> Result<T, String> {
        let route = self.route();
        if matches!(route, Route::Nothing) {
            return Err("no_tmdb_token".to_string());
        }

        // One retry, and only for a 429. A throttled key is the one failure
        // that is certain to pass on its own, and letting the row fail instead
        // shows an empty shelf for something that would have answered a second
        // later. Anything else -- 401, 404, a network error -- is returned as
        // it was: retrying those is just a second request with the same
        // answer.
        for attempt in 0..2 {
            self.await_cooldown().await;
            match self.send(path, query, &route).await {
                Err(TmdbFailure::RateLimited(cooldown)) if attempt == 0 => {
                    log::warn!(
                        "tmdb: 429 on {} -- backing off {:?} before one retry",
                        path,
                        cooldown
                    );
                    self.park(cooldown);
                }
                Err(TmdbFailure::RateLimited(cooldown)) => {
                    self.park(cooldown);
                    return Err("tmdb_rate_limited".to_string());
                }
                Err(TmdbFailure::Other(msg)) => return Err(msg),
                Ok(value) => return Ok(value),
            }
        }
        Err("tmdb_rate_limited".to_string())
    }

    /// Sleeps out whatever a previous 429 asked for. Read and dropped before
    /// the await: the lock is a std Mutex and must not be held across one.
    async fn await_cooldown(&self) {
        let wait = {
            let until = self.rate_limited_until.lock().ok().and_then(|u| *u);
            until.and_then(|until| until.checked_duration_since(Instant::now()))
        };
        if let Some(wait) = wait {
            tokio::time::sleep(wait).await;
        }
    }

    /// Parks every caller until the cooldown elapses, never shortening a
    /// cooldown another response already set.
    fn park(&self, cooldown: Duration) {
        if let Ok(mut until) = self.rate_limited_until.lock() {
            let deadline = Instant::now() + cooldown;
            if until.map(|existing| existing < deadline).unwrap_or(true) {
                *until = Some(deadline);
            }
        }
    }

    async fn send<T: DeserializeOwned>(
        &self,
        path: &str,
        query: &[(&str, String)],
        route: &Route,
    ) -> Result<T, TmdbFailure> {
        let mut request = self.client.get(request_url(route, path));

        let mut params: Vec<(String, String)> = vec![("language".into(), "en-US".into())];
        for (k, v) in query {
            params.push((k.to_string(), v.clone()));
        }
        match route {
            // A v4 read token is a JWT and goes in the header; a v3 key is a
            // 32-character hex string and goes in the query string. TMDB
            // offers both on the account page without saying they
            // authenticate differently, so they are told apart by shape.
            Route::Direct(token) if is_v4_token(token) => {
                request = request.bearer_auth(token);
            }
            Route::Direct(token) => params.push(("api_key".into(), token.clone())),
            // Nothing is attached: the proxy holds the key and adds it on the
            // far side, which is the entire point of having one.
            Route::Proxy(_) | Route::Nothing => {}
        }

        // This client is shared with the proxy's streaming client (state.rs),
        // which deliberately carries no client-level timeout so a long mpv
        // download is never cut off. A metadata fetch is not a download and
        // must not inherit that: a per-request timeout here, same shape as
        // AniListClient's own bounded timeout, is what stops a single stalled
        // TMDB connection from hanging every caller downstream forever with
        // no error and nothing in the log to explain it -- the release
        // picker, the detail page, and every cinema row all wait on this.
        let response = request
            .query(&params)
            .timeout(std::time::Duration::from_secs(20))
            .send()
            .await
            .map_err(|e| TmdbFailure::Other(format!("tmdb request failed: {}", e)))?;

        let status = response.status();
        if status == reqwest::StatusCode::TOO_MANY_REQUESTS {
            // TMDB states the cooldown in Retry-After; guessing when it does
            // not is better than retrying immediately into the same wall.
            let cooldown = cooldown_from_retry_after(
                response
                    .headers()
                    .get(reqwest::header::RETRY_AFTER)
                    .and_then(|v| v.to_str().ok()),
            );
            return Err(TmdbFailure::RateLimited(cooldown));
        }
        if !status.is_success() {
            // 401 is the one a user can actually fix, and it is the one they
            // will hit first, so it gets a name the UI can match on rather
            // than a status code buried in a string.
            if status == reqwest::StatusCode::UNAUTHORIZED {
                log::warn!("tmdb: rejected the token for {}", path);
                return Err(TmdbFailure::Other("tmdb_unauthorized".to_string()));
            }
            log::warn!("tmdb: {} returned HTTP {}", path, status);
            return Err(TmdbFailure::Other(format!("tmdb returned HTTP {}", status)));
        }

        response
            .json::<T>()
            .await
            .map_err(|e| TmdbFailure::Other(format!("tmdb response did not parse: {}", e)))
    }
}

/// Where one request is going, and what it carries.
enum Route {
    /// Straight to TMDB with this credential.
    Direct(String),
    /// To a proxy at this base URL, unauthenticated.
    Proxy(String),
    /// Neither is configured; cinema mode is off.
    Nothing,
}

/// The URL for one request. A proxy is addressed with the same `/3/...` paths
/// TMDB uses, so it can forward them unchanged and this stays one string
/// substitution rather than a second set of endpoint names to keep in step.
fn request_url(route: &Route, path: &str) -> String {
    match route {
        Route::Proxy(base) => format!("{}/3{}", base.trim_end_matches('/'), path),
        _ => format!("{}{}", TMDB_URL, path),
    }
}

/// A proxy URL has to be an origin we can build `/3/...` onto. A blank entry
/// (the packaging script writes the key unconditionally, so it is often
/// blank) and anything not http(s) read as "no proxy" rather than being
/// concatenated into a nonsense URL that fails every row with a parse error.
fn clean_proxy(proxy: Option<String>) -> Option<String> {
    proxy
        .map(|p| p.trim().trim_end_matches('/').to_string())
        .filter(|p| p.starts_with("https://") || p.starts_with("http://"))
}

/// How long to wait after a 429, from the header TMDB sends with it.
///
/// A `Retry-After` can also be an HTTP date rather than a count of seconds;
/// that form parses as nothing here and falls back to the default, which is
/// the safe direction -- a short wait that retries is better than treating an
/// unparsed header as permission to retry at once.
fn cooldown_from_retry_after(header: Option<&str>) -> Duration {
    header
        .and_then(|s| s.trim().parse::<u64>().ok())
        .map(Duration::from_secs)
        .unwrap_or(DEFAULT_COOLDOWN)
        .min(MAX_COOLDOWN)
}

/// A 429 separated from every other failure, because it is the only one the
/// caller answers by waiting rather than by giving up.
enum TmdbFailure {
    RateLimited(Duration),
    Other(String),
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn the_two_credential_shapes_are_told_apart() {
        // A v4 read access token is a JWT.
        assert!(is_v4_token("eyJhbGciOiJIUzI1NiJ9.eyJhdWQiOiJhYmMifQ.sig"));
        // A v3 key is 32 hex characters.
        assert!(!is_v4_token("0123456789abcdef0123456789abcdef"));
    }

    #[test]
    fn a_retry_after_is_honoured_but_capped() {
        assert_eq!(cooldown_from_retry_after(Some("3")), Duration::from_secs(3));
        // A header asking for ten minutes would freeze every cinema page in
        // the app behind one answer.
        assert_eq!(cooldown_from_retry_after(Some("600")), MAX_COOLDOWN);
        assert_eq!(cooldown_from_retry_after(Some(" 5 ")), Duration::from_secs(5));
    }

    #[test]
    fn an_unusable_retry_after_still_waits() {
        assert_eq!(cooldown_from_retry_after(None), DEFAULT_COOLDOWN);
        // The HTTP-date form of the header.
        assert_eq!(
            cooldown_from_retry_after(Some("Wed, 21 Oct 2026 07:28:00 GMT")),
            DEFAULT_COOLDOWN
        );
    }

    #[test]
    fn a_blank_token_counts_as_no_token() {
        // Settings writes an empty string when the field is cleared, and an
        // empty Authorization header reads as a malformed request rather than
        // as "not configured".
        let client = TmdbClient::new(reqwest::Client::new(), Some("   ".to_string()), None);
        assert!(!client.has_token());
        client.set_token(Some("".to_string()));
        assert!(!client.has_token());
        client.set_token(Some("0123456789abcdef0123456789abcdef".to_string()));
        assert!(client.has_token());
    }

    #[test]
    fn a_proxy_counts_as_a_way_in_and_a_key_still_wins() {
        let client = TmdbClient::new(reqwest::Client::new(), None, Some("https://p.example/".into()));
        assert!(client.has_token(), "a proxy is how a keyless build reaches TMDB");
        assert!(matches!(client.route(), Route::Proxy(base) if base == "https://p.example"));
        // A viewer's own key is theirs to spend: it goes straight to TMDB
        // rather than through somebody else's proxy and quota.
        client.set_token(Some("0123456789abcdef0123456789abcdef".to_string()));
        assert!(matches!(client.route(), Route::Direct(_)));
    }

    #[test]
    fn a_proxy_is_addressed_with_tmdb_s_own_paths() {
        let proxy = Route::Proxy("https://p.example".to_string());
        assert_eq!(request_url(&proxy, "/movie/550"), "https://p.example/3/movie/550");
        let direct = Route::Direct("k".to_string());
        assert_eq!(request_url(&direct, "/movie/550"), "https://api.themoviedb.org/3/movie/550");
    }

    #[test]
    fn an_unusable_proxy_url_reads_as_no_proxy() {
        // The packaging script writes the entry unconditionally, so a build
        // with no proxy still has the key present and empty.
        assert_eq!(clean_proxy(Some("".into())), None);
        assert_eq!(clean_proxy(Some("  ".into())), None);
        assert_eq!(clean_proxy(Some("p.example".into())), None);
        assert_eq!(clean_proxy(Some("https://p.example/".into())), Some("https://p.example".into()));
    }

    /// The proxy's whole purpose, asserted against a real socket: a build
    /// pointed at one sends no credential anywhere. A regression here would
    /// not fail anything visible -- the rows would still load, because the
    /// key would still be attached -- it would just quietly put the key back
    /// on the wire from every install.
    #[tokio::test]
    async fn a_proxied_request_carries_no_credential_at_all() {
        use tokio::io::{AsyncReadExt, AsyncWriteExt};

        let listener = tokio::net::TcpListener::bind("127.0.0.1:0").await.unwrap();
        let port = listener.local_addr().unwrap().port();
        let server = tokio::spawn(async move {
            let (mut socket, _) = listener.accept().await.unwrap();
            let mut buf = vec![0u8; 4096];
            let read = socket.read(&mut buf).await.unwrap();
            let request = String::from_utf8_lossy(&buf[..read]).to_string();
            socket
                .write_all(
                    b"HTTP/1.1 200 OK\r\ncontent-type: application/json\r\ncontent-length: 2\r\n\r\n{}",
                )
                .await
                .unwrap();
            request
        });

        let client = TmdbClient::new(
            reqwest::Client::new(),
            None,
            Some(format!("http://127.0.0.1:{port}")),
        );
        let out: Result<serde_json::Value, String> = client.get("/movie/550", &[]).await;
        assert!(out.is_ok(), "proxied request failed: {out:?}");

        let request = server.await.unwrap().to_ascii_lowercase();
        assert!(request.starts_with("get /3/movie/550?"), "wrong path: {request}");
        assert!(!request.contains("api_key"), "the key must not reach the URL");
        assert!(!request.contains("authorization"), "no credential header either");
    }

    #[tokio::test]
    async fn a_request_with_no_key_and_no_proxy_fails_before_it_is_sent() {
        let client = TmdbClient::new(reqwest::Client::new(), None, None);
        let out: Result<serde_json::Value, String> = client.get("/movie/550", &[]).await;
        assert_eq!(out.unwrap_err(), "no_tmdb_token");
    }
}
