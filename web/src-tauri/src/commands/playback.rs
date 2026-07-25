use std::collections::HashMap;

use serde::Serialize;
use serde_json::Value;
use tauri::{AppHandle, Emitter, Manager, State};

use crate::util::percent_encode;
use crate::state::AppState;

static CURRENT_MPV: std::sync::Mutex<Option<tokio::process::Child>> = std::sync::Mutex::new(None);

/// An episode counts as "watched" once playback passes this fraction of its
/// duration. The same line decides completion (advancing AniList progress) and
/// stops offering a resume — there is exactly one watched threshold.
const WATCHED_THRESHOLD_PCT: f64 = 85.0;

/// True once playback has passed the watched threshold for an episode of the
/// given duration. Below it — or with an unknown (non-positive) duration — the
/// episode is not counted as watched and AniList progress does not advance.
fn is_watched(stop_time: i64, duration: i64) -> bool {
    duration > 0 && (stop_time as f64 / duration as f64) * 100.0 >= WATCHED_THRESHOLD_PCT
}

/// Resume position for an episode, in seconds. Returns 0 (start from the
/// beginning) when the episode is already watched, when the recorded position
/// is trivially small, or when the duration is unknown — so a finished episode
/// never drops the user back near the end and a brief sample never starts in
/// the middle.
pub(crate) fn resume_position(stop_time: i64, duration: i64) -> i64 {
    const MIN_RESUME_SECONDS: i64 = 30;
    if duration <= 0 || stop_time < MIN_RESUME_SECONDS || is_watched(stop_time, duration) {
        0
    } else {
        stop_time
    }
}

fn get_ipc_path() -> String {
    if cfg!(target_os = "windows") {
        r"\\.\pipe\anicat-mpv".to_string()
    } else {
        let uid = std::env::var("USER").unwrap_or_else(|_| "user".to_string());
        format!("/tmp/anicat-mpv-{}.sock", uid)
    }
}

async fn try_send_ipc(ipc_path: &str, commands: Vec<serde_json::Value>) -> Result<(), String> {
    use tokio::io::AsyncWriteExt;

    #[cfg(unix)]
    {
        let mut stream = tokio::net::UnixStream::connect(ipc_path)
            .await
            .map_err(|e| e.to_string())?;
        for cmd in commands {
            let line = format!("{}\n", cmd);
            stream.write_all(line.as_bytes())
                .await
                .map_err(|e| e.to_string())?;
        }
        let _ = stream.flush().await;
        let _ = stream.shutdown().await;
        tokio::time::sleep(std::time::Duration::from_millis(20)).await;
        Ok(())
    }

    #[cfg(windows)]
    {
        use tokio::net::windows::named_pipe::ClientOptions;
        let mut client = ClientOptions::new()
            .open(ipc_path)
            .map_err(|e| e.to_string())?;
        for cmd in commands {
            let line = format!("{}\n", cmd.to_string());
            client.write_all(line.as_bytes())
                .await
                .map_err(|e| e.to_string())?;
        }
        let _ = client.flush().await;
        let _ = client.shutdown().await;
        tokio::time::sleep(std::time::Duration::from_millis(20)).await;
        return Ok(());
    }

    #[cfg(not(any(unix, windows)))]
    {
        let _ = ipc_path;
        let _ = commands;
        Err("Unsupported platform".to_string())
    }
}

pub async fn cancel_mpv_next(message: &str) -> Result<(), String> {
    let ipc_path = get_ipc_path();
    let cmd_osd = serde_json::json!({
        "command": ["show-text", message, 3000]
    });
    let cmd_cancel = serde_json::json!({
        "command": ["script-message", "anicat-cancel-next"]
    });
    try_send_ipc(&ipc_path, vec![cmd_osd, cmd_cancel]).await
}

/// Tells the webview whether the external mpv window is open. Low Data Mode
/// uses this to pause background traffic (home polling, hover prefetch) while
/// a stream is running. Emitted on successful playback start (fresh spawn or
/// IPC reuse) and from the exit monitor when mpv closes.
fn emit_playback_active(app: &AppHandle, active: bool) {
    let _ = app.emit("anicat_playback_state", serde_json::json!({ "active": active }));
}

pub async fn kill_current_mpv() {
    let child = {
        if let Ok(mut guard) = CURRENT_MPV.lock() {
            guard.take()
        } else {
            None
        }
    };

    if let Some(mut c) = child {
        log::info!("Killing previous mpv instance");
        let _ = c.kill().await;
    }

    #[cfg(unix)]
    {
        let path = get_ipc_path();
        let _ = std::fs::remove_file(path);
    }
}

#[derive(Serialize)]
pub struct PlaybackStart {
    pub stream_url: String,
}

/// Strip the Windows `\\?\` verbatim (extended-length) path prefix.
///
/// Tauri's `resource_dir()` returns verbatim paths on Windows. mpv opens
/// fully-formed file arguments (`--glsl-shaders=\\?\C:\...\x.glsl`) fine, but
/// it can't resolve anything *relative* to a `\\?\` config-dir: it appends
/// sub-paths with '/' (`\\?\C:\...\mpv_config/mpv.conf`), and forward slashes
/// are illegal inside the verbatim namespace, so every config lookup
/// (mpv.conf, input.conf, scripts/) silently fails and mpv falls back to its
/// built-in OSC and default keybindings — i.e. no anicat skin or shortcuts.
fn strip_verbatim_prefix(p: String) -> String {
    #[cfg(target_os = "windows")]
    {
        if let Some(rest) = p.strip_prefix(r"\\?\UNC\") {
            return format!(r"\\{}", rest);
        }
        if let Some(rest) = p.strip_prefix(r"\\?\") {
            return rest.to_string();
        }
    }
    p
}

fn resolve_mpv_path(app: &AppHandle) -> Result<(String, String, String), String> {
    let resource_dir = app.path().resource_dir().map_err(|e| e.to_string())?;

    let base_dir = if resource_dir.join("resources").exists() {
        resource_dir.join("resources")
    } else {
        resource_dir.clone()
    };

    let prod_config = base_dir.join("mpv_config");
    let config_dir = if prod_config.exists() {
        prod_config.to_string_lossy().to_string()
    } else {
        std::path::Path::new(env!("CARGO_MANIFEST_DIR"))
            .join("resources")
            .join("mpv_config")
            .to_string_lossy()
            .to_string()
    };
    // mpv can't use a `\\?\`-prefixed config-dir (see strip_verbatim_prefix).
    let config_dir = strip_verbatim_prefix(config_dir);

    // Prefer a system-installed mpv if present. Production macOS apps launched
    // from Finder do not inherit the shell PATH, so /opt/homebrew/bin is not
    // in it — check known install locations first before falling back to which.
    #[cfg(target_os = "macos")]
    {
        let known = ["/opt/homebrew/bin/mpv", "/usr/local/bin/mpv", "/usr/bin/mpv"];
        for p in &known {
            if std::path::Path::new(p).exists() {
                log::info!("Found system mpv at: {}", p);
                return Ok((p.to_string(), config_dir, String::new()));
            }
        }
    }
    let mpv_query = if cfg!(target_os = "windows") { "mpv.exe" } else { "mpv" };
    if let Some(path) = crate::util::find_on_path(mpv_query) {
        log::info!("Found system mpv at: {}", path);
        return Ok((path, config_dir, String::new()));
    }

    let mpv_name = if cfg!(target_os = "windows") {
        "mpv.exe"
    } else {
        "mpv"
    };
    let mpv_bin = base_dir.join(mpv_name);
    if !mpv_bin.exists() {
        let dev_path = std::path::Path::new(env!("CARGO_MANIFEST_DIR"))
            .join("resources")
            .join(mpv_name);
        if dev_path.exists() {
            let dev_lib_dir = std::path::Path::new(env!("CARGO_MANIFEST_DIR"))
                .join("resources")
                .join("lib");
            return Ok((
                dev_path.to_string_lossy().to_string(),
                config_dir,
                dev_lib_dir.to_string_lossy().to_string(),
            ));
        }
        return Err(format!(
            "mpv binary not found at {} or in dev resources",
            mpv_bin.display()
        ));
    }

    let lib_dir = base_dir.join("lib");

    Ok((
        mpv_bin.to_string_lossy().to_string(),
        config_dir,
        strip_verbatim_prefix(lib_dir.to_string_lossy().to_string()),
    ))
}

