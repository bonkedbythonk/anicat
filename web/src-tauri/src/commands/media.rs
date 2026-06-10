use std::collections::HashMap;

use serde_json::Value;
use tauri::State;

use crate::anilist::queries;
use crate::anilist::responses::{MediaResponse, PageResponse};
use crate::registry;
use crate::state::AppState;

#[tauri::command]
pub async fn search_media(
    state: State<'_, AppState>,
    query: String,
    page: Option<i64>,
) -> Result<Value, String> {
    let mut vars = HashMap::new();
    vars.insert("page".to_string(), serde_json::json!(page.unwrap_or(1)));
    vars.insert("perPage".to_string(), serde_json::json!(20));
    vars.insert("search".to_string(), serde_json::json!(query));
    vars.insert("type".to_string(), serde_json::json!("ANIME"));

    let result: PageResponse<crate::anilist::types::MediaItem> = state
        .anilist_client
        .execute(queries::MEDIA_SEARCH_QUERY, vars)
        .await?;

    serde_json::to_value(result).map_err(|e| e.to_string())
}

#[tauri::command]
pub async fn get_media_detail(
    state: State<'_, AppState>,
    media_id: i64,
) -> Result<Value, String> {
    let mut vars = HashMap::new();
    vars.insert("id".to_string(), serde_json::json!(media_id));
    vars.insert("type".to_string(), serde_json::json!("ANIME"));

    let result: MediaResponse = state
        .anilist_client
        .execute(queries::MEDIA_DETAIL_QUERY, vars)
        .await?;

    serde_json::to_value(result).map_err(|e| e.to_string())
}

#[tauri::command]
pub async fn get_trending(
    state: State<'_, AppState>,
    page: Option<i64>,
) -> Result<Value, String> {
    let mut vars = HashMap::new();
    vars.insert("page".to_string(), serde_json::json!(page.unwrap_or(1)));
    vars.insert("perPage".to_string(), serde_json::json!(20));
    vars.insert("type".to_string(), serde_json::json!("ANIME"));

    let result: PageResponse<crate::anilist::types::MediaItem> = state
        .anilist_client
        .execute(queries::MEDIA_TRENDING_QUERY, vars)
        .await?;

    serde_json::to_value(result).map_err(|e| e.to_string())
}

#[tauri::command]
pub async fn get_seasonal(
    state: State<'_, AppState>,
    season: Option<String>,
    season_year: Option<i32>,
    page: Option<i64>,
) -> Result<Value, String> {
    let mut vars = HashMap::new();
    vars.insert("page".to_string(), serde_json::json!(page.unwrap_or(1)));
    vars.insert("perPage".to_string(), serde_json::json!(20));
    vars.insert(
        "season".to_string(),
        serde_json::json!(season.unwrap_or_else(|| "SPRING".to_string())),
    );
    vars.insert(
        "seasonYear".to_string(),
        serde_json::json!(season_year.unwrap_or(2026)),
    );
    vars.insert("type".to_string(), serde_json::json!("ANIME"));

    let result: PageResponse<crate::anilist::types::MediaItem> = state
        .anilist_client
        .execute(queries::MEDIA_SEASONAL_QUERY, vars)
        .await?;

    serde_json::to_value(result).map_err(|e| e.to_string())
}

#[tauri::command]
pub async fn get_upcoming(
    state: State<'_, AppState>,
    page: Option<i64>,
) -> Result<Value, String> {
    let mut vars = HashMap::new();
    vars.insert("page".to_string(), serde_json::json!(page.unwrap_or(1)));
    vars.insert("perPage".to_string(), serde_json::json!(20));
    vars.insert("type".to_string(), serde_json::json!("ANIME"));

    let result: PageResponse<crate::anilist::types::MediaItem> = state
        .anilist_client
        .execute(queries::MEDIA_UPCOMING_QUERY, vars)
        .await?;

    serde_json::to_value(result).map_err(|e| e.to_string())
}

