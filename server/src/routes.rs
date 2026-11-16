//! The HTTP API. Route names follow `core/src/ffi.rs` one to one, so the
//! Swift app stays the reference for what each call means.

use axum::extract::{Path, State};
use axum::http::{header, StatusCode};
use axum::response::{Html, IntoResponse, Response};
use axum::routing::{delete, get, post};
use axum::{Json, Router};
use serde::Deserialize;
use serde_json::{json, Value};

use anicat_core::ffi::{FfiCatalog, SearchFilters, StreamRequest};

use crate::error::{ApiError, ApiJson, ApiPath, ApiQuery, ApiResult};
use crate::player::policy::list_entry_update;
use crate::player::PlayRequest;
use crate::state::AppState;

const INDEX_HTML: &str = include_str!("../static/index.html");

pub fn router(state: AppState) -> Router {
    Router::new()
        .route("/", get(index))
        .route("/api/search", post(search))
        .route("/api/trending", get(trending))
        .route("/api/discover", get(discover))
        .route("/api/cinema/rows", get(cinema_rows))
        .route("/api/cinema/row/{kind}", get(cinema_row))
        .route("/api/cinema/list", get(cinema_list).post(set_cinema_list_status))
        .route("/api/cinema/{id}", get(cinema_detail))
        .route("/api/user-list", get(user_list))
        .route("/api/media/{id}", get(media_detail))
        .route("/api/progress/{id}", get(progress))
        .route("/api/activity", get(activity))
        .route("/api/play", post(play))
        .route("/api/stop", post(stop))
        .route("/api/resolve-progress/{catalog}/{id}/{episode}", get(resolve_progress))
        .route("/api/releases", get(releases))
        .route("/api/track-preference", post(track_preference))
        .route("/api/watched", post(watched))
        .route("/api/list/{entry}", delete(remove_from_list))
        .route("/api/forget", post(forget))
        .route("/api/cache", get(cache_bytes).delete(purge_cache))
        .route("/api/token", post(set_token))
        .route("/api/viewer", get(viewer))
        .route("/api/skin-art/{skin}/{name}", get(skin_art))
        .route("/api/health", get(health))
        .route("/api/version", get(version))
        .route("/api/update", post(update))
        .route("/api/debug-report", get(debug_report))
        .route("/api/franchise/{id}", get(franchise))
        .route("/api/characters/{id}", get(characters))
        .route("/api/schedule", get(schedule))
        .route("/api/recommendations", get(recommendations))
        .route("/api/stats", get(stats))
        .route("/api/favourite", post(favourite))
        .route("/api/list-entry", post(list_entry))
        .route("/api/cinema/genres", get(cinema_genres))
        .route("/api/cinema/discover", get(cinema_discover))
        .route("/api/cinema/{id}/extras", get(cinema_extras))
        .route("/api/cinema/{id}/cast", get(cinema_cast))
        .with_state(state)
}

async fn index() -> Html<&'static str> {
    Html(INDEX_HTML)
}

fn default_limit() -> i32 {
    20
}

fn default_page() -> i32 {
    1
}

// ---- catalogs -------------------------------------------------------------

#[derive(Deserialize)]
#[serde(rename_all = "snake_case")]
enum SearchKind {
    Anime,
    Cinema,
}

#[derive(Deserialize)]
struct SearchBody {
    query: String,
    kind: SearchKind,
    filters: Option<SearchFilters>,
    #[serde(default = "default_page")]
    page: i32,
    #[serde(default = "default_limit")]
    limit: i32,
}

async fn search(State(s): State<AppState>, ApiJson(b): ApiJson<SearchBody>) -> ApiResult<Json<Value>> {
    let rows = match b.kind {
        SearchKind::Anime => {
            let q = Some(b.query).filter(|q| !q.trim().is_empty());
            s.engine
                .search_catalog(q, Some("ANIME".into()), b.filters, Some(b.page))
                .await?
        }
        SearchKind::Cinema => s.engine.search_cinema(b.query, b.limit, b.page).await?,
    };
    Ok(Json(json!(rows)))
}

#[derive(Deserialize)]
struct TrendingQuery {
    format: Option<String>,
    #[serde(default = "default_limit")]
    limit: i32,
}

async fn trending(State(s): State<AppState>, ApiQuery(q): ApiQuery<TrendingQuery>) -> ApiResult<Json<Value>> {
    let rows = s.engine.trending("ANIME".into(), q.format, q.limit).await?;
    Ok(Json(json!(rows)))
}

#[derive(Deserialize)]
struct DiscoverQuery {
    status: Option<String>,
    season: Option<String>,
    season_year: Option<i32>,
    #[serde(default = "default_limit")]
    limit: i32,
}

