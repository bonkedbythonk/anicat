use std::collections::HashMap;

use serde::Serialize;
use serde_json::Value;
use tauri::State;

use crate::scraper::StreamServer;
use crate::state::AppState;

#[derive(Serialize)]
pub struct PlaybackStart {
    pub stream_url: String,
    pub servers: Vec<StreamServer>,
}

#[tauri::command]
pub async fn start_playback(
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

    // Pick the first server as the initial stream
    let stream_url = servers
        .first()
        .map(|s| s.url.clone())
        .unwrap_or_default();

    Ok(PlaybackStart { stream_url, servers })
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
