use axum::{
    body::Body,
    extract::{ConnectInfo, Query, Request, State},
    http::{header, HeaderMap, HeaderValue, StatusCode},
    middleware,
    middleware::Next,
    response::Response,
    routing::{get, post},
    Router,
};
use std::net::SocketAddr;
use tower_http::services::{ServeDir, ServeFile};

use super::{mobile_api, mobile_auth, session};

/// Single entry point for both auth models — picks between the existing
/// single-PIN gate and Stage 2's per-user session auth per request, based on
/// the live `multi_user` config flag (an admin running `anicat-server
/// add-user` can flip this without restarting the server, so it's read
/// fresh each time rather than decided once at router-build time).
async fn require_auth(
    State(state): State<ProxyState>,
    ConnectInfo(addr): ConnectInfo<SocketAddr>,
    req: Request,
    next: Next,
) -> Result<Response, StatusCode> {
    let multi_user = state.app_state.config.read().await.general.multi_user;
    if multi_user {
        session::require_user_session(State(state), req, next).await
    } else {
        mobile_auth::require_mobile_auth(State(state), ConnectInfo(addr), req, next).await
    }
}

#[derive(serde::Deserialize)]
struct ProxyQuery {
    url: String,
    /// Optional Referer to forward to the upstream CDN. Set by the mobile
    /// playback path, which (unlike mpv) can't attach the header client-side.
    /// Not an SSRF lever — the target host is still allowlist-checked.
    #[serde(default)]
    referer: Option<String>,
}

#[derive(serde::Deserialize)]
struct PlaybackParams {
    pos: Option<i64>,
    duration: Option<i64>,
    manual: Option<bool>,
}

#[derive(Clone)]
pub struct ProxyState {
    pub client: reqwest::Client,
    /// `None` when running under the headless `anicat-server` binary — there
    /// is no Tauri webview to push events to and no same-host mpv process,
    /// so every AppHandle-dependent side effect below (desktop toasts,
    /// setting-sync events, the mpv-launching next/prev/toggle handlers, and
    /// `require_mobile_auth`'s loopback bypass) becomes a no-op rather than
    /// a hard dependency.
    pub app_handle: Option<tauri::AppHandle>,
    pub app_state: crate::state::AppState,
    pub proxy_port: u16,
    /// Per-IP failed-login counter shared by both login endpoints. Empty until
    /// something fails; see `throttle` module.
    pub login_throttle: super::throttle::LoginThrottle,
}

impl ProxyState {
    /// Builds an `AppState` scoped to the authenticated caller's own AniList
    /// session and playback state. `user_id == 0` (single-user mode, or the
    /// desktop sentinel `require_mobile_auth` always sets) short-circuits to
    /// a plain clone of the real global state with no DB lookup — see
    /// `AppState::scoped_for_user`. Shared by `mobile_api.rs`'s handlers and
    /// the `/player/*` handlers below, since mobile's `<video>` element
    /// reports progress through the latter, not mobile-api.
    pub async fn scoped_for(&self, crate::proxy::session::AuthedUser(user_id): crate::proxy::session::AuthedUser) -> crate::state::AppState {
        if user_id == 0 {
            return self.app_state.clone();
        }
        let (token, username) = self
            .app_state
            .open_db()
            .ok()
            .and_then(|db| crate::registry::service::get_user_by_id(&db, user_id).ok().flatten())
            .map(|u| (u.anilist_token, u.anilist_username))
            .unwrap_or((None, None));
        self.app_state.scoped_for_user(user_id, token, username).await
    }
}

pub async fn start_proxy(
    client: reqwest::Client,
    app_handle: Option<tauri::AppHandle>,
    app_state: crate::state::AppState,
) -> SocketAddr {
    // 0.0.0.0 so the proxy (and the new mobile-api/PWA routes) are reachable
    // from other devices on the LAN, not just this machine. /player/* and
    // /mobile-api/* are gated by require_mobile_auth below; /proxy and
    // /health are deliberately left open (see the router comment further
    // down) since they're either harmless or already SSRF-allowlisted.
    let addr = SocketAddr::from(([0, 0, 0, 0], 13370));
    let listener = match tokio::net::TcpListener::bind(addr).await {
        Ok(l) => l,
        Err(e) => {
            log::warn!("Port 13370 is in use ({}), falling back to OS-assigned port", e);
            let fallback = SocketAddr::from(([0, 0, 0, 0], 0));
            tokio::net::TcpListener::bind(fallback)
                .await
                .expect("Failed to bind any port for HLS proxy")
        }
    };
    let bound = listener.local_addr().expect("Failed to get proxy listener address");

    log::info!("HLS proxy bound to {}", bound);

    let state = ProxyState {
        client,
        proxy_port: bound.port(),
        app_handle: app_handle.clone(),
        app_state,
        login_throttle: super::throttle::LoginThrottle::new(),
    };

    // Player callback routes (called by mpv's Lua script today, and by the
    // mobile <video> element's progress-reporting once it exists) plus the
    // mobile data API, both behind the PIN gate. require_mobile_auth lets
    // loopback callers (mpv, always same-machine) through unconditionally,
    // so the existing desktop flow is unaffected.
    let gated = Router::new()
        .route("/player/next", get(player_next_handler))
        .route("/player/prev", get(player_prev_handler))
        .route("/player/stop", get(player_stop_handler))
        .route("/player/toggle-translation", get(player_toggle_translation_handler))
        .route("/player/toggle-upscale", get(player_toggle_upscale_handler))
        .route("/player/toggle-auto-next", get(player_toggle_auto_next_handler))
        .route("/player/toggle-autoskip", get(player_toggle_autoskip_handler))
        .route("/player/progress", get(player_progress_handler))
        .route("/player/pause", get(player_pause_handler))
        .route("/player/resume", get(player_resume_handler))
        .route("/player/preload", get(player_preload_handler))
        .nest("/mobile-api", mobile_api::routes())
        .route_layer(middleware::from_fn_with_state(state.clone(), require_auth));

    let mobile_dist_path = resolve_mobile_dist_path(app_handle.as_ref());
    log::info!("Serving mobile PWA static files from {:?}", mobile_dist_path);
    let mobile_index = mobile_dist_path.join("mobile.html");
    let static_service = ServeDir::new(&mobile_dist_path).fallback(ServeFile::new(&mobile_index));
    // ServeDir sets no Cache-Control by default, so Safari falls back to
    // heuristic HTTP caching for mobile.html — the entry point that
    // references each build's content-hashed JS bundle by name. A phone can
    // sit on a stale mobile.html (and therefore a stale bundle reference)
    // for a long time after a Pi redeploy with nothing to force a refetch.
    // Vite's hashed /assets/* filenames are already safe to cache forever
    // (a new build never reuses an old hash), so only the unhashed shell
    // files need no-cache — wrapped via a one-route catch-all Router rather
    // than a bare tower::ServiceBuilder since `tower` isn't a direct
    // dependency here, only tower-http and axum (which re-exports what it
    // needs from tower internally).
    let static_service = Router::new()
        .fallback_service(static_service)
        .layer(middleware::from_fn(no_cache_shell_files));

    let app = Router::new()
        .route("/proxy", get(proxy_handler))
        .route("/api/media/manga/proxy", get(proxy_handler))
        // Ungated like /proxy: mpv fetches this from loopback without a
        // token, and it only exposes video bytes of torrents this app added.
        .route("/torrent-stream", get(crate::torrent::stream::torrent_stream_handler))
        .route("/health", get(health_handler))
        // Unauthenticated on purpose: /auth and /session/login are the login
        // endpoints themselves (single-PIN and per-user respectively), and
        // /lan-info is informational (what IP to type into the phone, and
        // which of the two login flows to show) needed before a client has
        // a token at all.
        .route("/mobile-api/auth", post(mobile_auth::authenticate))
        .route("/mobile-api/session/login", post(session::login))
        .route("/mobile-api/lan-info", get(mobile_auth::lan_info))
        .route("/mobile-api/users/list-names", get(mobile_api::list_user_names))
        .merge(gated)
        // Fallback rather than a nested prefix: mobile.html and its manifest/
        // service-worker/asset references are root-relative (a standard Vite
        // build, not configured with a custom base path), so the static files
        // need to be reachable at the same paths they reference — e.g.
        // /mobile-manifest.webmanifest, not /m/mobile-manifest.webmanifest.
        // Using fallback_service means any request that doesn't match one of
        // the explicit routes above falls through to these static files
        // instead of competing with them for the same path space.
        .fallback_service(static_service)
        .with_state(state);

    tokio::spawn(async move {
        if let Err(e) = axum::serve(
            listener,
            app.into_make_service_with_connect_info::<SocketAddr>(),
        )
        .await
        {
            log::error!("HLS proxy server error: {}", e);
        }
    });

    bound
}

