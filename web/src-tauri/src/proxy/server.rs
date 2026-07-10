use axum::{
    body::Body,
    extract::{Query, State},
    http::{HeaderMap, HeaderValue, StatusCode},
    middleware,
    response::Response,
    routing::{get, post},
    Router,
};
use std::net::SocketAddr;
use tower_http::services::{ServeDir, ServeFile};

use super::{mobile_api, mobile_auth};

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
    pub app_handle: tauri::AppHandle,
    pub app_state: crate::state::AppState,
    pub proxy_port: u16,
}

pub async fn start_proxy(
    client: reqwest::Client,
    app_handle: tauri::AppHandle,
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
        .route("/player/toggle-interpolation", get(player_toggle_interpolation_handler))
        .route("/player/toggle-auto-next", get(player_toggle_auto_next_handler))
        .route("/player/toggle-autoskip", get(player_toggle_autoskip_handler))
        .route("/player/progress", get(player_progress_handler))
        .route("/player/pause", get(player_pause_handler))
        .route("/player/resume", get(player_resume_handler))
        .route("/player/preload", get(player_preload_handler))
        .nest("/mobile-api", mobile_api::routes())
        .route_layer(middleware::from_fn_with_state(state.clone(), mobile_auth::require_mobile_auth));

    let mobile_dist_path = resolve_mobile_dist_path(&app_handle);
    log::info!("Serving mobile PWA static files from {:?}", mobile_dist_path);
    let mobile_index = mobile_dist_path.join("mobile.html");
    let static_service = ServeDir::new(&mobile_dist_path).fallback(ServeFile::new(&mobile_index));

    let app = Router::new()
        .route("/proxy", get(proxy_handler))
        .route("/api/media/manga/proxy", get(proxy_handler))
        // Ungated like /proxy: mpv fetches this from loopback without a
        // token, and it only exposes video bytes of torrents this app added.
        .route("/torrent-stream", get(crate::torrent::stream::torrent_stream_handler))
        .route("/health", get(health_handler))
        // Unauthenticated on purpose: /auth is the login endpoint itself, and
        // /lan-info is informational (what IP to type into the phone) needed
        // before a client has a token at all.
        .route("/mobile-api/auth", post(mobile_auth::authenticate))
        .route("/mobile-api/lan-info", get(mobile_auth::lan_info))
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
fn resolve_mobile_dist_path(app_handle: &tauri::AppHandle) -> std::path::PathBuf {
    if cfg!(debug_assertions) {
        let manifest_dir = std::path::Path::new(env!("CARGO_MANIFEST_DIR"));
        return manifest_dir.join("..").join("dist");
    }
    use tauri::Manager;
    if let Ok(resource_dir) = app_handle.path().resource_dir() {
        let candidate = resource_dir.join("mobile-dist");
        if candidate.join("mobile.html").exists() {
            return candidate;
        }
    }
    let manifest_dir = std::path::Path::new(env!("CARGO_MANIFEST_DIR"));
    manifest_dir.join("..").join("dist")
}

fn notify_frontend(app_handle: &tauri::AppHandle, message: &str) {
    use tauri::Emitter;
    let _ = app_handle.emit("show_notification", serde_json::json!({ "message": message }));
}

async fn player_next_handler(
    State(state): State<ProxyState>,
    Query(params): Query<PlaybackParams>,
) -> Result<&'static str, StatusCode> {
    log::info!("Player requested next episode: pos={:?}, duration={:?}, manual={:?}", params.pos, params.duration, params.manual);
    // Navigating to the next episode records the actual position of the
    // current one — it never force-completes it. The episode only counts as
    // watched if that real position is past the threshold (record_playback_
    // progress decides). So skipping forward mid-episode no longer marks the
    // skipped episode as watched.
    let play_info = {
        let mut guard = state.app_state.current_playback.lock().await;
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
                let app_state_clone = state.app_state.clone();
                let media_id = play_info.media_id;
                let ep_num = play_info.episode_number;
                let total_eps = play_info.total_episodes;
                tokio::spawn(async move {
                    if let Err(e) = crate::commands::playback::record_playback_progress(
                        &app_state_clone,
                        media_id,
                        ep_num,
                        pos,
                        duration,
                        total_eps,
                    )
                    .await {
                        log::error!("Failed to record progress on next episode transition: {}", e);
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
            notify_frontend(&state.app_handle, "No more episodes available.");
            return Ok("ok");
        }
        log::info!(
            "Starting playback for next episode: media_id={}, episode={}, provider={}",
            play_info.media_id,
            next_ep,
            play_info.provider
        );
        let app_handle = state.app_handle.clone();
        tokio::spawn(async move {
            use tauri::Manager;
            let tauri_state = app_handle.state::<crate::state::AppState>();
            let app_handle_clone = app_handle.clone();
            let title = play_info.title.clone();
            let provider = play_info.provider.clone();
            let episode_title = play_info.episode_title.clone();
            let cover_image = play_info.cover_image.clone();
            let result = crate::commands::playback::start_playback(
                app_handle_clone.clone(),
                tauri_state,
                play_info.media_id,
                next_ep,
                Some(provider),
                None,
                Some(title),
                Some(episode_title),
                Some(cover_image),
                Some(play_info.total_episodes),
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
    Query(params): Query<PlaybackParams>,
) -> Result<&'static str, StatusCode> {
    log::info!("Player requested previous episode: pos={:?}, duration={:?}", params.pos, params.duration);
    let play_info = {
        let mut guard = state.app_state.current_playback.lock().await;
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
                let app_state_clone = state.app_state.clone();
                let media_id = play_info.media_id;
                let ep_num = play_info.episode_number;
                let total_eps = play_info.total_episodes;
                tokio::spawn(async move {
                    if let Err(e) = crate::commands::playback::record_playback_progress(
                        &app_state_clone,
                        media_id,
                        ep_num,
                        pos,
                        duration,
                        total_eps,
                    )
                    .await {
                        log::error!("Failed to record progress on previous episode transition: {}", e);
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
        let app_handle = state.app_handle.clone();
        let title = play_info.title.clone();
        let provider = play_info.provider.clone();
        let episode_title = play_info.episode_title.clone();
        let cover_image = play_info.cover_image.clone();
        tokio::spawn(async move {
            use tauri::Manager;
            let tauri_state = app_handle.state::<crate::state::AppState>();
            let app_handle_clone = app_handle.clone();
            let result = crate::commands::playback::start_playback(
                app_handle_clone.clone(),
                tauri_state,
                play_info.media_id,
                prev_ep,
                Some(provider),
                None,
                Some(title),
                Some(episode_title),
                Some(cover_image),
                Some(play_info.total_episodes),
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
    Query(params): Query<PlaybackParams>,
) -> Result<&'static str, StatusCode> {
    log::info!("Player requested stop: pos={:?}, duration={:?}", params.pos, params.duration);
    let play_info = {
        let mut guard = state.app_state.current_playback.lock().await;
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
                let app_state_clone = state.app_state.clone();
                let media_id = play_info.media_id;
                let ep_num = play_info.episode_number;
                let total_eps = play_info.total_episodes;
                tokio::spawn(async move {
                    if let Err(e) = crate::commands::playback::record_playback_progress(
                        &app_state_clone,
                        media_id,
                        ep_num,
                        pos,
                        duration,
                        total_eps,
                    )
                    .await {
                        log::error!("Failed to record progress on player stop: {}", e);
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
    Query(params): Query<PlaybackParams>,
) -> Result<&'static str, StatusCode> {
    // Progress ticks (every 30s and once per completed seek) re-anchor the
    // Discord countdown to the real position, so skipping around doesn't drift.
    // Only re-anchor while playing — a tick during pause must not revive the
    // timer.
    let play_info = {
        let mut guard = state.app_state.current_playback.lock().await;
        if let Some(ref mut pb) = *guard {
            if let (Some(pos), Some(duration)) = (params.pos, params.duration) {
                pb.last_position = pos;
                pb.last_duration = duration;
            }
            if pb.paused {
                None
            } else {
                Some(pb.clone())
            }
        } else {
            None
        }
    };
    if let Some(pb) = play_info {
        if let (Some(pos), Some(dur)) = (params.pos, params.duration) {
            state.app_state.discord.set_presence(
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
    Query(params): Query<PlaybackParams>,
) -> Result<&'static str, StatusCode> {
    log::info!("Player requested pause: pos={:?}, duration={:?}", params.pos, params.duration);
    // Only act on a real play->pause transition. mpv emits pause/resume on
    // window focus changes (e.g. cmd-tab), and re-sending presence each time
    // makes the timer visibly flicker.
    let play_info = {
        let mut guard = state.app_state.current_playback.lock().await;
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
        state.app_state.discord.set_presence(
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
    Query(params): Query<PlaybackParams>,
) -> Result<&'static str, StatusCode> {
    log::info!("Player requested resume: pos={:?}, duration={:?}", params.pos, params.duration);
    let play_info = {
        let mut guard = state.app_state.current_playback.lock().await;
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
        state.app_state.discord.set_presence(
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
    Query(_params): Query<PlaybackParams>,
) -> Result<&'static str, StatusCode> {
    // Fired by the player once it's most of the way through an episode: resolve
    // the next episode's stream ahead of time so auto-next is instant.
    let pb = {
        let guard = state.app_state.current_playback.lock().await;
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
    // Already preloaded (or being worked on) for this target — don't repeat.
    {
        let slot = state.app_state.preloaded_stream.lock().await;
        if let Some(ref p) = *slot {
            if p.media_id == pb.media_id && p.episode_number == next_ep {
                return Ok("ok");
            }
        }
    }
    let app_state = state.app_state.clone();
    tokio::spawn(async move {
        match crate::commands::playback::resolve_stream_for_provider(
            &app_state,
            pb.media_id,
            next_ep,
            &pb.provider,
            &None,
            Some(pb.title.clone()),
        )
        .await
        {
            Ok((raw_url, headers)) => {
                let mut slot = app_state.preloaded_stream.lock().await;
                *slot = Some(crate::state::PreloadedStream {
                    media_id: pb.media_id,
                    episode_number: next_ep,
                    provider: pb.provider.clone(),
                    raw_url,
                    headers,
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
    let new_type = {
        let mut cfg = state.app_state.config.write().await;
        let current = cfg.stream.translation_type.clone();
        let next = if current == "dub" { "sub".to_string() } else { "dub".to_string() };
        cfg.stream.translation_type = next.clone();
        next
    };
    if let Err(e) = state.app_state.save_config().await {
        log::error!("Failed to save config on translation toggle: {}", e);
    }
    notify_frontend(&state.app_handle, &format!("Switched to {} translation.", new_type));

    // Reload the current episode with the new translation type
    let play_info = {
        let guard = state.app_state.current_playback.lock().await;
        guard.clone()
    };
    if let Some(play_info) = play_info {
        // Persist the current position to watch_history before reloading.
        // Otherwise start_playback's resume logic reads a stale/absent entry
        // (the 30s progress ticks only update an in-memory field, never the DB)
        // and the sub/dub switch restarts the episode from the beginning
        // instead of resuming where the viewer is.
        if let (Some(pos), Some(duration)) = (params.pos, params.duration) {
            if pos > 0 && duration > 0 {
                let _ = crate::commands::playback::record_playback_progress(
                    &state.app_state,
                    play_info.media_id,
                    play_info.episode_number,
                    pos,
                    duration,
                    play_info.total_episodes,
                )
                .await;
            }
        }
        let app_handle = state.app_handle.clone();
        tokio::spawn(async move {
            use tauri::Manager;
            let tauri_state = app_handle.state::<crate::state::AppState>();
            let app_handle_clone = app_handle.clone();
            let title = play_info.title.clone();
            let provider = play_info.provider.clone();
            let episode_title = play_info.episode_title.clone();
            let cover_image = play_info.cover_image.clone();
            let _ = crate::commands::playback::start_playback(
                app_handle_clone,
                tauri_state,
                play_info.media_id,
                play_info.episode_number,
                Some(provider),
                None, // Pass None to let it auto-select the server based on the new sub/dub preference
                Some(title),
                Some(episode_title),
                Some(cover_image),
                None,
            )
            .await;
        });
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
    use tauri::Emitter;
    let _ = state.app_handle.emit("anicat_setting_toggled", serde_json::json!({ "key": "shader_profile", "value": new_val }));
    Ok("ok")
}

async fn player_toggle_interpolation_handler(
    State(state): State<ProxyState>,
) -> Result<&'static str, StatusCode> {
    log::info!("Player requested smooth-motion (interpolation) toggle");
    let new_val = {
        let mut cfg = state.app_state.config.write().await;
        let next = if cfg.stream.interpolation == "off" { "on" } else { "off" };
        cfg.stream.interpolation = next.to_string();
        next.to_string()
    };
    if let Err(e) = state.app_state.save_config().await {
        log::error!("Failed to save config on interpolation toggle: {}", e);
    }
    let enabled = new_val != "off";
    notify_frontend(&state.app_handle, &format!("Smooth motion {}.", if enabled { "enabled" } else { "disabled" }));
    use tauri::Emitter;
    let _ = state.app_handle.emit("anicat_setting_toggled", serde_json::json!({ "key": "interpolation", "value": new_val }));
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
    use tauri::Emitter;
    let _ = state.app_handle.emit("anicat_setting_toggled", serde_json::json!({ "key": "autoskip", "value": new_val }));
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
    use tauri::Emitter;
    let _ = state.app_handle.emit("anicat_setting_toggled", serde_json::json!({ "key": "autoplay", "value": new_val }));
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
    // mkissa (allanime) ok.ru sources: embed host + video CDN. Needed so the
    // mobile PWA, which proxies every stream, can serve them when the ok.ru
    // server is chosen over mp4upload.
    "ok.ru", "okcdn.ru",
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

    if let Some(ua) = headers.get("user-agent") {
        req_builder = req_builder.header("user-agent", ua);
    } else {
        req_builder = req_builder.header(
            "user-agent",
            "Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/605.1.15",
        );
    }

    // An explicit ?referer= (from the mobile playback path, carrying the
    // stream's own required Referer) wins over the per-host defaults below.
    if let Some(ref referer) = params.referer {
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
    use super::host_is_allowed;

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
