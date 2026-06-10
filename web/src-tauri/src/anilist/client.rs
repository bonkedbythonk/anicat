use std::collections::HashMap;

use serde::de::DeserializeOwned;
use log::debug;

use super::queries::GraphQLRequest;
use super::responses::AnilistResponse;

const ANILIST_URL: &str = "https://graphql.anilist.co";

#[derive(Debug, Clone)]
pub struct AniListClient {
    client: reqwest::Client,
    token: Option<String>,
}

impl AniListClient {
    pub fn new(client: reqwest::Client, token: Option<String>) -> Self {
        Self { client, token }
    }

    pub fn set_token(&mut self, token: Option<String>) {
        self.token = token;
    }

    pub fn has_token(&self) -> bool {
        self.token.is_some()
    }

    pub async fn execute<T: DeserializeOwned>(
        &self,
        query: &str,
        variables: HashMap<String, serde_json::Value>,
    ) -> Result<T, String> {
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

        if let Some(ref token) = self.token {
            req = req.header("Authorization", format!("Bearer {}", token));
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
            return Err(format!("AniList HTTP {}: {}", status.as_u16(), text));
        }

        let parsed: AnilistResponse<T> = serde_json::from_str(&text)
            .map_err(|e| format!("Failed to parse response: {}\nBody: {}", e, text))?;

        if let Some(errors) = parsed.errors {
            if !errors.is_empty() {
                let messages: Vec<&str> = errors.iter().map(|e| e.message.as_str()).collect();
                debug!("GraphQL errors: {:?}", messages);

                if messages.iter().any(|m| m.contains("Invalid token") || m.contains("authentication")) {
                    return Err("AniList authentication invalid. Please re-login.".to_string());
                }
                return Err(format!("GraphQL error: {}", messages.join("; ")));
            }
        }

        parsed.data.ok_or_else(|| "No data in response".to_string())
    }
}