async fn discover(State(s): State<AppState>, ApiQuery(q): ApiQuery<DiscoverQuery>) -> ApiResult<Json<Value>> {
    let rows = s
        .engine
        .discover("ANIME".into(), q.status, q.season, q.season_year, q.limit)
        .await?;
    Ok(Json(json!(rows)))
}

async fn cinema_rows(State(s): State<AppState>) -> Json<Value> {
    Json(json!(s.engine.cinema_row_kinds()))
}

#[derive(Deserialize)]
struct PageQuery {
    #[serde(default = "default_page")]
    page: i32,
}

async fn cinema_row(
    State(s): State<AppState>,
    ApiPath(kind): ApiPath<String>,
    ApiQuery(q): ApiQuery<PageQuery>,
) -> ApiResult<Json<Value>> {
    Ok(Json(json!(s.engine.cinema_row(kind, q.page).await?)))
}

#[derive(Deserialize)]
struct CatalogQuery {
    catalog: FfiCatalog,
}

/// `?catalog=tmdb_movie` or `tmdb_tv`: a TMDB id alone does not say which,
/// and the same number is a different title in each.
async fn cinema_detail(
    State(s): State<AppState>,
    ApiPath(id): ApiPath<i64>,
    ApiQuery(q): ApiQuery<CatalogQuery>,
) -> ApiResult<Json<Value>> {
    if q.catalog == FfiCatalog::Anilist || q.catalog == FfiCatalog::MangaDex {
        return Err(ApiError::bad_request("catalog must be tmdb_movie or tmdb_tv"));
    }
    Ok(Json(json!(s.engine.cinema_detail(q.catalog, id).await?)))
}

#[derive(Deserialize)]
struct StatusQuery {
    status: Option<String>,
}

async fn cinema_list(State(s): State<AppState>, ApiQuery(q): ApiQuery<StatusQuery>) -> ApiResult<Json<Value>> {
    let engine = s.engine.clone();
    let rows = tokio::task::spawn_blocking(move || engine.cinema_list(q.status))
        .await
        .map_err(|e| ApiError::internal(e.to_string()))??;
    Ok(Json(json!(rows)))
}

#[derive(Deserialize)]
struct CinemaStatusBody {
    catalog: FfiCatalog,
    catalog_id: i64,
    /// `null` removes the title from the local list.
    status: Option<String>,
}

async fn set_cinema_list_status(
    State(s): State<AppState>,
    ApiJson(b): ApiJson<CinemaStatusBody>,
) -> ApiResult<StatusCode> {
    s.writer.set_cinema_list_status(b.catalog, b.catalog_id, b.status).await?;
    Ok(StatusCode::NO_CONTENT)
}

#[derive(Deserialize)]
struct UserListQuery {
    #[serde(default = "current")]
    status: String,
}

fn current() -> String {
    "CURRENT".into()
}

async fn user_list(State(s): State<AppState>, ApiQuery(q): ApiQuery<UserListQuery>) -> ApiResult<Json<Value>> {
    if !s.signed_in() {
        return Err(ApiError::new(StatusCode::UNAUTHORIZED, "not signed in to AniList"));
    }
    Ok(Json(json!(s.engine.user_list(q.status, "ANIME".into()).await?)))
}

async fn media_detail(State(s): State<AppState>, ApiPath(id): ApiPath<i64>) -> ApiResult<Json<Value>> {
    Ok(Json(json!(s.engine.media_detail(id, false).await?)))
}

// ---- local history ----------------------------------------------------------

fn default_catalog() -> FfiCatalog {
    FfiCatalog::Anilist
}

#[derive(Deserialize)]
struct ProgressQuery {
    episode: i64,
    #[serde(default = "default_catalog")]
    catalog: FfiCatalog,
}

async fn progress(
    State(s): State<AppState>,
    ApiPath(id): ApiPath<i64>,
    ApiQuery(q): ApiQuery<ProgressQuery>,
) -> ApiResult<Json<Value>> {
    let engine = s.engine.clone();
    let hit = tokio::task::spawn_blocking(move || engine.get_progress(q.catalog, id, q.episode))
        .await
        .map_err(|e| ApiError::internal(e.to_string()))??;
    Ok(Json(json!(hit)))
}

#[derive(Deserialize)]
struct LimitQuery {
    #[serde(default = "default_limit")]
    limit: i32,
}