/// Path to a per-launch mpv log, written next to the app logs. Captures which
/// scripts (anicat_ui, ModernZ) and shaders actually loaded — the only way to
/// diagnose mpv on Windows, where there is no attached console.
fn mpv_log_path() -> Option<String> {
    #[cfg(target_os = "macos")]
    let dir = dirs::home_dir()?.join("Library/Logs/com.anicat.app");
    #[cfg(target_os = "windows")]
    let dir = dirs::data_dir()?.join("com.anicat.app").join("logs");
    #[cfg(target_os = "linux")]
    let dir = dirs::cache_dir()?.join("com.anicat.app").join("logs");

    let _ = std::fs::create_dir_all(&dir);
    Some(dir.join("mpv.log").to_string_lossy().to_string())
}

fn server_speed_rank(server: &crate::scraper::client::StreamServer) -> u8 {
    let url = server.url.to_lowercase();
    if url.contains("tools.fast4speed.rsvp") { return 0; }
    if url.contains("wixstatic.com") || url.contains("wixmp.com") { return 1; }
    if url.contains("sharepoint") || url.contains("fast4speed") { return 2; }
    if url.contains("mp4upload") || url.contains("youtu-chan") { return 3; }
    4
}

/// Numeric resolution parsed from a server's quality label ("1080p" -> 1080),
/// or 0 when the label isn't a resolution (e.g. "hls", "mp4", "unknown").
fn resolution_rank(server: &crate::scraper::client::StreamServer) -> u32 {
    server.quality.as_deref()
        .and_then(|q| q.trim_end_matches(['p', 'P']).parse::<u32>().ok())
        .unwrap_or(0)
}

/// Sort key: known-fast CDNs first (server_speed_rank), then highest
/// resolution within the same tier — previously ties were broken by
/// whatever order the scraper happened to return, which could silently
/// pick a 360p wixmp variant over a 1080p one from the same source.
fn quality_sort_key(server: &crate::scraper::client::StreamServer) -> (u8, std::cmp::Reverse<u32>) {
    (server_speed_rank(server), std::cmp::Reverse(resolution_rank(server)))
}

/// Picks the fastest target_quality server (1080p for normal mode, 720p for data_saver)
/// across every CDN if one exists; otherwise falls back to the fastest CDN with the highest
/// resolution on offer.
fn pick_best_server<'a>(
    servers: &'a [crate::scraper::client::StreamServer],
    target_quality: u32,
) -> Option<&'a crate::scraper::client::StreamServer> {
    servers.iter()
        .filter(|s| resolution_rank(s) == target_quality)
        .min_by_key(|s| server_speed_rank(s))
        .or_else(|| servers.iter().min_by_key(|s| quality_sort_key(s)))
}

fn pick_best_server_in_group<'a>(
    servers: &'a [crate::scraper::client::StreamServer],
    groups: &[&str],
    target_quality: u32,
) -> Option<&'a crate::scraper::client::StreamServer> {
    let in_group: Vec<&crate::scraper::client::StreamServer> = servers.iter().filter(|s| {
        let g = get_stream_group(s);
        groups.contains(&g)
    }).collect();
    in_group.iter()
        .filter(|s| resolution_rank(s) == target_quality)
        .min_by_key(|s| server_speed_rank(s))
        .copied()
        .or_else(|| in_group.iter().min_by_key(|s| quality_sort_key(s)).copied())
}
fn get_stream_group(server: &crate::scraper::client::StreamServer) -> &str {
    if let Some(ref group) = server.group {
        if group == "sub" {
            return "hard_sub";
        }
        return group;
    }
    let name = server.name.to_lowercase();
    if name.contains("dub") {
        "dub"
    } else {
        "hard_sub"
    }
}

/// Human-facing provider name for notifications.
pub(crate) fn provider_label(provider: &str) -> &str {
    match provider {
        "mkissa" => "Mkissa",
        "anineko" => "AniNeko",
        "mangakatana" => "MangaKatana",
        "nyaa" => "Torrents",
        other => other,
    }
}

/// Resolve a playable stream URL (+ headers) for one provider: find/auto-map
/// its slug, scrape the episode, and pick the best server for the configured
/// sub/dub preference. Returns Err with a reason if anything in that chain
/// fails, so the caller can try a fallback provider.
/// Per-show audio override (registry media_prefs) wins over the global
/// `stream.translation_type`. Prefs are keyed to the desktop owner (user 0);
/// Pi friends inherit the global default.
pub(crate) async fn effective_translation_type(state: &AppState, media_id: i64) -> String {
    let pref = {
        // Scoped so the non-Sync rusqlite Connection drops before any await.
        state
            .open_db()
            .ok()
            .and_then(|db| crate::registry::service::get_media_prefs(&db, 0, media_id))
            .and_then(|p| p.translation_type)
    };
    match pref {
        Some(t) if !t.is_empty() => t,
        _ => state.config.read().await.stream.translation_type.clone(),
    }
}

pub(crate) async fn resolve_stream_for_provider(
    state: &AppState,
    media_id: i64,
    episode_number: i64,
    provider_name: &str,
    server: &Option<String>,
    title: Option<String>,
) -> Result<(String, Option<std::collections::HashMap<String, String>>, Option<String>), String> {
    // Torrents don't go through the scraper: search Nyaa/SubsPlease, start
    // the embedded torrent session, and hand mpv the local range-stream URL.
    if provider_name == "nyaa" {
        let prefer_dub = effective_translation_type(state, media_id).await == "dub";
        let proxy_port = *state.inner.proxy_port.lock().unwrap_or_else(|e| e.into_inner());
        let (titles, episode_count) =
            crate::torrent::gather_media_info(state, media_id, title).await;
        // Movies/OVAs (single "episode") legitimately have no episode number
        // in their release names.
        let allow_episodeless = episode_number == 1 && episode_count.unwrap_or(0) <= 1;
        let url = state
            .torrent
            .resolve(
                &state.http_client,
                crate::torrent::ResolveTarget {
                    media_id,
                    episode: episode_number,
                    titles: &titles,
                    allow_episodeless,
                    prefer_dub,
                    // The stream picker passes the chosen release name back as
                    // `server`; honor it. Auto-play (Continue button) sends
                    // None and takes the best-scored candidate.
                    chosen_name: server.clone(),
                },
                proxy_port,
            )
            .await?;
        return Ok((url, None, None));
    }

    // Read any cached slug in a scoped block so the (non-Sync) DB connection is
    // dropped before the first await — otherwise this future is !Send.
    let cached_slug = {
        let db = state.open_db()?;
        crate::registry::service::get_provider_slug(&db, media_id, provider_name)
    };
    let slug_opt = match cached_slug {
        Some(s) => Some(s),
        None => super::media::resolve_and_save_provider_slug_for_episode(
            state,
            media_id,
            provider_name,
            false,
            title.clone(),
            Some(episode_number as i32),
        )
        .await
        .ok()
        .flatten(),
    };

    let mut servers = if let Some(ref s) = slug_opt {
        state
            .scraper_manager
            .get_streams(s, episode_number as i32, provider_name)
            .await
            .unwrap_or_default()
    } else {
        vec![]
    };

    // If cached slug yielded 0 streams, force a fresh slug resolution with stream validation!
    if servers.is_empty() {
        if let Ok(Some(fresh_slug)) = super::media::resolve_and_save_provider_slug_for_episode(
            state,
            media_id,
            provider_name,
            false,
            title.clone(),
            Some(episode_number as i32),
        )
        .await
        {
            if let Ok(fresh_servers) = state
                .scraper_manager
                .get_streams(&fresh_slug, episode_number as i32, provider_name)
                .await
            {
                servers = fresh_servers;
            }
        }
    }

    if servers.is_empty() {
        return Err(format!("No stream URL found on {}", provider_name));
    }

    let translation_type = effective_translation_type(state, media_id).await;
    let data_saver = state.config.read().await.stream.data_saver;
    let target_quality: u32 = if data_saver { 720 } else { 1080 };

    let selected_server = if let Some(ref s_name) = server {
        servers.iter().find(|s| s.name == *s_name)
            .or_else(|| pick_best_server(&servers, target_quality))
    } else if translation_type == "dub" {
        pick_best_server_in_group(&servers, &["dub"], target_quality)
            .or_else(|| pick_best_server_in_group(&servers, &["hard_sub"], target_quality))
            .or_else(|| pick_best_server_in_group(&servers, &["soft_sub"], target_quality))
            .or_else(|| pick_best_server(&servers, target_quality))
    } else {
        pick_best_server_in_group(&servers, &["hard_sub"], target_quality)
            .or_else(|| pick_best_server_in_group(&servers, &["soft_sub"], target_quality))
            .or_else(|| pick_best_server_in_group(&servers, &["dub"], target_quality))
            .or_else(|| pick_best_server(&servers, target_quality))
    };

    let raw_stream_url = selected_server.map(|s| s.url.clone()).unwrap_or_default();
    let headers = selected_server.and_then(|s| s.headers.clone());
    let subtitle_url = selected_server.and_then(|s| s.subtitle_url.clone());
    if raw_stream_url.is_empty() {
        return Err(format!("No stream URL found on {}", provider_name));
    }
    Ok((raw_stream_url, headers, subtitle_url))
}

