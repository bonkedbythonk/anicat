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
    let bound = listener.local_addr().unwrap();

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
        .with_state(state);

    tokio::spawn(async move {
        axum::serve(listener, app).await.unwrap();
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
    log::info!("Player requested next episode: pos={:?}, duration={:?}", params.pos, params.duration);
    let play_info = {
        let guard = state.app_state.current_playback.lock().await;
        guard.clone()
    };
    if let Some(play_info) = play_info {
        if let (Some(pos), Some(duration)) = (params.pos, params.duration) {
            if pos > 0 && duration > 0 {
                let app_state_clone = state.app_state.clone();
                let media_id = play_info.media_id;
                let ep_num = play_info.episode_number;
                tokio::spawn(async move {
                    if let Err(e) = crate::commands::playback::record_playback_progress(
                        &app_state_clone,
                        media_id,
                        ep_num,
                        pos,
                        duration,
                    )
                    .await {
                        log::error!("Failed to record progress on next episode transition: {}", e);
                    }
                });
            }
        }

        let next_ep = play_info.episode_number + 1;
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
        let guard = state.app_state.current_playback.lock().await;
        guard.clone()
    };
    if let Some(play_info) = play_info {
        if let (Some(pos), Some(duration)) = (params.pos, params.duration) {
            if pos > 0 && duration > 0 {
                let app_state_clone = state.app_state.clone();
                let media_id = play_info.media_id;
                let ep_num = play_info.episode_number;
                tokio::spawn(async move {
                    if let Err(e) = crate::commands::playback::record_playback_progress(
                        &app_state_clone,
                        media_id,
                        ep_num,
                        pos,
                        duration,
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
            notify_frontend(&state.app_handle, "Already at the first episode.");
            return Err(StatusCode::BAD_REQUEST);
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
            let _ = crate::commands::playback::start_playback(
                app_handle_clone,
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
        let guard = state.app_state.current_playback.lock().await;
        guard.clone()
    };
    if let Some(play_info) = play_info {
        if let (Some(pos), Some(duration)) = (params.pos, params.duration) {
            if pos > 0 && duration > 0 {
                let app_state_clone = state.app_state.clone();
                let media_id = play_info.media_id;
                let ep_num = play_info.episode_number;
                tokio::spawn(async move {
                    if let Err(e) = crate::commands::playback::record_playback_progress(
                        &app_state_clone,
                        media_id,
                        ep_num,
                        pos,
                        duration,
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

pub fn percent_encode(s: &str) -> String {
    let mut encoded = String::new();
    for b in s.bytes() {
        match b {
            b'a'..=b'z' | b'A'..=b'Z' | b'0'..=b'9' | b'-' | b'_' | b'.' | b'~' => {
                encoded.push(b as char);
            }
            _ => {
                encoded.push_str(&format!("%{:02X}", b));
            }
        }
    }
    encoded
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
                let encoded_url = percent_encode(resolved_url.as_str());
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

async fn proxy_handler(
    State(state): State<ProxyState>,
    Query(params): Query<ProxyQuery>,
    headers: HeaderMap,
) -> Result<Response, StatusCode> {
    let url = &params.url;

    // Restrict proxy to known media domains only (SSRF prevention)
    let allowed_domains = [
        "anilist.co", "anilistcdn",
        "mangakatana.com", "anineko.to", "vibeplayer.site", "ibyteimg.com",
        "ani.zip", "aniskip.com", "api.jikan.moe", "imgur.com",
        "gravatar.com",
        "allanime.day", "allanimecdn", "youtu-chan.com",
        "wixstatic.com", "tools.fast4speed.rsvp", "mp4upload.com",
        "filemoon.sx", "filemoon.art", "filemoon.top",
        "repackager.wixmp.com",
    ];
    let is_allowed = allowed_domains.iter().any(|d| url.contains(d));
    if !is_allowed {
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

    let mut bytes = upstream
        .bytes()
        .await
        .map_err(|e| {
            log::error!("Failed to read upstream body from {}: {}", url, e);
            StatusCode::BAD_GATEWAY
        })?
        .to_vec();

    let content_type = upstream_headers
        .get("content-type")
        .and_then(|v| v.to_str().ok())
        .unwrap_or("");

    let is_playlist = url.contains(".m3u8")
        || content_type.contains("mpegurl")
        || content_type.contains("mpegURL")
        || bytes.starts_with(b"#EXTM3U");

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