/// Forces revalidation of the mobile PWA's unhashed entry files (mobile.html,
/// the manifest, sw.js) so a Pi redeploy is visible on next load instead of
/// requiring a manual cache clear on the phone. Content-hashed build output
/// under /assets/ is left alone — a new build never reuses an old hash, so
/// caching those forever is both safe and desirable.
async fn no_cache_shell_files(req: Request<Body>, next: Next) -> Response {
    let is_asset = req.uri().path().starts_with("/assets/");
    let mut res = next.run(req).await;
    if !is_asset {
        res.headers_mut().insert(header::CACHE_CONTROL, HeaderValue::from_static("no-cache"));
    }
    res
}

/// Locates the built mobile PWA's static assets (mobile.html + its JS/CSS
/// bundle). In a packaged release these are copied in as a bundle resource
/// (see tauri.conf.json's `bundle.resources`) — but that resource list is
/// deliberately narrow (just the mobile entry's own files, not the whole
/// frontend), so in dev this must prefer the full `web/dist` folder straight
/// off disk instead: `tauri dev` also stages the same narrow resource list
/// under target/debug/, and if that were checked first it would shadow the
/// full dist folder and 404 on anything outside that narrow list (e.g.
/// shared images like the logo). `web/dist` only exists after running
/// `npm run build` at least once. ServeDir doesn't require the directory to
/// exist up front — it just 404s per request until a real build produces it
/// — so this is safe to call before any build has happened.
///
/// The headless `anicat-server` binary has no `AppHandle` to resolve a
/// bundle resource dir from at all, so it points here via `ANICAT_MOBILE_DIST`
/// instead (set by the systemd unit to wherever `npm run build`'s `dist/`
/// was copied on the Pi) — checked first so it also lets a desktop build
/// override the path for testing without touching this function further.
fn resolve_mobile_dist_path(app_handle: Option<&tauri::AppHandle>) -> std::path::PathBuf {
    if let Ok(dir) = std::env::var("ANICAT_MOBILE_DIST") {
        return std::path::PathBuf::from(dir);
    }
    if cfg!(debug_assertions) {
        let manifest_dir = std::path::Path::new(env!("CARGO_MANIFEST_DIR"));
        return manifest_dir.join("..").join("dist");
    }
    use tauri::Manager;
    if let Some(app_handle) = app_handle {
        if let Ok(resource_dir) = app_handle.path().resource_dir() {
            let candidate = resource_dir.join("mobile-dist");
            if candidate.join("mobile.html").exists() {
                return candidate;
            }
        }
    }
    let manifest_dir = std::path::Path::new(env!("CARGO_MANIFEST_DIR"));
    manifest_dir.join("..").join("dist")
}

fn notify_frontend(app_handle: &Option<tauri::AppHandle>, message: &str) {
    let Some(app_handle) = app_handle else { return };
    use tauri::Emitter;
    let _ = app_handle.emit("show_notification", serde_json::json!({ "message": message }));
}

/// Tell the webview a media's AniList progress/status may have changed, so it
/// re-fetches the watching list, detail drawer, etc. (see App.tsx's
/// `progress_updated` listener). Previously this only fired when the whole
/// mpv window closed, so `record_playback_progress`'s writes on next/prev/stop
/// (including the COMPLETED write on a finale, since there's no next episode
/// to auto-advance into and mpv just sits open) never reached the frontend
/// until the user closed mpv — Up Next stayed stale until then.
fn notify_progress_updated(app_handle: &Option<tauri::AppHandle>, media_id: i64, episode_number: i64) {
    let Some(app_handle) = app_handle else { return };
    use tauri::Emitter;
    let _ = app_handle.emit("progress_updated", serde_json::json!({
        "media_id": media_id,
        "episode_number": episode_number,
    }));
}

async fn player_next_handler(
    State(state): State<ProxyState>,
    auth @ session::AuthedUser(user_id): session::AuthedUser,
    Query(params): Query<PlaybackParams>,
) -> Result<&'static str, StatusCode> {
    log::info!("Player requested next episode: pos={:?}, duration={:?}, manual={:?}", params.pos, params.duration, params.manual);
    // Navigating to the next episode records the actual position of the
    // current one — it never force-completes it. The episode only counts as
    // watched if that real position is past the threshold (record_playback_
    // progress decides). So skipping forward mid-episode no longer marks the
    // skipped episode as watched.
    let scoped = state.scoped_for(auth).await;
    let play_info = {
        let mut guard = scoped.current_playback.lock().await;
        if let Some(ref mut pb) = *guard {
            if let (Some(pos), Some(duration)) = (params.pos, params.duration) {
                pb.last_position = pos;
                pb.last_duration = duration;
            }
        }
        guard.clone()
    };
    if let Some(play_info) = play_info {
        if let (Some(pos), Some(duration)) = (params.pos, params.duration) {
            if pos > 0 && duration > 0 {
                let scoped_clone = scoped.clone();
                let media_id = play_info.media_id;
                let ep_num = play_info.episode_number;
                let total_eps = play_info.total_episodes;
                let app_handle = state.app_handle.clone();
                tokio::spawn(async move {
                    match crate::commands::playback::record_playback_progress(
                        &scoped_clone,
                        user_id,
                        media_id,
                        ep_num,
                        pos,
                        duration,
                        total_eps,
                    )
                    .await {
                        Ok(()) => notify_progress_updated(&app_handle, media_id, ep_num),
                        Err(e) => log::error!("Failed to record progress on next episode transition: {}", e),
                    }
                });
            }
        }

        let next_ep = play_info.episode_number + 1;
        let total = play_info.total_episodes;
        if total > 0 && next_ep > total {
            log::info!("Already at last episode ({}), no next episode", total);
            if let Err(e) = crate::commands::playback::cancel_mpv_next("Already at the last episode.").await {
                log::error!("Failed to cancel mpv next: {}", e);
            }
            // Season handoff: when AniList knows a sequel, say so instead of
            // dead-ending — the detail page's primary button picks it up.
            let sequel_title = crate::commands::media::fetch_media_detail_cached(&scoped, play_info.media_id, false)
                .await
                .ok()
                .and_then(|d| d.media)
                .and_then(|m| m.relations)
                .and_then(|r| r.edges)
                .and_then(|edges| {
                    edges.into_iter().find(|e| e.relation_type.as_deref() == Some("SEQUEL"))
                })
                .and_then(|e| e.node)
                .and_then(|n| n.title)
                .and_then(|t| t.english.or(t.romaji));
            match sequel_title {
                Some(t) => notify_frontend(
                    &state.app_handle,
                    &format!("Season finished. Next up: {}.", t),
                ),
                None => notify_frontend(&state.app_handle, "No more episodes available."),
            }
            return Ok("ok");
        }
        log::info!(
            "Starting playback for next episode: media_id={}, episode={}, provider={}",
            play_info.media_id,
            next_ep,
            play_info.provider
        );
        // mpv-launching next/prev only make sense on the desktop; the headless
        // binary has no AppHandle to build a tauri::State from here at all.
        let Some(app_handle) = state.app_handle.clone() else { return Ok("ok") };
        tokio::spawn(async move {
            use tauri::Manager;
            let tauri_state = app_handle.state::<crate::state::AppState>();
            let app_handle_clone = Some(app_handle.clone());
            let title = play_info.title.clone();
            let provider = play_info.provider.clone();
            let episode_title = play_info.episode_title.clone();
            let cover_image = play_info.cover_image.clone();
            let result = crate::commands::playback::start_playback(
                app_handle.clone(),
                tauri_state,
                play_info.media_id,
                next_ep,
                Some(provider),
                None,
                Some(title),
                Some(episode_title),
                Some(cover_image),
                Some(play_info.total_episodes),
                None,
            )
            .await;
            if let Err(ref e) = result {
                log::warn!("Failed to start next episode: {}", e);
                if let Err(cancel_err) = crate::commands::playback::cancel_mpv_next("No more episodes available.").await {
                    log::error!("Failed to cancel mpv next: {}", cancel_err);
                }
                notify_frontend(&app_handle_clone, "No more episodes available.");
            }
        });
        return Ok("ok");
    }
    log::warn!("No current playback session found for next episode request");
    notify_frontend(&state.app_handle, "No current playback session.");
    Err(StatusCode::BAD_REQUEST)
}

