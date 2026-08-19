//! TMDB's REST client.
//!
//! Deliberately thinner than `anilist::client`: TMDB is a plain REST API with
//! generous limits and no GraphQL envelope, so there is no query batching or
//! rate-limit backoff to model. What it does share is the token living behind
//! a lock, so Settings can paste a new one in without a restart.

use std::sync::Mutex;

use serde::de::DeserializeOwned;

const TMDB_URL: &str = "https://api.themoviedb.org/3";

pub struct TmdbClient {
    client: reqwest::Client,
    token: Mutex<Option<String>>,
}

impl Clone for TmdbClient {
    fn clone(&self) -> Self {
        Self {
            client: self.client.clone(),
            token: Mutex::new(self.token.lock().unwrap().clone()),
        }
    }
}

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

        let mut request = self.client.get(format!("{}{}", TMDB_URL, path));

        let mut params: Vec<(String, String)> = vec![("language".into(), "en-US".into())];
        for (k, v) in query {
            params.push((k.to_string(), v.clone()));
        }
        if is_v4_token(&token) {
            request = request.bearer_auth(&token);
        } else {
            params.push(("api_key".into(), token.clone()));
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
            .map_err(|e| format!("tmdb request failed: {}", e))?;

        let status = response.status();
        if !status.is_success() {
            // 401 is the one a user can actually fix, and it is the one they
            // will hit first, so it gets a name the UI can match on rather
            // than a status code buried in a string.
            if status == reqwest::StatusCode::UNAUTHORIZED {
                log::warn!("tmdb: rejected the token for {}", path);
                return Err("tmdb_unauthorized".to_string());
            }
            log::warn!("tmdb: {} returned HTTP {}", path, status);
            return Err(format!("tmdb returned HTTP {}", status));
        }

        response
            .json::<T>()
            .await
            .map_err(|e| format!("tmdb response did not parse: {}", e))
    }
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
