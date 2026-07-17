use std::collections::HashMap;
use std::path::PathBuf;

use chrono::Datelike;
use serde_json::Value;
use tauri::State;
use tauri::Manager;

use crate::anilist::queries;
use crate::anilist::responses::{MediaResponse, PageResponse};
use crate::cache::AniListCache;
use crate::registry;
use crate::state::AppState;

#[tauri::command]
#[allow(clippy::too_many_arguments)] // search filter params map 1:1 to the IPC call
pub async fn search_media(
    state: State<'_, AppState>,
    query: String,
    page: Option<i64>,
    media_type: Option<String>,
    status: Option<String>,
    genre: Option<String>,
    year: Option<i64>,
    min_score: Option<i64>,
) -> Result<Value, String> {
    search_media_impl(state.inner(), query, page, media_type, status, genre, year, min_score).await
}

#[allow(clippy::too_many_arguments)]
pub async fn search_media_impl(
    state: &AppState,
    query: String,
    page: Option<i64>,
    media_type: Option<String>,
    status: Option<String>,
    genre: Option<String>,
    year: Option<i64>,
    min_score: Option<i64>,
) -> Result<Value, String> {
    log::info!("search_media: query='{}', page={:?}, media_type={:?}, status={:?}, genre={:?}, year={:?}, min_score={:?}", query, page, media_type, status, genre, year, min_score);
    let _has_token = state.anilist_client.has_token();
    let media_type = media_type.unwrap_or_else(|| "ANIME".to_string());

    // Key on every parameter so different filters/pages don't collide. Spares
    // repeat searches and back-navigation from re-hitting AniList (typing new
    // queries still goes through — the frontend's 400ms debounce handles that).
    let cache_key = AniListCache::key("search_media", &[
        ("q", &query),
        ("page", &page.unwrap_or(1).to_string()),
        ("type", &media_type),
        ("status", status.as_deref().unwrap_or("")),
        ("genre", genre.as_deref().unwrap_or("")),
        ("year", &year.map(|y| y.to_string()).unwrap_or_default()),
        ("min", &min_score.map(|s| s.to_string()).unwrap_or_default()),
    ]);
    if let Some(cached) = state.cache.get(&cache_key) { return Ok(cached); }

    let mut vars = HashMap::new();
    vars.insert("page".to_string(), serde_json::json!(page.unwrap_or(1)));
    vars.insert("perPage".to_string(), serde_json::json!(20));
    vars.insert("search".to_string(), if query.is_empty() { serde_json::json!(null) } else { serde_json::json!(query) });
    vars.insert("type".to_string(), serde_json::json!(media_type));
    vars.insert("isAdult".to_string(), serde_json::json!(false));
    if let Some(s) = status {
        vars.insert("status".to_string(), serde_json::json!(s));
    }
    if let Some(g) = genre {
        if !g.is_empty() {
            vars.insert("genre".to_string(), serde_json::json!(vec![g]));
        }
    }
    if let Some(y) = year {
        vars.insert("seasonYear".to_string(), serde_json::json!(y));
    }
    if let Some(s) = min_score {
        vars.insert("averageScoreGreater".to_string(), serde_json::json!(s));
    }

    let result: PageResponse<crate::anilist::types::MediaItem> = state
        .anilist_client
        .execute(queries::MEDIA_SEARCH_QUERY, vars)
        .await?;

    let val = serde_json::to_value(result).map_err(|e| e.to_string())?;
    state.cache.set(cache_key, val.clone(), "search_media");
    Ok(val)
}

#[tauri::command]
pub async fn get_media_detail(
    state: State<'_, AppState>,
    media_id: i64,
    media_type: Option<String>,
) -> Result<Value, String> {
    get_media_detail_impl(state.inner(), media_id, media_type).await
}

pub async fn get_media_detail_impl(
    state: &AppState,
    media_id: i64,
    media_type: Option<String>,
) -> Result<Value, String> {
    let mut vars = HashMap::new();
    vars.insert("id".to_string(), serde_json::json!(media_id));
    vars.insert("type".to_string(), serde_json::json!(media_type.unwrap_or_else(|| "ANIME".to_string())));

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
    media_type: Option<String>,
) -> Result<Value, String> {
    get_trending_impl(state.inner(), page, media_type).await
}

pub async fn get_trending_impl(
    state: &AppState,
    page: Option<i64>,
    media_type: Option<String>,
) -> Result<Value, String> {
    let mtype = media_type.unwrap_or_else(|| "ANIME".to_string());
    let key = AniListCache::key("get_trending", &[("page", &page.unwrap_or(1).to_string()), ("type", &mtype)]);
    if let Some(cached) = state.cache.get(&key) { return Ok(cached); }

    let mut vars = HashMap::new();
    vars.insert("page".to_string(), serde_json::json!(page.unwrap_or(1)));
    vars.insert("perPage".to_string(), serde_json::json!(20));
    vars.insert("type".to_string(), serde_json::json!(mtype));
    vars.insert("isAdult".to_string(), serde_json::json!(false));

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
    season_year: Option<i64>,
    page: Option<i64>,
    media_type: Option<String>,
) -> Result<Value, String> {
    get_seasonal_impl(state.inner(), season, season_year, page, media_type).await
}

pub async fn get_seasonal_impl(
    state: &AppState,
    season: Option<String>,
    season_year: Option<i64>,
    page: Option<i64>,
    media_type: Option<String>,
) -> Result<Value, String> {
    let s = season.clone().unwrap_or_else(|| "SPRING".to_string());
    let y = season_year.unwrap_or_else(|| chrono::Local::now().year() as i64);
    let mtype = media_type.unwrap_or_else(|| "ANIME".to_string());
    let key = AniListCache::key("get_seasonal", &[("season", &s), ("year", &y.to_string()), ("page", &page.unwrap_or(1).to_string()), ("type", &mtype)]);
    if let Some(cached) = state.cache.get(&key) { return Ok(cached); }

    let mut vars = HashMap::new();
    vars.insert("page".to_string(), serde_json::json!(page.unwrap_or(1)));
    vars.insert("perPage".to_string(), serde_json::json!(20));
    vars.insert("season".to_string(), serde_json::json!(s));
    vars.insert("seasonYear".to_string(), serde_json::json!(y));
    vars.insert("type".to_string(), serde_json::json!(mtype));
    vars.insert("isAdult".to_string(), serde_json::json!(false));

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
    media_type: Option<String>,
) -> Result<Value, String> {
    get_upcoming_impl(state.inner(), page, media_type).await
}

pub async fn get_upcoming_impl(
    state: &AppState,
    page: Option<i64>,
    media_type: Option<String>,
) -> Result<Value, String> {
    let mtype = media_type.unwrap_or_else(|| "ANIME".to_string());
    let key = AniListCache::key("get_upcoming", &[("page", &page.unwrap_or(1).to_string()), ("type", &mtype)]);
    if let Some(cached) = state.cache.get(&key) { return Ok(cached); }

    let mut vars = HashMap::new();
    vars.insert("page".to_string(), serde_json::json!(page.unwrap_or(1)));
    vars.insert("perPage".to_string(), serde_json::json!(20));
    vars.insert("type".to_string(), serde_json::json!(mtype));
    vars.insert("isAdult".to_string(), serde_json::json!(false));

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
    get_media_characters_impl(state.inner(), media_id).await
}

pub async fn get_media_characters_impl(
    state: &AppState,
    media_id: i64,
) -> Result<Value, String> {
    let key = AniListCache::key("get_media_characters", &[("id", &media_id.to_string())]);
    if let Some(cached) = state.cache.get(&key) { return Ok(cached); }

    let mut vars = HashMap::new();
    vars.insert("id".to_string(), serde_json::json!(media_id));
    vars.insert("page".to_string(), serde_json::json!(1));
    vars.insert("perPage".to_string(), serde_json::json!(25));

    let result: crate::anilist::responses::CharacterResponse = state
        .anilist_client
        .execute(queries::MEDIA_CHARACTERS_QUERY, vars)
        .await?;

    let val = serde_json::to_value(result).map_err(|e| e.to_string())?;
    state.cache.set(key, val.clone(), "get_media_characters");
    Ok(val)
}

#[tauri::command]
pub async fn get_smart_playlist(
    state: State<'_, AppState>,
) -> Result<Value, String> {
    get_smart_playlist_impl(state.inner()).await
}

