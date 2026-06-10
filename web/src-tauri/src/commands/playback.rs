use std::collections::HashMap;

use serde_json::Value;
use tauri::State;

use crate::state::AppState;

#[tauri::command]
pub async fn track_playback(
    state: State<'_, AppState>,
    media_id: i64,
    episode_number: i64,
    stop_time: i64,
    duration: i64,
) -> Result<(), String> {
    // Record locally
    let db = state.open_db()?;
    let _ = crate::registry::service::record_watched_episode(
        &db, media_id, episode_number, stop_time, duration,
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

#[tauri::command]
pub async fn get_watched_episodes(
    state: State<'_, AppState>,
    media_id: i64,
) -> Result<Vec<(i64, i64, i64)>, String> {
    let db = state.open_db()?;
    crate::registry::service::get_watched_episodes(&db, media_id)
}
