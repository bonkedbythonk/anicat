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
    query_cache: Arc<Mutex<HashMap<String, String>>>,
}

impl Clone for AniListClient {
    fn clone(&self) -> Self {
        Self {
            client: self.client.clone(),
            token: Mutex::new(self.token.lock().unwrap().clone()),
            username: Mutex::new(self.username.lock().unwrap().clone()),
            rate_limited_until: Mutex::new(*self.rate_limited_until.lock().unwrap()),
            request_lock: self.request_lock.clone(),
            query_cache: self.query_cache.clone(),
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
            query_cache: Arc::new(Mutex::new(HashMap::new())),
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

    fn cache_key(query: &str, variables: &HashMap<String, serde_json::Value>) -> String {
        use std::hash::{Hash, Hasher};
        let mut hasher = std::collections::hash_map::DefaultHasher::new();
        query.hash(&mut hasher);
        let vars_serialized = serde_json::to_string(variables).unwrap_or_else(|_| "{}".to_string());
        vars_serialized.hash(&mut hasher);
        format!("{:x}", hasher.finish())
    }

    pub async fn execute<T: DeserializeOwned>(
        &self,
        query: &str,
        variables: HashMap<String, serde_json::Value>,
    ) -> Result<T, String> {
        let ck = Self::cache_key(query, &variables);
        {
            let cache = self.query_cache.lock().unwrap();
            if let Some(cached) = cache.get(&ck) {
                if let Ok(parsed) = serde_json::from_str::<AnilistResponse<T>>(cached) {
                    if let Some(data) = parsed.data {
                        log::info!("AniList cache hit for query");
                        return Ok(data);
                    }
                }
            }
        }

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
        let text = resp
            .text()
            .await
            .map_err(|e| {
                log::error!("Failed to read AniList response body: {}", e);
                format!("Failed to read response: {}", e)
            })?;

        if !status.is_success() {
            log::error!("AniList request failed with status {}: {}", status.as_u16(), text);
            if status.as_u16() == 429 {
                let mut rl = self.rate_limited_until.lock().unwrap();
                *rl = Some(Instant::now() + std::time::Duration::from_secs(60));
                return Err("AniList HTTP 429: Too Many Requests — cooling down 60s".to_string());
            }
            return Err(format!("AniList HTTP {}: {}", status.as_u16(), text));
        }

        log::info!("AniList request succeeded (HTTP {})", status.as_u16());

        {
            if let Ok(mut cache) = self.query_cache.lock() {
                cache.insert(ck, text.clone());
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
