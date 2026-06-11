use std::collections::HashMap;

use serde_json::Value;
use tauri::State;

use crate::anilist::queries;
use crate::anilist::responses::{MediaResponse, PageResponse};
use crate::cache::AniListCache;
use crate::registry;
use crate::state::AppState;

#[tauri::command]
pub async fn search_media(
    state: State<'_, AppState>,
    query: String,
    page: Option<i64>,
    status: Option<String>,
) -> Result<Value, String> {
    let _has_token = state.anilist_client.has_token();
    let mut vars = HashMap::new();
    vars.insert("page".to_string(), serde_json::json!(page.unwrap_or(1)));
    vars.insert("perPage".to_string(), serde_json::json!(20));
    vars.insert("search".to_string(), if query.is_empty() { serde_json::json!(null) } else { serde_json::json!(query) });
    vars.insert("type".to_string(), serde_json::json!("ANIME"));
    if let Some(s) = status {
        vars.insert("status".to_string(), serde_json::json!(s));
    }

    let result: PageResponse<crate::anilist::types::MediaItem> = state
        .anilist_client
        .execute(queries::MEDIA_SEARCH_QUERY, vars)
        .await?;

    let val = serde_json::to_value(result).map_err(|e| e.to_string())?;
    if let Some(_m) = val.get("Page").and_then(|p| p.get("media")).and_then(|m| m.as_array()) {
    }
    Ok(val)
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
    let key = AniListCache::key("get_trending", &[("page", &page.unwrap_or(1).to_string())]);
    if let Some(cached) = state.cache.get(&key) { return Ok(cached); }

    let mut vars = HashMap::new();
    vars.insert("page".to_string(), serde_json::json!(page.unwrap_or(1)));
    vars.insert("perPage".to_string(), serde_json::json!(20));
    vars.insert("type".to_string(), serde_json::json!("ANIME"));

    let result: PageResponse<crate::anilist::types::MediaItem> = state
        .anilist_client
        .execute(queries::MEDIA_TRENDING_QUERY, vars)
        .await?;

    let val = serde_json::to_value(result).map_err(|e| e.to_string())?;
    state.cache.set(key, val.clone(), "get_trending");
    Ok(val)
}

#[tauri::command]
pub async fn get_seasonal(
    state: State<'_, AppState>,
    season: Option<String>,
    season_year: Option<i32>,
    page: Option<i64>,
) -> Result<Value, String> {
    let s = season.clone().unwrap_or_else(|| "SPRING".to_string());
    let y = season_year.unwrap_or(2026);
    let key = AniListCache::key("get_seasonal", &[("season", &s), ("year", &y.to_string()), ("page", &page.unwrap_or(1).to_string())]);
    if let Some(cached) = state.cache.get(&key) { return Ok(cached); }

    let mut vars = HashMap::new();
    vars.insert("page".to_string(), serde_json::json!(page.unwrap_or(1)));
    vars.insert("perPage".to_string(), serde_json::json!(20));
    vars.insert("season".to_string(), serde_json::json!(s));
    vars.insert("seasonYear".to_string(), serde_json::json!(y));
    vars.insert("type".to_string(), serde_json::json!("ANIME"));

    let result: PageResponse<crate::anilist::types::MediaItem> = state
        .anilist_client
        .execute(queries::MEDIA_SEASONAL_QUERY, vars)
        .await?;

    let val = serde_json::to_value(result).map_err(|e| e.to_string())?;
    state.cache.set(key, val.clone(), "get_seasonal");
    Ok(val)
}

