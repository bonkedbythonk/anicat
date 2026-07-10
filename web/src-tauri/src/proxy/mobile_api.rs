//! JSON HTTP surface for the LAN-facing mobile PWA.
//!
//! Every handler here is a thin wrapper: pull `AppState` out of the same
//! `AppHandle` the proxy already carries (`app_handle.state::<AppState>()` —
//! the same pattern `proxy/server.rs`'s `/player/*` handlers already use to
//! call into Tauri commands from outside Tauri's own IPC dispatch), then call
//! the existing `#[tauri::command]` function directly. No business logic is
//! duplicated; this module only adapts HTTP <-> the same command functions
//! the desktop webview calls via `invoke()`.
//!
//! Deliberately excluded: the 4 download-queue commands (out of scope per
//! the user's request), and anything that needs desktop OS integration
//! (OAuth browser launch, log viewer, auto-update, app restart).

use axum::{
    extract::{Path, Query, State},
    http::StatusCode,
    response::Json,
    routing::{delete, get, post},
    Router,
};
use serde::Deserialize;
use serde_json::Value;
use tauri::Manager;

use super::server::ProxyState;
use crate::state::AppState;

fn ok_or_500<T: serde::Serialize>(r: Result<T, String>) -> Result<Json<Value>, (StatusCode, Json<Value>)> {
    r.map(|v| Json(serde_json::to_value(v).unwrap_or(Value::Null)))
        .map_err(|e| (StatusCode::INTERNAL_SERVER_ERROR, Json(serde_json::json!({ "error": e }))))
}

pub fn routes() -> Router<ProxyState> {
    Router::new()
        .route("/config", get(get_config).post(update_config))
        .route("/user/list", get(get_user_list))
        .route("/user/profile", get(get_user_profile))
        .route("/user/list-entry", post(save_media_list_entry))
        .route("/user/list-entry/{entry_id}", delete(delete_media_list_entry))
        .route("/user/favourite", post(toggle_favourite))
        .route("/user/notifications", get(get_notifications))
        .route("/user/notifications/read", post(mark_notifications_read))
        .route("/schedule", get(get_airing_schedule))
        .route("/media/search", get(search_media))
        .route("/media/trending", get(get_trending))
        .route("/media/seasonal", get(get_seasonal))
        .route("/media/upcoming", get(get_upcoming))
        .route("/smart-playlist", get(get_smart_playlist))
        .route("/media/{id}", get(get_media_detail))
        .route("/media/{id}/characters", get(get_media_characters))
        .route("/media/{id}/episodes", get(get_episodes))
        .route("/media/{id}/streams", get(resolve_stream))
        .route("/media/{id}/chapters/{chapter_number}", get(get_chapter_pages))
        .route("/provider/search", get(search_provider))
        .route("/provider/map-slug", post(map_provider_slug))
        .route("/provider/clear-cache", post(clear_provider_cache))
        .route("/library", get(get_library).post(add_to_library))
        .route("/library/{media_id}", delete(remove_from_library))
        .route("/playback/watched/{media_id}", get(get_watched_episodes))
        .route("/playback/last-watched", get(get_all_last_watched))
        .route("/playback/preload", post(preload_episode))
        .route("/playback/resolve", post(resolve_playback))
        .route("/health", get(check_health))
        .route("/version", get(get_app_version))
}

fn state_of(state: &ProxyState) -> tauri::State<'_, AppState> {
    state.app_handle.state::<AppState>()
}

// ── config ──────────────────────────────────────────────────

async fn get_config(State(state): State<ProxyState>) -> Result<Json<Value>, (StatusCode, Json<Value>)> {
    ok_or_500(crate::commands::config::get_config(state_of(&state)).await)
}

async fn update_config(
    State(state): State<ProxyState>,
    Json(updates): Json<Value>,
) -> Result<Json<Value>, (StatusCode, Json<Value>)> {
    ok_or_500(crate::commands::config::update_config(state_of(&state), updates).await.map(|_| Value::Null))
}

// ── user ────────────────────────────────────────────────────

#[derive(Deserialize)]
struct UserListQuery {
    user_name: Option<String>,
    status: Option<String>,
    media_type: Option<String>,
}