pub async fn get_smart_playlist_impl(
    state: &AppState,
) -> Result<Value, String> {
    let key = "get_smart_playlist|action".to_string();
    if let Some(cached) = state.cache.get(&key) { return Ok(cached); }

    let mut vars = HashMap::new();
    vars.insert("genre".to_string(), serde_json::json!(["Action"]));
    vars.insert("sort".to_string(), serde_json::json!(["SCORE_DESC"]));
    vars.insert("isAdult".to_string(), serde_json::json!(false));

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
    app: tauri::AppHandle,
    state: State<'_, AppState>,
    media_id: i64,
    provider: Option<String>,
    title: Option<String>,
    episode_count: Option<i64>,
) -> Result<Value, String> {
    use tauri::Emitter;
    let notify = |message: &str| {
        let _ = app.emit("show_notification", serde_json::json!({ "message": message }));
    };
    get_episodes_impl(state.inner(), media_id, provider, title, episode_count, &notify).await
}

/// `notify` surfaces non-fatal scrape hiccups (auth-error toast, "loaded from
/// fallback provider" notice) to whatever's watching — the desktop wrapper
/// above emits a Tauri event for the webview to show as a toast; the
/// headless mobile-api route just logs, since there's no toast surface there.
pub async fn get_episodes_impl(
    state: &AppState,
    media_id: i64,
    provider: Option<String>,
    title: Option<String>,
    episode_count: Option<i64>,
    notify: &(dyn Fn(&str) + Send + Sync),
) -> Result<Value, String> {
    let provider_name = provider.unwrap_or_else(|| "mkissa".to_string());
    let fallback = {
        let cfg = state.config.read().await;
        cfg.general.fallback_provider.clone()
    };
    let is_manga = provider_name == "mangakatana";

    // Torrents have no scrapeable episode list: synthesize one from the count
    // the frontend already knows, or from AniList (aired-so-far for airing
    // shows). Whether each episode actually has a torrent is decided at play
    // time, with the regular provider fallback if it doesn't.
    if provider_name == "nyaa" && !is_manga {
        let count = match episode_count.filter(|&n| n > 0) {
            Some(n) => Some(n),
            None => crate::torrent::gather_media_info(state, media_id, title.clone()).await.1,
        };
        let episodes: Vec<crate::scraper::client::Episode> = (1..=count.unwrap_or(0))
            .map(|n| crate::scraper::client::Episode {
                number: n as i32,
                title: None,
                image: None,
                download_status: None,
            })
            .collect();
        return serde_json::to_value(episodes).map_err(|e| e.to_string());
    }

    let db = state.open_db().map_err(|e| e.to_string())?;
    // A saved slug is only meaningful on the provider it was resolved for.
    let (slug, slug_provider) = match registry::service::get_provider_slug(&db, media_id, &provider_name) {
        Some(s) => (Some(s), provider_name.clone()),
        None if fallback != provider_name => {
            log::info!("get_episodes: no slug for '{}', trying fallback '{}'", provider_name, fallback);
            (registry::service::get_provider_slug(&db, media_id, &fallback), fallback.clone())
        }
        None => (None, provider_name.clone()),
    };

    let mut episodes = if let Some(ref slug) = slug {
        let res = if is_manga {
            state.scraper_manager.get_manga(slug).await.map(|info| info.episodes)
        } else {
            state.scraper_manager.get_anime(slug, &slug_provider).await.map(|info| info.episodes)
        };
        match res {
            Ok(eps) => eps,
            Err(e) => {
                log::error!("Scraper auto-search error for media_id={}, provider={}, title={}: {}", media_id, slug_provider, title.as_deref().unwrap_or(""), e);
                let _ = registry::service::clear_provider_cache(&db, media_id);
                notify(&format!("Failed to load episodes: {}", e));
                vec![]
            }
        }
    } else {
        if let Some(slug) = resolve_and_save_provider_slug(
            state,
            media_id,
            &provider_name,
            is_manga,
            title,
        )
        .await?
        {
            let res = if is_manga {
                match state.scraper_manager.get_manga(&slug).await {
                    Ok(info) => info.episodes,
                    Err(e) => {
                        log::error!("get_manga failed for slug '{}': {}", slug, e);
                        vec![]
                    }
                }
            } else {
                match state.scraper_manager.get_anime(&slug, &provider_name).await {
                    Ok(info) => info.episodes,
                    Err(e) => {
                        log::error!("get_anime failed for slug '{}' on provider '{}': {}", slug, provider_name, e);
                        vec![]
                    }
                }
            };
            res
        } else {
            vec![]
        }
    };

    // Self-heal stale mis-matches: a saved slug whose episode count wildly
    // contradicts AniList's total for a finished show was matched to the
    // wrong franchise entry (e.g. a 2-episode specials entry saved for a
    // 12-episode season) by an older matcher. Re-resolve once with the
    // current season-aware matcher instead of trusting the mapping forever.
    if !is_manga && slug.is_some() {
        if let Some(expected) = episode_count.filter(|&n| n > 0) {
            let got = episodes.len() as i64;
            let suspect = got > 0 && (got * 2 <= expected || got >= expected * 2);
            if suspect && media_is_finished(state, media_id).await {
                log::warn!(
                    "get_episodes: saved '{}' slug '{}' has {} episodes but AniList expects {}; re-resolving",
                    slug_provider, slug.as_deref().unwrap_or(""), got, expected
                );
                let _ = registry::service::clear_provider_slug(&db, media_id, &slug_provider);
                match resolve_and_save_provider_slug(state, media_id, &slug_provider, false, None).await {
                    Ok(Some(new_slug)) if Some(&new_slug) != slug.as_ref() => {
                        if let Ok(info) = state.scraper_manager.get_anime(&new_slug, &slug_provider).await {
                            if !info.episodes.is_empty() {
                                episodes = info.episodes;
                            }
                        }
                    }
                    // Same slug re-chosen: the provider genuinely lists this
                    // count; resolve_and_save already restored the mapping.
                    Ok(Some(_)) => {}
                    // No confident match anymore: leave the mapping cleared and
                    // let the synthesis/fallback below take over.
                    _ => episodes = vec![],
                }
            }
        }
    }

    // Active fallback: if the primary provider yielded nothing (down, no match,
    // or an empty list), resolve and scrape the fallback provider instead of
    // showing a dead episode list. Only for anime — manga has one provider.
    if episodes.is_empty() && !is_manga {
        // First try: synthesise from the AniList episode count the frontend
        // already knows. This covers cases where the scraper's show() query
        // returns empty availableEpisodesDetail/availableEpisodes even though
        // streams resolve correctly (the stream query uses a different endpoint).
        if let Some(count) = episode_count.filter(|&n| n > 0) {
            log::info!(
                "get_episodes: '{}' returned no episodes but AniList count is {}; synthesising list",
                provider_name, count
            );
            episodes = (1..=count)
                .map(|n| crate::scraper::client::Episode {
                    number: n as i32,
                    title: None,
                    image: None,
                    download_status: None,
                })
                .collect();
        }

        // Second try: ask the fallback provider if we still have nothing.
        if episodes.is_empty() {
            let has_fallback = !fallback.is_empty() && fallback != "none" && fallback != provider_name;
            if has_fallback {
                log::info!("get_episodes: primary '{}' returned no episodes, trying fallback '{}'", provider_name, fallback);
                let fb_slug = registry::service::get_provider_slug(&db, media_id, &fallback)
                    .or(resolve_and_save_provider_slug(state, media_id, &fallback, false, None).await.ok().flatten());
                if let Some(slug) = fb_slug {
                    match state.scraper_manager.get_anime(&slug, &fallback).await {
                        Ok(info) if !info.episodes.is_empty() => {
                            notify(&format!("Couldn't reach {} — loaded from {}", super::playback::provider_label(&provider_name), super::playback::provider_label(&fallback)));
                            episodes = info.episodes;
                        }
                        Ok(_) => log::warn!("get_episodes: fallback '{}' also returned 0 episodes", fallback),
                        Err(e) => log::error!("get_episodes: fallback '{}' failed: {}", fallback, e),
                    }
                }
            }
        }
    }

    // Query download statuses from DB
    if let Ok(mut stmt) = db.prepare("SELECT episode_number, status FROM download_queue WHERE media_id = ?1") {
        if let Ok(status_rows) = stmt.query_map(rusqlite::params![media_id], |row| {
            Ok((row.get::<_, i64>(0)?, row.get::<_, String>(1)?))
        }) {
            let mut status_map = std::collections::HashMap::new();
            for (ep_num, status) in status_rows.flatten() {
                status_map.insert(ep_num, status);
            }
            for ep in &mut episodes {
                if let Some(status) = status_map.get(&(ep.number as i64)) {
                    ep.download_status = Some(status.clone());
                }
            }
        }
    }

    serde_json::to_value(episodes).map_err(|e| e.to_string())
}