/// Resolve and cache a stream ahead of time so the eventual `start_playback`
/// call for the same media/episode/provider is instant. Used both by the
/// in-player "near the end of an episode" preload and by the detail page,
/// which preloads the Continue episode as soon as it's known — by the time
/// the user presses play, mpv has nothing left to wait on.
#[tauri::command]
pub async fn preload_episode(
    state: State<'_, AppState>,
    media_id: i64,
    episode_number: i64,
    provider: Option<String>,
    title: Option<String>,
) -> Result<(), String> {
    preload_episode_impl(state.inner(), media_id, episode_number, provider, title).await
}

pub async fn preload_episode_impl(
    state: &AppState,
    media_id: i64,
    episode_number: i64,
    provider: Option<String>,
    title: Option<String>,
) -> Result<(), String> {
    let provider_name = match provider {
        Some(p) if !p.is_empty() => p,
        _ => state.config.read().await.general.provider.clone(),
    };

    // Low Data Mode: a nyaa preload starts an actual torrent download, not
    // just URL resolution — on a slow connection that competes with whatever
    // is currently streaming, and browsing detail pages would kick off
    // downloads for episodes that may never be played. Resolve at play time
    // instead. Scraper providers stay preloaded either way (cheap requests).
    if provider_name == "nyaa" && state.config.read().await.stream.data_saver {
        log::info!(
            "Low data mode: skipping torrent preload for media {} ep {}",
            media_id, episode_number
        );
        return Ok(());
    }

    // Already preloaded (or being worked on) for this exact target — skip.
    {
        let slot = state.preloaded_stream.lock().await;
        if let Some(ref p) = *slot {
            if p.media_id == media_id && p.episode_number == episode_number && p.provider == provider_name {
                return Ok(());
            }
        }
    }

    let state_inner = state.clone();
    tokio::spawn(async move {
        match resolve_stream_for_provider(&state_inner, media_id, episode_number, &provider_name, &None, title).await {
            Ok((raw_url, headers, subtitle_url)) => {
                let mut slot = state_inner.preloaded_stream.lock().await;
                *slot = Some(crate::state::PreloadedStream {
                    media_id,
                    episode_number,
                    provider: provider_name.clone(),
                    raw_url,
                    headers,
                    subtitle_url,
                    at: std::time::Instant::now(),
                });
                log::info!("Preloaded stream for media {} ep {} ({})", media_id, episode_number, provider_name);
            }
            Err(e) => log::warn!("preload_episode: media {} ep {} ({}) failed: {}", media_id, episode_number, provider_name, e),
        }
    });
    Ok(())
}

#[derive(serde::Serialize, Clone)]
pub struct AniSkipSegment {
    pub skip_type: String,
    pub start: f64,
    pub end: f64,
}

/// Resolves AniSkip op/ed skip segments for an episode: AniList's `idMal` if
/// present, else a Jikan title search, then a lookup against AniSkip's API.
/// Shared by desktop's mpv IPC push (`start_playback`'s background task,
/// below) and the mobile-api skip-times endpoint — extracted so both push
/// the same segments rather than reimplementing this resolution twice.
pub async fn fetch_aniskip_segments(
    state: &AppState,
    media_id: i64,
    episode_number: i64,
    title: &str,
) -> Vec<AniSkipSegment> {
    let mal_id = {
        let res = super::media::fetch_media_detail_cached(state, media_id, false).await;
        let mut found = None;
        if let Ok(r) = res {
            if let Some(media) = r.media {
                log::info!("[aniskip] AniList media id={}, id_mal={:?}, title_romaji={:?}, title_english={:?}",
                    media.id, media.id_mal,
                    media.title.as_ref().and_then(|t| t.romaji.as_deref()),
                    media.title.as_ref().and_then(|t| t.english.as_deref()));
                // 1. Direct idMal from AniList
                if let Some(id) = media.id_mal {
                    log::info!("[aniskip] Using MAL ID {} from AniList", id);
                    found = Some(id);
                // 2. Fallback: search Jikan by title
                } else if let Some(search_title) = media.title.as_ref()
                    .and_then(|t| t.english.as_deref().or(t.romaji.as_deref()))
                    .filter(|t| !t.is_empty())
                    .or(if !title.is_empty() { Some(title) } else { None })
                {
                    let jikan_url = format!(
                        "https://api.jikan.moe/v4/anime?q={}&limit=1&sfw",
                        percent_encode(search_title)
                    );
                    log::info!("[aniskip] Jikan searching by title '{}' url={}", search_title, jikan_url);
                    match state.http_client
                        .get(&jikan_url)
                        .timeout(std::time::Duration::from_secs(5))
                        .send()
                        .await
                    {
                        Ok(resp) => {
                            let status = resp.status();
                            log::info!("[aniskip] Jikan response status: {}", status);
                            if let Ok(body) = resp.text().await {
                                if let Ok(jikan_res) = serde_json::from_str::<serde_json::Value>(&body) {
                                    if let Some(data) = jikan_res["data"].as_array() {
                                        found = data.first().and_then(|f| f["mal_id"].as_i64());
                                    }
                                }
                            }
                        }
                        Err(e) => log::warn!("[aniskip] Jikan request error: {}", e),
                    }
                }
            }
        }
        found
    };

    let Some(m_id) = mal_id else { return Vec::new() };

    // Shared client: explicitly rustls — see AppState::new.
    let client = state.http_client.clone();
    let url = format!(
        "https://api.aniskip.com/v2/skip-times/{}/{}?types[]=op&types[]=ed&episodeLength=0",
        m_id, episode_number
    );
    log::info!("[aniskip] Fetching AniSkip times from: {}", url);
    let resp = match client.get(&url).timeout(std::time::Duration::from_millis(5000)).send().await {
        Ok(resp) if resp.status().is_success() => resp,
        Ok(resp) => {
            log::warn!("[aniskip] non-success status: {}", resp.status());
            return Vec::new();
        }
        Err(e) => {
            log::warn!("[aniskip] AniSkip request error: {}", e);
            return Vec::new();
        }
    };

    // The API has served both camelCase and snake_case over time; accept either.
    #[derive(serde::Deserialize)]
    struct AniSkipResult {
        #[serde(default)]
        results: Vec<AniSkipTime>,
    }
    #[derive(serde::Deserialize)]
    struct AniSkipTime {
        #[serde(rename = "skipType", alias = "skip_type")]
        skip_type: String,
        interval: AniSkipInterval,
    }
    #[derive(serde::Deserialize)]
    struct AniSkipInterval {
        #[serde(rename = "startTime", alias = "start_time")]
        start_time: f64,
        #[serde(rename = "endTime", alias = "end_time")]
        end_time: f64,
    }

    match resp.json::<AniSkipResult>().await {
        Ok(aniskip_res) => aniskip_res
            .results
            .into_iter()
            .map(|r| AniSkipSegment { skip_type: r.skip_type, start: r.interval.start_time, end: r.interval.end_time })
            .collect(),
        Err(e) => {
            log::warn!("[aniskip] Failed to parse AniSkip response: {}", e);
            Vec::new()
        }
    }
}

