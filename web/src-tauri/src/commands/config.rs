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
                "general" => {
                    if let Some(gen) = value.as_object() {
                        if let Some(v) = gen.get("provider").and_then(|v| v.as_str()) {
                            config.general.provider = v.to_string();
                        }
                        if let Some(v) = gen.get("autoplay").and_then(|v| v.as_bool()) {
                            config.general.autoplay = v;
                        }
                        if let Some(v) = gen.get("autoskip").and_then(|v| v.as_bool()) {
                            config.general.autoskip = v;
                        }
                        if let Some(v) = gen.get("anime_preview").and_then(|v| v.as_bool()) {
                            config.general.anime_preview = v;
                        }
                        if let Some(v) = gen.get("preferred_title_language").and_then(|v| v.as_str()) {
                            config.general.preferred_title_language = v.to_string();
                        }
                        if let Some(v) = gen.get("time_format").and_then(|v| v.as_str()) {
                            config.general.time_format = v.to_string();
                        }
                        if let Some(v) = gen.get("discord").and_then(|v| v.as_bool()) {
                            config.general.discord = v;
                            if v {
                                state.discord.connect();
                            } else {
                                state.discord.disconnect();
                            }
                        }
                        if let Some(v) = gen.get("media_api").and_then(|v| v.as_str()) {
                            config.general.media_api = v.to_string();
                        }
                        if let Some(v) = gen.get("manga_provider").and_then(|v| v.as_str()) {
                            config.general.manga_provider = v.to_string();
                        }
                        if let Some(v) = gen.get("update_branch").and_then(|v| v.as_str()) {
                            config.general.update_branch = v.to_string();
                        }
                        if let Some(v) = gen.get("downloads_path").and_then(|v| v.as_str()) {
                            config.general.downloads_path = v.to_string();
                        }
                    }
                }
                "stream" => {
                    if let Some(stream) = value.as_object() {
                        if let Some(v) = stream.get("player_type").and_then(|v| v.as_str()) {
                            config.stream.player_type = v.to_string();
                        }
                        if let Some(v) = stream.get("preferred_quality").and_then(|v| v.as_str()) {
                            config.stream.preferred_quality = v.to_string();
                        }
                        if let Some(v) = stream.get("data_saver").and_then(|v| v.as_bool()) {
                            config.stream.data_saver = v;
                        }
                        if let Some(v) = stream.get("shader_profile").and_then(|v| v.as_str()) {
                            config.stream.shader_profile = v.to_string();
                        }
                        if let Some(v) = stream.get("translation_type").and_then(|v| v.as_str()) {
                            config.stream.translation_type = v.to_string();
                        }
                    }
                }
                "api.anilist_token" => {
                    let token = value.as_str().map(|s| s.to_string());
                    let t = if token.as_deref() == Some("") { None } else { token };
                    config.api.anilist_token = t.clone();
                    state.anilist_client.set_token(t);
                }
                "api" => {
                    if let Some(api_obj) = value.as_object() {
                        if let Some(token) = api_obj.get("token").or_else(|| api_obj.get("anilist_token")).and_then(|v| v.as_str()) {
                            let t = if token.is_empty() { None } else { Some(token.to_string()) };
                            config.api.anilist_token = t.clone();
                            state.anilist_client.set_token(t);
                        }
                    }
                }
                "anilist" => {
                    if let Some(obj) = value.as_object() {
                        if let Some(token) = obj.get("token").and_then(|v| v.as_str()) {
                            let t = if token.is_empty() { None } else { Some(token.to_string()) };
                            config.api.anilist_token = t.clone();
                            state.anilist_client.set_token(t);
                        }
                    }
                }
                _ => {}
            }
        }
    }

    // Drop write lock before saving (save_config acquires its own read lock)
    drop(config);
    state.save_config().await.map_err(|e| e.to_string())
}
