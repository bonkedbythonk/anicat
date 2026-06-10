use crate::state::AppState;
use tauri::State;

#[tauri::command]
pub async fn get_config(state: State<'_, AppState>) -> Result<serde_json::Value, String> {
    let config = state.config.read().await;
    serde_json::to_value(&*config).map_err(|e| e.to_string())
}

#[tauri::command]
pub async fn update_config(
    state: State<'_, AppState>,
    updates: serde_json::Value,
) -> Result<(), String> {
    let mut config = state.config.write().await;

    if let Some(obj) = updates.as_object() {
        for (key, value) in obj {
            match key.as_str() {
                "general.provider" => {
                    if let Some(v) = value.as_str() {
                        config.general.provider = v.to_string();
                    }
                }
                "general.autoplay" => {
                    if let Some(v) = value.as_bool() {
                        config.general.autoplay = v;
                    }
                }
                "general.autoskip" => {
                    if let Some(v) = value.as_bool() {
                        config.general.autoskip = v;
                    }
                }
                "general.anime_preview" => {
                    if let Some(v) = value.as_bool() {
                        config.general.anime_preview = v;
                    }
                }
                "general.preferred_title_language" => {
                    if let Some(v) = value.as_str() {
                        config.general.preferred_title_language = v.to_string();
                    }
                }
                "stream.player_type" => {
                    if let Some(v) = value.as_str() {
                        config.stream.player_type = v.to_string();
                    }
                }
                "stream.preferred_quality" => {
                    if let Some(v) = value.as_str() {
                        config.stream.preferred_quality = v.to_string();
                    }
                }
                "stream.data_saver" => {
                    if let Some(v) = value.as_bool() {
                        config.stream.data_saver = v;
                    }
                }
                "api.anilist_token" => {
                    config.api.anilist_token = value.as_str().map(|s| s.to_string());
                }
                _ => {}
            }
        }
    }

    state.save_config().await.map_err(|e| e.to_string())
}