#[tauri::command]
#[allow(clippy::too_many_arguments)] // playback context is passed field-by-field over IPC
pub async fn start_playback(
    app: AppHandle,
    state: State<'_, AppState>,
    media_id: i64,
    episode_number: i64,
    provider: Option<String>,
    server: Option<String>,
    title: Option<String>,
    episode_title: Option<String>,
    cover_image: Option<String>,
    total_episodes: Option<i64>,
    start_over: Option<bool>,
) -> Result<PlaybackStart, String> {
    let mut provider_name = match provider {
        Some(p) if !p.is_empty() => p,
        _ => state.config.read().await.general.provider.clone(),
    };

    let title_str = title.clone().unwrap_or_default();
    let episode_title_str = episode_title.clone().unwrap_or_default();
    let cover_image_str = cover_image.clone().unwrap_or_default();
    let total_eps = total_episodes.unwrap_or(0);

    // New playback generation. Background tasks spawned below (the AniSkip
    // resolver) capture this and abort if a later start_playback supersedes
    // them, so a previous episode's slow IPC retry can't overwrite the current
    // episode's script-opts.
    let playback_gen = state
        .playback_generation
        .fetch_add(1, std::sync::atomic::Ordering::SeqCst)
        + 1;

    {
        let mut guard = state.current_playback.lock().await;
        *guard = Some(crate::state::CurrentPlayback {
            media_id,
            episode_number,
            provider: provider_name.clone(),
            title: title_str.clone(),
            episode_title: episode_title_str.clone(),
            cover_image: cover_image_str.clone(),
            total_episodes: total_eps,
            last_position: 0,
            last_duration: 0,
            paused: false,
        });
    }

    let db = state.open_db()?;

    let resume_seconds = if start_over.unwrap_or(false) {
        // The user explicitly chose "start over" — ignore any stored position.
        0
    } else {
        let mut sec = 0;
        if let Ok(entries) = crate::registry::service::get_watched_episodes(&db, 0, media_id) {
            if let Some(entry) = entries.iter().find(|e| e.episode_number == episode_number) {
                sec = resume_position(entry.stop_time, entry.duration);
                if sec > 0 {
                    log::info!("Found resume position: {}s (duration: {}s)", sec, entry.duration);
                }
            }
        }
        // Reconcile the two sources of truth: local watch_history says where you
        // stopped, but AniList progress is the authority on what's *watched*. If
        // AniList already counts this episode (progress >= episode_number), don't
        // drop back into the middle of it — start fresh. Fixes the "resumes
        // mid-episode instead of starting over" case after a desync or a watch on
        // another device.
        if sec > 0 {
            if let Some(anilist_progress) = state.cache.get_user_list_progress(media_id) {
                if anilist_progress >= episode_number {
                    log::info!(
                        "Suppressing resume for media {} ep {}: AniList progress {} already covers it",
                        media_id, episode_number, anilist_progress
                    );
                    sec = 0;
                }
            }
        }
        sec
    };

    state.discord.set_presence(&title_str, episode_number, &episode_title_str, total_eps, resume_seconds, 0, false);

    let local_file_path = {
        let mut path_found = None;
        if let Ok(items) = crate::registry::service::get_all_queue(&db) {
            if let Some(item) = items.iter().find(|i| i.media_id == media_id && i.episode_number == episode_number && i.status == "completed") {
                let downloads_path = {
                    let cfg = state.config.read().await;
                    let path = cfg.general.downloads_path.clone();
                    if path.is_empty() {
                        dirs::download_dir().unwrap_or_else(|| std::path::PathBuf::from(".")).to_string_lossy().to_string()
                    } else {
                        path
                    }
                };
                let safe_title: String = item.media_title.chars().filter(|c| c.is_alphanumeric() || *c == ' ' || *c == '-' || *c == '_').collect();
                let filename_mp4 = format!("{} - Episode {}.mp4", safe_title.trim(), episode_number);
                let filepath_mp4 = std::path::Path::new(&downloads_path).join(&filename_mp4);
                let filename_ts = format!("{} - Episode {}.ts", safe_title.trim(), episode_number);
                let filepath_ts = std::path::Path::new(&downloads_path).join(&filename_ts);

                if filepath_mp4.exists() {
                    path_found = Some(filepath_mp4.to_string_lossy().to_string());
                } else if filepath_ts.exists() {
                    path_found = Some(filepath_ts.to_string_lossy().to_string());
                }
            }
        }
        path_found
    };

    let mut stream_headers = None;
    let mut subtitle_url: Option<String> = None;

    let stream_url = if let Some(local_path) = local_file_path {
        log::info!("Playing offline local download: {}", local_path);
        local_path
    } else {
        // Try the primary provider; if it can't produce a playable stream
        // (provider down, no slug match, no servers), fall back to the
        // configured fallback provider instead of failing the play button.
        let (fallback_provider, secondary_fallback) = {
            let cfg = state.config.read().await;
            (cfg.general.fallback_provider.clone(), cfg.general.secondary_fallback_provider.clone())
        };

        // Instant transition: if the previous episode preloaded this one's
        // stream, use it and skip the scrape entirely. Stale or mismatched
        // entries fall through to a normal resolve.
        let preloaded = {
            let mut slot = state.preloaded_stream.lock().await;
            match slot.take() {
                Some(p)
                    if p.media_id == media_id
                        && p.episode_number == episode_number
                        && p.provider == provider_name
                        && p.at.elapsed() < std::time::Duration::from_secs(15 * 60) =>
                {
                    Some(p)
                }
                other => {
                    *slot = other;
                    None
                }
            }
        };

        let (raw_stream_url, headers, sub_url) = if let Some(p) = preloaded {
            log::info!("Using preloaded stream for media {} ep {}", media_id, episode_number);
            (p.raw_url, p.headers, p.subtitle_url)
        } else {
            let candidates = vec![provider_name.clone(), fallback_provider, secondary_fallback];
            let mut tried = Vec::new();
            let mut last_err = String::new();
            let mut resolved = None;

            for prov in candidates {
                if prov.is_empty() || prov == "none" || tried.contains(&prov) {
                    continue;
                }
                tried.push(prov.clone());

                match resolve_stream_for_provider(&state, media_id, episode_number, &prov, &server, title.clone()).await {
                    Ok(res) => {
                        if prov != provider_name {
                            {
                                let mut guard = state.current_playback.lock().await;
                                if let Some(ref mut pb) = *guard {
                                    pb.provider = prov.clone();
                                }
                            }
                            use tauri::Emitter;
                            let _ = app.emit("show_notification", serde_json::json!({
                                "message": format!(
                                    "Couldn't reach {} — playing from {}",
                                    provider_label(&provider_name),
                                    provider_label(&prov),
                                )
                            }));
                            provider_name = prov;
                        }
                        resolved = Some(res);
                        break;
                    }
                    Err(e) => {
                        log::warn!("Provider '{}' failed for media {} ep {}: {}", prov, media_id, episode_number, e);
                        last_err = e;
                    }
                }
            }

            match resolved {
                Some(res) => res,
                None => return Err(format!("No stream found on any provider (last error: {})", last_err)),
            }
        };

        stream_headers = headers;
        subtitle_url = sub_url;

        let mut stream_url = raw_stream_url.clone();
        if stream_url.contains("vibeplayer.site") || stream_url.contains("m3u8") {
            let proxy_port = *state.inner.proxy_port.lock().unwrap_or_else(|e| e.into_inner());
            let encoded_url = percent_encode(&stream_url);
            stream_url = format!("http://127.0.0.1:{}/proxy?url={}", proxy_port, encoded_url);
            log::info!("Proxied stream URL: {}", stream_url);
        }
        stream_url
    };

    // Sync AniList watching list after confirming stream is available — but
    // only when the entry isn't already CURRENT. Previously this fired a
    // SaveMediaListEntry on every episode launch; now it just moves
    // Planning/Paused/etc. into Watching and is a no-op for an already-watching
    // series.
    if state.anilist_client.has_token() && media_id > 0 {
        let already_current = state
            .cache
            .get_user_list_status(media_id)
            .map(|s| s.eq_ignore_ascii_case("CURRENT"))
            .unwrap_or(false);
        if !already_current {
            let anilist = state.anilist_client.clone();
            let cache = state.cache.clone();
            let m_id = media_id;
            tokio::spawn(async move {
                let mut vars = std::collections::HashMap::new();
                vars.insert("mediaId".to_string(), serde_json::json!(m_id));
                vars.insert("status".to_string(), serde_json::json!("CURRENT"));
                if let Err(e) = anilist
                    .execute::<serde_json::Value>(
                        crate::anilist::queries::SAVE_MEDIA_LIST_ENTRY_MUTATION,
                        vars,
                    )
                    .await
                {
                    log::warn!("Failed to sync AniList watching list: {}", e);
                } else {
                    cache.update_user_list_progress(m_id, None, Some("CURRENT"), None);
                }
            });
        }
    }

    let skip_times_arg = String::new();
    let state_clone = (*state).clone();
    let title_clone = title_str.clone();
    tokio::spawn(async move {
        // Bail if a newer episode has started while this resolver was queued —
        // its script-opts push would otherwise stomp the current episode.
        if state_clone.playback_generation.load(std::sync::atomic::Ordering::SeqCst) != playback_gen {
            return;
        }
        let segments = fetch_aniskip_segments(&state_clone, media_id, episode_number, &title_clone).await;
        let mut bg_skip_times_arg = String::new();
        if !segments.is_empty() {
            bg_skip_times_arg = segments
                .iter()
                .map(|s| format!("{},{},{}", s.skip_type, s.start.floor(), s.end.floor()))
                .collect::<Vec<_>>()
                .join(";");
            log::info!("[aniskip] Found skip times in background: {}", bg_skip_times_arg);
        }

        if !bg_skip_times_arg.is_empty() {
            // Update ONLY the skip_times key via change-list append, never a
            // full script-opts replacement. The episode number, autoskip and
            // auto_next were already set correctly by the launch/reuse path;
            // re-sending them from this late, episode-specific task is how a
            // stale resolver used to corrupt current_episode.
            let encoded = bg_skip_times_arg.replace(",", "%2C");

            let ipc_path = get_ipc_path();
            let cmd = serde_json::json!({
                "command": ["change-list", "script-opts", "append", format!("anicat_ui-skip_times={}", encoded)]
            });
            
            // Retry sending over IPC in case MPV is still launching. Re-check
            // the generation each iteration: if the user moved on to another
            // episode, stop — pushing now would overwrite that episode's
            // current_episode / skip_times.
            for i in 0..15 {
                if state_clone.playback_generation.load(std::sync::atomic::Ordering::SeqCst) != playback_gen {
                    log::info!("[aniskip] Skip-times push superseded by a newer episode; aborting");
                    return;
                }
                tokio::time::sleep(std::time::Duration::from_millis(200)).await;
                if try_send_ipc(&ipc_path, vec![cmd.clone()]).await.is_ok() {
                    log::info!("[aniskip] Dynamically loaded skip times via IPC on attempt {}", i + 1);
                    break;
                }
            }
        }
    });

    let (mpv_bin, config_dir, lib_dir) = resolve_mpv_path(&app)?;
    log::info!("mpv binary: {}", mpv_bin);
    log::info!("mpv config: {}", config_dir);
    log::info!("mpv lib dir: {}", lib_dir);

    // Self-healing permission setup for mpv binary
    #[cfg(unix)]
    {
        use std::os::unix::fs::PermissionsExt;
        if let Ok(metadata) = std::fs::metadata(&mpv_bin) {
            let mut perms = metadata.permissions();
            if perms.mode() & 0o111 == 0 {
                perms.set_mode(0o755);
                let _ = std::fs::set_permissions(&mpv_bin, perms);
                log::info!("Set executable permissions for mpv binary");
            }
        }
    }

    let mut cmd = tokio::process::Command::new(&mpv_bin);
    crate::util::suppress_console_tokio(&mut cmd);
    cmd.arg(format!("--config-dir={}", config_dir));
    if let Some(log_path) = mpv_log_path() {
        // Overwritten each launch; records script + shader load results.
        cmd.arg(format!("--log-file={}", log_path));
    }
    cmd.arg("--force-window=yes");
    cmd.arg("--ontop");
    cmd.arg(format!("--input-ipc-server={}", get_ipc_path()));

    if resume_seconds > 0 {
        cmd.arg(format!("--start={}", resume_seconds));
    }

    if !title_str.is_empty() {
        let media_title = format!("{} - Episode {}", title_str, episode_number);
        cmd.arg(format!("--force-media-title={}", media_title));
        cmd.arg(format!("--title={}", media_title));
    }

    let (autoskip, autoplay) = {
        let cfg = state.config.read().await;
        (cfg.general.autoskip, cfg.general.autoplay)
    };
    let mut script_opts = Vec::new();
    if !skip_times_arg.is_empty() {
        // Encode commas as %2C to avoid mpv --script-opts comma delimiter issue
        let encoded = skip_times_arg.replace(",", "%2C");
        script_opts.push(format!("anicat_ui-skip_times={}", encoded));
    }
    let shader_profile = {
        let cfg = state.config.read().await;
        cfg.stream.shader_profile.clone()
    };
    script_opts.push(format!("anicat_ui-autoskip={}", if autoskip { "yes" } else { "no" }));
    script_opts.push(format!("anicat_ui-auto_next={}", if autoplay { "yes" } else { "no" }));
    script_opts.push(format!("anicat_ui-current_episode={}", episode_number));
    script_opts.push(format!("anicat_ui-total_episodes={}", total_eps));
    script_opts.push(format!("anicat_ui-shader_profile={}", shader_profile));
    let script_opts_str = script_opts.join(",");
    log::info!("[aniskip] mpv script-opts: {}", script_opts_str);
    cmd.arg(format!("--script-opts={}", script_opts_str));

    if autoplay {
        cmd.arg("--keep-open=yes");
    }

    if shader_profile != "off" {
        let shader_dir = std::path::Path::new(&config_dir).join("shaders");
        // Anime4K official "Mode A (Fast)" — the recommended low-end-GPU preset
        // (Restore + 2x CNN upscale at M, final S refinement). Mode A is the
        // most popular general anime mode; tuned for the MacBook's thermals,
        // where the VL/HQ variants pegged the GPU and overheated it.
        // Source: github.com/bloc97/Anime4K (Template/GLSL_*_Low-end/input.conf)
        let shader_names = [
            "Anime4K_Clamp_Highlights.glsl",
            "Anime4K_Restore_CNN_M.glsl",
            "Anime4K_Upscale_CNN_x2_M.glsl",
            "Anime4K_AutoDownscalePre_x2.glsl",
            "Anime4K_AutoDownscalePre_x4.glsl",
            "Anime4K_Upscale_CNN_x2_S.glsl",
        ];
        let shader_arg: Vec<String> = shader_names
            .iter()
            .map(|n| shader_dir.join(n))
            // Only pass shaders that are actually present — missing files would
            // make mpv refuse to start (e.g. a build without the bundled
            // Anime4K shaders). Absent shaders just mean no upscaling.
            .filter(|p| p.exists())
            .filter_map(|p| p.to_str().map(|s| s.to_string()))
            .collect();
        if !shader_arg.is_empty() {
            // mpv uses ";" as path-list separator on Windows (because ":" appears
            // in drive letters), and ":" on macOS/Linux.
            let sep = if cfg!(target_os = "windows") { ";" } else { ":" };
            cmd.arg(format!("--glsl-shaders={}", shader_arg.join(sep)));
        }
    }

    // Torrent streams come off the local proxy from an in-progress download,
    // so reads can block for seconds while a piece arrives. Tune mpv for that:
    // never time the connection out (the default abort → retry loop is what
    // spams the console and makes playback "just stop"), buffer aggressively,
    // and pause to rebuffer instead of erroring on an underrun. ffmpeg's http
    // demuxer chatter is silenced so a transient slow read isn't log noise.
    let is_torrent_stream = stream_url.contains("/torrent-stream");
    if is_torrent_stream {
        cmd.arg("--network-timeout=0");
        cmd.arg("--cache=yes");
        cmd.arg("--cache-pause=yes");
        cmd.arg("--cache-pause-initial=yes");
        // 30s of media, not the 3s it used to be: resuming after 3s buffered
        // meant any starved stretch played as a play-3s/freeze/play-3s
        // stutter loop. A healthy swarm fills 30s of media in a few wall
        // seconds, so the worst case is one slightly longer rebuffer with
        // real playback between stalls.
        cmd.arg("--cache-pause-wait=30");
        cmd.arg("--demuxer-max-bytes=1GiB");
        cmd.arg("--demuxer-max-back-bytes=256MiB");
        cmd.arg("--demuxer-readahead-secs=120");
        cmd.arg("--force-seekable=yes");
        cmd.arg("--msg-level=ffmpeg=fatal");
    }

    if let Some(ref headers) = stream_headers {
        let mut fields = Vec::new();
        for (key, val) in headers {
            let key_lower = key.to_lowercase();
            if key_lower == "referer" {
                cmd.arg(format!("--referrer={}", val));
            } else if key_lower == "user-agent" {
                cmd.arg(format!("--user-agent={}", val));
            } else {
                fields.push(format!("{}: {}", key, val));
            }
        }
        if !fields.is_empty() {
            cmd.arg(format!("--http-header-fields={}", fields.join(",")));
        }
    }

    // anineko's soft_sub/dub servers deliver captions as an external VTT
    // instead of baking them into the video (see anineko.py's
    // _extract_subtitle_url) — mpv loads a remote --sub-file the same as a
    // local one and auto-selects it.
    if let Some(ref sub_url) = subtitle_url {
        cmd.arg(format!("--sub-file={}", sub_url));
    }

    cmd.arg(&stream_url);

    if cfg!(target_os = "macos") && !lib_dir.is_empty() {
        cmd.env("DYLD_LIBRARY_PATH", &lib_dir);
        let icd_path = std::path::Path::new(&lib_dir).join("vk_icd.json");
        cmd.env("VK_ICD_FILENAMES", icd_path);
    }
    if cfg!(target_os = "linux") {
        cmd.env("LD_LIBRARY_PATH", &lib_dir);
    }
    if cfg!(target_os = "windows") && !lib_dir.is_empty() {
        // Windows resolves DLLs via the exe directory and PATH; prepend the
        // bundled lib dir so any mpv DLLs there are found.
        let existing = std::env::var("PATH").unwrap_or_default();
        cmd.env("PATH", format!("{};{}", lib_dir, existing));
    }

    let has_active_mpv = {
        if let Ok(guard) = CURRENT_MPV.lock() {
            guard.is_some()
        } else {
            false
        }
    };

    let mut reused = false;
    if has_active_mpv {
        let mut commands = Vec::new();

        if let Some(ref headers) = stream_headers {
            let mut fields = Vec::new();
            for (key, val) in headers {
                let key_lower = key.to_lowercase();
                if key_lower == "referer" {
                    commands.push(serde_json::json!({
                        "command": ["set_property", "referrer", val]
                    }));
                } else if key_lower == "user-agent" {
                    commands.push(serde_json::json!({
                        "command": ["set_property", "user-agent", val]
                    }));
                } else {
                    fields.push(format!("{}: {}", key, val));
                }
            }
            if !fields.is_empty() {
                commands.push(serde_json::json!({
                    "command": ["set_property", "http-header-fields", fields.join(",")]
                }));
            }
        } else {
            commands.push(serde_json::json!({
                "command": ["set_property", "referrer", ""]
            }));
            commands.push(serde_json::json!({
                "command": ["set_property", "user-agent", ""]
            }));
            commands.push(serde_json::json!({
                "command": ["set_property", "http-header-fields", ""]
            }));
        }

        let (autoskip, autoplay) = {
            let cfg = state.config.read().await;
            (cfg.general.autoskip, cfg.general.autoplay)
        };
        let mut script_opts_parts = Vec::new();
        // Always include skip_times (empty if AniSkip hasn't arrived yet) so
        // the Lua observer doesn't fall back to the previous episode's stale
        // launch-time opts.skip_times value.
        script_opts_parts.push(format!("anicat_ui-skip_times={}", skip_times_arg.replace(",", "%2C")));
        script_opts_parts.push(format!("anicat_ui-autoskip={}", if autoskip { "yes" } else { "no" }));
        script_opts_parts.push(format!("anicat_ui-auto_next={}", if autoplay { "yes" } else { "no" }));
        script_opts_parts.push(format!("anicat_ui-current_episode={}", episode_number));
        script_opts_parts.push(format!("anicat_ui-total_episodes={}", total_eps));

        commands.push(serde_json::json!({
            "command": ["set_property", "script-opts", script_opts_parts.join(",")]
        }));

        if !title_str.is_empty() {
            let media_title = format!("{} - Episode {}", title_str, episode_number);
            commands.push(serde_json::json!({
                "command": ["set_property", "force-media-title", media_title]
            }));
        }

        // Always pass an explicit start position. The first episode launches
        // mpv with a global --start=<resume> option; without a per-file start
        // here, `loadfile … replace` re-applies that global start to the next
        // episode, dropping the user into it at the previous episode's
        // position. resume_seconds is 0 for a fresh episode, so this starts it
        // at the beginning; for a partially-watched one it resumes correctly.
        // anineko's soft_sub/dub servers deliver captions as an external VTT
        // (see anineko.py's _extract_subtitle_url) rather than baking them
        // into the video — loadfile's per-file options string accepts
        // sub-file the same as any other property override.
        let mut load_options = format!("start={}", resume_seconds);
        if let Some(ref sub_url) = subtitle_url {
            load_options.push_str(&format!(",sub-file={}", sub_url));
        }
        // The torrent-friendly cache/network options below are CLI args on a
        // fresh mpv launch (see is_torrent_stream above), which apply to every
        // file mpv opens afterward — but `loadfile … replace` on an already-
        // running mpv (auto-next reusing the window) doesn't re-read the CLI,
        // so a torrent episode loaded this way got mpv's defaults instead:
        // network-timeout's normal abort-on-stall behavior with no cache
        // tolerance, on a stream that's still actively downloading. That's
        // what made it hang right after the start instead of buffering.
        // loadfile's options string takes the same per-file option overrides
        // CLI args do, so set them the same way here.
        if is_torrent_stream {
            load_options.push_str(
                ",network-timeout=0,cache=yes,cache-pause=yes,cache-pause-initial=yes,\
                 cache-pause-wait=30,demuxer-max-bytes=1GiB,demuxer-max-back-bytes=256MiB,\
                 demuxer-readahead-secs=120,force-seekable=yes",
            );
        }
        let load_cmd = vec![
            serde_json::json!("loadfile"),
            serde_json::json!(stream_url),
            serde_json::json!("replace"),
            serde_json::json!("0"), // index argument
            serde_json::json!(load_options),
        ];
        commands.push(serde_json::json!({
            "command": load_cmd
        }));

        commands.push(serde_json::json!({
            "command": ["set_property", "pause", false]
        }));

        let ipc_path = get_ipc_path();
        log::info!("Connecting to running MPV at {} via IPC...", ipc_path);
        // Retry a few times — mpv may be briefly busy loading the stream.
        let mut ipc_ok = false;
        for attempt in 0..5 {
            if try_send_ipc(&ipc_path, commands.clone()).await.is_ok() {
                log::info!("Sent stream to running MPV via IPC (attempt {})", attempt + 1);
                ipc_ok = true;
                break;
            }
            tokio::time::sleep(std::time::Duration::from_millis(150)).await;
        }
        if ipc_ok {
            reused = true;
        } else {
            log::warn!("Failed to communicate with MPV over IPC after retries, will restart player");
            // Save progress for the current episode before killing mpv so the
            // position isn't lost when we respawn.
            let (last_pos, last_dur, cur_media, cur_ep, cur_total) = {
                let guard = state.current_playback.lock().await;
                if let Some(ref pb) = *guard {
                    (pb.last_position, pb.last_duration, pb.media_id, pb.episode_number, pb.total_episodes)
                } else {
                    (0, 0, 0, 0, 0)
                }
            };
            if last_pos > 0 && cur_media > 0 {
                let _ = record_playback_progress(&state, 0, cur_media, cur_ep, last_pos, last_dur, cur_total).await;
            }
        }
    }

    if reused {
        let mut guard = state.current_playback.lock().await;
        *guard = Some(crate::state::CurrentPlayback {
            media_id,
            episode_number,
            provider: provider_name.clone(),
            title: title_str.clone(),
            episode_title: episode_title_str.clone(),
            cover_image: cover_image_str.clone(),
            total_episodes: total_eps,
            last_position: 0,
            last_duration: 0,
            paused: false,
        });
        emit_playback_active(&app, true);
        return Ok(PlaybackStart { stream_url });
    }

    kill_current_mpv().await;

    log::info!("Launching mpv command: {:?}", cmd);
    let mut child = cmd
        .spawn()
        .map_err(|e| format!("Failed to launch mpv: {}", e))?;

    let pid = child.id().unwrap_or(0);
    log::info!("Launched mpv pid={} with stream: {}", pid, stream_url);

    tokio::time::sleep(std::time::Duration::from_millis(500)).await;
    match child.try_wait() {
        Ok(Some(status)) => {
            log::error!("mpv exited immediately with status {:?}", status);
            return Err(format!("mpv exited immediately: {:?}", status));
        }
        Ok(None) => {
            log::info!("mpv pid={} is running", pid);
        }
        Err(e) => {
            log::warn!("Failed to check mpv status: {}", e);
        }
    }

    if let Ok(mut guard) = CURRENT_MPV.lock() {
        *guard = Some(child);
    }

    {
        let mut guard = state.current_playback.lock().await;
        *guard = Some(crate::state::CurrentPlayback {
            media_id,
            episode_number,
            provider: provider_name.clone(),
            title: title_str.clone(),
            episode_title: episode_title_str.clone(),
            cover_image: cover_image_str.clone(),
            total_episodes: total_eps,
            last_position: 0,
            last_duration: 0,
            paused: false,
        });
    }

    let discord = state.discord.clone();
    let monitor_media_id = media_id;
    let monitor_episode = episode_number;
    let app_handle = app.clone();
    let app_state_clone = (*state).clone();
    tokio::spawn(async move {
        loop {
            tokio::time::sleep(std::time::Duration::from_millis(500)).await;
            let exited = {
                let mut guard = match CURRENT_MPV.lock() {
                    Ok(g) => g,
                    Err(e) => {
                        log::error!(
                            "mpv exit monitor: CURRENT_MPV mutex poisoned, stopping monitor for media {} ep {}: {}",
                            monitor_media_id, monitor_episode, e
                        );
                        return;
                    }
                };
                match guard.as_mut() {
                    Some(child) => match child.try_wait() {
                        Ok(Some(_)) => {
                            let _ = guard.take();
                            true
                        }
                        Ok(None) => false,
                        Err(e) => {
                            log::warn!(
                                "mpv exit monitor: try_wait failed for media {} ep {}, treating as exited: {}",
                                monitor_media_id, monitor_episode, e
                            );
                            let _ = guard.take();
                            true
                        }
                    },
                    None => true,
                }
            };
            if exited {
                let (monitor_media_id, monitor_episode) = {
                    let guard = app_state_clone.current_playback.lock().await;
                    if let Some(ref pb) = *guard {
                        (pb.media_id, pb.episode_number)
                    } else {
                        (monitor_media_id, monitor_episode)
                    }
                };

                // Give the Lua script time to send position via player/stop
                tokio::time::sleep(std::time::Duration::from_millis(2000)).await;

                // If player_stop already saved position, current_playback is None.
                // If still set, save last known position as a fallback.
                let should_save = {
                    let guard = app_state_clone.current_playback.lock().await;
                    guard.is_some()
                };
                if should_save {
                    let (last_pos, last_dur, total_eps) = {
                        let guard = app_state_clone.current_playback.lock().await;
                        if let Some(ref pb) = *guard {
                            (pb.last_position, pb.last_duration, pb.total_episodes)
                        } else {
                            (0, 0, 0)
                        }
                    };
                    if last_pos > 0 {
                        let _ = crate::commands::playback::record_playback_progress(
                            &app_state_clone,
                            0,
                            monitor_media_id,
                            monitor_episode,
                            last_pos,
                            last_dur,
                            total_eps,
                        )
                        .await;
                        log::info!("Saved last known playback position: {}s / {}s", last_pos, last_dur);
                    }
                }

                // Notify frontend
                let _ = app_handle.emit("progress_updated", serde_json::json!({
                    "media_id": monitor_media_id,
                    "episode_number": monitor_episode,
                }));
                emit_playback_active(&app_handle, false);
                discord.clear_presence();
                // Window closed: pause the torrent so it stops using the
                // network in the background. Auto-next reuses (and unpauses)
                // the next episode's torrent, so this doesn't disrupt it.
                app_state_clone.torrent.pause_all().await;
                {
                    let mut guard = app_state_clone.current_playback.lock().await;
                    *guard = None;
                }
                log::info!("mpv exited, Discord presence cleared");
                break;
            }
        }
    });

    emit_playback_active(&app, true);
    Ok(PlaybackStart { stream_url })
}