async fn activity(State(s): State<AppState>, ApiQuery(q): ApiQuery<LimitQuery>) -> ApiResult<Json<Value>> {
    let engine = s.engine.clone();
    let rows = tokio::task::spawn_blocking(move || engine.watch_activity(q.limit))
        .await
        .map_err(|e| ApiError::internal(e.to_string()))??;
    Ok(Json(json!(rows)))
}

// ---- playback ---------------------------------------------------------------

#[derive(Deserialize)]
struct PlayBody {
    #[serde(default = "default_catalog")]
    catalog: FfiCatalog,
    catalog_id: i64,
    episode: i64,
    title: Option<String>,
    #[serde(default)]
    prefer_dub: bool,
    /// A release picked from `/api/releases`; tried first.
    chosen_name: Option<String>,
    /// "Start over": ignore the recorded position.
    #[serde(default)]
    from_start: bool,
}


async fn play(State(s): State<AppState>, ApiJson(b): ApiJson<PlayBody>) -> ApiResult<Json<Value>> {
    let (mut start, mut duration) = (0.0_f64, None);
    if !b.from_start {
        let engine = s.engine.clone();
        let (catalog, id, ep) = (b.catalog, b.catalog_id, b.episode);
        let recorded = tokio::task::spawn_blocking(move || engine.get_progress(catalog, id, ep))
            .await
            .map_err(|e| ApiError::internal(e.to_string()))??;
        (start, duration) = crate::player::resume_point(recorded.as_ref());
    }
    let resume_fraction = crate::player::resume_fraction(start, duration);
    let req = StreamRequest {
        catalog: b.catalog,
        catalog_id: b.catalog_id,
        episode: b.episode,
        title: b.title.clone(),
        prefer_dub: b.prefer_dub,
        chosen_name: b.chosen_name,
        resume_fraction,
        preload: false,
    };
    let handle = s.engine.resolve_stream(req).await?;
    let request = PlayRequest {
        catalog: b.catalog,
        catalog_id: b.catalog_id,
        episode: b.episode,
        title: b.title,
        prefer_dub: b.prefer_dub,
        start_seconds: start,
    };
    s.player.play(&handle, &request).await.map_err(ApiError::internal)?;
    Ok(Json(json!({
        "stream": handle,
        "start_seconds": start,
    })))
}

async fn stop(State(s): State<AppState>) -> StatusCode {
    s.player.stop().await;
    StatusCode::NO_CONTENT
}

async fn resolve_progress(
    State(s): State<AppState>,
    ApiPath((catalog, id, episode)): ApiPath<(String, i64, i64)>,
) -> ApiResult<Json<Value>> {
    let catalog: FfiCatalog = serde_json::from_value(Value::String(catalog))
        .map_err(|e| ApiError::bad_request(format!("catalog: {e}")))?;
    Ok(Json(json!(s.engine.resolve_progress(catalog, id, episode))))
}

#[derive(Deserialize)]
struct ReleasesQuery {
    #[serde(default = "default_catalog")]
    catalog: FfiCatalog,
    catalog_id: i64,
    episode: i64,
    title: Option<String>,
    #[serde(default)]
    prefer_dub: bool,
}

async fn releases(State(s): State<AppState>, ApiQuery(q): ApiQuery<ReleasesQuery>) -> ApiResult<Json<Value>> {
    let rows = s
        .engine
        .list_release_candidates(q.catalog, q.catalog_id, q.episode, q.title)
        .await?;
    let remembered = s
        .engine
        .remembered_release_name(q.catalog, q.catalog_id, q.episode, q.prefer_dub);
    Ok(Json(json!({ "releases": rows, "remembered": remembered })))
}

#[derive(Deserialize)]
struct TrackPreferenceBody {
    #[serde(default = "default_catalog")]
    catalog: FfiCatalog,
    catalog_id: i64,
    audio_lang: Option<String>,
    subtitle_lang: Option<String>,
    subtitle_title: Option<String>,
}

async fn track_preference(
    State(s): State<AppState>,
    ApiJson(b): ApiJson<TrackPreferenceBody>,
) -> ApiResult<StatusCode> {
    s.writer
        .record_title_track_preference(b.catalog, b.catalog_id, b.audio_lang, b.subtitle_lang, b.subtitle_title)
        .await?;
    Ok(StatusCode::NO_CONTENT)
}

#[derive(Deserialize)]
struct WatchedBody {
    #[serde(default = "default_catalog")]
    catalog: FfiCatalog,
    catalog_id: i64,
    episode: i64,
}

