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
                if let Some(ref name_str) = name {
                    let mut config = state.inner.config.write().await;
                    if config.api.anilist_username.as_ref() != Some(name_str) {
                        config.api.anilist_username = Some(name_str.clone());
                        drop(config);
                        let _ = state.save_config().await;
                    }
                }
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
    if !url.starts_with("http://") && !url.starts_with("https://") {
        return Err("Only http and https URLs are allowed".to_string());
    }
    open::that(&url).map_err(|e| e.to_string())?;
    Ok(())
}

#[derive(Serialize)]
pub struct UpdateCheckResponse {
    pub current_version: String,
}

#[tauri::command]
pub async fn check_update(_state: State<'_, AppState>) -> Result<UpdateCheckResponse, String> {
    let current_version = env!("CARGO_PKG_VERSION").to_string();
    Ok(UpdateCheckResponse { current_version })
}

#[tauri::command]
pub async fn trigger_update(url: String) -> Result<(), String> {
    if !url.contains("github.com/bonkedbythonk/anicat/releases") && !url.contains(".dmg") {
        return Err("Invalid update URL".to_string());
    }

    let tmp_dir = std::env::temp_dir().join("anicat_update");
    std::fs::create_dir_all(&tmp_dir).map_err(|e| e.to_string())?;
    let dmg_path = tmp_dir.join("Anicat.dmg");

    // Download the DMG
    log::info!("Downloading update from {}", url);
    let resp = reqwest::get(&url)
        .await
        .map_err(|e| format!("Failed to download update: {}", e))?;
    let bytes = resp.bytes()
        .await
        .map_err(|e| format!("Failed to read download: {}", e))?;
    std::fs::write(&dmg_path, &bytes).map_err(|e| e.to_string())?;
    log::info!("Downloaded {} bytes to {:?}", bytes.len(), dmg_path);

    // Mount the DMG
    let mount_output = std::process::Command::new("hdiutil")
        .args(["attach", "-nobrowse", "-noautoopen"])
        .arg(&dmg_path)
        .output()
        .map_err(|e| format!("Failed to mount DMG: {}", e))?;
    let mount_output_str = String::from_utf8_lossy(&mount_output.stdout);
    log::info!("hdiutil attach: {}", mount_output_str);

    // Parse the mount point from hdiutil output: "/Volumes/Anicat 5.1.1"
    let mount_point = mount_output_str
        .lines()
        .find_map(|line| {
            let parts: Vec<&str> = line.split_whitespace().collect();
            if parts.len() >= 3 {
                Some(parts.last().unwrap_or(&"").to_string())
            } else {
                None
            }
        })
        .ok_or_else(|| "Could not find mount point".to_string())?;
    log::info!("DMG mounted at: {}", mount_point);

    // Find the .app in the mounted volume
    let app_path = format!("{}/Anicat.app", mount_point);
    if !std::path::Path::new(&app_path).exists() {
        let _ = std::process::Command::new("hdiutil")
            .args(["detach", &mount_point, "-quiet"])
            .output();
        return Err("Anicat.app not found in DMG".to_string());
    }

    // Copy over the existing installation
    let dst = "/Applications/Anicat.app";
    log::info!("Copying {} to {}", app_path, dst);
    let copy_output = std::process::Command::new("ditto")
        .args([&app_path, dst])
        .output()
        .map_err(|e| format!("Failed to copy app: {}", e))?;
    if !copy_output.status.success() {
        let stderr = String::from_utf8_lossy(&copy_output.stderr);
        let _ = std::process::Command::new("hdiutil")
            .args(["detach", &mount_point, "-quiet"])
            .output();
        return Err(format!("Failed to copy app: {}", stderr));
    }

    // Remove quarantine
    let _ = std::process::Command::new("xattr")
        .args(["-dr", "com.apple.quarantine", dst])
        .output();

    // Unmount DMG
    let _ = std::process::Command::new("hdiutil")
        .args(["detach", &mount_point, "-quiet"])
        .output();

    // Clean up temp files
    let _ = std::fs::remove_dir_all(&tmp_dir);

    log::info!("Update installed successfully to {}", dst);
    Ok(())
}