#[tauri::command]
pub async fn get_upcoming(
    state: State<'_, AppState>,
    page: Option<i64>,
) -> Result<Value, String> {
    let key = AniListCache::key("get_upcoming", &[("page", &page.unwrap_or(1).to_string())]);
    if let Some(cached) = state.cache.get(&key) { return Ok(cached); }

    let mut vars = HashMap::new();
    vars.insert("page".to_string(), serde_json::json!(page.unwrap_or(1)));
    vars.insert("perPage".to_string(), serde_json::json!(20));
    vars.insert("type".to_string(), serde_json::json!("ANIME"));

    let result: PageResponse<crate::anilist::types::MediaItem> = state
        .anilist_client
        .execute(queries::MEDIA_UPCOMING_QUERY, vars)
        .await?;

    let val = serde_json::to_value(result).map_err(|e| e.to_string())?;
    state.cache.set(key, val.clone(), "get_upcoming");
    Ok(val)
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
    let key = "get_smart_playlist|action".to_string();
    if let Some(cached) = state.cache.get(&key) { return Ok(cached); }

    let mut vars = HashMap::new();
    vars.insert("genre".to_string(), serde_json::json!(["Action"]));
    vars.insert("sort".to_string(), serde_json::json!(["SCORE_DESC"]));

    let result: PageResponse<crate::anilist::types::MediaItem> = state
        .anilist_client
        .execute(queries::SMART_PLAYLIST_QUERY, vars)
        .await?;

    let val = serde_json::to_value(result).map_err(|e| e.to_string())?;
    state.cache.set(key, val.clone(), "get_smart_playlist");
    Ok(val)
}