/// Marks the episode finished locally, then sets AniList's progress to it
/// when signed in. Both halves: the local one alone leaves AniList behind,
/// the AniList one alone leaves Up Next offering the episode again.
///
/// The Mac checkbox's rule (`AppModel.setEpisodeWatched`): not forward-only,
/// since ticking an earlier episode is how a viewer corrects an overshot
/// list, and the status the 85% path sets. Sending progress alone leaves a
/// finished season's entry on CURRENT at `total`, the bug the Mac's shared
/// `listEntryUpdate` exists to prevent.
async fn watched(State(s): State<AppState>, ApiJson(b): ApiJson<WatchedBody>) -> ApiResult<Json<Value>> {
    s.writer
        .mark_episode_completed(b.catalog, b.catalog_id, b.episode)
        .await?;
    let synced = b.catalog == FfiCatalog::Anilist && s.signed_in();
    if synced {
        let detail = s.engine.media_detail(b.catalog_id, false).await?;
        let count = detail.episode_count.or(detail.chapter_count).map(i64::from);
        let (progress, status) = list_entry_update(b.episode, count, detail.list_status.as_deref());
        s.writer
            .update_list_entry(b.catalog_id, status, None, Some(progress))
            .await?;
    }
    Ok(Json(json!({ "anilist_synced": synced })))
}

#[derive(Deserialize)]
struct ForgetBody {
    #[serde(default = "default_catalog")]
    catalog: FfiCatalog,
    catalog_id: i64,
    /// Forget this episode and every later one; 1 forgets the whole title.
    #[serde(default = "first_episode")]
    from_episode: i64,
}

fn first_episode() -> i64 {
    1
}

/// Local watch history only. Up Next and the watched ticks are built from
/// it, so a zeroed row instead of a deleted one would keep offering the
/// title; AniList's list is a separate write the page makes itself.
async fn forget(State(s): State<AppState>, ApiJson(b): ApiJson<ForgetBody>) -> ApiResult<StatusCode> {
    s.writer
        .submit_blocking(move |e| e.clear_progress_from(b.catalog, b.catalog_id, b.from_episode))
        .await?;
    Ok(StatusCode::NO_CONTENT)
}

async fn remove_from_list(State(s): State<AppState>, ApiPath(entry): ApiPath<i64>) -> ApiResult<StatusCode> {
    s.writer.remove_from_list(entry).await?;
    Ok(StatusCode::NO_CONTENT)
}

/// A skin's optional page picture. A file in `<data dir>/skin-art/<skin>/<name>.<ext>`
/// wins, the Windows twin of the Mac's `Application Support/Anicat/skin-art`; with none
/// there, the picture embedded from the Mac app's `Resources/SkinArt` answers (one copy
/// in the repo, wallhaven.cc art committed at the owner's say-so). Neither is a 404
/// and the page keeps its plain ground. Skin and name come from fixed lists, so no path
/// segment of the request reaches the disk.
async fn skin_art(State(s): State<AppState>, Path((skin, name)): Path<(String, String)>) -> Response {
    const SKINS: [&str; 6] = ["ink", "sakura", "royal", "dusk", "cyber", "oled"];
    if !SKINS.contains(&skin.as_str()) || name != "background" {
        return StatusCode::NOT_FOUND.into_response();
    }
    for (ext, mime) in [("jpg", "image/jpeg"), ("jpeg", "image/jpeg"), ("png", "image/png"), ("webp", "image/webp")] {
        let path = s.data_dir.join("skin-art").join(&skin).join(format!("{name}.{ext}"));
        if let Ok(bytes) = tokio::fs::read(&path).await {
            return ([(header::CONTENT_TYPE, mime), (header::CACHE_CONTROL, "no-cache")], bytes).into_response();
        }
    }
    let embedded: Option<&'static [u8]> = match skin.as_str() {
        "dusk" => Some(include_bytes!("../../AnicatApple/Sources/AnicatUI/Resources/SkinArt/dusk/background.jpg")),
        "cyber" => Some(include_bytes!("../../AnicatApple/Sources/AnicatUI/Resources/SkinArt/cyber/background.jpg")),
        _ => None,
    };
    match embedded {
        Some(bytes) => ([(header::CONTENT_TYPE, "image/jpeg"), (header::CACHE_CONTROL, "no-cache")], bytes).into_response(),
        None => StatusCode::NOT_FOUND.into_response(),
    }
}

async fn cache_bytes(State(s): State<AppState>) -> Json<Value> {
    Json(json!({ "bytes": s.engine.stream_cache_bytes().await }))
}

async fn purge_cache(State(s): State<AppState>) -> ApiResult<Json<Value>> {
    s.engine.purge_stream_cache().await?;
    Ok(Json(json!({ "bytes": s.engine.stream_cache_bytes().await })))
}

// ---- account ----------------------------------------------------------------

