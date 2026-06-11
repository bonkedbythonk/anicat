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
    pub auth_error: Option<String>,
}

#[tauri::command]
pub async fn check_health(state: State<'_, AppState>) -> Result<HealthResponse, String> {
    let token_present = state.anilist_client.has_token();
    let (authenticated, viewer_name, auth_error) = if token_present {
        match state
            .anilist_client
            .execute::<serde_json::Value>(crate::anilist::queries::HEALTH_CHECK_QUERY, HashMap::new())
            .await
        {
            Ok(data) => {
                let name = data
                    .get("Viewer")
                    .and_then(|v| v.get("name"))
                    .and_then(|v| v.as_str())
                    .map(|s| s.to_string());
                log::info!("AniList health check successful: viewer={:?}", name);
                (true, name, None)
            }
            Err(e) => {
                log::warn!("AniList health check failed: {}", e);
                state.anilist_client.set_token(None);
                (false, None, Some(e))
            }
        }
    } else {
        (false, None, None)
    };

    Ok(HealthResponse {
        connected: true,
        authenticated,
        offline: false,
        data_version: 1,
        token_present,
        viewer_name,
        auth_error,
    })
}

#[tauri::command]
pub async fn get_app_version() -> String {
    env!("CARGO_PKG_VERSION").to_string()
}
