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
    let has_token = state.anilist_client.has_token();
    log::info!("[RUST:get_user_list] has_token={} status={:?} user_name={:?} media_type={:?}", has_token, status, user_name, media_type);
    
    let mut resolved_user_name = user_name;
    if resolved_user_name.is_none() || resolved_user_name.as_ref().map(|s| s.is_empty()).unwrap_or(false) {
        if let Some(cached_name) = state.anilist_client.get_username() {
            resolved_user_name = Some(cached_name);
            log::info!("[RUST:get_user_list] using cached Viewer username: {:?}", resolved_user_name);
        } else {
            log::info!("[RUST:get_user_list] username not provided and not cached, fetching Viewer profile...");
            let profile_result: Value = state
                .anilist_client
                .execute(queries::USER_PROFILE_QUERY, HashMap::new())
                .await?;
            if let Some(name) = profile_result.get("Viewer").and_then(|v| v.get("name")).and_then(|n| n.as_str()) {
                let name_str = name.to_string();
                state.anilist_client.set_username(Some(name_str.clone()));
                resolved_user_name = Some(name_str);
                log::info!("[RUST:get_user_list] resolved and cached Viewer username: {}", name);
            } else {
                return Err("Failed to resolve authenticated Viewer username".to_string());
            }
        }
    }

    let mut vars = HashMap::new();
    if let Some(ref name) = resolved_user_name {
        vars.insert("userName".to_string(), serde_json::json!(name));
    }
    if let Some(ref s) = status {
        vars.insert("status".to_string(), serde_json::json!(s));
    }
    vars.insert("type".to_string(), serde_json::json!(media_type.clone().unwrap_or_else(|| "ANIME".to_string())));

    let cache_key = AniListCache::key("get_user_list", &[
        ("status", &status.as_deref().unwrap_or("all")),
        ("type", &media_type.as_deref().unwrap_or("ANIME")),
    ]);
    if let Some(cached) = state.cache.get(&cache_key) { return Ok(cached); }

    let result: Value = state
        .anilist_client
        .execute(queries::USER_LIST_QUERY, vars)
        .await?;

    log::info!("[RUST:get_user_list] raw response keys: {:?}", result.as_object().map(|o| o.keys().collect::<Vec<_>>()));
    if let Some(lists) = result.get("MediaListCollection").and_then(|m| m.get("lists")).and_then(|l| l.as_array()) {
        log::info!("[RUST:get_user_list] returned lists count: {}", lists.len());
        for (idx, list) in lists.iter().enumerate() {
            let name = list.get("name").and_then(|n| n.as_str()).unwrap_or("");
            let entries = list.get("entries").and_then(|e| e.as_array()).map(|a| a.len()).unwrap_or(0);
            log::info!("  List[{}]: name={}, entries={}", idx, name, entries);
        }
    } else {
        log::info!("[RUST:get_user_list] MediaListCollection or lists not found/empty in response");
    }

    state.cache.set(cache_key, result.clone(), "get_user_list");
    Ok(result)
}

#[tauri::command]
pub async fn get_user_profile(state: State<'_, AppState>) -> Result<Value, String> {
    let cache_key = "get_user_profile|default".to_string();
    if let Some(cached) = state.cache.get(&cache_key) { return Ok(cached); }

    let has_token = state.anilist_client.has_token();
    log::info!("[RUST:get_user_profile] has_token={}", has_token);
    let vars = HashMap::new();
    let result: Value = state
        .anilist_client
        .execute(queries::USER_PROFILE_QUERY, vars)
        .await?;
    log::info!("[RUST:get_user_profile] raw response keys: {:?}", result.as_object().map(|o| o.keys().collect::<Vec<_>>()));
    state.cache.set(cache_key, result.clone(), "get_user_profile");
    Ok(result)
}

#[tauri::command]
pub async fn save_media_list_entry(
    state: State<'_, AppState>,
    media_id: i64,
    updates: Value,
) -> Result<Value, String> {
    let has_token = state.anilist_client.has_token();
    log::info!("[RUST:save_media_list_entry] has_token={} media_id={} updates={:?}", has_token, media_id, updates);
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
    log::info!("[RUST:save_media_list_entry] result keys: {:?}", result.as_object().map(|o| o.keys().collect::<Vec<_>>()));
    state.cache.invalidate("get_user_list");
    state.cache.invalidate("get_airing_schedule");
    Ok(result)
}

#[tauri::command]
pub async fn delete_media_list_entry(
    state: State<'_, AppState>,
    entry_id: i64,
) -> Result<Value, String> {
    let mut vars = HashMap::new();
    vars.insert("id".to_string(), serde_json::json!(entry_id));

    let result: Value = state
        .anilist_client
        .execute(queries::DELETE_MEDIA_LIST_ENTRY_MUTATION, vars)
        .await?;
    state.cache.invalidate("get_user_list");
    state.cache.invalidate("get_airing_schedule");
    Ok(result)
}

#[tauri::command]
pub async fn get_notifications(
    state: State<'_, AppState>,
    page: Option<i64>,
) -> Result<Value, String> {
    let cache_key = AniListCache::key("get_notifications", &[("page", &page.unwrap_or(1).to_string())]);
    if let Some(cached) = state.cache.get(&cache_key) { return Ok(cached); }

    let has_token = state.anilist_client.has_token();
    log::info!("[RUST:get_notifications] has_token={} page={:?}", has_token, page);
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
    let has_token = state.anilist_client.has_token();
    log::info!("[RUST:mark_notifications_read] has_token={}", has_token);
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
    let has_token = state.anilist_client.has_token();
    log::info!("[RUST:get_airing_schedule] has_token={} days_back={:?} days_ahead={:?} media_ids={:?}", has_token, days_back, days_ahead, media_ids);
    let now = std::time::SystemTime::now()
        .duration_since(std::time::UNIX_EPOCH)
        .unwrap_or_default()
        .as_secs() as i64;

    let db = days_back.unwrap_or(1);
    let da = days_ahead.unwrap_or(3);
    let cache_key = AniListCache::key("get_airing_schedule", &[
        ("db", &db.to_string()),
        ("da", &da.to_string()),
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
    log::info!("[RUST:get_airing_schedule] raw response keys: {:?}", result.as_object().map(|o| o.keys().collect::<Vec<_>>()));
    if let Some(scheds) = result.get("Page").and_then(|p| p.get("airingSchedules")).and_then(|s| s.as_array()) {
        log::info!("[RUST:get_airing_schedule] returned airingSchedules count: {}", scheds.len());
    }
    state.cache.set(cache_key, result.clone(), "get_airing_schedule");
    Ok(result)
}