#[derive(Deserialize)]
struct TokenBody {
    /// `null` or empty signs out.
    token: Option<String>,
}

/// Validates before persisting: a pasted token that AniList rejects must
/// not be written to config.json, or every later launch starts signed in
/// to nothing and every list call fails.
async fn set_token(State(s): State<AppState>, ApiJson(b): ApiJson<TokenBody>) -> ApiResult<Json<Value>> {
    let token = b.token.map(|t| t.trim().to_string()).filter(|t| !t.is_empty());
    let Some(token) = token else {
        s.engine.set_anilist_token(None);
        *s.token.lock().expect("token lock") = None;
        crate::config::save_token(&s.data_dir, None).map_err(|e| ApiError::internal(e.to_string()))?;
        return Ok(Json(json!({ "signed_in": false })));
    };
    let previous = s.token.lock().expect("token lock").clone();
    s.engine.set_anilist_token(Some(token.clone()));
    match s.engine.viewer_profile().await {
        Ok(profile) => {
            *s.token.lock().expect("token lock") = Some(token.clone());
            crate::config::save_token(&s.data_dir, Some(&token))
                .map_err(|e| ApiError::internal(e.to_string()))?;
            Ok(Json(json!({ "signed_in": true, "profile": profile })))
        }
        Err(e) => {
            s.engine.set_anilist_token(previous);
            Err(e.into())
        }
    }
}

async fn viewer(State(s): State<AppState>) -> ApiResult<Json<Value>> {
    if !s.signed_in() {
        return Ok(Json(json!({ "signed_in": false })));
    }
    let profile = s.engine.viewer_profile().await?;
    Ok(Json(json!({ "signed_in": true, "profile": profile })))
}

// ---- support ----------------------------------------------------------------

/// What the single-instance probe asks. `/api/version` can make the daily
/// GitHub request inline, so probing it let a second launch wait out that
/// request, time out, and start a second engine on the same registry.
async fn health() -> Json<Value> {
    Json(json!({ "app": "anicat", "version": crate::version::current() }))
}

async fn version(State(s): State<AppState>) -> Json<Value> {
    Json(json!(crate::version::check(&s.http, &s.data_dir).await))
}

/// Update now. 202 once the installer is running; it quits this process
/// itself, so a reply is all the page gets before the connection drops.
async fn update(State(s): State<AppState>) -> ApiResult<StatusCode> {
    #[cfg(windows)]
    {
        let latest = crate::version::check(&s.http, &s.data_dir)
            .await
            .latest
            .ok_or_else(|| ApiError::internal("no release is known yet; check for updates first".to_string()))?;
        crate::version::start_install(&latest).map_err(|e| ApiError::internal(format!("could not start the installer: {e}")))?;
        Ok(StatusCode::ACCEPTED)
    }
    #[cfg(not(windows))]
    {
        let _ = s;
        Err(ApiError::bad_request("updating from the page is only available on Windows"))
    }
}

async fn debug_report(State(s): State<AppState>) -> impl IntoResponse {
    let engine = s.engine.clone();
    let counts = tokio::task::spawn_blocking(move || {
        let count = |r: Result<usize, anicat_core::ffi::AnicatError>| match r {
            Ok(n) => n.to_string(),
            Err(e) => format!("error: {e}"),
        };
        [
            ("watch history rows", count(engine.watch_activity(i32::MAX).map(|v| v.len()))),
            ("remembered releases", count(engine.export_resolved_releases().map(|v| v.len()))),
            ("cinema list entries", count(engine.cinema_list(None).map(|v| v.len()))),
        ]
    })
    .await
    .map(|rows| rows.map(|(k, v)| format!("{k}: {v}")).join("\n"))
    .unwrap_or_else(|e| format!("registry counts failed: {e}"));
    let stream_port = match s.engine.stream_port().await {
        Ok(p) => p.to_string(),
        Err(e) => format!("error: {e}"),
    };
    let report = format!(
        "Anicat server {version}\nOS: {os} {arch}\nData dir: {dir}\nAPI port: {port}\nStream port: {stream_port}\n\
         Signed in to AniList: {signed_in}\nTMDB proxy compiled or set: {proxy}\nStream cache bytes: {cache}\n\
         Log redirected to file: {redirected}\n\n{counts}\n\n--- last 200 log lines ---\n{tail}\n",
        version = crate::version::current(),
        os = std::env::consts::OS,
        arch = std::env::consts::ARCH,
        dir = s.data_dir.display(),
        port = s.port,
        signed_in = s.signed_in(),
        proxy = crate::config::tmdb_proxy().is_some(),
        cache = s.engine.stream_cache_bytes().await,
        redirected = s.log_redirected,
        tail = crate::logging::tail(&s.data_dir, 200),
    );
    ([(header::CONTENT_TYPE, "text/plain; charset=utf-8")], report)
}

