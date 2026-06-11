use serde::Serialize;
use std::collections::HashMap;
use tauri::State;

use crate::state::AppState;

#[derive(Serialize)]
pub struct HealthResponse {
    pub connected: bool,
    pub authenticated: bool,
    pub offline: bool,
    pub data_version: i64,
    pub token_present: bool,
    pub viewer_name: Option<String>,
}

#[tauri::command]
pub async fn check_health(state: State<'_, AppState>) -> Result<HealthResponse, String> {
    let token_present = state.anilist_client.has_token();
    let (authenticated, viewer_name) = if token_present {
        let mut vars = HashMap::new();
        vars.insert("name".to_string(), serde_json::json!(true));

        match state
            .anilist_client
            .execute::<serde_json::Value>(crate::anilist::queries::HEALTH_CHECK_QUERY, vars)
            .await
        {
            Ok(data) => {
                let name = data
                    .get("Viewer")
                    .and_then(|v| v.get("name"))
                    .and_then(|v| v.as_str())
                    .map(|s| s.to_string());
                (true, name)
            }
            Err(e) => {
                log::warn!("AniList health check failed: {}", e);
                // Clear invalid token
                state.anilist_client.set_token(None);
                (false, None)
            }
        }
    } else {
        (false, None)
    };

    Ok(HealthResponse {
        connected: true,
        authenticated,
        offline: false,
        data_version: 1,
        token_present,
        viewer_name,
    })
}

#[tauri::command]
pub async fn get_app_version() -> String {
    env!("CARGO_PKG_VERSION").to_string()
}