#[tauri::command]
pub async fn resolve_stream(
    state: State<'_, AppState>,
    media_id: i64,
    episode_number: i32,
    provider: Option<String>,
) -> Result<Value, String> {
    resolve_stream_impl(state.inner(), media_id, episode_number, provider).await
}

pub async fn resolve_stream_impl(
    state: &AppState,
    media_id: i64,
    episode_number: i32,
    provider: Option<String>,
) -> Result<Value, String> {
    let provider_name = provider.unwrap_or_else(|| "mkissa".to_string());
    let fallback = {
        let cfg = state.config.read().await;
        cfg.general.fallback_provider.clone()
    };

    if provider_name == "nyaa" {
        let (url, _) = super::playback::resolve_stream_for_provider(
            state, media_id, episode_number as i64, "nyaa", &None, None,
        )
        .await?;
        return Ok(serde_json::json!({ "streams": [{
            "name": "Torrent (1080p)",
            "url": url,
            "quality": "1080p",
            "isM3U8": false,
            "headers": null,
            "group": "hard_sub",
        }] }));
    }

    let db = state.open_db()?;

    // Try primary provider
    if let Some(slug) = registry::service::get_provider_slug(&db, media_id, &provider_name) {
        if let Ok(servers) = state
            .scraper_manager
            .get_streams(&slug, episode_number, &provider_name)
            .await
        {
            return Ok(serde_json::json!({ "streams": servers }));
        }
    }

    // Try fallback provider
    if fallback != provider_name {
        log::info!("resolve_stream: primary provider '{}' failed, trying fallback '{}'", provider_name, fallback);
        if let Some(slug) = registry::service::get_provider_slug(&db, media_id, &fallback) {
            let servers = state
                .scraper_manager
                .get_streams(&slug, episode_number, &fallback)
                .await?;
            return Ok(serde_json::json!({ "streams": servers }));
        }
    }

    Err(format!("No stream found for media {} on '{}' or fallback '{}'", media_id, provider_name, fallback))
}

#[tauri::command]
pub async fn search_provider(
    state: State<'_, AppState>,
    query: String,
    provider: Option<String>,
) -> Result<Vec<crate::scraper::AnimeRef>, String> {
    search_provider_impl(state.inner(), query, provider).await
}

pub async fn search_provider_impl(
    state: &AppState,
    query: String,
    provider: Option<String>,
) -> Result<Vec<crate::scraper::AnimeRef>, String> {
    let provider_name = provider.unwrap_or_else(|| "mkissa".to_string());
    let fallback = {
        let cfg = state.config.read().await;
        cfg.general.fallback_provider.clone()
    };

    // Torrents have no show catalog to search. The re-match UI still works:
    // echo the query back as the one result, and saving it stores the query
    // as a manual search-title override for this media.
    if provider_name == "nyaa" {
        return Ok(vec![crate::scraper::AnimeRef {
            id: query.clone(),
            title: format!("Search torrents for \"{}\"", query),
            year: None,
        }]);
    }

    let results = state.scraper_manager.search(&query, &provider_name).await?;
    if !results.is_empty() || fallback == provider_name {
        return Ok(results);
    }

    log::info!("search_provider: '{}' returned 0 results for '{}', trying fallback '{}'", provider_name, query, fallback);
    state.scraper_manager.search(&query, &fallback).await
}

#[tauri::command]
pub async fn map_provider_slug(
    state: State<'_, AppState>,
    media_id: i64,
    provider: String,
    slug: String,
) -> Result<(), String> {
    map_provider_slug_impl(state.inner(), media_id, provider, slug).await
}

pub async fn map_provider_slug_impl(
    state: &AppState,
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
    clear_provider_cache_impl(state.inner(), media_id).await
}

pub async fn clear_provider_cache_impl(
    state: &AppState,
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
    let provider_name = provider.unwrap_or_else(|| "mkissa".to_string());
    let fallback = {
        let cfg = state.config.read().await;
        cfg.general.fallback_provider.clone()
    };
    let db = state.open_db()?;

    // Try each provider in order: primary → fallback
    let providers = if fallback != provider_name {
        vec![provider_name.as_str(), fallback.as_str()]
    } else {
        vec![provider_name.as_str()]
    };

    let mut slug = None;
    let mut resolved_provider = provider_name.clone();
    for prov in &providers {
        if let Some(s) = registry::service::get_provider_slug(&db, media_id, prov) {
            slug = Some(s);
            resolved_provider = prov.to_string();
            break;
        }
        // Auto-search: get title from AniList, search provider, save slug
        if let Some(found_slug) = resolve_and_save_provider_slug(
            &state,
            media_id,
            prov,
            false, // debug_provider_streams is always anime
            None,
        )
        .await?
        {
            slug = Some(found_slug);
            resolved_provider = prov.to_string();
            break;
        }
        log::info!("debug_provider_streams: '{}' found no match", prov);
    }

    let slug = slug.ok_or_else(|| format!(
        r#"{{"error":"no_slug","media_id":{},"provider":"{}","hint":"No results on primary or fallback provider"}}"#,
        media_id, provider_name
    ))?;

    let mut result = state.scraper_manager.debug_streams(&slug, episode_number, &resolved_provider).await?;
    if let Some(obj) = result.as_object_mut() {
        obj.insert("resolved_slug".to_string(), serde_json::json!(slug));
        obj.insert("provider".to_string(), serde_json::json!(resolved_provider));
    }
    Ok(result)
}

#[tauri::command]
pub async fn get_chapter_pages(
    state: State<'_, AppState>,
    media_id: i64,
    chapter_number: String,
) -> Result<Value, String> {
    get_chapter_pages_impl(state.inner(), media_id, chapter_number).await
}

pub async fn get_chapter_pages_impl(
    state: &AppState,
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
    get_library_impl(state.inner(), 0).await
}

pub async fn get_library_impl(
    state: &AppState,
    user_id: i64,
) -> Result<Vec<crate::registry::LibraryEntry>, String> {
    let db = state.open_db()?;
    registry::service::get_all_library(&db, user_id)
}

#[tauri::command]
#[allow(clippy::too_many_arguments)]
pub async fn add_to_library(
    state: State<'_, AppState>,
    media_id: i64,
    media_type: String,
    status: Option<String>,
    score: Option<f64>,
    progress: Option<i32>,
    notes: Option<String>,
) -> Result<(), String> {
    add_to_library_impl(state.inner(), 0, media_id, media_type, status, score, progress, notes).await
}

#[allow(clippy::too_many_arguments)]
pub async fn add_to_library_impl(
    state: &AppState,
    user_id: i64,
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
        user_id,
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
    remove_from_library_impl(state.inner(), 0, media_id).await
}

pub async fn remove_from_library_impl(
    state: &AppState,
    user_id: i64,
    media_id: i64,
) -> Result<(), String> {
    let db = state.open_db()?;
    registry::service::delete_library_entry(&db, user_id, media_id)
}

fn notify_download(app_handle: &tauri::AppHandle, message: &str) {
    use tauri::Emitter;
    let _ = app_handle.emit("show_notification", serde_json::json!({ "message": message }));
}

fn update_status_and_emit(
    app_handle: &tauri::AppHandle,
    db: &rusqlite::Connection,
    media_id: i64,
    episode_number: i64,
    status: &str,
    error_message: Option<&str>,
) -> Result<(), String> {
    crate::registry::service::update_queue_status(db, media_id, episode_number, status, error_message)?;
    use tauri::Emitter;
    let _ = app_handle.emit("download_status_change", serde_json::json!({
        "media_id": media_id,
        "episode_number": episode_number,
        "status": status,
        "error_message": error_message
    }));
    Ok(())
}