#[tauri::command]
pub async fn record_playback_progress(
    state: &AppState,
    user_id: i64,
    media_id: i64,
    episode_number: i64,
    stop_time: i64,
    duration: i64,
    total_episodes: i64,
) -> Result<(), String> {
    // Dedupe the burst of recorders one stop/next event produces (stop handler,
    // shutdown handler, exit monitor). The first writes; the rest, arriving for
    // the same episode within a few seconds, are dropped. The first recorder
    // (the stop handler) carries the most accurate position, so keeping it is
    // also the right choice for resume.
    {
        const DEDUPE_WINDOW: std::time::Duration = std::time::Duration::from_secs(3);
        let mut last = state.last_progress_record.lock().await;
        if let Some((m, ep, at)) = *last {
            if m == media_id && ep == episode_number && at.elapsed() < DEDUPE_WINDOW {
                log::info!("Deduping duplicate progress record for media {} ep {}", media_id, episode_number);
                return Ok(());
            }
        }
        *last = Some((media_id, episode_number, std::time::Instant::now()));
    }

    let db = state.open_db()?;
    if let Err(e) = crate::registry::service::record_watched_episode(
        &db,
        user_id,
        media_id,
        episode_number,
        stop_time,
        duration,
    ) {
        log::error!(
            "Failed to persist watch progress (media {} ep {} pos {}): {}",
            media_id, episode_number, stop_time, e
        );
    }

    if duration > 0 {
        // Completion is the ONLY automatic way AniList progress advances: you
        // played the episode past the watched threshold. Navigation (next/prev)
        // records the real position but never forces this.
        if is_watched(stop_time, duration) {
            // Serialize automatic writes with manual list edits and with each
            // other, so the many concurrent recorders fired by one stop/next
            // event (player_stop, shutdown handler, process-exit monitor) can't
            // race into an out-of-order AniList write.
            let _lock = state.user_list_lock.lock().await;

            // Forward-only guard: never let a stale or out-of-order completion
            // regress AniList progress. If the cache knows the current progress
            // and it already covers this episode, skip the write entirely.
            if let Some(current) = state.cache.get_user_list_progress(media_id) {
                if episode_number <= current {
                    log::info!(
                        "Skipping progress write for media {} ep {}: AniList already at {}",
                        media_id, episode_number, current
                    );
                    return Ok(());
                }
            }

            // The frontend's total_episodes falls back to the *aired-so-far*
            // list length when AniList doesn't publish a final count (common
            // while a show is releasing), so reaching it only proves "watched
            // the newest available episode" — not the series. Before writing
            // COMPLETED, confirm against AniList's own planned episode count;
            // unknown count or a failed lookup stays CURRENT (a wrong CURRENT
            // is a one-click fix, a wrong COMPLETED silently drops the show
            // from Watching).
            let mut status = "CURRENT";
            let mut write_progress = episode_number;
            if total_episodes > 0 && episode_number >= total_episodes {
                // Bypass the media_detail cache here: it's a static-metadata
                // cache with a 1hr TTL, but "episodes" is exactly the field
                // that flips from null to a real number the instant a show's
                // final episode airs. A cache entry populated moments earlier
                // (e.g. the user opened the detail page while it was still
                // airing) would report the show as not-yet-finished right at
                // the one moment that matters — the finale.
                state.cache.invalidate("media_detail");
                let detail = super::media::fetch_media_detail_cached(state, media_id, false).await;
                match detail {
                    Ok(d) => {
                        let planned = d.media.as_ref().and_then(|m| m.episodes);
                        if let Some(n) = planned {
                            // Providers occasionally number episodes with a
                            // gap (e.g. a special bumping the finale to
                            // total+1); never write AniList progress past the
                            // series' real episode count.
                            write_progress = write_progress.min(n as i64);
                        }
                        if planned.map(|n| episode_number >= n as i64).unwrap_or(false) {
                            status = "COMPLETED";
                        } else {
                            log::info!(
                                "Not completing media {}: watched ep {} but AniList planned total is {:?}",
                                media_id, episode_number, planned
                            );
                        }
                    }
                    Err(e) => log::warn!(
                        "Completion check for media {} failed ({}); keeping status CURRENT",
                        media_id, e
                    ),
                }
            }

            let mut vars = HashMap::new();
            vars.insert("mediaId".to_string(), serde_json::json!(media_id));
            vars.insert("status".to_string(), serde_json::json!(status));
            vars.insert("progress".to_string(),
                serde_json::json!(write_progress),
            );

            let _: Value = state
                .anilist_client
                .execute(
                    crate::anilist::queries::SAVE_MEDIA_LIST_ENTRY_MUTATION,
                    vars,
                )
                .await
                .map_err(|e| {
                    log::error!(
                        "Failed to write AniList progress (media {} ep {} status {}): {}",
                        media_id, write_progress, status, e
                    );
                    e
                })?;

            state.cache.update_user_list_progress(media_id, Some(write_progress), Some(status), None);
            state.cache.invalidate("get_user_list");
            state.cache.invalidate("get_airing_schedule");
        }
    }

    Ok(())
}

