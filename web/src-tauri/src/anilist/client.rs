use std::collections::HashMap;
use std::sync::{Arc, Mutex};
use std::time::Instant;

use serde::de::DeserializeOwned;
use log::debug;

use super::queries::GraphQLRequest;
use super::responses::AnilistResponse;

const ANILIST_URL: &str = "https://graphql.anilist.co";

pub struct AniListClient {
    client: reqwest::Client,
    token: Mutex<Option<String>>,
    username: Mutex<Option<String>>,
    rate_limited_until: Mutex<Option<Instant>>,
    request_lock: Arc<tokio::sync::Semaphore>,
}

impl Clone for AniListClient {
    fn clone(&self) -> Self {
        Self {
            client: self.client.clone(),
            token: Mutex::new(self.token.lock().unwrap().clone()),
            username: Mutex::new(self.username.lock().unwrap().clone()),
            rate_limited_until: Mutex::new(*self.rate_limited_until.lock().unwrap()),
            request_lock: self.request_lock.clone(),
        }
    }
}

impl AniListClient {
    pub fn new(client: reqwest::Client, token: Option<String>) -> Self {
        Self {
            client,
            token: Mutex::new(token),
            username: Mutex::new(None),
            rate_limited_until: Mutex::new(None),
            request_lock: Arc::new(tokio::sync::Semaphore::new(3)),
        }
    }

    pub fn set_token(&self, token: Option<String>) {
        if let Ok(mut t) = self.token.lock() {
            *t = token;
        }
        if let Ok(mut u) = self.username.lock() {
            *u = None;
        }
    }

    pub fn has_token(&self) -> bool {
        self.token.lock().map(|t| t.is_some()).unwrap_or(false)
    }

    pub fn set_username(&self, username: Option<String>) {
        if let Ok(mut u) = self.username.lock() {
            *u = username;
        }
    }

    pub fn get_username(&self) -> Option<String> {
        self.username.lock().ok().and_then(|u| u.clone())
    }

    pub async fn execute<T: DeserializeOwned>(
        &self,
        query: &str,
        variables: HashMap<String, serde_json::Value>,
    ) -> Result<T, String> {
        {
            let wait_duration = {
                let rl = self.rate_limited_until.lock().unwrap();
                rl.and_then(|until| {
                    if Instant::now() < until {
                        Some(until.duration_since(Instant::now()))
                    } else {
                        None
                    }
                })
            };
            if let Some(wait) = wait_duration {
                log::warn!("AniList rate limited, waiting {:?} before proceeding", wait);
                tokio::time::sleep(wait).await;
            }
        }

        let _permit = self.request_lock.acquire().await.map_err(|e| format!("Semaphore error: {}", e))?;

        let vars_str = serde_json::to_string(&variables).unwrap_or_else(|_| "{}".to_string());
        let body = GraphQLRequest {
            query: query.to_string(),
            variables,
        };

        let mut req = self
            .client
            .post(ANILIST_URL)
            .json(&body)
            .header("Content-Type", "application/json")
            .header("Accept", "application/json");

        if let Ok(guard) = self.token.lock() {
            if let Some(ref token) = *guard {
                req = req.header("Authorization", format!("Bearer {}", token));
            }
        }

        let query_first_line = query.lines().map(|s| s.trim()).find(|s| !s.is_empty()).unwrap_or("");
        log::info!("Sending request to AniList API: query='{}' variables={}", query_first_line, vars_str);
        let resp = req
            .send()
            .await
            .map_err(|e| {
                log::error!("AniList request connection failed: {}", e);
                format!("AniList request failed: {}", e)
            })?;

        let status = resp.status();
        // Capture headers before consuming the body — the rate-limit headers
        // (Retry-After, X-RateLimit-Remaining) live here and reqwest moves
        // `resp` into `.text()`.
        let headers = resp.headers().clone();
        let text = resp
            .text()
            .await
            .map_err(|e| {
                log::error!("Failed to read AniList response body: {}", e);
                format!("Failed to read response: {}", e)
            })?;

        let header_secs = |name: &str| -> Option<u64> {
            headers.get(name).and_then(|v| v.to_str().ok()).and_then(|s| s.trim().parse::<u64>().ok())
        };

        if !status.is_success() {
            log::error!("AniList request failed with status {}: {}", status.as_u16(), text);
            if status.as_u16() == 429 {
                // Honor the server's Retry-After when present instead of always
                // guessing 60s — AniList sets it to the exact cooldown, so we
                // resume as early as allowed rather than over-waiting.
                let cooldown = header_secs("retry-after").unwrap_or(60).clamp(1, 300);
                let mut rl = self.rate_limited_until.lock().unwrap();
                *rl = Some(Instant::now() + std::time::Duration::from_secs(cooldown));
                return Err(format!("AniList HTTP 429: Too Many Requests — cooling down {}s", cooldown));
            }
            // Extract the human-readable message from the GraphQL error body
            // (AniList returns JSON even for 4xx, e.g. downtime 403).
            if let Ok(val) = serde_json::from_str::<serde_json::Value>(&text) {
                if let Some(msg) = val["errors"][0]["message"].as_str() {
                    return Err(format!("anilist_down:{}", msg));
                }
            }
            return Err(format!("AniList HTTP {}: {}", status.as_u16(), text));
        }

        log::info!("AniList request succeeded (HTTP {})", status.as_u16());

        // Proactive throttle: when the remaining budget for this window runs
        // low, insert a short cooldown so the next requests spread out instead
        // of sprinting into a 429. Cheap insurance on top of the client-side
        // query cache — most requests report plenty of headroom and skip this.
        if let Some(remaining) = header_secs("x-ratelimit-remaining") {
            if remaining <= 3 {
                let mut rl = self.rate_limited_until.lock().unwrap();
                let backoff = Instant::now() + std::time::Duration::from_secs(2);
                if rl.map(|until| until < backoff).unwrap_or(true) {
                    *rl = Some(backoff);
                }
                log::warn!("AniList rate budget low ({} left) — spacing next request by 2s", remaining);
            }
        }

        let parsed: AnilistResponse<T> = serde_json::from_str(&text)
            .map_err(|e| {
                log::error!("Failed to parse AniList response JSON: {}, body: {}", e, text);
                format!("Failed to parse response: {}\nBody: {}", e, text)
            })?;

        if let Some(errors) = parsed.errors {
            if !errors.is_empty() {
                let messages: Vec<&str> = errors.iter().map(|e| e.message.as_str()).collect();
                debug!("GraphQL errors: {:?}", messages);

                if messages
                    .iter()
                    .any(|m| m.contains("Invalid token") || m.contains("authentication"))
                {
                    return Err("AniList authentication invalid. Please re-login.".to_string());
                }
                return Err(format!("GraphQL error: {}", messages.join("; ")));
            }
        }

        parsed.data.ok_or_else(|| "No data in response".to_string())
    }
}