pub async fn start_download_worker(app_handle: tauri::AppHandle, state: crate::state::AppState) {
    log::info!("Download worker started");
    
    // Reset any stuck 'downloading' states to 'queued' on startup
    if let Ok(db) = state.open_db() {
        let _ = db.execute(
            "UPDATE download_queue SET status = 'queued' WHERE status = 'downloading'",
            [],
        );
    }

    loop {
        tokio::time::sleep(tokio::time::Duration::from_secs(2)).await;

        let db = match state.open_db() {
            Ok(d) => d,
            Err(e) => {
                log::error!("Download worker failed to open db: {}", e);
                continue;
            }
        };

        // Check if there is already an active download
        let active_count: Result<i64, _> = db.query_row(
            "SELECT COUNT(*) FROM download_queue WHERE status = 'downloading'",
            [],
            |row| row.get(0),
        );

        match active_count {
            Ok(count) if count > 0 => {
                // Downloader is busy, wait for next tick
                continue;
            }
            Err(e) => {
                log::error!("Failed to check active downloads: {}", e);
                continue;
            }
            _ => {}
        }

        // Fetch the next queued item
        let next_item: Result<(i64, i64, String), _> = db.query_row(
            "SELECT media_id, episode_number, media_title FROM download_queue WHERE status = 'queued' ORDER BY id ASC LIMIT 1",
            [],
            |row| Ok((row.get::<_, i64>(0)?, row.get::<_, i64>(1)?, row.get::<_, String>(2)?)),
        );

        if let Ok((media_id, ep_num, title)) = next_item {
            log::info!("Download worker: Starting download for media_id={}, episode={}", media_id, ep_num);
            download_episode(
                app_handle.clone(),
                state.clone(),
                media_id,
                ep_num,
                title,
            ).await;
        }
    }
}

async fn download_episode(
    app_handle: tauri::AppHandle,
    state: crate::state::AppState,
    media_id: i64,
    episode_number: i64,
    title: String,
) {
    let notify = |msg: &str| notify_download(&app_handle, msg);

    // Update status to downloading
    if let Ok(db) = state.open_db() {
        let _ = update_status_and_emit(&app_handle, &db, media_id, episode_number, "downloading", None);
    }

    // Get stream URL
    let db = match state.open_db() {
        Ok(d) => d,
        Err(_) => {
            notify("Failed to open database");
            return;
        }
    };
    let (slug, provider) = if let Some(s) = crate::registry::service::get_provider_slug(&db, media_id, "mkissa") {
        (s, "mkissa")
    } else if let Some(s) = crate::registry::service::get_provider_slug(&db, media_id, "anineko") {
        (s, "anineko")
    } else {
        let err = format!("No provider mapping for media {}", media_id);
        let _ = update_status_and_emit(&app_handle, &db, media_id, episode_number, "failed", Some(&err));
        notify(&err);
        return;
    };

    let servers = match state.scraper_manager.get_streams(&slug, episode_number as i32, provider).await {
        Ok(s) => s,
        Err(e) => {
            let err = format!("Failed to get stream: {}", e);
            if let Ok(db) = state.open_db() {
                let _ = update_status_and_emit(&app_handle, &db, media_id, episode_number, "failed", Some(&err));
            }
            notify(&err);
            return;
        }
    };

    let raw_url = match servers.first() {
        Some(s) => s.url.clone(),
        None => {
            let err = "No stream URL found".to_string();
            if let Ok(db) = state.open_db() {
                let _ = update_status_and_emit(&app_handle, &db, media_id, episode_number, "failed", Some(&err));
            }
            notify(&err);
            return;
        }
    };

    if !raw_url.starts_with("http://") && !raw_url.starts_with("https://") {
        let err = "Invalid stream URL scheme".to_string();
        if let Ok(db) = state.open_db() {
            let _ = update_status_and_emit(&app_handle, &db, media_id, episode_number, "failed", Some(&err));
        }
        notify(&err);
        return;
    }

    notify(&format!("Downloading episode {}...", episode_number));

    // Determine download path
    let downloads_path = {
        let cfg = state.config.read().await;
        let path = cfg.general.downloads_path.clone();
        if path.is_empty() {
            dirs::download_dir().unwrap_or_else(|| PathBuf::from(".")).to_string_lossy().to_string()
        } else {
            path
        }
    };

    let safe_title: String = title.chars().filter(|c| c.is_alphanumeric() || *c == ' ' || *c == '-' || *c == '_').collect();
    let filename = format!("{} - Episode {}.mp4", safe_title.trim(), episode_number);
    let filepath = std::path::Path::new(&downloads_path).join(&filename);

    if filepath.exists() {
        let _ = tokio::fs::remove_file(&filepath).await;
    }
    let filepath_ts = std::path::Path::new(&downloads_path).join(format!("{} - Episode {}.ts", safe_title.trim(), episode_number));
    if filepath_ts.exists() {
        let _ = tokio::fs::remove_file(&filepath_ts).await;
    }
    let filepath_part = std::path::Path::new(&downloads_path).join(format!("{} - Episode {}.mp4.part", safe_title.trim(), episode_number));
    if filepath_part.exists() {
        let _ = tokio::fs::remove_file(&filepath_part).await;
    }

    // Try to run yt-dlp directly if installed globally to start downloads instantly
    let mut cmd = if tokio::process::Command::new("yt-dlp").arg("--version").output().await.is_ok() {
        tokio::process::Command::new("yt-dlp")
    } else if std::path::Path::new("/opt/homebrew/bin/yt-dlp").exists() {
        tokio::process::Command::new("/opt/homebrew/bin/yt-dlp")
    } else if std::path::Path::new("/usr/local/bin/yt-dlp").exists() {
        tokio::process::Command::new("/usr/local/bin/yt-dlp")
    } else {
        let manifest_dir = std::path::Path::new(env!("CARGO_MANIFEST_DIR"));
        let dev_venv_yt = manifest_dir.join("../../.venv/bin/yt-dlp");
        let dev_venv_yt_win = manifest_dir.join("../../.venv/Scripts/yt-dlp.exe");

        let python_path = state.scraper_manager.python_path();
        let py_path = std::path::Path::new(python_path);
        let py_venv_yt = if py_path.is_absolute() {
            if let Some(parent) = py_path.parent() {
                let bin_yt = parent.join("yt-dlp");
                let exe_yt = parent.join("yt-dlp.exe");
                if bin_yt.exists() {
                    Some(bin_yt)
                } else if exe_yt.exists() {
                    Some(exe_yt)
                } else {
                    None
                }
            } else {
                None
            }
        } else {
            None
        };

        if dev_venv_yt.exists() {
            tokio::process::Command::new(dev_venv_yt)
        } else if dev_venv_yt_win.exists() {
            tokio::process::Command::new(dev_venv_yt_win)
        } else if let Some(p) = py_venv_yt {
            tokio::process::Command::new(p)
        } else if python_path.contains("uv") {
            let mut c = tokio::process::Command::new("uv");
            c.arg("run")
             .arg("yt-dlp");
            c
        } else {
            let mut c = tokio::process::Command::new(python_path);
            c.arg("-m")
             .arg("yt_dlp");
            c
        }
    };

    cmd.arg(&raw_url);

    // Pass custom HTTP headers if present (e.g. Referer, User-Agent)
    if let Some(server) = servers.first() {
        if let Some(ref headers) = server.headers {
            for (key, val) in headers {
                cmd.arg("--http-header").arg(format!("{}: {}", key, val));
            }
        }
    }

    cmd.arg("-o").arg(&filepath);
    cmd.arg("--force-overwrites");
    cmd.arg("--no-playlist");
    crate::util::suppress_console_tokio(&mut cmd);
    cmd.stdout(std::process::Stdio::piped());
    cmd.stderr(std::process::Stdio::piped());

    log::info!("Spawning download command: {:?}", cmd);

    // Run the download command
    let mut child = match cmd.spawn() {
        Ok(c) => c,
        Err(e) => {
            let err_msg = e.to_string();
            log::error!("Failed to spawn download process: {}", err_msg);
            if let Ok(db) = state.open_db() {
                let _ = update_status_and_emit(&app_handle, &db, media_id, episode_number, "failed", Some(&err_msg));
            }
            notify(&format!("Download process failed: {}", err_msg));
            return;
        }
    };

    let stdout = child.stdout.take().unwrap();
    let stderr = child.stderr.take().unwrap();

    use tokio::io::{AsyncBufReadExt, AsyncReadExt, BufReader};
    let mut stdout_reader = BufReader::new(stdout);
    let mut stderr_reader = BufReader::new(stderr).lines();

    let app_handle_clone = app_handle.clone();
    let state_clone = state.clone();

    // Spawn a task to read stdout and parse progress
    let stdout_handle = tokio::spawn(async move {
        let mut last_progress = -1.0;
        let mut buf = [0u8; 4096];
        let mut accumulator = Vec::new();

        while let Ok(n) = stdout_reader.read(&mut buf).await {
            if n == 0 {
                break;
            }
            accumulator.extend_from_slice(&buf[..n]);

            while let Some(pos) = accumulator.iter().position(|&b| b == b'\n' || b == b'\r') {
                let line_bytes = &accumulator[..pos];
                let line = String::from_utf8_lossy(line_bytes).into_owned();
                accumulator.drain(..=pos);

                let trimmed = line.trim();
                if trimmed.is_empty() {
                    continue;
                }

                let is_progress = is_progress_line(&line);

                if !is_progress {
                    log::info!("[yt-dlp stdout] {}", line);
                } else {
                    if let Some(pos) = line.find('%') {
                        let prefix = &line[..pos];
                        if let Some(start_pos) = prefix.rfind(|c: char| c.is_whitespace() || c == ']') {
                            let pct_str = prefix[start_pos + 1..].trim();
                            if let Ok(pct) = pct_str.parse::<f64>() {
                                if (pct - last_progress).abs() >= 1.0 || pct >= 100.0 {
                                    last_progress = pct;
                                    if let Ok(db) = state_clone.open_db() {
                                        let _ = crate::registry::service::update_queue_progress(&db, media_id, episode_number, pct);
                                    }
                                    use tauri::Emitter;
                                    let _ = app_handle_clone.emit("download_progress", serde_json::json!({
                                        "media_id": media_id,
                                        "episode_number": episode_number,
                                        "progress": pct
                                    }));
                                }
                            }
                        } else {
                            let pct_str = prefix.trim();
                            if let Ok(pct) = pct_str.parse::<f64>() {
                                if (pct - last_progress).abs() >= 1.0 || pct >= 100.0 {
                                    last_progress = pct;
                                    if let Ok(db) = state_clone.open_db() {
                                        let _ = crate::registry::service::update_queue_progress(&db, media_id, episode_number, pct);
                                    }
                                    use tauri::Emitter;
                                    let _ = app_handle_clone.emit("download_progress", serde_json::json!({
                                        "media_id": media_id,
                                        "episode_number": episode_number,
                                        "progress": pct
                                    }));
                                }
                            }
                        }
                    }
                }
            }
        }

        if !accumulator.is_empty() {
            let line = String::from_utf8_lossy(&accumulator).into_owned();
            let trimmed = line.trim();
            if !trimmed.is_empty() && !is_progress_line(&line) {
                log::info!("[yt-dlp stdout] {}", line);
            }
        }
    });

    let mut stderr_content = String::new();
    while let Ok(Some(line)) = stderr_reader.next_line().await {
        log::error!("[yt-dlp stderr] {}", line);
        stderr_content.push_str(&line);
        stderr_content.push('\n');
    }
    let _ = stdout_handle.await;

    match child.wait().await {
        Ok(status) => {
            log::info!("yt-dlp exited with status: {}", status);
            if status.success() {
                if let Ok(db) = state.open_db() {
                    let _ = update_status_and_emit(&app_handle, &db, media_id, episode_number, "completed", None);
                    let _ = crate::registry::service::update_queue_progress(&db, media_id, episode_number, 100.0);
                }
                notify(&format!("Downloaded: {}", filename));
                // Emit final 100% progress event
                use tauri::Emitter;
                let _ = app_handle.emit("download_progress", serde_json::json!({
                    "media_id": media_id,
                    "episode_number": episode_number,
                    "progress": 100.0
                }));
            } else {
                let err_msg = stderr_content.trim();
                let short_err = if err_msg.is_empty() {
                    "yt-dlp exited with error status".to_string()
                } else {
                    err_msg.lines().next().unwrap_or("Unknown error").to_string()
                };
                if let Ok(db) = state.open_db() {
                    let _ = update_status_and_emit(&app_handle, &db, media_id, episode_number, "failed", Some(&short_err));
                }
                notify(&format!("Download failed for episode {}: {}", episode_number, short_err));
            }
        }
        Err(e) => {
            let err_msg = e.to_string();
            log::error!("Failed to wait for download process: {}", err_msg);
            if let Ok(db) = state.open_db() {
                let _ = update_status_and_emit(&app_handle, &db, media_id, episode_number, "failed", Some(&err_msg));
            }
            notify(&format!("Download process failed: {}", err_msg));
        }
    }
}

