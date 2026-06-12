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
    pub current_version: String,
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
                state.anilist_client.set_username(name.clone());
                (true, name, None)
            }
            Err(e) => {
                log::warn!("[RUST:check_health] failed error: {}", e);
                log::warn!("AniList health check failed: {}", e);
                if e.contains("authentication invalid") || e.contains("Invalid token") {
                    state.anilist_client.set_token(None);
                }
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
        current_version: env!("CARGO_PKG_VERSION").to_string(),
    })
}

#[tauri::command]
pub async fn get_app_version() -> String {
    env!("CARGO_PKG_VERSION").to_string()
}

#[tauri::command]
pub fn log_frontend(level: String, message: String) {
    match level.as_str() {
        "error" => log::error!("[FRONTEND] {}", message),
        "warn" => log::warn!("[FRONTEND] {}", message),
        _ => log::info!("[FRONTEND] {}", message),
    }
}

#[tauri::command]
pub async fn get_logs(app: tauri::AppHandle, limit: Option<usize>) -> Result<String, String> {
    use tauri::Manager;
    let log_dir = app.path().app_log_dir().map_err(|e| e.to_string())?;
    let log_file = log_dir.join("Anicat.log");
    
    let content = if log_file.exists() {
        std::fs::read_to_string(&log_file).map_err(|e| e.to_string())?
    } else {
        let log_file_lower = log_dir.join("anicat.log");
        if log_file_lower.exists() {
            std::fs::read_to_string(&log_file_lower).map_err(|e| e.to_string())?
        } else {
            let mut found_content = None;
            if let Ok(entries) = std::fs::read_dir(&log_dir) {
                for entry in entries.flatten() {
                    if entry.path().extension().map_or(false, |ext| ext == "log") {
                        if let Ok(c) = std::fs::read_to_string(entry.path()) {
                            found_content = Some(c);
                            break;
                        }
                    }
                }
            }
            found_content.ok_or_else(|| "No log files found".to_string())?
        }
    };

    if let Some(lim) = limit {
        let lines: Vec<&str> = content.lines().collect();
        let start = lines.len().saturating_sub(lim);
        Ok(lines[start..].join("\n"))
    } else {
        Ok(content)
    }
}

#[tauri::command]
pub async fn open_logs_folder(app: tauri::AppHandle) -> Result<(), String> {
    use tauri::Manager;
    let log_dir = app.path().app_log_dir().map_err(|e| e.to_string())?;
    if !log_dir.exists() {
        std::fs::create_dir_all(&log_dir).map_err(|e| e.to_string())?;
    }
    #[cfg(target_os = "macos")]
    {
        std::process::Command::new("open")
            .arg(&log_dir)
            .spawn()
            .map_err(|e| e.to_string())?;
    }
    #[cfg(not(target_os = "macos"))]
    {
        open::that(&log_dir).map_err(|e| e.to_string())?;
    }
    Ok(())
}

#[tauri::command]
pub async fn open_in_browser(url: String) -> Result<(), String> {
    open::that(&url).map_err(|e| e.to_string())?;
    Ok(())
}