#[tauri::command]
pub async fn get_media_characters(
    state: State<'_, AppState>,
    media_id: i64,
) -> Result<Value, String> {
    let mut vars = HashMap::new();
    vars.insert("id".to_string(), serde_json::json!(media_id));
    vars.insert("page".to_string(), serde_json::json!(1));
    vars.insert("perPage".to_string(), serde_json::json!(25));

    let result: crate::anilist::responses::CharacterResponse = state
        .anilist_client
        .execute(queries::MEDIA_CHARACTERS_QUERY, vars)
        .await?;

    serde_json::to_value(result).map_err(|e| e.to_string())
}

#[tauri::command]
pub async fn get_smart_playlist(
    state: State<'_, AppState>,
) -> Result<Value, String> {
    let mut vars = HashMap::new();
    vars.insert("genre".to_string(), serde_json::json!(["Action"]));
    vars.insert("sort".to_string(), serde_json::json!(["SCORE_DESC"]));

    let result: PageResponse<crate::anilist::types::MediaItem> = state
        .anilist_client
        .execute(queries::SMART_PLAYLIST_QUERY, vars)
        .await?;

    serde_json::to_value(result).map_err(|e| e.to_string())
}

#[tauri::command]
pub async fn get_episodes(
    state: State<'_, AppState>,
    media_id: i64,
    provider: Option<String>,
) -> Result<Value, String> {
    let provider_name = provider.unwrap_or_else(|| "gogoanime".to_string());

    let db = state.open_db().map_err(|e| e.to_string())?;
    let slug = registry::service::get_provider_slug(&db, media_id, &provider_name);

    let episodes = if let Some(slug) = slug {
        match state.scraper_manager.get_anime(&slug).await {
            Ok(anime_info) => anime_info.episodes,
            Err(_e) => {
                let _ = registry::service::clear_provider_cache(&db, media_id);
                vec![]
            }
        }
    } else {
        vec![]
    };

    serde_json::to_value(episodes).map_err(|e| e.to_string())
}

#[tauri::command]
pub async fn resolve_stream(
    state: State<'_, AppState>,
    media_id: i64,
    episode_number: i32,
    provider: Option<String>,
) -> Result<Value, String> {
    let provider_name = provider.unwrap_or_else(|| "gogoanime".to_string());

    let db = state.open_db()?;
    let slug = registry::service::get_provider_slug(&db, media_id, &provider_name)
        .ok_or_else(|| format!("No provider mapping for media {}", media_id))?;

    let servers = state
        .scraper_manager
        .get_streams(&slug, episode_number)
        .await?;

    serde_json::to_value(servers).map_err(|e| e.to_string())
}

#[tauri::command]
pub async fn search_provider(
    state: State<'_, AppState>,
    query: String,
) -> Result<Vec<crate::scraper::AnimeRef>, String> {
    state.scraper_manager.search(&query).await
}

#[tauri::command]
pub async fn map_provider_slug(
    state: State<'_, AppState>,
    media_id: i64,
    provider: String,
    slug: String,
) -> Result<(), String> {
    let db = state.open_db()?;
    registry::service::set_provider_slug(&db, media_id, &provider, &slug)
}

#[tauri::command]
pub async fn clear_provider_cache(
    state: State<'_, AppState>,
    media_id: i64,
) -> Result<(), String> {
    let db = state.open_db()?;
    registry::service::clear_provider_cache(&db, media_id)
}

// ── Local library commands ────────────────────────────────

#[tauri::command]
pub async fn get_library(
    state: State<'_, AppState>,
) -> Result<Vec<crate::registry::LibraryEntry>, String> {
    let db = state.open_db()?;
    registry::service::get_all_library(&db)
}

#[tauri::command]
pub async fn add_to_library(
    state: State<'_, AppState>,
    media_id: i64,
    media_type: String,
    status: Option<String>,
    score: Option<f64>,
    progress: Option<i32>,
    notes: Option<String>,
) -> Result<(), String> {
    let db = state.open_db()?;
    registry::service::upsert_library_entry(
        &db,
        media_id,
        &media_type,
        status.as_deref(),
        score,
        progress,
        notes.as_deref(),
    )
}

#[tauri::command]
pub async fn remove_from_library(
    state: State<'_, AppState>,
    media_id: i64,
) -> Result<(), String> {
    let db = state.open_db()?;
    registry::service::delete_library_entry(&db, media_id)
}