async fn player_prev_handler(
    State(state): State<ProxyState>,
    auth @ session::AuthedUser(user_id): session::AuthedUser,
    Query(params): Query<PlaybackParams>,
) -> Result<&'static str, StatusCode> {
    log::info!("Player requested previous episode: pos={:?}, duration={:?}", params.pos, params.duration);
    let scoped = state.scoped_for(auth).await;
    let play_info = {
        let mut guard = scoped.current_playback.lock().await;
        if let Some(ref mut pb) = *guard {
            if let (Some(pos), Some(duration)) = (params.pos, params.duration) {
                pb.last_position = pos;
                pb.last_duration = duration;
            }
        }
        guard.clone()
    };
    if let Some(play_info) = play_info {
        if let (Some(pos), Some(duration)) = (params.pos, params.duration) {
            if pos > 0 && duration > 0 {
                let scoped_clone = scoped.clone();
                let media_id = play_info.media_id;
                let ep_num = play_info.episode_number;
                let total_eps = play_info.total_episodes;
                let app_handle = state.app_handle.clone();
                tokio::spawn(async move {
                    match crate::commands::playback::record_playback_progress(
                        &scoped_clone,
                        user_id,
                        media_id,
                        ep_num,
                        pos,
                        duration,
                        total_eps,
                    )
                    .await {
                        Ok(()) => notify_progress_updated(&app_handle, media_id, ep_num),
                        Err(e) => log::error!("Failed to record progress on previous episode transition: {}", e),
                    }
                });
            }
        }

        let prev_ep = play_info.episode_number - 1;
        if prev_ep < 1 {
            log::warn!("Previous episode cannot be less than 1");
            if let Err(e) = crate::commands::playback::cancel_mpv_next("Already at the first episode.").await {
                log::error!("Failed to cancel mpv next: {}", e);
            }
            notify_frontend(&state.app_handle, "Already at the first episode.");
            return Ok("ok");
        }
        log::info!(
            "Starting playback for previous episode: media_id={}, episode={}, provider={}",
            play_info.media_id,
            prev_ep,
            play_info.provider
        );
        let Some(app_handle) = state.app_handle.clone() else { return Ok("ok") };
        let title = play_info.title.clone();
        let provider = play_info.provider.clone();
        let episode_title = play_info.episode_title.clone();
        let cover_image = play_info.cover_image.clone();
        tokio::spawn(async move {
            use tauri::Manager;
            let tauri_state = app_handle.state::<crate::state::AppState>();
            let app_handle_clone = Some(app_handle.clone());
            let result = crate::commands::playback::start_playback(
                app_handle.clone(),
                tauri_state,
                play_info.media_id,
                prev_ep,
                Some(provider),
                None,
                Some(title),
                Some(episode_title),
                Some(cover_image),
                Some(play_info.total_episodes),
                None,
            )
            .await;
            if let Err(ref e) = result {
                log::warn!("Failed to start previous episode: {}", e);
                if let Err(cancel_err) = crate::commands::playback::cancel_mpv_next("Failed to load previous episode.").await {
                    log::error!("Failed to cancel mpv next: {}", cancel_err);
                }
                notify_frontend(&app_handle_clone, "Failed to load previous episode.");
            }
        });
        return Ok("ok");
    }
    log::warn!("No current playback session found for previous episode request");
    notify_frontend(&state.app_handle, "No current playback session.");
    Err(StatusCode::BAD_REQUEST)
}

async fn player_stop_handler(
    State(state): State<ProxyState>,
    auth @ session::AuthedUser(user_id): session::AuthedUser,
    Query(params): Query<PlaybackParams>,
) -> Result<&'static str, StatusCode> {
    log::info!("Player requested stop: pos={:?}, duration={:?}", params.pos, params.duration);
    let scoped = state.scoped_for(auth).await;
    let play_info = {
        let mut guard = scoped.current_playback.lock().await;
        if let Some(ref mut pb) = *guard {
            if let (Some(pos), Some(duration)) = (params.pos, params.duration) {
                pb.last_position = pos;
                pb.last_duration = duration;
            }
        }
        guard.clone()
    };
    if let Some(play_info) = play_info {
        if let (Some(pos), Some(duration)) = (params.pos, params.duration) {
            if pos > 0 && duration > 0 {
                let scoped_clone = scoped.clone();
                let media_id = play_info.media_id;
                let ep_num = play_info.episode_number;
                let total_eps = play_info.total_episodes;
                let app_handle = state.app_handle.clone();
                tokio::spawn(async move {
                    match crate::commands::playback::record_playback_progress(
                        &scoped_clone,
                        user_id,
                        media_id,
                        ep_num,
                        pos,
                        duration,
                        total_eps,
                    )
                    .await {
                        Ok(()) => notify_progress_updated(&app_handle, media_id, ep_num),
                        Err(e) => log::error!("Failed to record progress on player stop: {}", e),
                    }
                });
            }
        }
        return Ok("ok");
    }
    log::warn!("No current playback session found for stop request");
    Err(StatusCode::BAD_REQUEST)
}