async fn get_user_list(
    State(state): State<ProxyState>,
    Query(q): Query<UserListQuery>,
) -> Result<Json<Value>, (StatusCode, Json<Value>)> {
    ok_or_500(crate::commands::user::get_user_list(state_of(&state), q.user_name, q.status, q.media_type).await)
}

async fn get_user_profile(State(state): State<ProxyState>) -> Result<Json<Value>, (StatusCode, Json<Value>)> {
    ok_or_500(crate::commands::user::get_user_profile(state_of(&state)).await)
}

#[derive(Deserialize)]
struct ListEntryBody {
    media_id: i64,
    updates: Value,
}

async fn save_media_list_entry(
    State(state): State<ProxyState>,
    Json(body): Json<ListEntryBody>,
) -> Result<Json<Value>, (StatusCode, Json<Value>)> {
    ok_or_500(crate::commands::user::save_media_list_entry(state_of(&state), body.media_id, body.updates).await)
}

async fn delete_media_list_entry(
    State(state): State<ProxyState>,
    Path(entry_id): Path<i64>,
) -> Result<Json<Value>, (StatusCode, Json<Value>)> {
    ok_or_500(crate::commands::user::delete_media_list_entry(state_of(&state), entry_id).await)
}

#[derive(Deserialize)]
struct FavouriteBody {
    media_id: i64,
    is_manga: bool,
}

async fn toggle_favourite(
    State(state): State<ProxyState>,
    Json(body): Json<FavouriteBody>,
) -> Result<Json<Value>, (StatusCode, Json<Value>)> {
    ok_or_500(crate::commands::user::toggle_favourite(state_of(&state), body.media_id, body.is_manga).await)
}

#[derive(Deserialize)]
struct PageQuery {
    page: Option<i64>,
}

async fn get_notifications(
    State(state): State<ProxyState>,
    Query(q): Query<PageQuery>,
) -> Result<Json<Value>, (StatusCode, Json<Value>)> {
    ok_or_500(crate::commands::user::get_notifications(state_of(&state), q.page).await)
}

async fn mark_notifications_read(State(state): State<ProxyState>) -> Result<Json<Value>, (StatusCode, Json<Value>)> {
    ok_or_500(crate::commands::user::mark_notifications_read(state_of(&state)).await)
}

#[derive(Deserialize)]
struct ScheduleQuery {
    days_back: Option<i64>,
    days_ahead: Option<i64>,
    media_ids: Option<String>,
    page: Option<i64>,
    per_page: Option<i64>,
}

async fn get_airing_schedule(
    State(state): State<ProxyState>,
    Query(q): Query<ScheduleQuery>,
) -> Result<Json<Value>, (StatusCode, Json<Value>)> {
    let media_ids = q.media_ids.as_deref().map(|s| {
        s.split(',').filter_map(|p| p.trim().parse::<i64>().ok()).collect::<Vec<_>>()
    });
    ok_or_500(
        crate::commands::user::get_airing_schedule(state_of(&state), q.days_back, q.days_ahead, media_ids, q.page, q.per_page)
            .await,
    )
}

// ── media ───────────────────────────────────────────────────

#[derive(Deserialize)]
struct SearchQuery {
    #[serde(default)]
    query: String,
    page: Option<i64>,
    media_type: Option<String>,
    status: Option<String>,
    genre: Option<String>,
    year: Option<i64>,
    min_score: Option<i64>,
}

async fn search_media(
    State(state): State<ProxyState>,
    Query(q): Query<SearchQuery>,
) -> Result<Json<Value>, (StatusCode, Json<Value>)> {
    ok_or_500(
        crate::commands::media::search_media(
            state_of(&state), q.query, q.page, q.media_type, q.status, q.genre, q.year, q.min_score,
        )
        .await,
    )
}

#[derive(Deserialize)]
struct MediaTypeQuery {
    media_type: Option<String>,
}

async fn get_media_detail(
    State(state): State<ProxyState>,
    Path(id): Path<i64>,
    Query(q): Query<MediaTypeQuery>,
) -> Result<Json<Value>, (StatusCode, Json<Value>)> {
    ok_or_500(crate::commands::media::get_media_detail(state_of(&state), id, q.media_type).await)
}

#[derive(Deserialize)]
struct PagedTypeQuery {
    page: Option<i64>,
    media_type: Option<String>,
}

