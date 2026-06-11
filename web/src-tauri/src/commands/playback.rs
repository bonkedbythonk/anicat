use std::collections::HashMap;

use serde::Serialize;
use serde_json::Value;
use tauri::{AppHandle, Manager, State};

use crate::state::AppState;

/// Holds a reference to the currently running mpv child so we can
/// check its status and kill it from stop_playback.
static CURRENT_MPV: std::sync::Mutex<Option<tokio::process::Child>> = std::sync::Mutex::new(None);

#[derive(Serialize)]
pub struct PlaybackStart {
    pub stream_url: String,
}

fn resolve_mpv_path(app: &AppHandle) -> Result<(String, String, String), String> {
    let resource_dir = app.path().resource_dir().map_err(|e| e.to_string())?;

    let mpv_name = if cfg!(target_os = "windows") {
        "mpv.exe"
    } else {
        "mpv"
    };
    let mpv_bin = resource_dir.join(mpv_name);
    if !mpv_bin.exists() {
        // Dev mode fallback: look relative to CARGO_MANIFEST_DIR
        let dev_path = std::path::Path::new(env!("CARGO_MANIFEST_DIR"))
            .join("resources")
            .join(mpv_name);
        if dev_path.exists() {
            let config_dir = std::path::Path::new(env!("CARGO_MANIFEST_DIR"))
                .join("resources")
                .join("mpv_config");
            let lib_dir = std::path::Path::new(env!("CARGO_MANIFEST_DIR"))
                .join("resources")
                .join("lib");
            return Ok((
                dev_path.to_string_lossy().to_string(),
                config_dir.to_string_lossy().to_string(),
                lib_dir.to_string_lossy().to_string(),
            ));
        }
        return Err(format!(
            "mpv binary not found at {} or in dev resources",
            mpv_bin.display()
        ));
    }

    let config_dir = resource_dir.join("mpv_config");
    let lib_dir = resource_dir.join("lib");

    Ok((
        mpv_bin.to_string_lossy().to_string(),
        config_dir.to_string_lossy().to_string(),
        lib_dir.to_string_lossy().to_string(),
    ))
}

#[tauri::command]
pub async fn start_playback(
    app: AppHandle,
    state: State<'_, AppState>,
    media_id: i64,
    episode_number: i64,
    provider: Option<String>,
) -> Result<PlaybackStart, String> {
    let provider_name = provider.unwrap_or_else(|| "anineko".to_string());

    let db = state.open_db()?;

    let slug = crate::registry::service::get_provider_slug(&db, media_id, &provider_name)
        .ok_or_else(|| format!("No provider mapping for media {}", media_id))?;

    let servers = state
        .scraper_manager
        .get_streams(&slug, episode_number as i32)
        .await?;

    let stream_url = servers
        .first()
        .map(|s| s.url.clone())
        .unwrap_or_default();

    if stream_url.is_empty() {
        return Err("No stream URL found".to_string());
    }

    let (mpv_bin, config_dir, lib_dir) = resolve_mpv_path(&app)?;
    log::info!("mpv binary: {}", mpv_bin);
    log::info!("mpv config: {}", config_dir);
    log::info!("mpv lib dir: {}", lib_dir);

    let mut cmd = tokio::process::Command::new(&mpv_bin);
    cmd.arg(format!("--config-dir={}", config_dir));
    cmd.arg("--force-window=yes");
    cmd.arg("--ontop");
    cmd.arg(&stream_url);

    // Set library path for macOS .dylibs
    if cfg!(target_os = "macos") {
        cmd.env("DYLD_LIBRARY_PATH", &lib_dir);
    }
    if cfg!(target_os = "linux") {
        cmd.env("LD_LIBRARY_PATH", &lib_dir);
    }

    let mut child = cmd
        .spawn()
        .map_err(|e| format!("Failed to launch mpv: {}", e))?;

    let pid = child.id().unwrap_or(0);
    log::info!("Launched mpv pid={} with stream: {}", pid, stream_url);

    // Check if mpv exits immediately (crashes)
    tokio::time::sleep(std::time::Duration::from_millis(500)).await;
    match child.try_wait() {
        Ok(Some(status)) => {
            log::error!("mpv exited immediately with status {:?}", status);
            return Err(format!("mpv exited immediately: {:?}", status));
        }
        Ok(None) => {
            log::info!("mpv pid={} is running", pid);
        }
        Err(e) => {
            log::warn!("Failed to check mpv status: {}", e);
        }
    }

    // Store child handle
    if let Ok(mut guard) = CURRENT_MPV.lock() {
        *guard = Some(child);
    }

    Ok(PlaybackStart { stream_url })
}

#[tauri::command]
pub async fn stop_playback(
    state: State<'_, AppState>,
    media_id: i64,
    episode_number: i64,
    stop_time: i64,
    duration: i64,
) -> Result<(), String> {
    // Record locally
    let db = state.open_db()?;
    let _ = crate::registry::service::record_watched_episode(
        &db,
        media_id,
        episode_number,
        stop_time,
        duration,
    );

    // Update AniList if episode is sufficiently watched
    if duration > 0 {
        let percentage = (stop_time as f64 / duration as f64) * 100.0;
        if percentage >= 80.0 {
            let mut vars = HashMap::new();
            vars.insert("mediaId".to_string(), serde_json::json!(media_id));
            vars.insert(
                "progress".to_string(),
                serde_json::json!(episode_number),
            );

            let _: Value = state
                .anilist_client
                .execute(
                    crate::anilist::queries::SAVE_MEDIA_LIST_ENTRY_MUTATION,
                    vars,
                )
                .await?;
        }
    }

    Ok(())
}

use crate::registry::WatchEntry;

#[tauri::command]
pub async fn get_watched_episodes(
    state: State<'_, AppState>,
    media_id: i64,
) -> Result<Vec<WatchEntry>, String> {
    let db = state.open_db()?;
    crate::registry::service::get_watched_episodes(&db, media_id)
}