async fn player_progress_handler(
    State(state): State<ProxyState>,
    auth @ session::AuthedUser(user_id): session::AuthedUser,
    Query(params): Query<PlaybackParams>,
) -> Result<&'static str, StatusCode> {
    // Progress ticks (every 30s and once per completed seek) re-anchor the
    // Discord countdown to the real position, so skipping around doesn't drift.
    // Only re-anchor while playing — a tick during pause must not revive the
    // timer.
    let scoped = state.scoped_for(auth).await;
    let (play_info, persist_info) = {
        let mut guard = scoped.current_playback.lock().await;
        if let Some(ref mut pb) = *guard {
            if let (Some(pos), Some(duration)) = (params.pos, params.duration) {
                pb.last_position = pos;
                pb.last_duration = duration;
            }
            let persist = Some((pb.media_id, pb.episode_number));
            if pb.paused {
                (None, persist)
            } else {
                (Some(pb.clone()), persist)
            }
        } else {
            (None, None)
        }
    };
    // Persist the position on every tick, not just on exit — a crash or power
    // loss between ticks costs at most 30s of resume position. SQLite upsert
    // only; AniList writes stay on the stop/next/exit paths.
    if let (Some((media_id, episode_number)), Some(pos), Some(duration)) =
        (persist_info, params.pos, params.duration)
    {
        if pos > 0 && duration > 0 {
            if let Ok(db) = scoped.open_db() {
                if let Err(e) = crate::registry::service::record_watched_episode(
                    &db, user_id, media_id, episode_number, pos, duration,
                ) {
                    log::error!(
                        "Failed to persist progress tick (media {} ep {} pos {}): {}",
                        media_id, episode_number, pos, e
                    );
                }
            }
        }
    }
    if let Some(pb) = play_info {
        if let (Some(pos), Some(dur)) = (params.pos, params.duration) {
            scoped.discord.set_presence(
                &pb.title,
                pb.episode_number,
                &pb.episode_title,
                pb.total_episodes,
                pos,
                dur,
                false, // playing
            );
        }
    }
    Ok("ok")
}

async fn player_pause_handler(
    State(state): State<ProxyState>,
    auth: session::AuthedUser,
    Query(params): Query<PlaybackParams>,
) -> Result<&'static str, StatusCode> {
    log::info!("Player requested pause: pos={:?}, duration={:?}", params.pos, params.duration);
    // Only act on a real play->pause transition. mpv emits pause/resume on
    // window focus changes (e.g. cmd-tab), and re-sending presence each time
    // makes the timer visibly flicker.
    let scoped = state.scoped_for(auth).await;
    let play_info = {
        let mut guard = scoped.current_playback.lock().await;
        if let Some(ref mut pb) = *guard {
            if let (Some(pos), Some(duration)) = (params.pos, params.duration) {
                pb.last_position = pos;
                pb.last_duration = duration;
            }
            if pb.paused {
                None
            } else {
                pb.paused = true;
                Some(pb.clone())
            }
        } else {
            None
        }
    };
    if let Some(play_info) = play_info {
        let pos = params.pos.unwrap_or(0);
        let dur = params.duration.unwrap_or(0);
        scoped.discord.set_presence(
            &play_info.title,
            play_info.episode_number,
            &play_info.episode_title,
            play_info.total_episodes,
            pos,
            dur,
            true, // paused
        );
    }
    Ok("ok")
}

async fn player_resume_handler(
    State(state): State<ProxyState>,
    auth: session::AuthedUser,
    Query(params): Query<PlaybackParams>,
) -> Result<&'static str, StatusCode> {
    log::info!("Player requested resume: pos={:?}, duration={:?}", params.pos, params.duration);
    let scoped = state.scoped_for(auth).await;
    let play_info = {
        let mut guard = scoped.current_playback.lock().await;
        if let Some(ref mut pb) = *guard {
            if let (Some(pos), Some(duration)) = (params.pos, params.duration) {
                pb.last_position = pos;
                pb.last_duration = duration;
            }
            if pb.paused {
                pb.paused = false;
                Some(pb.clone())
            } else {
                None
            }
        } else {
            None
        }
    };
    if let Some(play_info) = play_info {
        let pos = params.pos.unwrap_or(0);
        let dur = params.duration.unwrap_or(0);
        scoped.discord.set_presence(
            &play_info.title,
            play_info.episode_number,
            &play_info.episode_title,
            play_info.total_episodes,
            pos,
            dur,
            false, // playing
        );
    }
    Ok("ok")
}

async fn player_preload_handler(
    State(state): State<ProxyState>,
    auth: session::AuthedUser,
    Query(_params): Query<PlaybackParams>,
) -> Result<&'static str, StatusCode> {
    // Fired by the player once it's most of the way through an episode: resolve
    // the next episode's stream ahead of time so auto-next is instant.
    let scoped = state.scoped_for(auth).await;
    let pb = {
        let guard = scoped.current_playback.lock().await;
        guard.clone()
    };
    let pb = match pb {
        Some(pb) => pb,
        None => return Ok("ok"),
    };
    let next_ep = pb.episode_number + 1;
    if pb.total_episodes > 0 && next_ep > pb.total_episodes {
        return Ok("ok");
    }
    // Matched on translation_type too — a sub/dub toggle restarts playback
    // (see player_toggle_translation_handler) for the *current* episode, but
    // this preload is for the *next* one and isn't touched by that restart,
    // so it can still be sitting here resolved under the pre-toggle
    // preference when auto-next later consumes it.
    let translation_type = crate::commands::playback::effective_translation_type(&scoped, pb.media_id).await;

    // Already preloaded for this target — don't repeat. Matched on provider
    // too, like `preload_episode_impl` does: an entry resolved through a
    // different provider is a different stream, and `start_playback` won't
    // consume it anyway.
    {
        let slot = scoped.preloaded_stream.lock().await;
        if let Some(ref p) = *slot {
            if p.media_id == pb.media_id && p.episode_number == next_ep && p.provider == pb.provider && p.client == crate::state::StreamClient::Mpv && p.translation_type == translation_type {
                return Ok("ok");
            }
        }
    }
    // Low Data Mode: don't start the next episode's torrent while the current
    // one is still downloading — on a slow connection they'd fight for the
    // same bandwidth and stall the episode being watched. If the current
    // download already finished, the preload goes through and auto-next stays
    // instant; otherwise the next episode resolves at play time instead.
    if crate::commands::playback::is_torrent_backed(&pb.provider, pb.media_id)
        && scoped.config.read().await.stream.data_saver
        && scoped.torrent.any_download_active().await
    {
        log::info!(
            "Low data mode: deferring next-episode torrent preload (media {} ep {}) until current download finishes",
            pb.media_id, next_ep
        );
        return Ok("ok");
    }
    // The slot check above can't see a resolve that is still running (the slot
    // is only filled on completion), and this handler fires from several Lua
    // triggers — the 30s progress tick and every settled seek past the 85%
    // mark. Claim the target so only the first one scrapes.
    let Some(guard) = scoped.claim_preload(pb.media_id, next_ep, &pb.provider) else {
        log::info!(
            "Preload for media {} ep {} ({}) already in flight; skipping",
            pb.media_id, next_ep, pb.provider
        );
        return Ok("ok");
    };
    let app_state = scoped.clone();
    tokio::spawn(async move {
        let _guard = guard;
        match crate::commands::playback::resolve_stream_for_provider(
            &app_state,
            pb.media_id,
            next_ep,
            &pb.provider,
            &None,
            Some(pb.title.clone()),
            // /player/preload is only ever called by mpv's Lua script; the
            // PWA has no equivalent trigger.
            crate::state::StreamClient::Mpv,
        )
        .await
        {
            Ok((raw_url, headers, subtitle_url)) => {
                let mut slot = app_state.preloaded_stream.lock().await;
                *slot = Some(crate::state::PreloadedStream {
                    media_id: pb.media_id,
                    episode_number: next_ep,
                    provider: pb.provider.clone(),
                    client: crate::state::StreamClient::Mpv,
                    translation_type,
                    raw_url,
                    headers,
                    subtitle_url,
                    at: std::time::Instant::now(),
                });
                log::info!("Preloaded next episode stream: media {} ep {}", pb.media_id, next_ep);
            }
            Err(e) => log::warn!("Preload of media {} ep {} failed: {}", pb.media_id, next_ep, e),
        }
    });
    Ok("ok")
}