#[tauri::command]
pub async fn stop_playback(
    state: State<'_, AppState>,
    media_id: i64,
    episode_number: i64,
    stop_time: i64,
    duration: i64,
) -> Result<(), String> {
    kill_current_mpv().await;

    // Stop the torrent download the moment playback ends (no-op unless the
    // "nyaa" provider started a session). Files stay cached for instant resume.
    state.torrent.pause_all().await;

    state.discord.clear_presence();

    let total_episodes = {
        let guard = state.current_playback.lock().await;
        guard.as_ref().map(|p| p.total_episodes).unwrap_or(0)
    };
    record_playback_progress(&state, 0, media_id, episode_number, stop_time, duration, total_episodes).await?;

    Ok(())
}

use crate::registry::WatchEntry;

#[tauri::command]
pub async fn get_watched_episodes(
    state: State<'_, AppState>,
    media_id: i64,
) -> Result<Vec<WatchEntry>, String> {
    get_watched_episodes_impl(state.inner(), 0, media_id).await
}

pub async fn get_watched_episodes_impl(
    state: &AppState,
    user_id: i64,
    media_id: i64,
) -> Result<Vec<WatchEntry>, String> {
    let db = state.open_db()?;
    crate::registry::service::get_watched_episodes(&db, user_id, media_id)
}