#[tauri::command]
pub async fn add_to_queue(
    app: tauri::AppHandle,
    state: State<'_, AppState>,
    media_id: i64,
    episodes: Vec<i64>,
    title: Option<String>,
    cover_image: Option<String>,
) -> Result<(), String> {
    log::info!("add_to_queue invoked: media_id={}, episodes={:?}, title={:?}, cover_image={:?}", media_id, episodes, title, cover_image);
    let db = state.open_db()?;
    let title_str = title.clone().unwrap_or_else(|| format!("Media {}", media_id));
    
    // Download cover image if it's an online URL to allow offline loading
    let cover_str = if let Some(ref url) = cover_image {
        if url.starts_with("http") {
            let app_data_dir = app.path().app_data_dir()
                .unwrap_or_else(|_| std::path::PathBuf::from("."));
            let covers_dir = app_data_dir.join("covers");
            let _ = std::fs::create_dir_all(&covers_dir);
            let dest_path = covers_dir.join(format!("{}.jpg", media_id));
            
            match state.http_client.get(url).send().await {
                Ok(resp) => {
                    if let Ok(bytes) = resp.bytes().await {
                        if std::fs::write(&dest_path, bytes).is_ok() {
                            log::info!("Saved local cover image to: {:?}", dest_path);
                            dest_path.to_string_lossy().to_string()
                        } else {
                            url.clone()
                        }
                    } else {
                        url.clone()
                    }
                }
                Err(e) => {
                    log::warn!("Failed to download cover image: {}", e);
                    url.clone()
                }
            }
        } else {
            url.clone()
        }
    } else {
        "".to_string()
    };

    for ep in episodes {
        crate::registry::service::add_to_queue(&db, media_id, ep, &title_str, &cover_str)?;
        use tauri::Emitter;
        let _ = app.emit("download_status_change", serde_json::json!({
            "media_id": media_id,
            "episode_number": ep,
            "status": "queued"
        }));
    }
    Ok(())
}

#[tauri::command]
pub async fn get_queue(
    app: tauri::AppHandle,
    state: State<'_, AppState>,
) -> Result<Vec<crate::registry::service::QueueItem>, String> {
    let db = state.open_db()?;
    let mut res = crate::registry::service::get_all_queue(&db)?;
    
    // Migrate old cover paths to the sandboxed app_data_dir/covers
    let app_data_dir = app.path().app_data_dir().unwrap_or_else(|_| std::path::PathBuf::from("."));
    let new_covers_dir = app_data_dir.join("covers");
    let _ = std::fs::create_dir_all(&new_covers_dir);

    for item in &mut res {
        if item.cover_image.contains("/anicat/covers/") {
            let old_path = std::path::PathBuf::from(&item.cover_image);
            if old_path.exists() {
                if let Some(file_name) = old_path.file_name() {
                    let new_path = new_covers_dir.join(file_name);
                    if !new_path.exists() {
                        let _ = std::fs::copy(&old_path, &new_path);
                    }
                    let new_path_str = new_path.to_string_lossy().to_string();
                    let _ = db.execute(
                        "UPDATE download_queue SET cover_image = ?1 WHERE media_id = ?2",
                        rusqlite::params![new_path_str, item.media_id],
                    );
                    item.cover_image = new_path_str;
                }
            }
        }
    }

    log::debug!("get_queue returning {} items: {:?}", res.len(), res);
    Ok(res)
}

