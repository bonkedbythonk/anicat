use std::collections::HashMap;

use serde_json::Value;
use tauri::State;

use crate::anilist::queries;
use crate::state::AppState;

#[tauri::command]
pub async fn get_user_list(
    state: State<'_, AppState>,
    user_name: Option<String>,
    status: Option<String>,
) -> Result<Value, String> {
    let mut vars = HashMap::new();
    if let Some(name) = user_name {
        vars.insert("userName".to_string(), serde_json::json!(name));
    }
    if let Some(s) = status {
        vars.insert("status".to_string(), serde_json::json!(s));
    }
    vars.insert("type".to_string(), serde_json::json!("ANIME"));

    let result: Value = state
        .anilist_client
        .execute(queries::USER_LIST_QUERY, vars)
        .await?;

    Ok(result)
}

#[tauri::command]
pub async fn get_user_profile(state: State<'_, AppState>) -> Result<Value, String> {
    let vars = HashMap::new();
    let result: Value = state
        .anilist_client
        .execute(queries::USER_PROFILE_QUERY, vars)
        .await?;
    Ok(result)
}

#[tauri::command]
pub async fn save_media_list_entry(
    state: State<'_, AppState>,
    media_id: i64,
    updates: Value,
) -> Result<Value, String> {
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

    Ok(result)
}

#[tauri::command]
pub async fn get_notifications(
    state: State<'_, AppState>,
    page: Option<i64>,
) -> Result<Value, String> {
    let mut vars = HashMap::new();
    vars.insert("page".to_string(), serde_json::json!(page.unwrap_or(1)));
    vars.insert("perPage".to_string(), serde_json::json!(20));

    let result: Value = state
        .anilist_client
        .execute(queries::USER_NOTIFICATIONS_QUERY, vars)
        .await?;

    Ok(result)
}
