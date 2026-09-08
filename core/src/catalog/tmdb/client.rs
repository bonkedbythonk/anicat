//! TMDB's REST client.
//!
//! Deliberately thinner than `anilist::client`: TMDB is a plain REST API with
//! generous limits and no GraphQL envelope, so there is no query batching or
//! rate-limit backoff to model. What it does share is the token living behind
//! a lock, so Settings can paste a new one in without a restart.

use std::sync::Mutex;
use std::time::{Duration, Instant};

use serde::de::DeserializeOwned;

const TMDB_URL: &str = "https://api.themoviedb.org/3";

pub struct TmdbClient {
    client: reqwest::Client,
    token: Mutex<Option<String>>,
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
    pub fn new(client: reqwest::Client, token: Option<String>) -> Self {
        Self {
            client,
            token: Mutex::new(token.filter(|t| !t.trim().is_empty())),
            rate_limited_until: Mutex::new(None),
        }
    }

    pub fn set_token(&self, token: Option<String>) {
        if let Ok(mut t) = self.token.lock() {
            *t = token.filter(|t| !t.trim().is_empty());
        }
    }

    pub fn has_token(&self) -> bool {
        self.token.lock().map(|t| t.is_some()).unwrap_or(false)
    }

    /// GET a TMDB endpoint. `path` is everything after /3, starting with a
    /// slash; `query` is appended after the language parameter.
    pub async fn get<T: DeserializeOwned>(
        &self,
        path: &str,
        query: &[(&str, String)],
    ) -> Result<T, String> {
        let token = self
            .token
            .lock()
            .ok()
            .and_then(|t| t.clone())
            .ok_or_else(|| "no_tmdb_token".to_string())?;

        // One retry, and only for a 429. A throttled key is the one failure
        // that is certain to pass on its own, and letting the row fail instead
        // shows an empty shelf for something that would have answered a second
        // later. Anything else -- 401, 404, a network error -- is returned as
        // it was: retrying those is just a second request with the same
        // answer.
        for attempt in 0..2 {
            self.await_cooldown().await;
            match self.send(path, query, &token).await {
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
        token: &str,
    ) -> Result<T, TmdbFailure> {
        let mut request = self.client.get(format!("{}{}", TMDB_URL, path));

        let mut params: Vec<(String, String)> = vec![("language".into(), "en-US".into())];
        for (k, v) in query {
            params.push((k.to_string(), v.clone()));
        }
        if is_v4_token(token) {
            request = request.bearer_auth(token);
        } else {
            params.push(("api_key".into(), token.to_string()));
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
        let client = TmdbClient::new(reqwest::Client::new(), Some("   ".to_string()));
        assert!(!client.has_token());
        client.set_token(Some("".to_string()));
        assert!(!client.has_token());
        client.set_token(Some("0123456789abcdef0123456789abcdef".to_string()));
        assert!(client.has_token());
    }

    #[tokio::test]
    async fn a_request_without_a_token_fails_before_it_is_sent() {
        let client = TmdbClient::new(reqwest::Client::new(), None);
        let out: Result<serde_json::Value, String> = client.get("/movie/550", &[]).await;
        assert_eq!(out.unwrap_err(), "no_tmdb_token");
    }
}
