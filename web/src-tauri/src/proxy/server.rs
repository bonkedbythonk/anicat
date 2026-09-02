use axum::{
    body::Body,
    extract::{Query, State},
    http::{HeaderMap, HeaderValue, StatusCode},
    response::Response,
    routing::get,
    Router,
};
use std::net::SocketAddr;

#[derive(serde::Deserialize)]
struct ProxyQuery {
    url: String,
    /// Optional Referer to forward to the upstream CDN — some CDNs 403
    /// without it. Not an SSRF lever — the target host is still
    /// allowlist-checked.
    #[serde(default)]
    referer: Option<String>,
}

#[derive(serde::Deserialize)]
struct PlaybackParams {
    pos: Option<i64>,
    duration: Option<i64>,
    manual: Option<bool>,
    /// Only sent by `/player/loaded`: what mpv actually opened.
    episode: Option<i64>,
    media_id: Option<i64>,
}

#[derive(Clone)]
pub struct ProxyState {
    pub client: reqwest::Client,
    /// `None` when running under a non-desktop context — there is no Tauri
    /// webview to push events to, so every AppHandle-dependent side effect
    /// below (desktop toasts, setting-sync events, the mpv-launching
    /// next/prev/toggle handlers) becomes a no-op rather than a hard
    /// dependency.
    pub app_handle: Option<tauri::AppHandle>,
    pub app_state: crate::state::AppState,
    pub proxy_port: u16,
}