async fn player_toggle_translation_handler(
    State(state): State<ProxyState>,
    Query(params): Query<PlaybackParams>,
) -> Result<&'static str, StatusCode> {
    log::info!("Player requested translation toggle (sub/dub): pos={:?}, duration={:?}", params.pos, params.duration);
    let play_info = {
        let guard = state.app_state.current_playback.lock().await;
        guard.clone()
    };
    // If the playing show carries a per-show audio override, the toggle flips
    // that override — flipping the global value would visibly do nothing,
    // since the override wins at stream resolution. Otherwise flip the global.
    let per_show_pref = play_info.as_ref().and_then(|pb| {
        let db = state.app_state.open_db().ok()?;
        crate::registry::service::get_media_prefs(&db, 0, pb.media_id)
            .filter(|p| p.translation_type.is_some())
            .map(|p| (pb.media_id, p))
    });
    let new_type = if let Some((media_id, mut prefs)) = per_show_pref {
        let current = prefs.translation_type.as_deref().unwrap_or("sub");
        let next = if current == "dub" { "sub".to_string() } else { "dub".to_string() };
        prefs.translation_type = Some(next.clone());
        if let Ok(db) = state.app_state.open_db() {
            if let Err(e) = crate::registry::service::set_media_prefs(&db, 0, media_id, &prefs) {
                log::error!("Failed to save per-show translation toggle: {}", e);
            }
        }
        next
    } else {
        let next = {
            let mut cfg = state.app_state.config.write().await;
            let current = cfg.stream.translation_type.clone();
            let next = if current == "dub" { "sub".to_string() } else { "dub".to_string() };
            cfg.stream.translation_type = next.clone();
            next
        };
        if let Err(e) = state.app_state.save_config().await {
            log::error!("Failed to save config on translation toggle: {}", e);
        }
        next
    };
    notify_frontend(&state.app_handle, &format!("Switched to {} translation.", new_type));
    if let Some(play_info) = play_info {
        // Persist the current position to watch_history before reloading.
        // The 30s progress ticks also persist, but the last one can be up to
        // 30s stale — without this write the sub/dub switch would resume up
        // to half a minute behind where the viewer actually is.
        if let (Some(pos), Some(duration)) = (params.pos, params.duration) {
            if pos > 0 && duration > 0 {
                // Sub/dub toggle is desktop-only (mobile never calls this route).
                if let Err(e) = crate::commands::playback::record_playback_progress(
                    &state.app_state,
                    0,
                    play_info.media_id,
                    play_info.episode_number,
                    pos,
                    duration,
                    play_info.total_episodes,
                )
                .await
                {
                    log::error!(
                        "Failed to persist progress on sub/dub switch (media {} ep {}): {}",
                        play_info.media_id, play_info.episode_number, e
                    );
                }
            }
        }
        if let Some(app_handle) = state.app_handle.clone() {
            tokio::spawn(async move {
                use tauri::Manager;
                let tauri_state = app_handle.state::<crate::state::AppState>();
                let title = play_info.title.clone();
                let provider = play_info.provider.clone();
                let episode_title = play_info.episode_title.clone();
                let cover_image = play_info.cover_image.clone();
                let media_id = play_info.media_id;
                let episode_number = play_info.episode_number;
                if let Err(e) = crate::commands::playback::start_playback(
                    app_handle.clone(),
                    tauri_state,
                    media_id,
                    episode_number,
                    Some(provider),
                    None, // Pass None to let it auto-select the server based on the new sub/dub preference
                    Some(title),
                    Some(episode_title),
                    Some(cover_image),
                    // Carry the episode count through. Passing None here made
                    // start_playback push `anicat_ui-total_episodes=0` to the
                    // Lua script, which disables its end-of-series guard
                    // (`total_eps > 0 and current_ep >= total_eps`) — so after
                    // a sub/dub switch, auto-next off the finale tried to load
                    // an episode that doesn't exist.
                    Some(play_info.total_episodes),
                    None,
                )
                .await
                {
                    log::error!(
                        "Failed to restart playback after sub/dub switch (media {} ep {}): {}",
                        media_id, episode_number, e
                    );
                }
            });
        }
    }

    Ok("ok")
}

/// The mpv shortcuts (ctrl+1 upscaling, ctrl+2 auto-skip) were previously
/// session-only — they changed mpv's live behavior but never touched the
/// app's actual config, so Settings and the detail-page toggles would still
/// show the old value. These handlers persist the flip into config.toml and
/// push the new value into the frontend's settings store so every toggle in
/// the app (not just mpv) reflects it immediately.
async fn player_toggle_upscale_handler(
    State(state): State<ProxyState>,
) -> Result<&'static str, StatusCode> {
    log::info!("Player requested upscaling toggle");
    let new_val = {
        let mut cfg = state.app_state.config.write().await;
        let next = if cfg.stream.shader_profile == "off" { "on" } else { "off" };
        cfg.stream.shader_profile = next.to_string();
        next.to_string()
    };
    if let Err(e) = state.app_state.save_config().await {
        log::error!("Failed to save config on upscale toggle: {}", e);
    }
    let enabled = new_val != "off";
    notify_frontend(&state.app_handle, &format!("Upscaling {}.", if enabled { "enabled" } else { "disabled" }));
    if let Some(ah) = &state.app_handle {
        use tauri::Emitter;
        let _ = ah.emit("anicat_setting_toggled", serde_json::json!({ "key": "shader_profile", "value": new_val }));
    }
    Ok("ok")
}

async fn player_toggle_autoskip_handler(
    State(state): State<ProxyState>,
) -> Result<&'static str, StatusCode> {
    log::info!("Player requested auto-skip-intro toggle");
    let new_val = {
        let mut cfg = state.app_state.config.write().await;
        let next = !cfg.general.autoskip;
        cfg.general.autoskip = next;
        next
    };
    if let Err(e) = state.app_state.save_config().await {
        log::error!("Failed to save config on autoskip toggle: {}", e);
    }
    notify_frontend(&state.app_handle, &format!("Auto-skip intro {}.", if new_val { "enabled" } else { "disabled" }));
    if let Some(ah) = &state.app_handle {
        use tauri::Emitter;
        let _ = ah.emit("anicat_setting_toggled", serde_json::json!({ "key": "autoskip", "value": new_val }));
    }
    Ok("ok")
}

