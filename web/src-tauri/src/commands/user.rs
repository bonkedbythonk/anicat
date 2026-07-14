use std::collections::HashMap;

use serde_json::Value;
use tauri::State;

use crate::anilist::queries;
use crate::cache::AniListCache;
use crate::state::AppState;

#[tauri::command]
pub async fn get_user_list(
    state: State<'_, AppState>,
    user_name: Option<String>,
    status: Option<String>,
    media_type: Option<String>,
) -> Result<Value, String> {
    get_user_list_impl(state.inner(), user_name, status, media_type).await
}

pub async fn get_user_list_impl(
    state: &AppState,
    user_name: Option<String>,
    status: Option<String>,
    media_type: Option<String>,
) -> Result<Value, String> {
    let resolved_type = media_type.clone().unwrap_or_else(|| "ANIME".to_string());

    // Acquire lock to prevent concurrent redundant fetches (coalescing)
    let _lock = state.inner.user_list_lock.lock().await;

    // Cache key for the unified/full list collection containing all statuses
    let cache_key_all = AniListCache::key("get_user_list", &[
        ("status", "all"),
        ("type", &resolved_type),
    ]);

    let full_collection = match state.cache.get(&cache_key_all) {
        Some(cached) => cached,
        None => {
            // Resolve authenticated Viewer username if user_name is not specified
            let mut resolved_user_name = user_name.clone();
            if resolved_user_name.is_none() || resolved_user_name.as_ref().map(|s| s.is_empty()).unwrap_or(false) {
                if let Some(cached_name) = state.anilist_client.get_username() {
                    resolved_user_name = Some(cached_name);
                } else {
                    let profile_result: Value = state
                        .anilist_client
                        .execute(queries::USER_PROFILE_QUERY, HashMap::new())
                        .await?;
                    if let Some(name) = profile_result.get("Viewer").and_then(|v| v.get("name")).and_then(|n| n.as_str()) {
                        let name_str = name.to_string();
                        state.anilist_client.set_username(Some(name_str.clone()));
                        // Save username to configuration
                        let mut config = state.inner.config.write().await;
                        if config.api.anilist_username.as_ref() != Some(&name_str) {
                            config.api.anilist_username = Some(name_str.clone());
                            drop(config);
                            let _ = state.save_config().await;
                        }
                        resolved_user_name = Some(name_str);
                    } else {
                        return Err("Failed to resolve authenticated Viewer username".to_string());
                    }
                }
            }

            let mut vars = HashMap::new();
            if let Some(ref name) = resolved_user_name {
                vars.insert("userName".to_string(), serde_json::json!(name));
            }
            vars.insert("type".to_string(), serde_json::json!(resolved_type));
            // Most recently updated entry first within each status — for
            // "watching" that's whatever you last made progress on, for
            // "completed" that's whatever you most recently finished.
            vars.insert("sort".to_string(), serde_json::json!(["UPDATED_TIME_DESC"]));

            let result: Value = state
                .anilist_client
                .execute(queries::USER_LIST_QUERY, vars)
                .await?;

            if let Some(lists) = result.get("MediaListCollection").and_then(|m| m.get("lists")).and_then(|l| l.as_array()) {
                for (idx, list) in lists.iter().enumerate() {
                    let name = list.get("name").and_then(|n| n.as_str()).unwrap_or("");
                    let entries = list.get("entries").and_then(|e| e.as_array()).map(|a| a.len()).unwrap_or(0);
                    log::info!("  List[{}]: name={}, entries={}", idx, name, entries);
                }
            }

            state.cache.set(cache_key_all.clone(), result.clone(), "get_user_list");
            result
        }
    };

    // Release the lock early before processing and filtering the JSON
    drop(_lock);

    // If a specific status is requested, filter in-place to keep only the matching list
    if let Some(ref target_status) = status {
        let mut filtered_collection = full_collection;
        if let Some(mlc) = filtered_collection.get_mut("MediaListCollection") {
            if let Some(lists) = mlc.get_mut("lists") {
                if let Some(lists_arr) = lists.as_array_mut() {
                    let target_upper = target_status.to_uppercase();
                    lists_arr.retain(|list_val| {
                        if let Some(list_status) = list_val.get("status").and_then(|s| s.as_str()) {
                            list_status.to_uppercase() == target_upper
                        } else {
                            false
                        }
                    });
                }
            }
        }
        Ok(filtered_collection)
    } else {
        Ok(full_collection)
    }
}