#[tauri::command]
pub async fn get_all_last_watched(
    state: State<'_, AppState>,
) -> Result<HashMap<i64, String>, String> {
    get_all_last_watched_impl(state.inner(), 0).await
}

#[tauri::command]
pub async fn get_watch_history(
    state: State<'_, AppState>,
    limit: Option<i64>,
) -> Result<Vec<crate::registry::service::HistoryEntry>, String> {
    get_watch_history_impl(state.inner(), 0, limit).await
}

pub async fn get_watch_history_impl(
    state: &AppState,
    user_id: i64,
    limit: Option<i64>,
) -> Result<Vec<crate::registry::service::HistoryEntry>, String> {
    let db = state.open_db()?;
    crate::registry::service::get_watch_history(&db, user_id, limit.unwrap_or(1500))
}

pub async fn get_all_last_watched_impl(
    state: &AppState,
    user_id: i64,
) -> Result<HashMap<i64, String>, String> {
    let db = state.open_db()?;
    crate::registry::service::get_all_last_watched(&db, user_id)
}

// Separate from CURRENT_MPV: a trailer is a standalone, untracked playback
// session (no episode progress, no AniList sync, no skip/auto-next), so it
// must not interfere with the regular episode-playback process slot.
static CURRENT_TRAILER_MPV: std::sync::Mutex<Option<tokio::process::Child>> =
    std::sync::Mutex::new(None);