async fn player_toggle_auto_next_handler(
    State(state): State<ProxyState>,
) -> Result<&'static str, StatusCode> {
    log::info!("Player requested auto-play-next toggle");
    let new_val = {
        let mut cfg = state.app_state.config.write().await;
        let next = !cfg.general.autoplay;
        cfg.general.autoplay = next;
        next
    };
    if let Err(e) = state.app_state.save_config().await {
        log::error!("Failed to save config on auto-play-next toggle: {}", e);
    }
    notify_frontend(&state.app_handle, &format!("Auto-play next {}.", if new_val { "enabled" } else { "disabled" }));
    if let Some(ah) = &state.app_handle {
        use tauri::Emitter;
        let _ = ah.emit("anicat_setting_toggled", serde_json::json!({ "key": "autoplay", "value": new_val }));
    }
    Ok("ok")
}

async fn health_handler() -> &'static str {
    "ok"
}

/// Rewrites playlist segment URLs to relative `/proxy?url=...` references
/// rather than an absolute `127.0.0.1` host. Both mpv's ffmpeg-based HLS
/// demuxer and Safari's native HLS engine resolve relative playlist entries
/// against the manifest's own request URL (standard RFC 3986 resolution), so
/// a path-only reference correctly resolves to whatever host the manifest was
/// fetched from — `127.0.0.1:13370` for desktop mpv, or the Mac's LAN IP for a
/// phone. A hardcoded `127.0.0.1` host would be unreachable from a phone.
fn rewrite_playlist(playlist_text: &str, base_url: &reqwest::Url) -> String {
    let mut new_playlist = String::new();
    for line in playlist_text.lines() {
        let trimmed = line.trim();
        if trimmed.is_empty() || trimmed.starts_with('#') {
            new_playlist.push_str(line);
            new_playlist.push('\n');
        } else {
            if let Ok(resolved_url) = base_url.join(trimmed) {
                let encoded_url = crate::util::percent_encode(resolved_url.as_str());
                new_playlist.push_str(&format!("/proxy?url={}", encoded_url));
                new_playlist.push('\n');
            } else {
                new_playlist.push_str(line);
                new_playlist.push('\n');
            }
        }
    }
    new_playlist
}

/// Domains the proxy is allowed to fetch from. Every entry is a full domain
/// matched as an exact host or a dotted suffix (`anilist.co` matches
/// `s4.anilist.co`). CDN hosts must be listed as their full domain
/// (`allanimecdn.b-cdn.net`), never a bare label — a bare-label `contains`
/// match let `allanimecdn.evil.com` through.
const ALLOWED_DOMAINS: &[&str] = &[
    "anilist.co",
    "mangakatana.com", "anineko.to", "vibeplayer.site", "ibyteimg.com",
    "ani.zip", "aniskip.com", "api.jikan.moe", "imgur.com",
    "gravatar.com",
    "allanime.day", "allanimecdn.b-cdn.net", "youtu-chan.com",
    "wixstatic.com", "tools.fast4speed.rsvp", "mp4upload.com",
    "filemoon.sx", "filemoon.art", "filemoon.top",
    "repackager.wixmp.com", "vivibebe.site",
    // anineko's HD-2, reached via bibiemb.xyz. One fixed Cloudflare Workers
    // subdomain hosts the playlist, its variants and its segments, so the full
    // `vibevibe.workers.dev` covers it. Deliberately NOT bare `workers.dev` --
    // that is a shared public platform and would let the proxy fetch anyone's
    // Worker. HD-2 is what keeps mobile playable on the episodes where HD-1's
    // ad-CDN segments have been revoked.
    "vibevibe.workers.dev",
    // anineko's jwplayer embed hosts. The scraper deliberately resolves them
    // to their same-origin `/stream/.../master.m3u8` (the player's own `hls4`)
    // rather than the `hls2`/`hls3` mirrors, which sit on rotating throwaway
    // CDN domains that could never be listed here. Playlist, variants and
    // segments therefore all stay on these three hosts.
    "otakuhg.site", "otakuvid.online", "otakuvid.com",
    // anineko's soft-sub sidecar CDN. Only the mobile PWA's <track> element
    // ever hits this — desktop's mpv fetches --sub-file URLs directly over
    // the network, bypassing this proxy (and its allowlist) entirely, which
    // is why a missing entry here breaks subtitles on mobile only.
    "anizara.store",
    // mkissa (allanime) ok.ru sources: embed host + video CDN(s). Needed so
    // the mobile PWA, which proxies every stream, can serve them when the
    // ok.ru server is chosen over mp4upload. ok.ru rotates the actual video
    // host between okcdn.ru and vkuser.net (same VK video infrastructure) --
    // missing either one means playback dies within seconds whenever mkissa
    // happens to hand back a stream server on the missing host.
    "ok.ru", "okcdn.ru", "vkuser.net",
    // anineko's StreamHG server (rotated in as HD-1's replacement when HD-1's
    // own ad-CDN segments are revoked). Real media, PNG-obfuscated the same
    // way as the ibyteimg.com case above, served from a TikTok-owned CDN
    // subdomain under signed URLs (`p16-`/`p19-ad-site-sign-sg.tiktokcdn.com`).
    // Deliberately the narrow `ad-site-sign-sg.tiktokcdn.com` suffix rather
    // than bare `tiktokcdn.com` -- the bare domain is TikTok's general CDN and
    // would let the proxy fetch arbitrary TikTok-hosted content.
    "ad-site-sign-sg.tiktokcdn.com",
];

fn host_is_allowed(url: &str) -> bool {
    let host = match reqwest::Url::parse(url) {
        Ok(u) => match u.host_str() {
            Some(h) => h.to_lowercase(),
            None => return false,
        },
        Err(_) => return false,
    };
    ALLOWED_DOMAINS.iter().any(|d| host == *d || host.ends_with(&format!(".{d}")))
}

/// Length of the decoy PNG prefixed to an obfuscated media segment, or `None`
/// when `head` isn't one and must be passed through untouched.
///
/// What separates a real image from a wrapper is whether anything follows the
/// IEND chunk: a genuine PNG ends there, a wrapper has the media payload. The
/// caller must therefore keep reading past IEND until a payload byte appears
/// or the body ends, rather than deciding the moment it sees IEND.
fn png_decoy_len(head: &[u8]) -> Option<usize> {
    const PNG_MAGIC: &[u8] = b"\x89PNG\r\n\x1a\n";
    if !head.starts_with(PNG_MAGIC) {
        return None;
    }
    // IEND's 4-byte name, then its 4-byte CRC.
    let offset = head.windows(4).position(|w| w == b"IEND")? + 8;
    (offset < head.len()).then_some(offset)
}