async fn get_trending(
    State(state): State<ProxyState>,
    Query(q): Query<PagedTypeQuery>,
) -> Result<Json<Value>, (StatusCode, Json<Value>)> {
    ok_or_500(crate::commands::media::get_trending(state_of(&state), q.page, q.media_type).await)
}

#[derive(Deserialize)]
struct SeasonalQuery {
    season: Option<String>,
    season_year: Option<i64>,
    page: Option<i64>,
    media_type: Option<String>,
}

async fn get_seasonal(
    State(state): State<ProxyState>,
    Query(q): Query<SeasonalQuery>,
) -> Result<Json<Value>, (StatusCode, Json<Value>)> {
    ok_or_500(crate::commands::media::get_seasonal(state_of(&state), q.season, q.season_year, q.page, q.media_type).await)
}

async fn get_upcoming(
    State(state): State<ProxyState>,
    Query(q): Query<PagedTypeQuery>,
) -> Result<Json<Value>, (StatusCode, Json<Value>)> {
    ok_or_500(crate::commands::media::get_upcoming(state_of(&state), q.page, q.media_type).await)
}

async fn get_media_characters(
    State(state): State<ProxyState>,
    Path(id): Path<i64>,
) -> Result<Json<Value>, (StatusCode, Json<Value>)> {
    ok_or_500(crate::commands::media::get_media_characters(state_of(&state), id).await)
}

async fn get_smart_playlist(State(state): State<ProxyState>) -> Result<Json<Value>, (StatusCode, Json<Value>)> {
    ok_or_500(crate::commands::media::get_smart_playlist(state_of(&state)).await)
}

#[derive(Deserialize)]
struct EpisodesQuery {
    provider: Option<String>,
    title: Option<String>,
    episode_count: Option<i64>,
}

async fn get_episodes(
    State(state): State<ProxyState>,
    Path(id): Path<i64>,
    Query(q): Query<EpisodesQuery>,
) -> Result<Json<Value>, (StatusCode, Json<Value>)> {
    ok_or_500(
        crate::commands::media::get_episodes(state.app_handle.clone(), state_of(&state), id, q.provider, q.title, q.episode_count)
            .await,
    )
}

async fn get_chapter_pages(
    State(state): State<ProxyState>,
    Path((id, chapter_number)): Path<(i64, String)>,
) -> Result<Json<Value>, (StatusCode, Json<Value>)> {
    ok_or_500(crate::commands::media::get_chapter_pages(state_of(&state), id, chapter_number).await)
}

#[derive(Deserialize)]
struct ResolveStreamQuery {
    episode_number: i32,
    provider: Option<String>,
}

/// Lists available stream servers for manual server selection (mirrors the
/// desktop "choose a server" UI) — distinct from `/playback/resolve`, which
/// picks one server automatically and returns a ready-to-play proxied URL.
async fn resolve_stream(
    State(state): State<ProxyState>,
    Path(id): Path<i64>,
    Query(q): Query<ResolveStreamQuery>,
) -> Result<Json<Value>, (StatusCode, Json<Value>)> {
    ok_or_500(crate::commands::media::resolve_stream(state_of(&state), id, q.episode_number, q.provider).await)
}

#[derive(Deserialize)]
struct ProviderSearchQuery {
    query: String,
    provider: Option<String>,
}

async fn search_provider(
    State(state): State<ProxyState>,
    Query(q): Query<ProviderSearchQuery>,
) -> Result<Json<Value>, (StatusCode, Json<Value>)> {
    ok_or_500(crate::commands::media::search_provider(state_of(&state), q.query, q.provider).await)
}

#[derive(Deserialize)]
struct MapSlugBody {
    media_id: i64,
    provider: String,
    slug: String,
}

async fn map_provider_slug(
    State(state): State<ProxyState>,
    Json(body): Json<MapSlugBody>,
) -> Result<Json<Value>, (StatusCode, Json<Value>)> {
    ok_or_500(
        crate::commands::media::map_provider_slug(state_of(&state), body.media_id, body.provider, body.slug)
            .await
            .map(|_| Value::Null),
    )
}

#[derive(Deserialize)]
struct MediaIdBody {
    media_id: i64,
}

async fn clear_provider_cache(
    State(state): State<ProxyState>,
    Json(body): Json<MediaIdBody>,
) -> Result<Json<Value>, (StatusCode, Json<Value>)> {
    ok_or_500(crate::commands::media::clear_provider_cache(state_of(&state), body.media_id).await.map(|_| Value::Null))
}