#[tauri::command]
pub async fn get_user_profile(state: State<'_, AppState>) -> Result<Value, String> {
    get_user_profile_impl(state.inner()).await
}

pub async fn get_user_profile_impl(state: &AppState) -> Result<Value, String> {
    let cache_key = "get_user_profile|default".to_string();
    if let Some(cached) = state.cache.get(&cache_key) { return Ok(cached); }

    let _has_token = state.anilist_client.has_token();
    let vars = HashMap::new();
    let result: Value = state
        .anilist_client
        .execute(queries::USER_PROFILE_QUERY, vars)
        .await?;
    state.cache.set(cache_key, result.clone(), "get_user_profile");
    Ok(result)
}

#[tauri::command]
pub async fn save_media_list_entry(
    state: State<'_, AppState>,
    media_id: i64,
    updates: Value,
) -> Result<Value, String> {
    save_media_list_entry_impl(state.inner(), media_id, updates).await
}

pub async fn save_media_list_entry_impl(
    state: &AppState,
    media_id: i64,
    updates: Value,
) -> Result<Value, String> {
    let _has_token = state.anilist_client.has_token();
    let mut vars = HashMap::new();
    vars.insert("mediaId".to_string(), serde_json::json!(media_id));

    if let Some(s) = updates.get("status").and_then(|v| v.as_str()) {
        vars.insert("status".to_string(), serde_json::json!(s));
    }
    if let Some(s) = updates.get("score").and_then(|v| v.as_f64()) {
        vars.insert("score".to_string(), serde_json::json!(s));
    }
    if let Some(p) = updates.get("progress").and_then(|v| v.as_i64()) {
        vars.insert("progress".to_string(), serde_json::json!(p));
    }

    let result: Value = state
        .anilist_client
        .execute(queries::SAVE_MEDIA_LIST_ENTRY_MUTATION, vars)
        .await?;

    // In-place cache mutation to avoid CDN cache lag on subsequent requests
    let progress = updates.get("progress").and_then(|v| v.as_i64());
    let status = updates.get("status").and_then(|v| v.as_str());
    let score = updates.get("score").and_then(|v| v.as_f64());
    state.cache.update_user_list_progress(media_id, progress, status, score);

    state.cache.invalidate("get_user_list");
    state.cache.invalidate("get_airing_schedule");
    Ok(result)
}

#[tauri::command]
pub async fn toggle_favourite(
    state: State<'_, AppState>,
    media_id: i64,
    is_manga: bool,
) -> Result<Value, String> {
    toggle_favourite_impl(state.inner(), media_id, is_manga).await
}

pub async fn toggle_favourite_impl(
    state: &AppState,
    media_id: i64,
    is_manga: bool,
) -> Result<Value, String> {
    let mut vars = HashMap::new();
    if is_manga {
        vars.insert("mangaId".to_string(), serde_json::json!(media_id));
    } else {
        vars.insert("animeId".to_string(), serde_json::json!(media_id));
    }

    let result: Value = state
        .anilist_client
        .execute(queries::TOGGLE_FAVOURITE_MUTATION, vars)
        .await?;

    state.cache.invalidate("get_user_profile");
    Ok(result)
}

#[tauri::command]
pub async fn delete_media_list_entry(
    state: State<'_, AppState>,
    entry_id: i64,
) -> Result<Value, String> {
    delete_media_list_entry_impl(state.inner(), entry_id).await
}

pub async fn delete_media_list_entry_impl(
    state: &AppState,
    entry_id: i64,
) -> Result<Value, String> {
    let mut vars = HashMap::new();
    vars.insert("id".to_string(), serde_json::json!(entry_id));

    let result: Value = state
        .anilist_client
        .execute(queries::DELETE_MEDIA_LIST_ENTRY_MUTATION, vars)
        .await?;

    // In-place cache removal to avoid CDN cache lag on subsequent requests
    state.cache.remove_from_user_list_by_entry_id(entry_id);
    state.cache.invalidate("get_user_list");
    state.cache.invalidate("get_airing_schedule");
    Ok(result)
}