async fn proxy_handler(
    State(state): State<ProxyState>,
    Query(params): Query<ProxyQuery>,
    headers: HeaderMap,
) -> Result<Response, StatusCode> {
    let url = &params.url;

    // Restrict proxy to known media domains only (SSRF prevention). Matching is
    // done against the parsed *host*, never the raw URL string — a substring
    // match on the whole URL is bypassable with e.g.
    // `http://169.254.169.254/?x=anilist.co`.
    if !host_is_allowed(url) {
        log::warn!("Proxy blocked request to disallowed domain: {}", url);
        return Err(StatusCode::FORBIDDEN);
    }

    let mut req_builder = state.client.get(url);

    if let Some(range) = headers.get("range") {
        req_builder = req_builder.header("range", range);
    }

    // The upstream CDNs (especially ok.ru/okcdn.ru) often enforce that the
    // User-Agent matches the one used to extract the stream URL (e.g. srcAg/GECKO).
    // mpv sends 'mpv 0.41.0', which gets rejected with 400 Bad Request.
    let ua = if url.contains("srcAg/GECKO") {
        "Mozilla/5.0 (Windows NT 10.0; Win64; x64; rv:150.0) Gecko/20100101 Firefox/150.0"
    } else if url.contains("srcAg/CHROME") {
        "Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/119.0.0.0 Safari/537.36"
    } else {
        "Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/605.1.15 (KHTML, like Gecko)"
    };
    req_builder = req_builder.header("user-agent", ua);

    // An explicit ?referer= (from the mobile playback path, carrying the
    // stream's own required Referer) wins over the per-host defaults below.
    //
    // Held to the same allowlist as the target URL. This parameter is
    // caller-controlled on an endpoint that is deliberately unauthenticated
    // (a phone's <video>/<img> cannot attach a bearer token), so without the
    // check anyone who can reach the port could make this server send an
    // arbitrary Referer of their choosing to a third-party CDN. Every real
    // caller sends a provider origin, so this rejects nothing legitimate.
    if let Some(referer) = params.referer.as_deref().filter(|r| host_is_allowed(r)) {
        req_builder = req_builder.header("referer", referer);
    } else if url.contains("mangakatana.com") {
        req_builder = req_builder.header("referer", "https://mangakatana.com/");
    } else if url.contains("vibeplayer.site") || url.contains("ibyteimg.com") {
        req_builder = req_builder.header("referer", "https://anineko.to/");
    } else if let Some(referer) = headers.get("referer") {
        req_builder = req_builder.header("referer", referer);
    }

    req_builder = req_builder.header("accept", "*/*");

    let upstream = req_builder
        .send()
        .await
        .map_err(|e| {
            log::error!("Proxy request to {} failed: {}", url, e);
            StatusCode::BAD_GATEWAY
        })?;

    let mut status = upstream.status();
    let upstream_headers = upstream.headers().clone();

    let content_type = upstream_headers
        .get("content-type")
        .and_then(|v| v.to_str().ok())
        .unwrap_or("")
        .to_string();

    let is_playlist_meta = url.contains(".m3u8")
        || content_type.contains("mpegurl")
        || content_type.contains("mpegURL");

    // A direct full-file video download (e.g. mkissa's mp4upload source) that
    // reports a generic content-type. mp4upload serves `application/octet-
    // stream`, so the content-type test below misses it and it would otherwise
    // hit the buffered path — reading the whole 100+ MB file into RAM before
    // the phone gets a single byte, which is the mobile slow-start. Matching by
    // path extension streams it instead. Deliberately excludes .ts/.m4s HLS
    // segments, which can carry the prepended-PNG obfuscation the buffered path
    // has to strip.
    let path_lc = url.split('?').next().unwrap_or(url).to_lowercase();
    let is_direct_video_file = [".mp4", ".m4v", ".webm", ".mkv", ".mov"]
        .iter()
        .any(|ext| path_lc.ends_with(ext));

    // Stream media segments straight through instead of buffering the whole body
    // in RAM first. Segments (fMP4/TS audio+video) are the largest and most
    // frequent items during playback, and they never carry the prepended-PNG
    // obfuscation that the buffered path below has to detect and strip. This
    // drops both peak memory and time-to-first-byte for the common case.
    // Playlists and images still buffer so they can be rewritten/cleaned.
    if !is_playlist_meta
        && (content_type.starts_with("video/") || content_type.starts_with("audio/") || is_direct_video_file)
    {
        let mut response = Response::builder().status(status);
        for (key, value) in upstream_headers.iter() {
            let key_lower = key.as_str().to_lowercase();
            if matches!(
                key_lower.as_str(),
                "transfer-encoding"
                    | "connection"
                    | "keep-alive"
                    | "trailer"
                    | "upgrade"
                    | "content-length"
            ) {
                continue;
            }
            if let Ok(hv) = HeaderValue::from_bytes(value.as_bytes()) {
                response = response.header(key.as_str(), hv);
            }
        }
        response = response
            .header("access-control-allow-origin", "*")
            .header("access-control-expose-headers", "*");
        // Some origins (mp4upload) satisfy range requests — they return 206 to
        // a Range header — but never advertise `accept-ranges`. Without it a
        // browser <video> treats the file as non-seekable and buffers a large
        // progressive chunk before it will start, which is the slow-start on
        // the mkissa mp4 source. Advertise it when the upstream didn't, so the
        // player range-seeks (moov is at the front) and starts promptly.
        if !upstream_headers.contains_key("accept-ranges") {
            response = response.header("accept-ranges", "bytes");
        }
        return response
            .body(Body::from_stream(upstream.bytes_stream()))
            .map_err(|_| StatusCode::INTERNAL_SERVER_ERROR);
    }

    // Obfuscated HLS segments. anineko serves its real media from an ad CDN
    // (p16-ad-sg.ibyteimg.com) as `content-type: image/png`: a tiny decoy PNG
    // followed by the actual MPEG-TS payload. Because that content-type is
    // neither video/* nor audio/*, these fell into the fully-buffered path
    // below — mpv got its first byte only after the whole ~800 KB segment had
    // been downloaded and re-assembled in RAM. mpv wants ~15s of readahead
    // before it starts, so that cost was paid serially over several segments:
    // a long black screen at the start of every episode, and much worse
    // whenever the CDN was slow (observed: ~130 ms per segment on a warm cache,
    // ~4 s on a cold one).
    //
    // Buffer only far enough to find the end of the decoy (IEND is at byte 62
    // in practice; the cap is pure insurance), then stream the rest straight
    // through. Time-to-first-byte becomes the decoy's length instead of the
    // whole segment's.
    //
    // Genuine images still work: a real PNG (a cover) ends *at* IEND, so the
    // "is there payload after it" test below fails and nothing is stripped.
    if !is_playlist_meta && content_type.starts_with("image/") {
        use futures_util::StreamExt;

        const PNG_MAGIC: &[u8] = b"\x89PNG\r\n\x1a\n";
        const PNG_PEEK_LIMIT: usize = 64 * 1024;

        let mut body_stream = upstream.bytes_stream();
        let mut head: Vec<u8> = Vec::new();
        let mut upstream_ended = false;

        loop {
            let decided = if head.len() < PNG_MAGIC.len() {
                false
            } else if !head.starts_with(PNG_MAGIC) {
                // Not obfuscated at all — nothing to look for.
                true
            } else {
                // Finding IEND isn't enough: a genuine PNG also ends there.
                // Keep pulling until either a payload byte shows up (wrapper)
                // or the stream ends (real image). Deciding at IEND alone
                // would strip a small cover image down to nothing, since the
                // loop exits before reqwest ever yields its end-of-stream.
                match head.windows(4).position(|w| w == b"IEND") {
                    Some(pos) => head.len() > pos + 8,
                    None => false,
                }
            };
            if decided || upstream_ended || head.len() >= PNG_PEEK_LIMIT {
                break;
            }
            match body_stream.next().await {
                Some(Ok(chunk)) => head.extend_from_slice(&chunk),
                Some(Err(e)) => {
                    log::error!("Failed to read upstream body from {}: {}", url, e);
                    return Err(StatusCode::BAD_GATEWAY);
                }
                None => upstream_ended = true,
            }
        }

        let mut stripped = false;
        if let Some(offset) = png_decoy_len(&head) {
            head.drain(..offset);
            stripped = true;
        }

        if stripped && status == StatusCode::PARTIAL_CONTENT {
            status = StatusCode::OK;
        }

        let mut response = Response::builder().status(status);
        for (key, value) in upstream_headers.iter() {
            let key_lower = key.as_str().to_lowercase();
            if matches!(
                key_lower.as_str(),
                "transfer-encoding" | "connection" | "keep-alive" | "trailer" | "upgrade" | "content-length"
            ) {
                continue;
            }
            // Stripping the decoy shifts every offset, so the upstream's byte
            // ranges no longer describe what we're sending.
            if stripped && matches!(key_lower.as_str(), "content-range" | "accept-ranges" | "x-length") {
                continue;
            }
            if let Ok(hv) = HeaderValue::from_bytes(value.as_bytes()) {
                response = response.header(key.as_str(), hv);
            }
        }
        response = response
            .header("access-control-allow-origin", "*")
            .header("access-control-expose-headers", "*");

        let head_chunk = futures_util::stream::once(async move {
            Ok::<_, reqwest::Error>(bytes::Bytes::from(head))
        });
        return response
            .body(Body::from_stream(head_chunk.chain(body_stream)))
            .map_err(|_| StatusCode::INTERNAL_SERVER_ERROR);
    }

    let mut bytes = upstream
        .bytes()
        .await
        .map_err(|e| {
            log::error!("Failed to read upstream body from {}: {}", url, e);
            StatusCode::BAD_GATEWAY
        })?
        .to_vec();

    let is_playlist = is_playlist_meta || bytes.starts_with(b"#EXTM3U");

    let mut strip_headers = false;
    if is_playlist {
        if let Ok(text) = String::from_utf8(bytes.clone()) {
            if let Ok(base_url) = reqwest::Url::parse(url) {
                let rewritten = rewrite_playlist(&text, &base_url);
                bytes = rewritten.into_bytes();
            }
        }
    } else if bytes.starts_with(b"\x89PNG\r\n\x1a\n") {
        if let Some(pos) = bytes.windows(4).position(|w| w == b"IEND") {
            let offset = pos + 8;
            if offset < bytes.len() {
                bytes = bytes[offset..].to_vec();
                strip_headers = true;
            }
        }
    }

    if strip_headers && status == StatusCode::PARTIAL_CONTENT {
        status = StatusCode::OK;
    }

    let mut response = Response::builder().status(status);

    for (key, value) in upstream_headers.iter() {
        let key_lower = key.as_str().to_lowercase();
        if matches!(
            key_lower.as_str(),
            "transfer-encoding"
                | "connection"
                | "keep-alive"
                | "trailer"
                | "upgrade"
                | "content-length"
        ) {
            continue;
        }
        if is_playlist && key_lower.as_str() == "content-type" {
            continue;
        }
        if strip_headers && matches!(key_lower.as_str(), "content-range" | "accept-ranges" | "x-length") {
            continue;
        }
        if let Ok(hv) = HeaderValue::from_bytes(value.as_bytes()) {
            response = response.header(key.as_str(), hv);
        }
    }

    response = response
        .header("access-control-allow-origin", "*")
        .header("access-control-expose-headers", "*");

    if is_playlist {
        response = response.header("content-type", "application/vnd.apple.mpegurl");
    }

    response
        .body(Body::from(bytes))
        .map_err(|_| StatusCode::INTERNAL_SERVER_ERROR)
}

