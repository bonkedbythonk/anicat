//! JSON HTTP surface for the LAN-facing mobile PWA.
//!
//! Every handler here is a thin wrapper: it calls the same plain
//! `X_impl(state: &AppState, ...)` function the corresponding
//! `#[tauri::command]` wrapper delegates to for the desktop IPC path (see
//! e.g. `commands::config::get_config`/`get_config_impl`). No business logic
//! is duplicated; this module only adapts HTTP <-> the same underlying
//! implementation the desktop webview reaches via `invoke()`. Unlike the
//! desktop wrappers, these handlers never need a live `tauri::AppHandle` —
//! `ProxyState.app_state` is a plain, Tauri-free `AppState` clone, which is
//! what makes this surface reachable from the headless server binary too.
//!
//! Deliberately excluded: the 4 download-queue commands (out of scope per
//! the user's request), and anything that needs desktop OS integration
//! (OAuth browser launch, log viewer, auto-update, app restart).
//!
//! **Multi-user scoping**: every handler that touches AniList (client,
//! cache, or the DB's user_id-columned watch-history/library tables) calls
//! `ProxyState::scoped_for` first and uses the result instead of
//! `state.app_state` directly. This isn't limited to obviously-personal
//! endpoints like "my list" — AniList embeds the authenticated viewer's own
//! list status (`mediaListEntry`/`user_status`) into otherwise-generic
//! queries too (trending, seasonal, search, smart-playlist), and
//! `cache.rs`'s `update_user_list_progress` rewrites exactly those embedded
//! fields in cached responses. Leaving any of those unscoped would let one
//! user's progress badges bleed into another's browsing. Provider-slug
//! mapping and scraper calls are the one category that's genuinely global (a
//! slug maps an AniList id to a scraper-site id — the same fact regardless
//! of who's asking), so those stay unscoped.
//!
//! In single-user mode `AuthedUser(0)` (set by `mobile_auth::require_mobile_auth`
//! on every successful request) makes `scoped_for` a no-op clone of the real
//! global `AppState` — see `AppState::scoped_for_user`'s doc comment. The
//! `/player/*` handlers in `server.rs` use the same `scoped_for` method,
//! since mobile's `<video>` element reports progress through those routes,
//! not through this module.

use axum::{
    extract::{Path, Query, State},
    http::StatusCode,
    response::Json,
    routing::{delete, get, post},
    Router,
};
use serde::Deserialize;
use serde_json::Value;

use super::server::ProxyState;
use super::session::AuthedUser;

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
        .route("/user/connect-anilist", post(connect_anilist))
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
        .route("/media/{id}/skip-times", get(get_skip_times))
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
        .route("/session/whoami", get(whoami))
        .route("/health", get(check_health))
        .route("/version", get(get_app_version))
}

// ── config (global — not per-user; mirrors the single desktop config.toml) ─

async fn get_config(State(state): State<ProxyState>) -> Result<Json<Value>, (StatusCode, Json<Value>)> {
    ok_or_500(crate::commands::config::get_config_impl(&state.app_state).await)
}

async fn update_config(
    State(state): State<ProxyState>,
    Json(updates): Json<Value>,
) -> Result<Json<Value>, (StatusCode, Json<Value>)> {
    // config.toml is process-global (one file shared by every user on a
    // headless deployment), so any authenticated friend hitting this endpoint
    // would otherwise be able to rewrite server-wide state — including the
    // owner's AniList token (`api.token`), the phone-access PIN, and
    // `lan_access_enabled` (setting it false locks everyone out). PIN/Tailscale
    // is an identity boundary, not an authorization one, so this can't rely on
    // "friends won't poke it." Restrict the mobile surface to a fixed allowlist
    // of benign playback preferences; everything else is silently dropped. The
    // desktop IPC path calls `update_config_impl` directly and is unaffected.
    let filtered = sanitize_mobile_config_updates(updates);
    ok_or_500(crate::commands::config::update_config_impl(&state.app_state, filtered).await.map(|_| Value::Null))
}

