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
        app_handle,
        app_state,
    };

    let app = Router::new()
        .route("/proxy", get(proxy_handler))
        .route("/api/media/manga/proxy", get(proxy_handler))
        .route("/health", get(health_handler))
        .route("/player/next", get(player_next_handler))
        .route("/player/prev", get(player_prev_handler))
        .route("/player/stop", get(player_stop_handler))
        .route("/player/toggle-translation", get(player_toggle_translation_handler))
        .route("/player/progress", get(player_progress_handler))
        .route("/player/pause", get(player_pause_handler))
        .route("/player/resume", get(player_resume_handler))
        .route("/player/preload", get(player_preload_handler))
        .with_state(state);

    tokio::spawn(async move {
        if let Err(e) = axum::serve(listener, app).await {
            log::error!("HLS proxy server error: {}", e);
        }
    });

    bound
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
) -> Result<&'static str, StatusCode> {
    log::info!("Player requested translation toggle (sub/dub)");
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

async fn health_handler() -> &'static str {
    "ok"
}

fn rewrite_playlist(playlist_text: &str, base_url: &reqwest::Url, proxy_port: u16) -> String {
    let mut new_playlist = String::new();
    for line in playlist_text.lines() {
        let trimmed = line.trim();
        if trimmed.is_empty() || trimmed.starts_with('#') {
            new_playlist.push_str(line);
            new_playlist.push('\n');
        } else {
            if let Ok(resolved_url) = base_url.join(trimmed) {
                let encoded_url = crate::util::percent_encode(resolved_url.as_str());
                new_playlist.push_str(&format!("http://127.0.0.1:{}/proxy?url={}", proxy_port, encoded_url));
                new_playlist.push('\n');
            } else {
                new_playlist.push_str(line);
                new_playlist.push('\n');
            }
        }
    }
    new_playlist
}

/// Domains the proxy is allowed to fetch from. Entries with a dot are matched
/// as domain suffixes (`anilist.co` matches `s4.anilist.co`); bare tokens
/// (`anilistcdn`) are matched against individual host labels, which covers
/// CDN subdomains without matching unrelated hosts.
const ALLOWED_DOMAINS: &[&str] = &[
    "anilist.co", "anilistcdn",
    "mangakatana.com", "anineko.to", "vibeplayer.site", "ibyteimg.com",
    "ani.zip", "aniskip.com", "api.jikan.moe", "imgur.com",
    "gravatar.com",
    "allanime.day", "allanimecdn", "youtu-chan.com",
    "wixstatic.com", "tools.fast4speed.rsvp", "mp4upload.com",
    "filemoon.sx", "filemoon.art", "filemoon.top",
    "repackager.wixmp.com",
];

fn host_is_allowed(url: &str) -> bool {
    let host = match reqwest::Url::parse(url) {
        Ok(u) => match u.host_str() {
            Some(h) => h.to_lowercase(),
            None => return false,
        },
        Err(_) => return false,
    };
    ALLOWED_DOMAINS.iter().any(|d| {
        if d.contains('.') {
            host == *d || host.ends_with(&format!(".{d}"))
        } else {
            host.split('.').any(|label| label.contains(d))
        }
    })
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

    if url.contains("mangakatana.com") {
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

    // Stream media segments straight through instead of buffering the whole body
    // in RAM first. Segments (fMP4/TS audio+video) are the largest and most
    // frequent items during playback, and they never carry the prepended-PNG
    // obfuscation that the buffered path below has to detect and strip. This
    // drops both peak memory and time-to-first-byte for the common case.
    // Playlists and images still buffer so they can be rewritten/cleaned.
    if !is_playlist_meta
        && (content_type.starts_with("video/") || content_type.starts_with("audio/"))
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
                let rewritten = rewrite_playlist(&text, &base_url, state.proxy_port);
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
    }
}