#[tauri::command]
pub async fn get_episodes(
    state: State<'_, AppState>,
    media_id: i64,
    provider: Option<String>,
    title: Option<String>,
) -> Result<Value, String> {
    let provider_name = provider.unwrap_or_else(|| "anineko".to_string());
    let is_manga = provider_name == "mangakatana";

    let db = state.open_db().map_err(|e| e.to_string())?;
    let slug = registry::service::get_provider_slug(&db, media_id, &provider_name);

    let episodes = if let Some(slug) = slug {
        let res = if is_manga {
            state.scraper_manager.get_manga(&slug).await.map(|info| info.episodes)
        } else {
            state.scraper_manager.get_anime(&slug).await.map(|info| info.episodes)
        };
        match res {
            Ok(eps) => eps,
            Err(_e) => {
                let _ = registry::service::clear_provider_cache(&db, media_id);
                vec![]
            }
        }
    } else {
        // No mapping yet — auto-search by media title (frontend must pass this)
        let Some(title) = title.filter(|t| !t.is_empty()) else {
            return serde_json::to_value(Vec::<crate::scraper::Episode>::new())
                .map_err(|e| e.to_string());
        };

        let results = if is_manga {
            state.scraper_manager.search_manga(&title).await.unwrap_or_default()
        } else {
            state.scraper_manager.search(&title).await.unwrap_or_default()
        };

        if let Some(best) = find_best_match(&title, results, |r| &r.title) {
            let _ = registry::service::set_provider_slug(
                &db, media_id, &provider_name, &best.id,
            );
            let res = if is_manga {
                state.scraper_manager.get_manga(&best.id).await.map(|info| info.episodes)
            } else {
                state.scraper_manager.get_anime(&best.id).await.map(|info| info.episodes)
            };
            res.unwrap_or_default()
        } else {
            vec![]
        }
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
    let provider_name = provider.unwrap_or_else(|| "anineko".to_string());

    let db = state.open_db()?;
    let slug = registry::service::get_provider_slug(&db, media_id, &provider_name)
        .ok_or_else(|| format!("No provider mapping for media {}", media_id))?;

    let servers = state
        .scraper_manager
        .get_streams(&slug, episode_number)
        .await?;

    let result = serde_json::json!({ "streams": servers });
    Ok(result)
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

#[tauri::command]
pub async fn debug_provider_streams(
    state: State<'_, AppState>,
    media_id: i64,
    episode_number: i32,
    provider: Option<String>,
) -> Result<serde_json::Value, String> {
    let provider_name = provider.unwrap_or_else(|| "anineko".to_string());
    let db = state.open_db()?;
    let slug = match registry::service::get_provider_slug(&db, media_id, &provider_name) {
        Some(s) => s,
        None => {
            // Auto-search: get title from AniList, search AniNeko, save slug
            let mut vars = std::collections::HashMap::new();
            vars.insert("id".to_string(), serde_json::json!(media_id));
            vars.insert("type".to_string(), serde_json::json!("ANIME"));
            let detail: crate::anilist::responses::MediaResponse = state
                .anilist_client
                .execute(crate::anilist::queries::MEDIA_DETAIL_QUERY, vars)
                .await
                .map_err(|e| format!("Failed to get anime title: {}", e))?;
            let title = detail.media
                .and_then(|m| m.title)
                .and_then(|t| t.english.or(t.romaji))
                .unwrap_or_default();
            if title.is_empty() {
                return Err(format!("No title found for media {}", media_id));
            }
            let results = state.scraper_manager.search(&title).await.unwrap_or_default();
            match find_best_match(&title, results, |r| &r.title) {
                Some(best) => {
                    let _ = registry::service::set_provider_slug(&db, media_id, &provider_name, &best.id);
                    best.id
                }
                None => {
                    return Err(format!(
                        r#"{{"error":"no_slug","media_id":{},"provider":"{}","hint":"AniNeko search for '{}' returned no results"}}"#,
                        media_id, provider_name, title
                    ));
                }
            }
        }
    };
    let mut result = state.scraper_manager.debug_streams(&slug, episode_number).await?;
    if let Some(obj) = result.as_object_mut() {
        obj.insert("resolved_slug".to_string(), serde_json::json!(slug));
        obj.insert("provider".to_string(), serde_json::json!(provider_name));
    }
    Ok(result)
}

#[tauri::command]
pub async fn get_chapter_pages(
    state: State<'_, AppState>,
    media_id: i64,
    chapter_number: String,
) -> Result<Value, String> {
    let provider_name = "mangakatana".to_string();

    let db = state.open_db().map_err(|e| e.to_string())?;
    let slug = registry::service::get_provider_slug(&db, media_id, &provider_name)
        .ok_or_else(|| format!("No provider mapping for media {}", media_id))?;

    let pages = state
        .scraper_manager
        .get_chapter_pages(&slug, &chapter_number)
        .await?;

    Ok(pages)
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

// ── Smart Similarity Matcher for Anime/Manga Searches ──────

fn normalize_title(title: &str) -> String {
    title
        .chars()
        .filter(|c| c.is_alphanumeric())
        .collect::<String>()
        .to_lowercase()
}

fn levenshtein_distance(s1: &str, s2: &str) -> usize {
    let v1: Vec<char> = s1.chars().collect();
    let v2: Vec<char> = s2.chars().collect();
    let len1 = v1.len();
    let len2 = v2.len();

    if len1 == 0 { return len2; }
    if len2 == 0 { return len1; }

    let mut dp = vec![vec![0; len2 + 1]; len1 + 1];

    for i in 0..=len1 {
        dp[i][0] = i;
    }
    for j in 0..=len2 {
        dp[0][j] = j;
    }

    for i in 1..=len1 {
        for j in 1..=len2 {
            let cost = if v1[i - 1] == v2[j - 1] { 0 } else { 1 };
            dp[i][j] = std::cmp::min(
                std::cmp::min(dp[i - 1][j] + 1, dp[i][j - 1] + 1),
                dp[i - 1][j - 1] + cost,
            );
        }
    }

    dp[len1][len2]
}

fn calculate_similarity(target: &str, candidate: &str) -> f64 {
    let target_norm = normalize_title(target);
    let candidate_norm = normalize_title(candidate);

    if target_norm.is_empty() || candidate_norm.is_empty() {
        return 0.0;
    }

    if target_norm == candidate_norm {
        return 1.0;
    }

    // Check if one is a substring of another
    if candidate_norm.contains(&target_norm) {
        let ratio = target_norm.len() as f64 / candidate_norm.len() as f64;
        return ratio * 0.9;
    }

    if target_norm.contains(&candidate_norm) {
        let ratio = candidate_norm.len() as f64 / target_norm.len() as f64;
        return ratio * 0.8;
    }

    let lev = levenshtein_distance(&target_norm, &candidate_norm);
    let max_len = std::cmp::max(target_norm.len(), candidate_norm.len()) as f64;
    1.0 - (lev as f64 / max_len)
}

fn find_best_match<T, F>(target: &str, candidates: Vec<T>, get_title: F) -> Option<T>
where
    F: Fn(&T) -> &str,
{
    let mut best_candidate = None;
    let mut best_score = -1.0;

    for candidate in candidates {
        let score = calculate_similarity(target, get_title(&candidate));
        if score > best_score {
            best_score = score;
            best_candidate = Some(candidate);
        }
    }

    best_candidate
}