// ---- title page, schedule, stats --------------------------------------------

async fn franchise(State(s): State<AppState>, ApiPath(id): ApiPath<i64>) -> ApiResult<Json<Value>> {
    Ok(Json(json!(s.engine.franchise(id).await?)))
}

async fn characters(State(s): State<AppState>, ApiPath(id): ApiPath<i64>) -> ApiResult<Json<Value>> {
    Ok(Json(json!(s.engine.media_characters(id).await?)))
}

#[derive(Deserialize)]
struct ScheduleQuery {
    from: i64,
    to: i64,
}

async fn schedule(State(s): State<AppState>, ApiQuery(q): ApiQuery<ScheduleQuery>) -> ApiResult<Json<Value>> {
    Ok(Json(json!(s.engine.airing_schedule(q.from, q.to).await?)))
}

async fn recommendations(State(s): State<AppState>, ApiQuery(q): ApiQuery<LimitQuery>) -> ApiResult<Json<Value>> {
    if !s.signed_in() {
        return Err(ApiError::new(StatusCode::UNAUTHORIZED, "not signed in to AniList"));
    }
    Ok(Json(json!(s.engine.recommendations_for_viewer(q.limit).await?)))
}

#[derive(Deserialize)]
struct StatsQuery {
    #[serde(default = "default_stats_days")]
    days: i32,
    /// `anime` or `cinema`; the same split the Mac Stats page makes, since a
    /// page showing films that answers about anime is a wrong answer.
    mode: Option<String>,
}

fn default_stats_days() -> i32 {
    182
}

async fn stats(State(s): State<AppState>, ApiQuery(q): ApiQuery<StatsQuery>) -> ApiResult<Json<Value>> {
    let catalogs = match q.mode.as_deref() {
        Some("anime") => vec![FfiCatalog::Anilist],
        Some("cinema") => vec![FfiCatalog::TmdbMovie, FfiCatalog::TmdbTv],
        _ => Vec::new(),
    };
    let engine = s.engine.clone();
    let out = tokio::task::spawn_blocking(move || engine.watch_stats(q.days, catalogs))
        .await
        .map_err(|e| ApiError::internal(e.to_string()))??;
    Ok(Json(json!(out)))
}

#[derive(Deserialize)]
struct FavouriteBody {
    catalog_id: i64,
    currently_favourite: bool,
}

async fn favourite(State(s): State<AppState>, ApiJson(b): ApiJson<FavouriteBody>) -> ApiResult<Json<Value>> {
    let now = s
        .engine
        .toggle_favourite(b.catalog_id, false, b.currently_favourite)
        .await?;
    Ok(Json(json!({ "is_favourite": now })))
}

#[derive(Deserialize)]
struct ListEntryBody {
    catalog_id: i64,
    status: Option<String>,
    score: Option<f64>,
    progress: Option<i64>,
}

async fn list_entry(State(s): State<AppState>, ApiJson(b): ApiJson<ListEntryBody>) -> ApiResult<StatusCode> {
    if !s.signed_in() {
        return Err(ApiError::new(StatusCode::UNAUTHORIZED, "not signed in to AniList"));
    }
    s.writer
        .update_list_entry(b.catalog_id, b.status, b.score, b.progress)
        .await?;
    Ok(StatusCode::NO_CONTENT)
}

#[derive(Deserialize)]
struct SeriesQuery {
    #[serde(default)]
    series: bool,
}

async fn cinema_genres(State(s): State<AppState>, ApiQuery(q): ApiQuery<SeriesQuery>) -> ApiResult<Json<Value>> {
    Ok(Json(json!(s.engine.cinema_genres(q.series).await?)))
}

#[derive(Deserialize)]
struct CinemaDiscoverQuery {
    #[serde(default)]
    series: bool,
    genre: Option<i64>,
    year: Option<i32>,
    sort: Option<String>,
    #[serde(default = "default_page")]
    page: i32,
}

async fn cinema_discover(
    State(s): State<AppState>,
    ApiQuery(q): ApiQuery<CinemaDiscoverQuery>,
) -> ApiResult<Json<Value>> {
    let rows = s
        .engine
        .cinema_discover(q.series, q.genre, q.year, q.sort, q.page)
        .await?;
    Ok(Json(json!(rows)))
}