pub async fn start_proxy(
    client: reqwest::Client,
    app_handle: Option<tauri::AppHandle>,
    app_state: crate::state::AppState,
) -> SocketAddr {
    // Loopback only: every caller (mpv's Lua script, this app's own webview
    // fetching /proxy, /torrent-stream, /hls segments) is same-machine.
    // Bound 0.0.0.0 while there was a phone client to reach it; that surface
    // is gone, so there is no reason to accept connections from off-box.
    let addr = SocketAddr::from(([127, 0, 0, 1], 13370));
    let listener = match tokio::net::TcpListener::bind(addr).await {
        Ok(l) => l,
        Err(e) => {
            log::warn!("Port 13370 is in use ({}), falling back to OS-assigned port", e);
            let fallback = SocketAddr::from(([127, 0, 0, 1], 0));
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

    let app = Router::new()
        .route("/proxy", get(proxy_handler))
        .route("/api/media/manga/proxy", get(proxy_handler))
        .route("/torrent-stream", get(crate::torrent::stream::torrent_stream_handler))
        // A <video> element fetches its own HLS playlist and segments itself
        // and cannot be made to send a token; these expose bytes of a torrent
        // this app is already streaming, same as /torrent-stream above.
        .route("/hls/{id}/{file}", get(super::remux::session_file_handler))
        .route("/hls/{id}/{dir}/{file}", get(super::remux::session_nested_handler))
        .route("/hls/stop", get(super::remux::stop_handler))
        .route("/health", get(health_handler))
        .route("/player/next", get(player_next_handler))
        .route("/player/prev", get(player_prev_handler))
        .route("/player/stop", get(player_stop_handler))
        .route("/player/toggle-translation", get(player_toggle_translation_handler))
        .route("/player/toggle-upscale", get(player_toggle_upscale_handler))
        .route("/player/toggle-auto-next", get(player_toggle_auto_next_handler))
        .route("/player/toggle-autoskip", get(player_toggle_autoskip_handler))
        .route("/player/loaded", get(player_loaded_handler))
        .route("/player/progress", get(player_progress_handler))
        .route("/player/pause", get(player_pause_handler))
        .route("/player/resume", get(player_resume_handler))
        .route("/player/preload", get(player_preload_handler))
        .layer(
            tower_http::cors::CorsLayer::new()
                .allow_origin(tower_http::cors::Any)
                .allow_methods(tower_http::cors::Any)
                .allow_headers(tower_http::cors::Any)
                .expose_headers(tower_http::cors::Any),
        )
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

/// mpv opened a file. The one signal that a transition actually completed.
///
/// `current_playback` is advanced when the `loadfile` batch is *sent*, because
/// the callbacks for the new episode have to have something to report against.
/// A successful send is not a successful load, though, and nothing used to
/// close that gap: if mpv failed to open the stream, the counter stayed
/// advanced and the next press skipped the episode that never played. This
/// records what really opened; `start_playback` waits on it and rolls the
/// bookkeeping back when it never arrives.
///
/// Both ids come from the player rather than from `current_playback` here: the
/// backend writes that record a moment *after* sending the batch, so reading it
/// in this handler would race the callback, and losing that race would look
/// exactly like a transition that never happened.
async fn player_loaded_handler(
    State(state): State<ProxyState>,
    Query(params): Query<PlaybackParams>,
) -> Result<&'static str, StatusCode> {
    let (Some(episode), Some(media_id)) = (params.episode, params.media_id) else {
        return Ok("ok");
    };
    log::info!("Player reports media {} ep {} is open", media_id, episode);
    let mut slot = state.app_state.confirmed_playing.lock().await;
    *slot = Some((media_id, episode));
    Ok("ok")
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
    let scoped = state.app_state.clone();
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
                        0,
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
                Some(t) => {
                    let message = format!("Season finished. Next up: {}.", t);
                    // Also onto the OSD, as a second message superseding the
                    // one sent above. The sequel is the useful half of this
                    // answer and it used to reach the webview alone -- which
                    // during playback is behind a fullscreen mpv window, so
                    // nobody watching ever saw it. Sent after rather than
                    // instead, because the first message is immediate while
                    // this one waits on a media-detail fetch.
                    if let Err(e) = crate::commands::playback::cancel_mpv_next(&message).await {
                        log::error!("Failed to show the sequel hint on mpv: {}", e);
                    }
                    notify_frontend(&state.app_handle, &message);
                }
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
                // Deliberately not "No more episodes available." -- that
                // sentence belongs to the end-of-season branch above and
                // nowhere else. See `transition_failure_message`.
                let message = crate::commands::playback::transition_failure_message(next_ep, e);
                if let Err(cancel_err) = crate::commands::playback::cancel_mpv_next(&message).await {
                    log::error!("Failed to cancel mpv next: {}", cancel_err);
                }
                notify_frontend(&app_handle_clone, &message);
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
    let scoped = state.app_state.clone();
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
                        0,
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
                let message = crate::commands::playback::transition_failure_message(prev_ep, e);
                if let Err(cancel_err) = crate::commands::playback::cancel_mpv_next(&message).await {
                    log::error!("Failed to cancel mpv next: {}", cancel_err);
                }
                notify_frontend(&app_handle_clone, &message);
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
    let scoped = state.app_state.clone();
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
                        0,
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
    Query(params): Query<PlaybackParams>,
) -> Result<&'static str, StatusCode> {
    // Progress ticks (every 30s and once per completed seek) re-anchor the
    // Discord countdown to the real position, so skipping around doesn't drift.
    // Only re-anchor while playing — a tick during pause must not revive the
    // timer.
    let scoped = state.app_state.clone();
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
                    &db, 0, media_id, episode_number, pos, duration,
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
    Query(params): Query<PlaybackParams>,
) -> Result<&'static str, StatusCode> {
    log::info!("Player requested pause: pos={:?}, duration={:?}", params.pos, params.duration);
    // Only act on a real play->pause transition. mpv emits pause/resume on
    // window focus changes (e.g. cmd-tab), and re-sending presence each time
    // makes the timer visibly flicker.
    let scoped = state.app_state.clone();
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
    Query(params): Query<PlaybackParams>,
) -> Result<&'static str, StatusCode> {
    log::info!("Player requested resume: pos={:?}, duration={:?}", params.pos, params.duration);
    let scoped = state.app_state.clone();
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
    Query(_params): Query<PlaybackParams>,
) -> Result<&'static str, StatusCode> {
    // Fired by the player once it's most of the way through an episode: resolve
    // the next episode's stream ahead of time so auto-next is instant.
    let scoped = state.app_state.clone();
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
        let mut slot = scoped.preloaded_stream.lock().await;
        if let Some(p) = slot.as_mut() {
            if p.media_id == pb.media_id && p.episode_number == next_ep && p.provider == pb.provider && p.client == crate::state::StreamClient::Mpv && p.translation_type == translation_type {
                // Warmed by a hover earlier, wanted by auto-next now. Promoting
                // it is the point: left marked speculative, the next hover in
                // the episode list would evict the stream the player is about
                // to ask for.
                p.priority = crate::state::PreloadPriority::Primary;
                return Ok("ok");
            }
        }
    }
    // Low Data Mode: don't start the next episode's torrent while the current
    // one is still downloading — on a slow connection they'd fight for the
    // same bandwidth and stall the episode being watched. If the current
    // download already finished, the preload goes through and auto-next stays
    // instant; otherwise the next episode resolves at play time instead.
    if crate::source::StreamSource::resolve(pb.media_id, &pb.provider).is_torrent()
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
    let app_handle = state.app_handle.clone();
    tokio::spawn(async move {
        let _guard = guard;
        match crate::commands::playback::resolve_stream_for_provider(
            &app_state,
            pb.media_id,
            next_ep,
            &pb.provider,
            &None,
            Some(pb.title.clone()),
            // /player/preload is only ever called by mpv's Lua script, so the
            // stream it warms is always the one mpv would be given.
            crate::state::StreamClient::Mpv,
            None,
        )
        .await
        {
            Ok((raw_url, headers, subtitle_url)) => {
                // Primary: auto-next is about to consume this. It therefore
                // outranks the episode list's hover guesses, and displaces
                // whatever they left in the slot -- reporting the displacement,
                // since the webview's per-episode map is push-fed and a silent
                // overwrite leaves it calling a cold episode "ready".
                let decision = {
                    let mut slot = app_state.preloaded_stream.lock().await;
                    let decision = crate::state::preload_write_decision(
                        slot.as_ref(),
                        crate::state::PreloadPriority::Primary,
                    );
                    if let crate::state::PreloadWrite::Store { .. } = decision {
                        *slot = Some(crate::state::PreloadedStream {
                            media_id: pb.media_id,
                            episode_number: next_ep,
                            provider: pb.provider.clone(),
                            client: crate::state::StreamClient::Mpv,
                            translation_type,
                            priority: crate::state::PreloadPriority::Primary,
                            raw_url,
                            headers,
                            subtitle_url,
                            at: std::time::Instant::now(),
                        });
                    }
                    decision
                };
                if let crate::state::PreloadWrite::Store { evicted: Some((ev_media, ev_ep)) } = decision {
                    crate::commands::playback::emit_preload_status(app_handle.as_ref(), ev_media, ev_ep, "idle");
                }
                crate::commands::playback::emit_preload_status(app_handle.as_ref(), pb.media_id, next_ep, "ready");
                log::info!("Preloaded next episode stream: media {} ep {}", pb.media_id, next_ep);
            }
            Err(e) => {
                log::warn!("Preload of media {} ep {} failed: {}", pb.media_id, next_ep, e);
                crate::commands::playback::emit_preload_status(app_handle.as_ref(), pb.media_id, next_ep, "idle");
            }
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
                // Sub/dub toggle is an mpv binding; nothing else calls this route.
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
/// fetched from, and stays correct when the proxy binds a port other than
/// 13370 (see `start`, which falls back to an OS-assigned one).
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
///
/// Only the hosts something in the app can still ask for. A retired provider's
/// scraper module is kept in-tree in case it comes back, but its hosts are
/// deleted with it: every entry here is a host this process will fetch from on
/// request, so a list that outlives its reason is pure attack surface and
/// nothing else. anineko's and mkissa's are gone on those grounds;
/// `scraper/anineko.py` still names anineko's if it is ever reinstated, and
/// mkissa's live in this file's history.
///
/// What remains is the metadata and manga hosts the app itself reaches — the
/// anime and cinema paths stream over the torrent engine and never come
/// through here at all.
const ALLOWED_DOMAINS: &[&str] = &[
    "anilist.co",
    "mangakatana.com",
    "ani.zip", "aniskip.com", "api.jikan.moe", "imgur.com",
    "gravatar.com",
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

/// Attempts made against a segment that answers 429 before giving up on it.
const SEGMENT_RETRY_MAX: u32 = 3;
/// Doubling from half a second: 0.5s, 1s, 2s. The ladder used to be
/// 150/300/450ms, which spent all three attempts inside a single second and
/// then gave up — against a rate limiter thinking in seconds that is
/// indistinguishable from not retrying at all. Observed live: three 429s
/// inside 900ms, "hls: Failed to open segment 118", and mpv left to retry the
/// whole segment itself a second later.
const SEGMENT_RETRY_BASE_DELAY: std::time::Duration = std::time::Duration::from_millis(500);
/// A cap on what a `Retry-After` may talk us into. Some CDNs answer with tens
/// of seconds, which is a fine instruction for a crawler and a stalled player
/// for us — past a few seconds mpv is better off failing the segment and
/// moving on.
const SEGMENT_RETRY_MAX_WAIT: std::time::Duration = std::time::Duration::from_secs(4);

/// How long to wait before retrying a rate-limited segment.
///
/// Prefers what the server asked for, since a limiter knows its own window
/// better than any ladder we pick. Only the delta-seconds form is read: the
/// HTTP-date form is legal but vanishingly rare from segment CDNs, and
/// misreading one costs a stalled segment.
fn segment_retry_delay(attempt: u32, retry_after: Option<&str>) -> std::time::Duration {
    retry_after
        .and_then(|raw| raw.trim().parse::<u64>().ok())
        .map(std::time::Duration::from_secs)
        .unwrap_or(SEGMENT_RETRY_BASE_DELAY * 2u32.pow(attempt))
        .min(SEGMENT_RETRY_MAX_WAIT)
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

    // An explicit ?referer= (carrying the stream's own required Referer) wins
    // over the per-host defaults below.
    //
    // Held to the same allowlist as the target URL. This parameter is
    // caller-controlled on an endpoint that is deliberately unauthenticated
    // (a webview <video>/<img> cannot attach a bearer token), so without the
    // check anyone who can reach the port could make this server send an
    // arbitrary Referer of their choosing to a third-party CDN. Every real
    // caller sends a provider origin, so this rejects nothing legitimate.
    if let Some(referer) = params.referer.as_deref().filter(|r| host_is_allowed(r)) {
        req_builder = req_builder.header("referer", referer);
    } else if url.contains("mangakatana.com") {
        req_builder = req_builder.header("referer", "https://mangakatana.com/");
    } else if let Some(referer) = headers.get("referer") {
        req_builder = req_builder.header("referer", referer);
    }

    req_builder = req_builder.header("accept", "*/*");

    // A CDN 429 here used to reach mpv untouched. Enough of those in a row
    // (segment CDNs like anineko's ration hard under load) make mpv's HLS
    // demuxer give up on the whole stream, which falls back to mpv's generic
    // playlist demuxer — and that one doesn't resolve the proxy's
    // intentionally relative playlist entries (see `rewrite_playlist`)
    // against the manifest's fetch URL, so it hands mpv a schemeless path it
    // can't open at all. A brief retry here absorbs the rate limit before it
    // ever reaches that failure mode.
    let mut upstream = None;
    for attempt in 0..=SEGMENT_RETRY_MAX {
        let resp = req_builder
            .try_clone()
            .expect("GET request with no streaming body is always cloneable")
            .send()
            .await
            .map_err(|e| {
                log::error!("Proxy request to {} failed: {}", url, e);
                StatusCode::BAD_GATEWAY
            })?;
        if resp.status() == StatusCode::TOO_MANY_REQUESTS && attempt < SEGMENT_RETRY_MAX {
            let wait = segment_retry_delay(
                attempt,
                resp.headers().get(reqwest::header::RETRY_AFTER).and_then(|v| v.to_str().ok()),
            );
            log::warn!(
                "Proxy got 429 from {} (attempt {}/{}), retrying in {}ms",
                url, attempt + 1, SEGMENT_RETRY_MAX, wait.as_millis()
            );
            tokio::time::sleep(wait).await;
            continue;
        }
        upstream = Some(resp);
        break;
    }
    let upstream = upstream.expect("loop always assigns before exiting");

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

    // A direct full-file video download that reports a generic content-type.
    // Some hosts serve `application/octet-stream`, so the content-type test
    // below misses it and it would otherwise hit the buffered path — reading
    // the whole 100+ MB file into RAM before the player gets a single byte.
    // Matching by path extension streams it instead. Deliberately excludes .ts/.m4s HLS
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
        // Some origins satisfy range requests — they return 206 to a Range
        // header — but never advertise `accept-ranges`. Without it a browser
        // <video> treats the file as non-seekable and buffers a large
        // progressive chunk before it will start. Advertise it when the
        // upstream didn't, so the player range-seeks (moov is at the front)
        // and starts promptly.
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
    use super::segment_retry_delay;

    #[test]
    fn a_rate_limited_segment_backs_off_over_seconds_not_milliseconds() {
        use std::time::Duration;
        // The whole ladder used to fit inside 900ms, which a limiter counting
        // in seconds never notices. Three attempts now span 3.5s.
        assert_eq!(segment_retry_delay(0, None), Duration::from_millis(500));
        assert_eq!(segment_retry_delay(1, None), Duration::from_millis(1000));
        assert_eq!(segment_retry_delay(2, None), Duration::from_millis(2000));

        // A server that states its window wins over the ladder, in both
        // directions -- a short one gets playback moving again sooner.
        assert_eq!(segment_retry_delay(0, Some("2")), Duration::from_secs(2));
        assert_eq!(segment_retry_delay(2, Some("1")), Duration::from_secs(1));

        // ...but only so far. A crawler can wait a minute; a player cannot.
        assert_eq!(segment_retry_delay(0, Some("60")), Duration::from_secs(4));

        // The HTTP-date form and anything else unparseable falls back to the
        // ladder rather than to zero, which would hammer the limiter.
        assert_eq!(
            segment_retry_delay(1, Some("Wed, 21 Oct 2026 07:28:00 GMT")),
            Duration::from_millis(1000)
        );
        assert_eq!(segment_retry_delay(0, Some("")), Duration::from_millis(500));
    }

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

    /// An entry is matched as a whole domain or a dotted suffix of one, never
    /// as a bare label. Written against the CDN entries that are now gone, but
    /// it is the rule every future entry has to satisfy: name the tenant, never
    /// the platform hosting it, or the proxy becomes an open relay for whoever
    /// else rents space there.
    #[test]
    fn a_subdomain_is_allowed_but_a_lookalike_is_not() {
        // Subdomains of an allowed domain are in.
        assert!(host_is_allowed("https://s4.anilist.co/file/anilistcdn/x.jpg"));
        assert!(host_is_allowed("https://deep.nested.anilist.co/x.jpg"));
        // A hostile host that merely starts with the allowed label is not.
        assert!(!host_is_allowed("https://anilist.co.evil.com/x.jpg"));
        assert!(!host_is_allowed("https://notanilist.co/x.jpg"));
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
        assert!(host_is_allowed("https://mangakatana.com/page.jpg"));
        assert!(host_is_allowed("https://api.ani.zip/mappings?anilist_id=1"));
        assert!(host_is_allowed("https://api.aniskip.com/v2/skip-times/1/1"));
        // Ports and subdomains don't change the host match.
        assert!(host_is_allowed("https://cdn.mangakatana.com:8443/page.jpg"));
        // A retired provider's hosts go with it.
        assert!(!host_is_allowed("https://allanime.day/apivtwo/x.m3u8"));

        assert!(!host_is_allowed("https://vd724.okcdn.ru/expires/1/x.m3u8"));
        assert!(!host_is_allowed("https://anineko.to/watch/x"));
    }

    #[test]
    fn blocks_ssrf_bypass_attempts() {
        // token in the query string must not grant access
        assert!(!host_is_allowed("http://169.254.169.254/latest/meta-data/?x=anilist.co"));
        assert!(!host_is_allowed("http://evil.com/?x=anilist.co"));
        // suffix-spoofing: allowed domain as a prefix label of a hostile host
        assert!(!host_is_allowed("http://anilist.co.evil.com/x"));
        assert!(!host_is_allowed("http://localhost:8080/admin"));
        assert!(!host_is_allowed("not a url"));
        // bare-label spoofing: a hostile host reusing a CDN label as its own
        // first label must not pass now that matching is suffix-only.
        assert!(!host_is_allowed("http://anilistcdn.evil.com/x"));
        assert!(!host_is_allowed("http://mangakatana.evil.com/x"));
    }
}