#[tauri::command]
pub async fn remove_from_queue(
    app: tauri::AppHandle,
    state: State<'_, AppState>,
    media_id: i64,
    episode_number: i64,
) -> Result<(), String> {
    let db = state.open_db()?;
    
    // Attempt to delete downloaded files
    let queue_items = crate::registry::service::get_all_queue(&db)?;
    let item = queue_items.iter().find(|i| i.media_id == media_id && i.episode_number == episode_number);
    if let Some(i) = item {
        let downloads_path = {
            let cfg = state.config.read().await;
            let path = cfg.general.downloads_path.clone();
            if path.is_empty() {
                dirs::download_dir().unwrap_or_else(|| PathBuf::from(".")).to_string_lossy().to_string()
            } else {
                path
            }
        };
        let safe_title: String = i.media_title.chars().filter(|c| c.is_alphanumeric() || *c == ' ' || *c == '-' || *c == '_').collect();
        let filename = format!("{} - Episode {}.mp4", safe_title.trim(), episode_number);
        let filepath = std::path::Path::new(&downloads_path).join(&filename);
        if filepath.exists() {
            let _ = std::fs::remove_file(filepath);
        }
        let filename_ts = format!("{} - Episode {}.ts", safe_title.trim(), episode_number);
        let filepath_ts = std::path::Path::new(&downloads_path).join(&filename_ts);
        if filepath_ts.exists() {
            let _ = std::fs::remove_file(filepath_ts);
        }
    }

    crate::registry::service::remove_from_queue(&db, media_id, episode_number)?;

    use tauri::Emitter;
    let _ = app.emit("download_status_change", serde_json::json!({
        "media_id": media_id,
        "episode_number": episode_number,
        "status": "removed"
    }));
    Ok(())
}

#[tauri::command]
pub async fn retry_queue(
    app: tauri::AppHandle,
    state: State<'_, AppState>,
) -> Result<(), String> {
    let db = state.open_db()?;
    let all_items = crate::registry::service::get_all_queue(&db)?;
    let failed_items: Vec<_> = all_items.into_iter().filter(|i| i.status == "failed").collect();
    
    crate::registry::service::retry_queue(&db)?;

    use tauri::Emitter;
    for item in failed_items {
        let _ = app.emit("download_status_change", serde_json::json!({
            "media_id": item.media_id,
            "episode_number": item.episode_number,
            "status": "queued"
        }));
    }
    Ok(())
}

// ── Smart Similarity Matcher for Anime/Manga Searches ──────

fn normalize_title(title: &str) -> String {
    title
        .chars()
        .filter(|c| c.is_alphanumeric())
        .collect::<String>()
        .to_lowercase()
}

/// Which entry of a franchise a title names. AniList and provider catalogs
/// express this in incompatible ways ("Season 2", "2nd Season", a bare
/// trailing "2", the double-integral in "Go-toubun no Hanayome ∬"), and
/// `normalize_title` strips the non-alphanumeric markers entirely — so pure
/// string similarity happily maps a season-2 or 2-episode-specials entry onto
/// season 1. The variant is extracted before normalization and mismatching
/// candidates are vetoed in `calculate_similarity`.
#[derive(Debug, PartialEq, Eq, Clone, Copy)]
enum TitleKind {
    Tv,
    Movie,
    Special,
}

#[derive(Debug, PartialEq, Eq, Clone, Copy)]
struct TitleVariant {
    season: u32,
    part: u32,
    kind: TitleKind,
    /// Tilde/asterisk-style specials markers ("Quintuplets~" vs "Quintuplets*"
    /// are different specials), kept to break ties normalization erases.
    marker: Option<char>,
}

/// Fold unicode season/variant markers into plain ascii so one parser handles
/// both AniList's typography and provider catalog titles.
fn fold_title_markers(title: &str) -> String {
    let mut folded = String::with_capacity(title.len() + 4);
    for c in title.chars() {
        match c {
            '∬' | 'Ⅱ' | 'ⅱ' => folded.push_str(" 2"),
            '∭' | 'Ⅲ' | 'ⅲ' => folded.push_str(" 3"),
            'Ⅳ' | 'ⅳ' => folded.push_str(" 4"),
            'Ⅴ' | 'ⅴ' => folded.push_str(" 5"),
            '∽' | '〜' | '～' => folded.push('~'),
            '＊' => folded.push('*'),
            _ => folded.push(c),
        }
    }
    folded
}

fn title_variant(title: &str) -> TitleVariant {
    use std::sync::OnceLock;
    static SEASON_RES: OnceLock<Vec<regex_lite::Regex>> = OnceLock::new();
    static TRAILING_NUM_RE: OnceLock<regex_lite::Regex> = OnceLock::new();
    static TRAILING_ROMAN_RE: OnceLock<regex_lite::Regex> = OnceLock::new();
    static PART_RE: OnceLock<regex_lite::Regex> = OnceLock::new();
    static MOVIE_RE: OnceLock<regex_lite::Regex> = OnceLock::new();
    static SPECIAL_RE: OnceLock<regex_lite::Regex> = OnceLock::new();

    let lower = fold_title_markers(title).to_lowercase();

    // A lone trailing "~" or "*" is a specials marker ("Quintuplets~" vs
    // "Quintuplets*"); paired tildes are just a wrapped subtitle
    // ("Uma Musume ~Pretty Derby~") and say nothing about the variant.
    let trimmed = lower.trim_end();
    let marker = ['~', '*']
        .into_iter()
        .find(|&c| trimmed.ends_with(c) && lower.matches(c).count() == 1);

    let season_res = SEASON_RES.get_or_init(|| {
        [
            r"\bseason[\s._-]*(\d{1,2})\b",
            r"\b(\d{1,2})(?:st|nd|rd|th)[\s._-]*season\b",
            r"\bs(\d{1,2})\b",
        ]
        .iter()
        .map(|p| regex_lite::Regex::new(p).unwrap())
        .collect()
    });
    let mut season = season_res
        .iter()
        .find_map(|re| re.captures(&lower))
        .and_then(|c| c[1].parse::<u32>().ok());
    if season.is_none() {
        // A bare trailing number ("Quintuplets 2") or roman numeral
        // ("Overlord III") is a season marker too; longer numbers
        // ("Mob Psycho 100") are part of the name.
        let num_re = TRAILING_NUM_RE
            .get_or_init(|| regex_lite::Regex::new(r"\s(\d{1,2})\s*$").unwrap());
        season = num_re.captures(&lower).and_then(|c| c[1].parse::<u32>().ok());
    }
    if season.is_none() {
        let roman_re = TRAILING_ROMAN_RE
            .get_or_init(|| regex_lite::Regex::new(r"\s(ix|iv|v?i{1,3}|x)\s*$").unwrap());
        season = roman_re.captures(&lower).map(|c| match &c[1] {
            "ii" => 2,
            "iii" => 3,
            "iv" => 4,
            "v" => 5,
            "vi" => 6,
            "vii" => 7,
            "viii" => 8,
            "ix" => 9,
            "x" => 10,
            _ => 1,
        });
    }

    let part_re = PART_RE
        .get_or_init(|| regex_lite::Regex::new(r"\b(?:part|cour)[\s._-]*(\d{1,2})\b").unwrap());
    let part = part_re
        .captures(&lower)
        .and_then(|c| c[1].parse::<u32>().ok())
        .unwrap_or(1);

    let movie_re = MOVIE_RE
        .get_or_init(|| regex_lite::Regex::new(r"\bmovie\b|\beiga\b|\bgekijouban\b").unwrap());
    let special_re = SPECIAL_RE
        .get_or_init(|| regex_lite::Regex::new(r"\bspecials?\b|\bovas?\b|\bona\b").unwrap());
    let kind = if movie_re.is_match(&lower) || lower.contains("映画") || lower.contains("劇場版") {
        TitleKind::Movie
    } else if special_re.is_match(&lower) || marker.is_some() {
        TitleKind::Special
    } else {
        TitleKind::Tv
    };

    TitleVariant {
        season: season.unwrap_or(1),
        part,
        kind,
        marker,
    }
}

/// Multiplier applied on top of string similarity. A candidate naming a
/// different season/part/kind is vetoed outright (pushed below the 0.4
/// match threshold no matter how similar the base strings are); a mere
/// specials-marker difference ("~" vs "*") is only demoted so the right
/// marker wins ties but a lone candidate can still match.
fn variant_penalty(target: &TitleVariant, candidate: &TitleVariant) -> f64 {
    if target.season != candidate.season
        || target.part != candidate.part
        || target.kind != candidate.kind
    {
        return 0.3;
    }
    if target.marker != candidate.marker {
        return 0.8;
    }
    1.0
}