/// Rebuilds the incoming config-update object keeping only the nested keys the
/// mobile PWA is allowed to change. Anything not explicitly listed (any `api`/
/// `anilist`/`mobile` section, `general.multi_user`/`provider`/`downloads_path`,
/// etc.) is discarded before it reaches `update_config_impl`.
fn sanitize_mobile_config_updates(updates: Value) -> Value {
    const ALLOWED: &[(&str, &[&str])] = &[
        ("general", &["autoplay", "autoskip", "anime_preview", "preferred_title_language", "time_format"]),
        ("stream", &["shader_profile", "interpolation", "translation_type", "quality"]),
    ];
    let mut out = serde_json::Map::new();
    if let Some(obj) = updates.as_object() {
        for (section, keys) in ALLOWED {
            if let Some(section_obj) = obj.get(*section).and_then(Value::as_object) {
                let mut kept = serde_json::Map::new();
                for key in *keys {
                    if let Some(v) = section_obj.get(*key) {
                        kept.insert((*key).to_string(), v.clone());
                    }
                }
                if !kept.is_empty() {
                    out.insert((*section).to_string(), Value::Object(kept));
                }
            }
        }
    }
    Value::Object(out)
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
    auth: AuthedUser,
    Query(q): Query<UserListQuery>,
) -> Result<Json<Value>, (StatusCode, Json<Value>)> {
    let scoped = state.scoped_for(auth).await;
    ok_or_500(crate::commands::user::get_user_list_impl(&scoped, q.user_name, q.status, q.media_type).await)
}

async fn get_user_profile(
    State(state): State<ProxyState>,
    auth: AuthedUser,
) -> Result<Json<Value>, (StatusCode, Json<Value>)> {
    let scoped = state.scoped_for(auth).await;
    ok_or_500(crate::commands::user::get_user_profile_impl(&scoped).await)
}

#[derive(Deserialize)]
struct ListEntryBody {
    media_id: i64,
    updates: Value,
}

async fn save_media_list_entry(
    State(state): State<ProxyState>,
    auth: AuthedUser,
    Json(body): Json<ListEntryBody>,
) -> Result<Json<Value>, (StatusCode, Json<Value>)> {
    let scoped = state.scoped_for(auth).await;
    ok_or_500(crate::commands::user::save_media_list_entry_impl(&scoped, body.media_id, body.updates).await)
}

async fn delete_media_list_entry(
    State(state): State<ProxyState>,
    auth: AuthedUser,
    Path(entry_id): Path<i64>,
) -> Result<Json<Value>, (StatusCode, Json<Value>)> {
    let scoped = state.scoped_for(auth).await;
    ok_or_500(crate::commands::user::delete_media_list_entry_impl(&scoped, entry_id).await)
}

#[derive(Deserialize)]
struct FavouriteBody {
    media_id: i64,
    is_manga: bool,
}

async fn toggle_favourite(
    State(state): State<ProxyState>,
    auth: AuthedUser,
    Json(body): Json<FavouriteBody>,
) -> Result<Json<Value>, (StatusCode, Json<Value>)> {
    let scoped = state.scoped_for(auth).await;
    ok_or_500(crate::commands::user::toggle_favourite_impl(&scoped, body.media_id, body.is_manga).await)
}

#[derive(Deserialize)]
struct PageQuery {
    page: Option<i64>,
}

async fn get_notifications(
    State(state): State<ProxyState>,
    auth: AuthedUser,
    Query(q): Query<PageQuery>,
) -> Result<Json<Value>, (StatusCode, Json<Value>)> {
    let scoped = state.scoped_for(auth).await;
    ok_or_500(crate::commands::user::get_notifications_impl(&scoped, q.page).await)
}