#[cfg(test)]
mod tests {
    use super::{host_is_allowed, png_decoy_len};

    /// A minimal but structurally real PNG: signature, IHDR, IEND.
    fn decoy_png() -> Vec<u8> {
        let mut v = b"\x89PNG\r\n\x1a\n".to_vec();
        v.extend_from_slice(&[0, 0, 0, 13]);
        v.extend_from_slice(b"IHDR");
        v.extend_from_slice(&[0, 0, 0, 1, 0, 0, 0, 1, 8, 6, 0, 0, 0]);
        v.extend_from_slice(&[0x1f, 0x15, 0xc4, 0x89]);
        v.extend_from_slice(&[0, 0, 0, 0]);
        v.extend_from_slice(b"IEND");
        v.extend_from_slice(&[0xae, 0x42, 0x60, 0x82]);
        v
    }

    #[test]
    fn hd2_worker_subdomain_is_allowed_but_not_all_workers() {
        // HD-2's playlist, variants and segments all sit on one fixed Workers
        // subdomain, and it is what keeps mobile playable when HD-1's ad-CDN
        // segments have been revoked.
        assert!(host_is_allowed(
            "https://morning-credit-3bcc.vibevibe.workers.dev/abc/master.m3u8"
        ));
        // workers.dev is a shared public platform. Allowing the whole thing
        // would turn the proxy into an open relay for anyone's Worker.
        assert!(!host_is_allowed("https://someone-else.workers.dev/x.m3u8"));
        assert!(!host_is_allowed("https://workers.dev/x.m3u8"));
        // And the usual suffix-confusion guard.
        assert!(!host_is_allowed("https://vibevibe.workers.dev.evil.com/x.m3u8"));
    }

    #[test]
    fn strips_decoy_from_wrapped_segment() {
        let decoy = decoy_png();
        let mut body = decoy.clone();
        // MPEG-TS payload: 0x47 sync byte, as anineko's ad-CDN segments carry.
        body.extend_from_slice(b"\x47\x40\x11\x10payload");
        let offset = png_decoy_len(&body).expect("wrapper should be detected");
        assert_eq!(offset, decoy.len());
        assert_eq!(&body[offset..offset + 1], b"\x47");
    }

    #[test]
    fn leaves_a_genuine_png_alone() {
        // A real cover image: the body ends at IEND, nothing follows. Stripping
        // here would serve an empty image.
        assert_eq!(png_decoy_len(&decoy_png()), None);
    }

    #[test]
    fn ignores_non_png_bodies() {
        assert_eq!(png_decoy_len(b"\x47\x40\x11\x10raw ts"), None);
        assert_eq!(png_decoy_len(b""), None);
    }

    #[test]
    fn allows_known_media_hosts() {
        assert!(host_is_allowed("https://s4.anilist.co/file/anilistcdn/x.jpg"));
        assert!(host_is_allowed("https://allanime.day/apivtwo/x.m3u8"));
        assert!(host_is_allowed("https://api.allanime.day/api"));
        assert!(host_is_allowed("https://mangakatana.com/page.jpg"));
        assert!(host_is_allowed("https://repackager.wixmp.com/video.mp4"));
        // bare CDN token matched as a host label
        assert!(host_is_allowed("https://allanimecdn.b-cdn.net/seg1.ts"));
        // mkissa mp4upload + ok.ru sources (with ports / subdomains)
        assert!(host_is_allowed("https://a3.mp4upload.com:183/d/x/video.mp4"));
        assert!(host_is_allowed("https://vd724.okcdn.ru/expires/1/x.m3u8"));
    }

    #[test]
    fn blocks_ssrf_bypass_attempts() {
        // token in the query string must not grant access
        assert!(!host_is_allowed("http://169.254.169.254/latest/meta-data/?x=anilist.co"));
        assert!(!host_is_allowed("http://evil.com/?x=allanime.day"));
        // suffix-spoofing: allowed domain as a prefix label of a hostile host
        assert!(!host_is_allowed("http://anilist.co.evil.com/x"));
        assert!(!host_is_allowed("http://localhost:8080/admin"));
        assert!(!host_is_allowed("not a url"));
        // bare-label spoofing: a hostile host reusing a CDN label as its own
        // first label must not pass now that matching is suffix-only.
        assert!(!host_is_allowed("http://allanimecdn.evil.com/x"));
        assert!(!host_is_allowed("http://anilistcdn.evil.com/x"));
    }
}