#[allow(clippy::needless_range_loop)] // index-based DP table is clearest here
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
    let penalty = variant_penalty(&title_variant(target), &title_variant(candidate));
    base_similarity(target, candidate) * penalty
}

fn base_similarity(target: &str, candidate: &str) -> f64 {
    let target_norm = normalize_title(target);
    let candidate_norm = normalize_title(candidate);

    if target_norm.is_empty() || candidate_norm.is_empty() {
        return 0.0;
    }

    if target.eq_ignore_ascii_case(candidate) {
        return 1.2; // Absolute perfect match
    }

    if target_norm == candidate_norm {
        // If they normalize to the same string (e.g. "Title" and "Title*"), 
        // penalize the one that had extra characters stripped so the exact match wins.
        let len_diff = (target.len() as i32 - candidate.len() as i32).abs() as f64;
        return 1.0 - (len_diff * 0.01);
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

/// Fetch a media's AniList detail, cached by (id, type). MEDIA_DETAIL_QUERY is
/// executed from several backend paths for the same media during one
/// open-and-watch flow — the detail page, the provider-slug resolver, the
/// AniSkip MAL-id lookup, the completion check, and the torrent title
/// gatherer. They all read stable metadata (title, synonyms, episode count,
/// id_mal), so serving them from a shared cache collapses 4-5 identical
/// AniList requests into one. (The mediaListEntry / progress in the response
/// is *not* relied on by these internal callers; the UI's own
/// `get_media_detail` command stays uncached so it always shows fresh
/// progress.)
pub(crate) async fn fetch_media_detail_cached(
    state: &AppState,
    media_id: i64,
    is_manga: bool,
) -> Result<crate::anilist::responses::MediaResponse, String> {
    let media_type = if is_manga { "MANGA" } else { "ANIME" };
    let key = AniListCache::key("media_detail", &[("id", &media_id.to_string()), ("type", media_type)]);
    if let Some(cached) = state.cache.get(&key) {
        if let Ok(parsed) = serde_json::from_value::<crate::anilist::responses::MediaResponse>(cached) {
            return Ok(parsed);
        }
    }
    let mut vars = std::collections::HashMap::new();
    vars.insert("id".to_string(), serde_json::json!(media_id));
    vars.insert("type".to_string(), serde_json::json!(media_type));
    let result: crate::anilist::responses::MediaResponse = state
        .anilist_client
        .execute(crate::anilist::queries::MEDIA_DETAIL_QUERY, vars)
        .await?;
    if let Ok(v) = serde_json::to_value(&result) {
        state.cache.set(key, v, "media_detail");
    }
    Ok(result)
}

async fn media_is_finished(state: &AppState, media_id: i64) -> bool {
    match fetch_media_detail_cached(state, media_id, false).await {
        Ok(detail) => detail
            .media
            .and_then(|m| m.status)
            .as_deref()
            == Some("FINISHED"),
        Err(_) => false,
    }
}

pub async fn resolve_and_save_provider_slug(
    state: &AppState,
    media_id: i64,
    provider_name: &str,
    is_manga: bool,
    frontend_title: Option<String>,
) -> Result<Option<String>, String> {
    // The torrent provider has no scraper catalog to search against; its
    // "slug" is only ever a user-entered search-title override.
    if provider_name == "nyaa" {
        return Ok(None);
    }
    let detail_res = fetch_media_detail_cached(state, media_id, is_manga).await;

    let mut romaji_title = String::new();
    let mut english_title = String::new();
    let mut native_title = String::new();
    let mut synonyms_vec = vec![];

    if let Ok(ref detail) = detail_res {
        if let Some(ref m) = detail.media {
            if let Some(ref t) = m.title {
                romaji_title = t.romaji.clone().unwrap_or_default();
                english_title = t.english.clone().unwrap_or_default();
                native_title = t.native.clone().unwrap_or_default();
            }
            if let Some(ref syns) = m.synonyms {
                for s in syns {
                    synonyms_vec.push(s.clone());
                }
            }
        }
    }

    if romaji_title.is_empty() && english_title.is_empty() {
        if let Some(ref t) = frontend_title {
            romaji_title = t.clone();
        }
    }

    let mut target_titles = vec![];
    if !romaji_title.is_empty() { target_titles.push(romaji_title.as_str()); }
    if !english_title.is_empty() { target_titles.push(english_title.as_str()); }
    if !native_title.is_empty() { target_titles.push(native_title.as_str()); }
    for s in &synonyms_vec {
        target_titles.push(s.as_str());
    }

    let mut search_candidates = vec![];
    if !english_title.is_empty() {
        search_candidates.push(english_title.clone());
    }
    if !romaji_title.is_empty() && !search_candidates.contains(&romaji_title) {
        search_candidates.push(romaji_title.clone());
    }
    for s in &synonyms_vec {
        if !s.is_empty() && !search_candidates.contains(s) {
            search_candidates.push(s.clone());
        }
    }
    if search_candidates.is_empty() {
        if let Some(ref t) = frontend_title {
            if !t.is_empty() {
                search_candidates.push(t.clone());
            }
        }
    }

    if search_candidates.is_empty() {
        return Ok(None);
    }

    let mut results = vec![];
    for (idx, query) in search_candidates.iter().enumerate() {
        if idx > 0 {
            log::info!("resolve_and_save_provider_slug: sleeping 1.5s before next query to prevent rate limiting");
            tokio::time::sleep(std::time::Duration::from_millis(1500)).await;
        }
        log::info!("resolve_and_save_provider_slug: searching '{}' on '{}'", query, provider_name);
        let search_res = if is_manga {
            state.scraper_manager.search_manga(query).await
        } else {
            state.scraper_manager.search(query, provider_name).await
        };

        match search_res {
            Ok(res) => {
                if !res.is_empty() {
                    log::info!("resolve_and_save_provider_slug: found {} results for query '{}'", res.len(), query);
                    results = res;
                    break;
                }
            }
            Err(e) => {
                log::error!("resolve_and_save_provider_slug: search failed for '{}' on '{}': {}", query, provider_name, e);
            }
        }
    }

    let translation_type = {
        let cfg = state.config.read().await;
        cfg.stream.translation_type.clone()
    };

    if let Some(best) = find_best_match(&target_titles, results, |r| &r.title, &translation_type) {
        log::info!("resolve_and_save_provider_slug: matched '{}' to slug '{}'", best.title, best.id);
        let db = state.open_db()?;
        let _ = registry::service::set_provider_slug(&db, media_id, provider_name, &best.id);
        Ok(Some(best.id))
    } else {
        log::warn!("resolve_and_save_provider_slug: no match found for media_id={}", media_id);
        Ok(None)
    }
}

pub fn find_best_match<T, F>(target_titles: &[&str], candidates: Vec<T>, get_title: F, preferred_translation: &str) -> Option<T>
where
    F: Fn(&T) -> &str,
{
    let mut best_index = None;
    let mut best_score = 0.4_f64;

    for (idx, candidate) in candidates.iter().enumerate() {
        let cand_title = get_title(candidate);
        let cand_lower = cand_title.to_lowercase();
        
        let has_dub = cand_lower.contains("dub") && (cand_lower.contains("(dub)") || cand_lower.contains("[dub]"));
        let translation_penalty = if preferred_translation == "sub" && has_dub {
            0.5
        } else if preferred_translation == "dub" && !has_dub && candidates.iter().any(|c| get_title(c).to_lowercase().contains("dub")) {
            0.5
        } else {
            1.0
        };

        for &target in target_titles {
            if target.is_empty() {
                continue;
            }
            let score = calculate_similarity(target, cand_title) * translation_penalty;
            if score > best_score {
                best_score = score;
                best_index = Some(idx);
            }
        }
    }

    if let Some(idx) = best_index {
        let mut candidates = candidates;
        Some(candidates.remove(idx))
    } else {
        None
    }
}

fn is_progress_line(line: &str) -> bool {
    let trimmed = line.trim();
    if trimmed.is_empty() {
        return true;
    }
    let has_progress_keywords = trimmed.contains('%') 
        || trimmed.contains("ETA") 
        || trimmed.contains("frag") 
        || trimmed.contains("KiB/s") 
        || trimmed.contains("MiB/s") 
        || trimmed.contains("B/s");
        
    (trimmed.contains("[download]") && has_progress_keywords)
        || (trimmed.starts_with(|c: char| c.is_ascii_digit() || c == '.') && trimmed.contains('%'))
        || (trimmed.contains('%') && (trimmed.contains("at") || trimmed.contains("ETA")))
}

#[cfg(test)]
mod tests {
    use super::*;

    #[derive(Debug, Clone)]
    struct DummyAnime {
        title: String,
        id: String,
    }

    #[test]
    fn test_find_best_match_multi() {
        let candidates = vec![
            DummyAnime {
                title: "The Ramparts of Ice".to_string(),
                id: "123".to_string(),
            },
            DummyAnime {
                title: "Bleach".to_string(),
                id: "456".to_string(),
            },
        ];

        let targets = vec!["Koori no Jouheki", "The Ramparts of Ice", "氷 of 城壁"];
        let matched = find_best_match(&targets, candidates, |r| &r.title, "");
        assert!(matched.is_some());
        assert_eq!(matched.unwrap().id, "123");
    }

    // Real mkissa search results for "The Quintessential Quintuplets".
    fn quintuplets_candidates() -> Vec<DummyAnime> {
        [
            ("The Quintessential Quintuplets*", "specials2"),
            ("The Quintessential Quintuplets Specials", "specials"),
            ("The Quintessential Quintuplets Movie", "movie"),
            ("The Quintessential Quintuplets 2", "s2"),
            ("The Quintessential Quintuplets", "s1"),
        ]
        .iter()
        .map(|(t, id)| DummyAnime { title: t.to_string(), id: id.to_string() })
        .collect()
    }

    #[test]
    fn season_one_does_not_match_specials() {
        // Season 1's targets normalize identically to the "*" specials entry,
        // which used to win when it appeared first in the search results.
        let targets = vec!["Go-toubun no Hanayome", "The Quintessential Quintuplets"];
        let m = find_best_match(&targets, quintuplets_candidates(), |r| &r.title, "").unwrap();
        assert_eq!(m.id, "s1");
    }

    #[test]
    fn season_two_integral_marker_is_a_season() {
        // Romaji-only targets: "∬" used to be stripped by normalization,
        // making season 2 a near-exact (0.98) match for the season 1 entry.
        // With the marker read as a season, nothing here is string-similar
        // enough — no match beats a wrong-season match.
        let targets = vec!["Go-toubun no Hanayome ∬", "5-toubun no Hanayome ∬"];
        assert!(find_best_match(&targets, quintuplets_candidates(), |r| &r.title, "").is_none());

        // With the English title present (as the real resolver always has),
        // season 2 wins.
        let targets = vec!["Go-toubun no Hanayome ∬", "The Quintessential Quintuplets 2"];
        let m = find_best_match(&targets, quintuplets_candidates(), |r| &r.title, "").unwrap();
        assert_eq!(m.id, "s2");
    }

    #[test]
    fn wrong_season_is_vetoed_when_right_one_is_absent() {
        let targets = vec!["Go-toubun no Hanayome ∬"];
        let candidates = vec![DummyAnime {
            title: "The Quintessential Quintuplets".to_string(),
            id: "s1".to_string(),
        }];
        assert!(find_best_match(&targets, candidates, |r| &r.title, "").is_none());
    }

    #[test]
    fn specials_marker_breaks_normalization_ties() {
        // anineko names the two specials "…~" and "…*"; the "∽" target must
        // pick the tilde entry, not season 1 or the other specials.
        let targets = vec!["Go-toubun no Hanayome∽", "The Quintessential Quintuplets∽"];
        let candidates: Vec<DummyAnime> = [
            ("The Quintessential Quintuplets: The Movie", "movie"),
            ("The Quintessential Quintuplets", "s1"),
            ("The Quintessential Quintuplets 2", "s2"),
            ("The Quintessential Quintuplets*", "specials2"),
            ("The Quintessential Quintuplets~", "specials"),
        ]
        .iter()
        .map(|(t, id)| DummyAnime { title: t.to_string(), id: id.to_string() })
        .collect();
        let m = find_best_match(&targets, candidates, |r| &r.title, "").unwrap();
        assert_eq!(m.id, "specials");
    }

    #[test]
    fn season_word_forms_agree() {
        let targets = vec!["Golden Kamuy 2nd Season"];
        let candidates: Vec<DummyAnime> = [
            ("Golden Kamuy", "s1"),
            ("Golden Kamuy Season 2", "s2"),
        ]
        .iter()
        .map(|(t, id)| DummyAnime { title: t.to_string(), id: id.to_string() })
        .collect();
        let m = find_best_match(&targets, candidates, |r| &r.title, "").unwrap();
        assert_eq!(m.id, "s2");
    }

    #[test]
    fn trailing_long_numbers_are_not_seasons() {
        let targets = vec!["Mob Psycho 100"];
        let candidates: Vec<DummyAnime> = [
            ("Mob Psycho 100 II", "s2"),
            ("Mob Psycho 100", "s1"),
        ]
        .iter()
        .map(|(t, id)| DummyAnime { title: t.to_string(), id: id.to_string() })
        .collect();
        let m = find_best_match(&targets, candidates, |r| &r.title, "").unwrap();
        assert_eq!(m.id, "s1");
    }

    #[test]
    fn wrapped_tilde_subtitle_is_not_a_specials_marker() {
        let targets = vec!["Uma Musume: Pretty Derby"];
        let candidates = vec![DummyAnime {
            title: "Uma Musume ~Pretty Derby~".to_string(),
            id: "s1".to_string(),
        }];
        let m = find_best_match(&targets, candidates, |r| &r.title, "").unwrap();
        assert_eq!(m.id, "s1");
    }

    #[test]
    fn movie_target_prefers_movie_entry() {
        let targets = vec!["Go-toubun no Hanayome Movie", "The Quintessential Quintuplets Movie"];
        let m = find_best_match(&targets, quintuplets_candidates(), |r| &r.title, "").unwrap();
        assert_eq!(m.id, "movie");
    }

    #[tokio::test]
    #[ignore = "integration test: needs the scraper binary and network; run with --ignored"]
    async fn quintuplets_seasons_resolve_to_distinct_entries() {
        let _ = env_logger::builder().is_test(true).try_init();
        let state = AppState::new();
        let db = state.open_db().unwrap();

        // S1 (12 eps), S2 (12 eps), Specials (2 eps) must map to three
        // different mkissa catalog entries.
        let ids = [103572_i64, 109261, 163327];
        let mut slugs = vec![];
        for id in ids {
            let _ = registry::service::clear_provider_slug(&db, id, "mkissa");
            let slug = resolve_and_save_provider_slug(&state, id, "mkissa", false, None)
                .await
                .unwrap();
            println!("media {} -> {:?}", id, slug);
            let _ = registry::service::clear_provider_slug(&db, id, "mkissa");
            slugs.push(slug.expect("each entry should resolve"));
        }
        assert_eq!(
            slugs.iter().collect::<std::collections::HashSet<_>>().len(),
            slugs.len(),
            "seasons collapsed onto the same provider entry: {:?}",
            slugs
        );
    }

    #[tokio::test]
    #[ignore = "integration test: needs the scraper binary and network; run with --ignored"]
    async fn test_synonym_fallbacks() {
        let _ = env_logger::builder().is_test(true).try_init();
        let state = AppState::new();
        let db = state.open_db().unwrap();
        
        let _ = registry::service::clear_provider_cache(&db, 149893);
        let _ = registry::service::clear_provider_cache(&db, 20668);

        // Test Mistress Kanan is Devilishly Easy on MangaKatana
        let slug_manga = resolve_and_save_provider_slug(
            &state,
            149893,
            "mangakatana",
            true, // is_manga
            Some("Mistress Kanan is Devilishly Easy".to_string()),
        )
        .await
        .unwrap();
        println!("RESOLVED MANGA SLUG: {:?}", slug_manga);
        assert!(slug_manga.is_some());
        assert!(slug_manga.unwrap().contains("kanan-sama-is-easy-as-hell"));

        // Test Monthly Girls' Nozaki-kun on Mkissa
        let slug_anime = resolve_and_save_provider_slug(
            &state,
            20668,
            "mkissa",
            false, // is_manga
            Some("Monthly Girls' Nozaki-kun".to_string()),
        )
        .await
        .unwrap();
        println!("RESOLVED ANIME SLUG: {:?}", slug_anime);
        assert!(slug_anime.is_some());
        assert_eq!(slug_anime.unwrap(), "5oBy5h4pAPn6wrxvv");
    }
}