async fn get_library(State(state): State<ProxyState>) -> Result<Json<Value>, (StatusCode, Json<Value>)> {
    ok_or_500(crate::commands::media::get_library(state_of(&state)).await)
}

#[derive(Deserialize)]
struct AddLibraryBody {
    media_id: i64,
    media_type: String,
    status: Option<String>,
    score: Option<f64>,
    progress: Option<i32>,
    notes: Option<String>,
}

async fn add_to_library(
    State(state): State<ProxyState>,
    Json(body): Json<AddLibraryBody>,
) -> Result<Json<Value>, (StatusCode, Json<Value>)> {
    ok_or_500(
        crate::commands::media::add_to_library(
            state_of(&state), body.media_id, body.media_type, body.status, body.score, body.progress, body.notes,
        )
        .await
        .map(|_| Value::Null),
    )
}

async fn remove_from_library(
    State(state): State<ProxyState>,
    Path(media_id): Path<i64>,
) -> Result<Json<Value>, (StatusCode, Json<Value>)> {
    ok_or_500(crate::commands::media::remove_from_library(state_of(&state), media_id).await.map(|_| Value::Null))
}

// ── playback (read-only + mobile resolve) ──────────────────

async fn get_watched_episodes(
    State(state): State<ProxyState>,
    Path(media_id): Path<i64>,
) -> Result<Json<Value>, (StatusCode, Json<Value>)> {
    ok_or_500(crate::commands::playback::get_watched_episodes(state_of(&state), media_id).await)
}

async fn get_all_last_watched(State(state): State<ProxyState>) -> Result<Json<Value>, (StatusCode, Json<Value>)> {
    ok_or_500(crate::commands::playback::get_all_last_watched(state_of(&state)).await)
}

#[derive(Deserialize)]
struct PreloadBody {
    media_id: i64,
    episode_number: i64,
    provider: Option<String>,
    title: Option<String>,
}

async fn preload_episode(
    State(state): State<ProxyState>,
    Json(body): Json<PreloadBody>,
) -> Result<Json<Value>, (StatusCode, Json<Value>)> {
    ok_or_500(
        crate::commands::playback::preload_episode(state_of(&state), body.media_id, body.episode_number, body.provider, body.title)
            .await
            .map(|_| Value::Null),
    )
}

#[derive(Deserialize)]
struct ResolvePlaybackBody {
    media_id: i64,
    episode_number: i64,
    provider: Option<String>,
    title: Option<String>,
    episode_title: Option<String>,
    cover_image: Option<String>,
    total_episodes: Option<i64>,
}