async fn mark_notifications_read(
    State(state): State<ProxyState>,
    auth: AuthedUser,
) -> Result<Json<Value>, (StatusCode, Json<Value>)> {
    let scoped = state.scoped_for(auth).await;
    ok_or_500(crate::commands::user::mark_notifications_read_impl(&scoped).await)
}

#[derive(Deserialize)]
struct ConnectAniListBody {
    token: String,
}

/// Each registered friend connects their OWN AniList account once, from
/// their own phone browser (AniList's implicit-grant authorize URL, opened
/// client-side — see `web/src/mobile/ConnectAniList.tsx`), then POSTs the
/// resulting token here. Tied to the caller's own session, so there's no way
/// to set another user's token. Desktop's separate `commands::auth`
/// (browser + `open::that()`) flow is untouched.
async fn connect_anilist(
    State(state): State<ProxyState>,
    AuthedUser(user_id): AuthedUser,
    Json(body): Json<ConnectAniListBody>,
) -> Result<Json<Value>, (StatusCode, Json<Value>)> {
    if user_id == 0 {
        // Single-user mode: this is just the desktop's own token — reuse
        // the existing config-based path instead of the users table.
        return ok_or_500(
            crate::commands::config::update_config_impl(
                &state.app_state,
                serde_json::json!({ "api": { "token": body.token } }),
            )
            .await
            .map(|_| Value::Null),
        );
    }

    let db = state.app_state.open_db().map_err(|e| (StatusCode::INTERNAL_SERVER_ERROR, Json(serde_json::json!({ "error": e }))))?;
    // Resolve the username with a throwaway client scoped to the freshly
    // provided token — the same pattern get_user_list_impl uses to resolve
    // its own username, just against a client that isn't cached anywhere.
    let probe = crate::anilist::AniListClient::new(state.app_state.http_client.clone(), Some(body.token.clone()));
    let username: Option<String> = probe
        .execute::<Value>(crate::anilist::queries::USER_PROFILE_QUERY, std::collections::HashMap::new())
        .await
        .ok()
        .and_then(|v| v.get("Viewer").and_then(|v| v.get("name")).and_then(|n| n.as_str()).map(|s| s.to_string()));

    crate::registry::service::set_user_anilist_token(&db, user_id, Some(&body.token), username.as_deref())
        .map_err(|e| (StatusCode::INTERNAL_SERVER_ERROR, Json(serde_json::json!({ "error": e }))))?;

    // Drop the cached UserAniList entry (if any) so the next request picks
    // up the new token/username immediately instead of a stale prior one.
    state.app_state.user_anilist.lock().await.remove(&user_id);

    Ok(Json(serde_json::json!({ "username": username })))
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
    auth: AuthedUser,
    Query(q): Query<ScheduleQuery>,
) -> Result<Json<Value>, (StatusCode, Json<Value>)> {
    let media_ids = q.media_ids.as_deref().map(|s| {
        s.split(',').filter_map(|p| p.trim().parse::<i64>().ok()).collect::<Vec<_>>()
    });
    let scoped = state.scoped_for(auth).await;
    ok_or_500(
        crate::commands::user::get_airing_schedule_impl(&scoped, q.days_back, q.days_ahead, media_ids, q.page, q.per_page)
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
    auth: AuthedUser,
    Query(q): Query<SearchQuery>,
) -> Result<Json<Value>, (StatusCode, Json<Value>)> {
    let scoped = state.scoped_for(auth).await;
    ok_or_500(
        crate::commands::media::search_media_impl(
            &scoped, q.query, q.page, q.media_type, q.status, q.genre, q.year, q.min_score,
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
    auth: AuthedUser,
    Path(id): Path<i64>,
    Query(q): Query<MediaTypeQuery>,
) -> Result<Json<Value>, (StatusCode, Json<Value>)> {
    let scoped = state.scoped_for(auth).await;
    ok_or_500(crate::commands::media::get_media_detail_impl(&scoped, id, q.media_type).await)
}

#[derive(Deserialize)]
struct PagedTypeQuery {
    page: Option<i64>,
    media_type: Option<String>,
}

async fn get_trending(
    State(state): State<ProxyState>,
    auth: AuthedUser,
    Query(q): Query<PagedTypeQuery>,
) -> Result<Json<Value>, (StatusCode, Json<Value>)> {
    let scoped = state.scoped_for(auth).await;
    ok_or_500(crate::commands::media::get_trending_impl(&scoped, q.page, q.media_type).await)
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
    auth: AuthedUser,
    Query(q): Query<SeasonalQuery>,
) -> Result<Json<Value>, (StatusCode, Json<Value>)> {
    let scoped = state.scoped_for(auth).await;
    ok_or_500(crate::commands::media::get_seasonal_impl(&scoped, q.season, q.season_year, q.page, q.media_type).await)
}

async fn get_upcoming(
    State(state): State<ProxyState>,
    auth: AuthedUser,
    Query(q): Query<PagedTypeQuery>,
) -> Result<Json<Value>, (StatusCode, Json<Value>)> {
    let scoped = state.scoped_for(auth).await;
    ok_or_500(crate::commands::media::get_upcoming_impl(&scoped, q.page, q.media_type).await)
}

async fn get_media_characters(
    State(state): State<ProxyState>,
    Path(id): Path<i64>,
) -> Result<Json<Value>, (StatusCode, Json<Value>)> {
    // Character bios carry no per-viewer data — safe to leave on the shared
    // global cache/client rather than scoping.
    ok_or_500(crate::commands::media::get_media_characters_impl(&state.app_state, id).await)
}

async fn get_smart_playlist(
    State(state): State<ProxyState>,
    auth: AuthedUser,
) -> Result<Json<Value>, (StatusCode, Json<Value>)> {
    let scoped = state.scoped_for(auth).await;
    ok_or_500(crate::commands::media::get_smart_playlist_impl(&scoped).await)
}

#[derive(Deserialize)]
struct EpisodesQuery {
    provider: Option<String>,
    title: Option<String>,
    episode_count: Option<i64>,
}

async fn get_episodes(
    State(state): State<ProxyState>,
    auth: AuthedUser,
    Path(id): Path<i64>,
    Query(q): Query<EpisodesQuery>,
) -> Result<Json<Value>, (StatusCode, Json<Value>)> {
    // No webview to push a toast to headlessly — just log it server-side.
    let notify = |message: &str| log::info!("[mobile-api get_episodes] {}", message);
    let scoped = state.scoped_for(auth).await;
    ok_or_500(
        crate::commands::media::get_episodes_impl(&scoped, id, q.provider, q.title, q.episode_count, &notify)
            .await,
    )
}

async fn get_chapter_pages(
    State(state): State<ProxyState>,
    Path((id, chapter_number)): Path<(i64, String)>,
) -> Result<Json<Value>, (StatusCode, Json<Value>)> {
    // Scraper-only, no AniList/viewer data involved — global is correct.
    ok_or_500(crate::commands::media::get_chapter_pages_impl(&state.app_state, id, chapter_number).await)
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
    // Stream server list is scraper-derived, not per-viewer.
    ok_or_500(crate::commands::media::resolve_stream_impl(&state.app_state, id, q.episode_number, q.provider).await)
}

#[derive(Deserialize)]
struct SkipTimesQuery {
    episode_number: i64,
    #[serde(default)]
    title: String,
}

/// Desktop gets AniSkip segments pushed into mpv over IPC; the mobile player
/// has no mpv to push into, so it fetches the same segments directly and
/// renders its own skip button. Never fails hard — an empty list just means
/// no skip button shows, same as AniSkip having no data for desktop.
async fn get_skip_times(
    State(state): State<ProxyState>,
    Path(id): Path<i64>,
    Query(q): Query<SkipTimesQuery>,
) -> Json<Value> {
    let segments = crate::commands::playback::fetch_aniskip_segments(&state.app_state, id, q.episode_number, &q.title).await;
    Json(serde_json::json!({ "segments": segments }))
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
    ok_or_500(crate::commands::media::search_provider_impl(&state.app_state, q.query, q.provider).await)
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
        crate::commands::media::map_provider_slug_impl(&state.app_state, body.media_id, body.provider, body.slug)
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
    ok_or_500(crate::commands::media::clear_provider_cache_impl(&state.app_state, body.media_id).await.map(|_| Value::Null))
}

async fn get_library(
    State(state): State<ProxyState>,
    AuthedUser(user_id): AuthedUser,
) -> Result<Json<Value>, (StatusCode, Json<Value>)> {
    ok_or_500(crate::commands::media::get_library_impl(&state.app_state, user_id).await)
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
    AuthedUser(user_id): AuthedUser,
    Json(body): Json<AddLibraryBody>,
) -> Result<Json<Value>, (StatusCode, Json<Value>)> {
    ok_or_500(
        crate::commands::media::add_to_library_impl(
            &state.app_state, user_id, body.media_id, body.media_type, body.status, body.score, body.progress, body.notes,
        )
        .await
        .map(|_| Value::Null),
    )
}

async fn remove_from_library(
    State(state): State<ProxyState>,
    AuthedUser(user_id): AuthedUser,
    Path(media_id): Path<i64>,
) -> Result<Json<Value>, (StatusCode, Json<Value>)> {
    ok_or_500(crate::commands::media::remove_from_library_impl(&state.app_state, user_id, media_id).await.map(|_| Value::Null))
}

// ── playback (read-only + mobile resolve) ──────────────────

async fn get_watched_episodes(
    State(state): State<ProxyState>,
    AuthedUser(user_id): AuthedUser,
    Path(media_id): Path<i64>,
) -> Result<Json<Value>, (StatusCode, Json<Value>)> {
    ok_or_500(crate::commands::playback::get_watched_episodes_impl(&state.app_state, user_id, media_id).await)
}

async fn get_all_last_watched(
    State(state): State<ProxyState>,
    AuthedUser(user_id): AuthedUser,
) -> Result<Json<Value>, (StatusCode, Json<Value>)> {
    ok_or_500(crate::commands::playback::get_all_last_watched_impl(&state.app_state, user_id).await)
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
    auth: AuthedUser,
    Json(body): Json<PreloadBody>,
) -> Result<Json<Value>, (StatusCode, Json<Value>)> {
    let scoped = state.scoped_for(auth).await;
    ok_or_500(
        crate::commands::playback::preload_episode_impl(&scoped, body.media_id, body.episode_number, body.provider, body.title)
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
/// have a session to update — those handlers read/write the SAME per-user
/// scoped `current_playback` this sets, since `AuthedUser` (populated by
/// whichever auth middleware ran) resolves to the same user_id there too.
async fn resolve_playback(
    State(state): State<ProxyState>,
    AuthedUser(user_id): AuthedUser,
    Json(body): Json<ResolvePlaybackBody>,
) -> Result<Json<Value>, (StatusCode, Json<Value>)> {
    let app_state = state.scoped_for(AuthedUser(user_id)).await;
    let app_state = &app_state;
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
            if let Ok(entries) = crate::registry::service::get_watched_episodes(&db, user_id, body.media_id) {
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

// ── session (Stage 2: multi-user) ──────────────────────────

#[derive(serde::Serialize)]
struct WhoamiResponse {
    user_id: i64,
    display_name: String,
    anilist_connected: bool,
    anilist_username: Option<String>,
}

/// Tells the PWA who's logged in and whether they still need the
/// "connect AniList" onboarding step. In single-user mode (`user_id == 0`)
/// this reflects the desktop's own config-based token instead of a users
/// table row, so the same screen works for both modes.
async fn whoami(
    State(state): State<ProxyState>,
    AuthedUser(user_id): AuthedUser,
) -> Result<Json<WhoamiResponse>, (StatusCode, Json<Value>)> {
    if user_id == 0 {
        let cfg = state.app_state.config.read().await;
        return Ok(Json(WhoamiResponse {
            user_id: 0,
            display_name: cfg.api.anilist_username.clone().unwrap_or_else(|| "You".to_string()),
            anilist_connected: cfg.api.anilist_token.is_some(),
            anilist_username: cfg.api.anilist_username.clone(),
        }));
    }
    let db = state.app_state.open_db().map_err(|e| (StatusCode::INTERNAL_SERVER_ERROR, Json(serde_json::json!({ "error": e }))))?;
    let user = crate::registry::service::get_user_by_id(&db, user_id)
        .map_err(|e| (StatusCode::INTERNAL_SERVER_ERROR, Json(serde_json::json!({ "error": e }))))?
        .ok_or((StatusCode::NOT_FOUND, Json(serde_json::json!({ "error": "user not found" }))))?;
    Ok(Json(WhoamiResponse {
        user_id: user.id,
        display_name: user.display_name,
        anilist_connected: user.anilist_token.is_some(),
        anilist_username: user.anilist_username,
    }))
}

#[derive(serde::Serialize)]
pub struct UserNameEntry {
    display_name: String,
}

/// Unauthenticated on purpose, same rationale as `/mobile-api/lan-info` —
/// registered directly in `server.rs` alongside `/mobile-api/auth` and
/// `/mobile-api/session/login` rather than through this module's `routes()`,
/// which is entirely behind the auth gate. A client needs this to populate
/// the login screen's "who's watching" picker before it has a token.
/// Deliberately returns only display names — never ids, PINs, or AniList
/// tokens.
pub async fn list_user_names(State(state): State<ProxyState>) -> Result<Json<Vec<UserNameEntry>>, (StatusCode, Json<Value>)> {
    let db = state.app_state.open_db().map_err(|e| (StatusCode::INTERNAL_SERVER_ERROR, Json(serde_json::json!({ "error": e }))))?;
    let users = crate::registry::service::list_users(&db)
        .map_err(|e| (StatusCode::INTERNAL_SERVER_ERROR, Json(serde_json::json!({ "error": e }))))?;
    Ok(Json(users.into_iter().map(|u| UserNameEntry { display_name: u.display_name }).collect()))
}

// ── health ──────────────────────────────────────────────────

async fn check_health(State(state): State<ProxyState>) -> Result<Json<Value>, (StatusCode, Json<Value>)> {
    ok_or_500(crate::commands::health::check_health_impl(&state.app_state).await)
}

async fn get_app_version() -> Json<Value> {
    Json(serde_json::json!({ "version": crate::commands::health::get_app_version().await }))
}

#[cfg(test)]
mod tests {
    use super::sanitize_mobile_config_updates;
    use serde_json::json;

    #[test]
    fn strips_sensitive_sections() {
        let out = sanitize_mobile_config_updates(json!({
            "api": { "token": "steal-me" },
            "anilist": { "token": "steal-me" },
            "mobile": { "pin": "0000", "lan_access_enabled": false },
            "general": { "multi_user": false, "provider": "x", "autoskip": true }
        }));
        // Only the allowlisted general.autoskip survives.
        assert_eq!(out, json!({ "general": { "autoskip": true } }));
    }

    #[test]
    fn keeps_benign_playback_prefs() {
        let out = sanitize_mobile_config_updates(json!({
            "general": { "autoplay": true, "autoskip": false },
            "stream": { "shader_profile": "on" }
        }));
        assert_eq!(out, json!({
            "general": { "autoplay": true, "autoskip": false },
            "stream": { "shader_profile": "on" }
        }));
    }

    #[test]
    fn empty_when_nothing_allowed() {
        let out = sanitize_mobile_config_updates(json!({ "api": { "token": "x" } }));
        assert_eq!(out, json!({}));
    }
}