#[tauri::command]
pub async fn get_notifications(
    state: State<'_, AppState>,
    page: Option<i64>,
) -> Result<Value, String> {
    get_notifications_impl(state.inner(), page).await
}

pub async fn get_notifications_impl(
    state: &AppState,
    page: Option<i64>,
) -> Result<Value, String> {
    let cache_key = AniListCache::key("get_notifications", &[("page", &page.unwrap_or(1).to_string())]);
    if let Some(cached) = state.cache.get(&cache_key) { return Ok(cached); }

    let _has_token = state.anilist_client.has_token();
    let mut vars = HashMap::new();
    vars.insert("page".to_string(), serde_json::json!(page.unwrap_or(1)));
    vars.insert("perPage".to_string(), serde_json::json!(20));
    vars.insert("reset".to_string(), serde_json::json!(false));

    let result: Value = state
        .anilist_client
        .execute(queries::USER_NOTIFICATIONS_QUERY, vars)
        .await?;
    state.cache.set(cache_key, result.clone(), "get_notifications");
    Ok(result)
}

#[tauri::command]
pub async fn mark_notifications_read(
    state: State<'_, AppState>,
) -> Result<Value, String> {
    mark_notifications_read_impl(state.inner()).await
}

pub async fn mark_notifications_read_impl(
    state: &AppState,
) -> Result<Value, String> {
    let _has_token = state.anilist_client.has_token();
    let mut vars = HashMap::new();
    vars.insert("page".to_string(), serde_json::json!(1));
    vars.insert("perPage".to_string(), serde_json::json!(1));
    vars.insert("reset".to_string(), serde_json::json!(true));

    let result: Value = state
        .anilist_client
        .execute(queries::USER_NOTIFICATIONS_QUERY, vars)
        .await?;
    state.cache.invalidate("get_notifications");
    Ok(result)
}

#[tauri::command]
pub async fn get_airing_schedule(
    state: State<'_, AppState>,
    days_back: Option<i64>,
    days_ahead: Option<i64>,
    media_ids: Option<Vec<i64>>,
    page: Option<i64>,
    per_page: Option<i64>,
) -> Result<Value, String> {
    get_airing_schedule_impl(state.inner(), days_back, days_ahead, media_ids, page, per_page).await
}

pub async fn get_airing_schedule_impl(
    state: &AppState,
    days_back: Option<i64>,
    days_ahead: Option<i64>,
    media_ids: Option<Vec<i64>>,
    page: Option<i64>,
    per_page: Option<i64>,
) -> Result<Value, String> {
    let _has_token = state.anilist_client.has_token();
    let now = std::time::SystemTime::now()
        .duration_since(std::time::UNIX_EPOCH)
        .unwrap_or_default()
        .as_secs() as i64;

    let db = days_back.unwrap_or(1);
    let da = days_ahead.unwrap_or(3);
    let media_ids_str = match &media_ids {
        Some(ids) if !ids.is_empty() => {
            ids.iter().map(|id| id.to_string()).collect::<Vec<_>>().join(",")
        }
        _ => "all".to_string(),
    };
    let cache_key = AniListCache::key("get_airing_schedule", &[
        ("db", &db.to_string()),
        ("da", &da.to_string()),
        ("ids", &media_ids_str),
    ]);
    if let Some(cached) = state.cache.get(&cache_key) { return Ok(cached); }

    let mut vars = HashMap::new();
    vars.insert("page".to_string(), serde_json::json!(page.unwrap_or(1)));
    vars.insert("perPage".to_string(), serde_json::json!(per_page.unwrap_or(50)));
    vars.insert("airingAt_greater".to_string(), serde_json::json!(now - (db * 86400)));
    vars.insert("airingAt_lesser".to_string(), serde_json::json!(now + (da * 86400)));
    if let Some(ids) = media_ids {
        if !ids.is_empty() {
            vars.insert("mediaId_in".to_string(), serde_json::json!(ids));
        }
    }

    let result: Value = state.anilist_client
        .execute(queries::AIRING_SCHEDULE_QUERY, vars)
        .await?;
    if let Some(_scheds) = result.get("Page").and_then(|p| p.get("airingSchedules")).and_then(|s| s.as_array()) {
    }
    state.cache.set(cache_key, result.clone(), "get_airing_schedule");
    Ok(result)
}