/// Mobile has no mpv — instead of `start_playback` spawning a native player,
/// this resolves the stream the same way and hands the client a proxied,
/// relative URL a plain `<video>` tag can play directly. It still updates
/// `current_playback` so the existing `/player/progress` etc. handlers (which
/// the phone's `<video>` element calls the same way the mpv Lua script does)
/// have a session to update.
///
/// Known limitation, accepted for personal/home use: `current_playback` is a
/// single process-global, not per-session — simultaneous desktop mpv and
/// phone playback would clobber each other's progress state.
async fn resolve_playback(
    State(state): State<ProxyState>,
    Json(body): Json<ResolvePlaybackBody>,
) -> Result<Json<Value>, (StatusCode, Json<Value>)> {
    let app_state = &state.app_state;
    let provider_name = body.provider.clone().unwrap_or_else(|| "mkissa".to_string());
    let fallback_provider = {
        let cfg = app_state.config.read().await;
        cfg.general.fallback_provider.clone()
    };

    let title_str = body.title.clone().unwrap_or_default();
    let episode_title_str = body.episode_title.clone().unwrap_or_default();
    let cover_image_str = body.cover_image.clone().unwrap_or_default();
    let total_eps = body.total_episodes.unwrap_or(0);

    let (raw_url, stream_headers, resolved_provider) = match crate::commands::playback::resolve_stream_for_provider(
        app_state, body.media_id, body.episode_number, &provider_name, &None, body.title.clone(),
    )
    .await
    {
        Ok((url, headers)) => (url, headers, provider_name.clone()),
        Err(primary_err) => {
            let has_fallback = !fallback_provider.is_empty() && fallback_provider != "none" && fallback_provider != provider_name;
            if !has_fallback {
                return Err((StatusCode::BAD_GATEWAY, Json(serde_json::json!({ "error": primary_err }))));
            }
            match crate::commands::playback::resolve_stream_for_provider(
                app_state, body.media_id, body.episode_number, &fallback_provider, &None, body.title.clone(),
            )
            .await
            {
                Ok((url, headers)) => (url, headers, fallback_provider.clone()),
                Err(fb_err) => {
                    return Err((
                        StatusCode::BAD_GATEWAY,
                        Json(serde_json::json!({ "error": format!("{} / {}", primary_err, fb_err) })),
                    ));
                }
            }
        }
    };

    // A phone's <video> element can't attach custom Referer/User-Agent
    // headers the way mpv can, so mobile always routes through /proxy
    // (which injects them server-side) rather than only doing so for the
    // vibeplayer/m3u8 cases start_playback special-cases for mpv. Forward the
    // stream's own Referer through the proxy URL — some CDNs reject the fetch
    // without it (mp4upload returns 403; the desktop path gets it via mpv's
    // --referrer arg). Without this, mkissa playback fails on the PWA.
    let mut stream_url = format!("/proxy?url={}", crate::util::percent_encode(&raw_url));
    if let Some(referer) = stream_headers.as_ref().and_then(|h| {
        h.get("Referer").or_else(|| h.get("referer")).or_else(|| h.get("REFERER"))
    }) {
        stream_url.push_str(&format!("&referer={}", crate::util::percent_encode(referer)));
    }

    {
        let mut guard = app_state.current_playback.lock().await;
        *guard = Some(crate::state::CurrentPlayback {
            media_id: body.media_id,
            episode_number: body.episode_number,
            provider: resolved_provider,
            title: title_str.clone(),
            episode_title: episode_title_str,
            cover_image: cover_image_str,
            total_episodes: total_eps,
            last_position: 0,
            last_duration: 0,
            paused: false,
        });
    }

    let resume_seconds = {
        let mut sec = 0;
        if let Ok(db) = app_state.open_db() {
            if let Ok(entries) = crate::registry::service::get_watched_episodes(&db, body.media_id) {
                if let Some(entry) = entries.iter().find(|e| e.episode_number == body.episode_number) {
                    sec = crate::commands::playback::resume_position(entry.stop_time, entry.duration);
                }
            }
        }
        if sec > 0 {
            if let Some(anilist_progress) = app_state.cache.get_user_list_progress(body.media_id) {
                if anilist_progress >= body.episode_number {
                    sec = 0;
                }
            }
        }
        sec
    };

    // Move Planning/Paused/etc. into Watching, same as start_playback — a
    // no-op if the entry is already CURRENT.
    if app_state.anilist_client.has_token() && body.media_id > 0 {
        let already_current = app_state
            .cache
            .get_user_list_status(body.media_id)
            .map(|s| s.eq_ignore_ascii_case("CURRENT"))
            .unwrap_or(false);
        if !already_current {
            let anilist = app_state.anilist_client.clone();
            let cache = app_state.cache.clone();
            let m_id = body.media_id;
            tokio::spawn(async move {
                let mut vars = std::collections::HashMap::new();
                vars.insert("mediaId".to_string(), serde_json::json!(m_id));
                vars.insert("status".to_string(), serde_json::json!("CURRENT"));
                if let Err(e) = anilist
                    .execute::<serde_json::Value>(crate::anilist::queries::SAVE_MEDIA_LIST_ENTRY_MUTATION, vars)
                    .await
                {
                    log::warn!("Failed to sync AniList watching list from mobile playback: {}", e);
                } else {
                    cache.update_user_list_progress(m_id, None, Some("CURRENT"), None);
                }
            });
        }
    }

    Ok(Json(serde_json::json!({
        "stream_url": stream_url,
        "resume_seconds": resume_seconds,
    })))
}

// ── health ──────────────────────────────────────────────────

async fn check_health(State(state): State<ProxyState>) -> Result<Json<Value>, (StatusCode, Json<Value>)> {
    ok_or_500(crate::commands::health::check_health(state_of(&state)).await)
}

async fn get_app_version() -> Json<Value> {
    Json(serde_json::json!({ "version": crate::commands::health::get_app_version().await }))
}