fn find_yt_dlp_path() -> Option<String> {
    if let Some(path) = crate::util::find_on_path("yt-dlp") {
        return Some(path);
    }
    let candidates = [
        "/opt/homebrew/bin/yt-dlp".to_string(),
        "/usr/local/bin/yt-dlp".to_string(),
        format!("{}/.local/bin/yt-dlp", std::env::var("HOME").unwrap_or_default()),
    ];
    candidates.into_iter().find(|p| std::path::Path::new(p).exists())
}

/// Resolve a YouTube trailer to a direct stream URL via yt-dlp and play it in
/// mpv. Trailers are short, low-stakes, and play through the same player as
/// everything else in the app rather than an embedded YouTube iframe (no
/// YouTube branding/UI, no CSP frame-src surface, consistent controls).
#[tauri::command]
pub async fn play_trailer(app: AppHandle, trailer_id: String) -> Result<(), String> {
    let yt_dlp = find_yt_dlp_path().ok_or_else(|| {
        "yt-dlp not found. Install it (e.g. \"brew install yt-dlp\") to play trailers in-app."
            .to_string()
    })?;

    let youtube_url = format!("https://www.youtube.com/watch?v={}", trailer_id);
    log::info!("[trailer] Resolving stream URL via yt-dlp for {}", youtube_url);

    let mut resolve_cmd = tokio::process::Command::new(&yt_dlp);
    crate::util::suppress_console_tokio(&mut resolve_cmd);
    resolve_cmd.args(["-f", "best[ext=mp4]/best", "-g", &youtube_url]);
    let output = resolve_cmd
        .output()
        .await
        .map_err(|e| format!("Failed to run yt-dlp: {}", e))?;

    if !output.status.success() {
        let stderr = String::from_utf8_lossy(&output.stderr);
        log::error!("[trailer] yt-dlp failed: {}", stderr);
        let reason = stderr.lines().last().unwrap_or("unknown error");
        return Err(format!("Could not resolve trailer stream: {}", reason));
    }

    let stream_url = String::from_utf8_lossy(&output.stdout).trim().to_string();
    if stream_url.is_empty() {
        return Err("yt-dlp returned no stream URL".to_string());
    }

    let (mpv_bin, config_dir, lib_dir) = resolve_mpv_path(&app)?;

    {
        let child = {
            if let Ok(mut guard) = CURRENT_TRAILER_MPV.lock() {
                guard.take()
            } else {
                None
            }
        };
        if let Some(mut c) = child {
            log::info!("[trailer] Killing previous trailer mpv instance");
            let _ = c.kill().await;
        }
    }

    let mut cmd = tokio::process::Command::new(&mpv_bin);
    crate::util::suppress_console_tokio(&mut cmd);
    cmd.arg(format!("--config-dir={}", config_dir));
    // Trailers don't carry an episode/progress session, so the anicat_ui
    // script's IPC callbacks (which assume one exists) have nothing to talk
    // to — suppress script autoloading for this one launch.
    cmd.arg("--scripts=");
    cmd.arg("--force-window=yes");
    cmd.arg("--title=Trailer");
    cmd.arg(&stream_url);

    if cfg!(target_os = "macos") && !lib_dir.is_empty() {
        cmd.env("DYLD_LIBRARY_PATH", &lib_dir);
        let icd_path = std::path::Path::new(&lib_dir).join("vk_icd.json");
        cmd.env("VK_ICD_FILENAMES", icd_path);
    }
    if cfg!(target_os = "linux") {
        cmd.env("LD_LIBRARY_PATH", &lib_dir);
    }
    if cfg!(target_os = "windows") && !lib_dir.is_empty() {
        let existing = std::env::var("PATH").unwrap_or_default();
        cmd.env("PATH", format!("{};{}", lib_dir, existing));
    }

    let child = cmd
        .spawn()
        .map_err(|e| format!("Failed to launch mpv: {}", e))?;
    log::info!("[trailer] Launched mpv for trailer playback");

    if let Ok(mut guard) = CURRENT_TRAILER_MPV.lock() {
        *guard = Some(child);
    }

    Ok(())
}

#[cfg(test)]
mod tests {
    use super::{is_watched, resume_position};

    #[test]
    fn watched_only_past_threshold() {
        // 85% threshold on a 100s episode.
        assert!(!is_watched(84, 100));
        assert!(is_watched(85, 100));
        assert!(is_watched(100, 100));
        // Unknown duration is never "watched".
        assert!(!is_watched(9999, 0));
        assert!(!is_watched(50, -1));
    }

    #[test]
    fn resume_skips_finished_and_trivial_positions() {
        // Mid-episode past the 30s floor resumes where you stopped.
        assert_eq!(resume_position(600, 1400), 600);
        // Under the floor starts from the beginning.
        assert_eq!(resume_position(12, 1400), 0);
        assert_eq!(resume_position(30, 1400), 30);
        // A finished episode (>= threshold) never resumes near the end.
        assert_eq!(resume_position(1300, 1400), 0);
        // Unknown duration cannot resume.
        assert_eq!(resume_position(500, 0), 0);
    }
}
