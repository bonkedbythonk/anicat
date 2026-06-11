use std::collections::HashMap;
use std::sync::{Arc, Mutex};
use std::time::{Duration, Instant};

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
            request_lock: Arc::new(tokio::sync::Semaphore::new(1)),
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

        let resp = req
            .send()
            .await
            .map_err(|e| format!("AniList request failed: {}", e))?;

        let status = resp.status();
        let text = resp
            .text()
            .await
            .map_err(|e| format!("Failed to read response: {}", e))?;

        if !status.is_success() {
            if status.as_u16() == 429 {
                let mut rl = self.rate_limited_until.lock().unwrap();
                *rl = Some(Instant::now() + Duration::from_secs(60));
                return Err("AniList HTTP 429: Too Many Requests — cooling down 60s".to_string());
            }
            return Err(format!("AniList HTTP {}: {}", status.as_u16(), text));
        }

        tokio::time::sleep(Duration::from_millis(150)).await;

        let parsed: AnilistResponse<T> = serde_json::from_str(&text)
            .map_err(|e| format!("Failed to parse response: {}\nBody: {}", e, text))?;

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