fn cinema_catalog(catalog: FfiCatalog) -> ApiResult<FfiCatalog> {
    match catalog {
        FfiCatalog::TmdbMovie | FfiCatalog::TmdbTv => Ok(catalog),
        _ => Err(ApiError::bad_request("catalog must be tmdb_movie or tmdb_tv")),
    }
}

async fn cinema_extras(
    State(s): State<AppState>,
    ApiPath(id): ApiPath<i64>,
    ApiQuery(q): ApiQuery<CatalogQuery>,
) -> ApiResult<Json<Value>> {
    Ok(Json(json!(s.engine.cinema_extras(cinema_catalog(q.catalog)?, id).await?)))
}

async fn cinema_cast(
    State(s): State<AppState>,
    ApiPath(id): ApiPath<i64>,
    ApiQuery(q): ApiQuery<CatalogQuery>,
) -> ApiResult<Json<Value>> {
    Ok(Json(json!(s.engine.cinema_cast(cinema_catalog(q.catalog)?, id).await?)))
}

#[cfg(test)]
mod tests {
    use super::*;
    use axum::body::Body;
    use axum::http::Request;
    use tower::ServiceExt;

    async fn send(s: &AppState, method: &str, uri: &str, body: Option<Value>) -> (StatusCode, Vec<u8>, String) {
        let mut req = Request::builder().method(method).uri(uri);
        if body.is_some() {
            req = req.header(header::CONTENT_TYPE, "application/json");
        }
        let body = body.map(|b| Body::from(b.to_string())).unwrap_or_else(Body::empty);
        let resp = router(s.clone()).oneshot(req.body(body).unwrap()).await.unwrap();
        let status = resp.status();
        let mime = resp
            .headers()
            .get(header::CONTENT_TYPE)
            .and_then(|v| v.to_str().ok())
            .unwrap_or_default()
            .to_string();
        let bytes = axum::body::to_bytes(resp.into_body(), usize::MAX).await.unwrap();
        (status, bytes.to_vec(), mime)
    }

    async fn send_json(s: &AppState, method: &str, uri: &str, body: Option<Value>) -> (StatusCode, Value) {
        let (status, bytes, _) = send(s, method, uri, body).await;
        (status, serde_json::from_slice(&bytes).expect("a JSON body"))
    }

    fn done(s: AppState) {
        let _ = std::fs::remove_dir_all(&s.data_dir);
    }

    /// The page calls `response.json()` on every answer; a plain-text
    /// rejection showed as a JSON syntax error instead of what was wrong.
    #[tokio::test]
    async fn malformed_requests_answer_in_the_json_error_shape() {
        let s = AppState::for_test("routes-rejections", None);
        let cases = [
            ("POST", "/api/watched", Some(json!({ "catalog_id": 1 })), StatusCode::UNPROCESSABLE_ENTITY),
            ("GET", "/api/progress/1", None, StatusCode::BAD_REQUEST),
            ("GET", "/api/media/abc", None, StatusCode::BAD_REQUEST),
            ("GET", "/api/resolve-progress/bogus/1/1", None, StatusCode::BAD_REQUEST),
        ];
        for (method, uri, body, want) in cases {
            let (status, v) = send_json(&s, method, uri, body).await;
            assert_eq!(status, want, "{uri}");
            assert!(v["error"].is_string(), "{uri}: {v}");
            assert_eq!(v["anilist_down"], false, "{uri}");
        }
        done(s);
    }

    /// A TMDB id under the AniList catalog is a different title; these
    /// must refuse before asking TMDB anything.
    #[tokio::test]
    async fn cinema_routes_refuse_a_non_tmdb_catalog() {
        let s = AppState::for_test("routes-cinema-catalog", None);
        for uri in ["/api/cinema/1?catalog=anilist", "/api/cinema/1/extras?catalog=anilist", "/api/cinema/1/cast?catalog=manga_dex"] {
            let (status, v) = send_json(&s, "GET", uri, None).await;
            assert_eq!(status, StatusCode::BAD_REQUEST, "{uri}");
            assert_eq!(v["error"], "catalog must be tmdb_movie or tmdb_tv", "{uri}");
        }
        done(s);
    }

    #[tokio::test]
    async fn signed_out_list_routes_answer_401_without_asking_anilist() {
        let s = AppState::for_test("routes-signed-out", None);
        let cases = [
            ("GET", "/api/user-list", None),
            ("GET", "/api/recommendations", None),
            ("POST", "/api/list-entry", Some(json!({ "catalog_id": 1, "progress": 3 }))),
        ];
        for (method, uri, body) in cases {
            let (status, v) = send_json(&s, method, uri, body).await;
            assert_eq!(status, StatusCode::UNAUTHORIZED, "{uri}");
            assert!(v["error"].is_string(), "{uri}");
        }
        let (status, v) = send_json(&s, "GET", "/api/viewer", None).await;
        assert_eq!((status, v), (StatusCode::OK, json!({ "signed_in": false })));
        done(s);
    }

    /// Marked locally always; AniList only for an AniList title. Signed in
    /// with a TMDB title, a lost catalog check would ask AniList for a TMDB
    /// id and fail the whole request after the local write.
    #[tokio::test]
    async fn watched_marks_locally_and_syncs_only_anilist_titles() {
        let s = AppState::for_test("routes-watched", Some("token"));
        let body = json!({ "catalog": "tmdb_tv", "catalog_id": 1399, "episode": 2 });
        let (status, v) = send_json(&s, "POST", "/api/watched", Some(body)).await;
        assert_eq!((status, v), (StatusCode::OK, json!({ "anilist_synced": false })));
        *s.token.lock().unwrap() = None;
        let body = json!({ "catalog_id": 21, "episode": 5 });
        let (status, v) = send_json(&s, "POST", "/api/watched", Some(body)).await;
        assert_eq!((status, v), (StatusCode::OK, json!({ "anilist_synced": false })));
        let (_, rows) = send_json(&s, "GET", "/api/activity", None).await;
        let mut seen: Vec<(String, i64, i64)> = rows
            .as_array()
            .unwrap()
            .iter()
            .map(|r| {
                let catalog = r["catalog"].as_str().unwrap().to_string();
                (catalog, r["catalog_id"].as_i64().unwrap(), r["episode_number"].as_i64().unwrap())
            })
            .collect();
        seen.sort();
        assert_eq!(seen, [("anilist".to_string(), 21, 5), ("tmdb_tv".to_string(), 1399, 2)]);
        done(s);
    }

    #[tokio::test]
    async fn progress_round_trips_and_forget_drops_from_the_episode_on() {
        let s = AppState::for_test("routes-forget", None);
        for ep in 1..=3 {
            s.writer.record_progress(FfiCatalog::Anilist, 7, ep, 300, 1440).await.unwrap();
        }
        let (_, v) = send_json(&s, "GET", "/api/progress/7?episode=1", None).await;
        assert_eq!(v["stop_time"], 300);
        let (status, _, _) = send(&s, "POST", "/api/forget", Some(json!({ "catalog_id": 7, "from_episode": 2 }))).await;
        assert_eq!(status, StatusCode::NO_CONTENT);
        let left: Vec<bool> = [1, 2, 3]
            .iter()
            .map(|&ep| s.engine.get_progress(FfiCatalog::Anilist, 7, ep).unwrap().is_some())
            .collect();
        assert_eq!(left, [true, false, false]);
        done(s);
    }

    /// A blank paste is a sign-out, not a token of spaces saved to
    /// config.json that every later launch would sign in with.
    #[tokio::test]
    async fn blank_token_signs_out_and_clears_config() {
        let s = AppState::for_test("routes-token", Some("old"));
        crate::config::save_token(&s.data_dir, Some("old")).unwrap();
        let (status, v) = send_json(&s, "POST", "/api/token", Some(json!({ "token": "   " }))).await;
        assert_eq!((status, v), (StatusCode::OK, json!({ "signed_in": false })));
        assert!(!s.signed_in());
        assert_eq!(crate::config::load_token(&s.data_dir), None);
        done(s);
    }

    #[tokio::test]
    async fn skin_art_serves_only_known_names_with_the_data_dir_first() {
        let s = AppState::for_test("routes-skin-art", None);
        for uri in ["/api/skin-art/nope/background", "/api/skin-art/ink/other", "/api/skin-art/ink/background", "/api/skin-art/..%2F..%2Fconfig/background"] {
            let (status, _, _) = send(&s, "GET", uri, None).await;
            assert_eq!(status, StatusCode::NOT_FOUND, "{uri}");
        }
        let (status, bytes, mime) = send(&s, "GET", "/api/skin-art/dusk/background", None).await;
        assert_eq!((status, mime.as_str()), (StatusCode::OK, "image/jpeg"));
        assert!(!bytes.is_empty());
        let dir = s.data_dir.join("skin-art").join("ink");
        std::fs::create_dir_all(&dir).unwrap();
        std::fs::write(dir.join("background.png"), b"png").unwrap();
        let (status, bytes, mime) = send(&s, "GET", "/api/skin-art/ink/background", None).await;
        assert_eq!((status, mime.as_str(), bytes.as_slice()), (StatusCode::OK, "image/png", b"png".as_slice()));
        done(s);
    }
}
