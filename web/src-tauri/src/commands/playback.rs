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

/// Whether a play will go through the embedded torrent session rather than a
/// scraper.
///
/// Not the same question as "is the provider nyaa". Cinema mode is always
/// torrent-backed whatever `general.provider` happens to say — that setting
/// describes the anime world — so a guard written against the provider name
/// alone silently stops applying the moment a film is playing.
pub(crate) fn is_torrent_backed(provider: &str, media_id: i64) -> bool {
    provider == "nyaa" || crate::media_id::source_of(media_id).is_cinema()
}

/// Which provider labels to try, in order, when resolving a stream.
///
/// For anime this is the configured fallback chain: try the primary
/// provider, then the fallback, then the secondary fallback, skipping blanks
/// and duplicates. For a cinema id it collapses to a single entry.
/// `resolve_stream_for_provider` checks `is_cinema()` before it looks at the
/// provider string at all, so every one of those three names would run the
/// identical apibay-or-Knaben search and hit the identical failure -- three
/// full search timeouts for one answer, and a log line reading "provider
/// 'anineko' failed" for a film anineko was never going to have an opinion
/// about.
pub(crate) fn provider_fallback_chain(
    media_id: i64,
    provider_name: &str,
    fallback_provider: String,
    secondary_fallback: String,
) -> Vec<String> {
    if crate::media_id::source_of(media_id).is_cinema() {
        vec![provider_name.to_string()]
    } else {
        vec![provider_name.to_string(), fallback_provider, secondary_fallback]
    }
}

/// Path to mpv's JSON IPC socket.
///
/// Not in `/tmp`. That socket is a command channel — everything this file sends
/// over it (`loadfile` at any URL, `set_property` for referrer/user-agent/
/// http-header-fields, `script-message` into anicat_ui) is equally available to
/// anyone else who can connect. `/tmp` is world-writable and the default umask
/// leaves the socket world-connectable, so on a shared machine any other local
/// user could drive the player. Putting it inside a 0700 directory the OS
/// already gives us per-user closes that at the directory level, which is the
/// part we control — mpv creates the socket itself, so its own mode is not ours
/// to set.
///
/// Windows is unaffected: a named pipe, not a filesystem path.
fn get_ipc_path() -> String {
    #[cfg(target_os = "windows")]
    {
        r"\\.\pipe\anicat-mpv".to_string()
    }

    #[cfg(not(target_os = "windows"))]
    {
        // Falls back to the old /tmp path only if there is no per-user config
        // dir at all, which would also mean the app has nowhere to store its
        // config or registry — i.e. it is already badly broken.
        let Some(dir) = dirs::config_dir().map(|d| d.join("anicat")) else {
            let uid = std::env::var("USER").unwrap_or_else(|_| "user".to_string());
            return format!("/tmp/anicat-mpv-{}.sock", uid);
        };
        if std::fs::create_dir_all(&dir).is_ok() {
            use std::os::unix::fs::PermissionsExt;
            // Best-effort: an existing dir created before this change may be
            // 0755, so tighten it rather than assuming create_dir_all's mode.
            let _ = std::fs::set_permissions(&dir, std::fs::Permissions::from_mode(0o700));
        }
        dir.join("mpv.sock").to_string_lossy().to_string()
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

/// Waits on mpv's IPC socket for the `file-loaded` event — the point where
/// the demuxer has actually opened the stream and mpv knows there is a video
/// track, which is also when `--force-window` paints something on screen.
///
/// This is a real readiness signal, unlike "the process is still alive 500ms
/// after spawn": for a torrent-backed stream, opening the file can mean
/// seeking to read an MKV's Cues element near the end of the file (see
/// torrent/stream.rs's doc comment on seek-reprioritization), which on a slow
/// swarm can block for minutes. Connecting immediately after spawn — well
/// before mpv could plausibly have finished that probe — avoids the race
/// where `file-loaded` fires before this function starts listening.
///
/// Returns `Ok(true)` once loaded, `Ok(false)` if mpv reported `shutdown` /
/// `end-file` (closed or failed before loading), and `Err` if the socket
/// couldn't be reached at all (e.g. not created yet).
async fn wait_for_mpv_file_loaded(ipc_path: &str) -> Result<bool, String> {
    use tokio::io::{AsyncBufReadExt, AsyncWriteExt};

    async fn query_then_listen<S: tokio::io::AsyncRead + tokio::io::AsyncWrite + Unpin>(
        mut stream: S,
    ) -> bool {
        // `file-loaded` is a one-shot broadcast: a connection that joins
        // after it already fired never sees it and would otherwise wait out
        // the full timeout despite mpv already playing fine. That race is
        // real, not theoretical — an episode that's fully cached on disk
        // from an earlier attempt (this file's own connect-retry loop can
        // lose to it) loads in well under the time a connect + 150ms retry
        // takes. So ask directly whether a file is already loaded before
        // falling back to listening for the event.
        let query = serde_json::json!({"command": ["get_property", "path"], "request_id": 1});
        if stream
            .write_all(format!("{}\n", query).as_bytes())
            .await
            .is_ok()
        {
            let _ = stream.flush().await;
        }

        let mut lines = tokio::io::BufReader::new(stream).lines();
        loop {
            match lines.next_line().await {
                Ok(Some(line)) => {
                    let Ok(v) = serde_json::from_str::<serde_json::Value>(&line) else { continue };
                    match v.get("event").and_then(|e| e.as_str()) {
                        Some("file-loaded") => return true,
                        Some("shutdown") | Some("end-file") => return false,
                        _ => {}
                    }
                    // Response to the get_property above: request_id 1
                    // succeeding means a file is already loaded right now.
                    if v.get("request_id").and_then(|r| r.as_i64()) == Some(1)
                        && v.get("error").and_then(|e| e.as_str()) == Some("success")
                    {
                        return true;
                    }
                }
                _ => return false, // EOF or read error: mpv's end of the socket is gone
            }
        }
    }

    #[cfg(unix)]
    {
        let stream = tokio::net::UnixStream::connect(ipc_path)
            .await
            .map_err(|e| e.to_string())?;
        Ok(query_then_listen(stream).await)
    }

    #[cfg(windows)]
    {
        use tokio::net::windows::named_pipe::ClientOptions;
        let client = ClientOptions::new().open(ipc_path).map_err(|e| e.to_string())?;
        Ok(query_then_listen(client).await)
    }

    #[cfg(not(any(unix, windows)))]
    {
        let _ = ipc_path;
        Err("Unsupported platform".to_string())
    }
}

/// Polls for the socket to exist and then waits for `file-loaded`, giving up
/// after `timeout`. The connect retry loop covers the brief window right
/// after spawn where mpv hasn't created its IPC socket yet.
async fn wait_for_mpv_window(ipc_path: &str, timeout: std::time::Duration) -> bool {
    let deadline = tokio::time::Instant::now() + timeout;
    loop {
        let now = tokio::time::Instant::now();
        if now >= deadline {
            return false;
        }
        match tokio::time::timeout(deadline - now, wait_for_mpv_file_loaded(ipc_path)).await {
            Ok(Ok(loaded)) => return loaded,
            Ok(Err(_)) => tokio::time::sleep(std::time::Duration::from_millis(150)).await,
            Err(_) => return false, // overall timeout
        }
    }
}

/// Puts a preloaded stream back after a start that took it out of the slot
/// but then bailed (superseded by a newer start). Only fills an empty slot:
/// whatever a later preload has already put there is fresher by definition.
async fn restore_preload(state: &AppState, entry: Option<crate::state::PreloadedStream>) {
    let Some(entry) = entry else { return };
    let mut slot = state.preloaded_stream.lock().await;
    if slot.is_none() {
        *slot = Some(entry);
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
    // A failure here is recoverable, so don't propagate it: every remaining
    // lookup below (system install, PATH, dev resources) works without a
    // resource dir. Bailing out on `?` turned a resolvable "where did Tauri
    // put the bundle" question into "playback is dead", surfacing to the user
    // as a bare "unknown path" after the stream had already been resolved.
    let base_dir = match app.path().resource_dir() {
        Ok(resource_dir) => {
            if resource_dir.join("resources").exists() {
                Some(resource_dir.join("resources"))
            } else {
                Some(resource_dir)
            }
        }
        Err(e) => {
            log::warn!(
                "Could not resolve the resource dir ({}); falling back to a system or dev-tree mpv",
                e
            );
            None
        }
    };

    let prod_config = base_dir.as_ref().map(|d| d.join("mpv_config"));
    let config_dir = match prod_config {
        Some(p) if p.exists() => p.to_string_lossy().to_string(),
        _ => std::path::Path::new(env!("CARGO_MANIFEST_DIR"))
            .join("resources")
            .join("mpv_config")
            .to_string_lossy()
            .to_string(),
    };
    // mpv can't use a `\\?\`-prefixed config-dir (see strip_verbatim_prefix).
    let config_dir = strip_verbatim_prefix(config_dir);

    let mpv_name = if cfg!(target_os = "windows") {
        "mpv.exe"
    } else {
        "mpv"
    };
    // Prefer bundled mpv if present (ensures self-contained reliability in release builds)
    if let Some(ref base) = base_dir {
        let mpv_bin = base.join(mpv_name);
        let lib_dir = base.join("lib");
        if mpv_bin.exists() {
            log::info!("Using bundled mpv at: {}", mpv_bin.display());
            strip_quarantine_once(&mpv_bin, &lib_dir);
            return Ok((
                mpv_bin.to_string_lossy().to_string(),
                config_dir,
                strip_verbatim_prefix(lib_dir.to_string_lossy().to_string()),
            ));
        }
    }

    // Fall back to a system-installed mpv if present. Production macOS apps launched
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

    // Fall back to dev resources directory
    let dev_path = std::path::Path::new(env!("CARGO_MANIFEST_DIR"))
        .join("resources")
        .join(mpv_name);
    if dev_path.exists() {
        let dev_lib_dir = std::path::Path::new(env!("CARGO_MANIFEST_DIR"))
            .join("resources")
            .join("lib");
        strip_quarantine_once(&dev_path, &dev_lib_dir);
        return Ok((
            dev_path.to_string_lossy().to_string(),
            config_dir,
            dev_lib_dir.to_string_lossy().to_string(),
        ));
    }

    Err(match base_dir {
        Some(base) => format!(
            "mpv binary not found at {} or in system/dev resources",
            base.join(mpv_name).display()
        ),
        None => "mpv binary not found: no bundled resource dir, and no system or dev-tree mpv"
            .to_string(),
    })
}

/// `cp -R` carries `com.apple.quarantine` forward from wherever a bundled
/// binary came from (the mpv cask bottle, pulled over the network by `brew
/// fetch`), and ad-hoc codesign does not clear it. `setup_bundled_player.sh`
/// strips it once at bundle-prep time, but Tauri makes its own copy of
/// `resources/` into `target/debug/resources` on every dev build — a copy
/// that already existed before a prep-time fix runs stays quarantined
/// forever otherwise, and that's exactly the copy `tauri dev` launches from.
/// Doing it here, on every resolve, means it self-heals regardless of which
/// build tree the binary ended up in or when it was copied there.
#[cfg(target_os = "macos")]
fn strip_quarantine(path: &std::path::Path) {
    let _ = std::process::Command::new("/usr/bin/xattr")
        .args(["-r", "-d", "com.apple.quarantine"])
        .arg(path)
        .output();
}

// Recursive `xattr -r -d` over the whole mpv lib dir is a blocking,
// filesystem-walking shell-out; re-running it on every single play (as this
// used to, once per launch for both mpv_bin and lib_dir) adds real latency
// to every launch for a self-heal that, once it has actually run, doesn't
// need repeating within the same process lifetime — the copy on disk
// doesn't get re-quarantined mid-session.
#[cfg(target_os = "macos")]
static QUARANTINE_STRIPPED: std::sync::atomic::AtomicBool = std::sync::atomic::AtomicBool::new(false);

#[cfg(target_os = "macos")]
fn strip_quarantine_once(mpv_bin: &std::path::Path, lib_dir: &std::path::Path) {
    if QUARANTINE_STRIPPED.swap(true, std::sync::atomic::Ordering::SeqCst) {
        return;
    }
    strip_quarantine(mpv_bin);
    strip_quarantine(lib_dir);
}

// Quarantine is a macOS concept, so off-macOS this is the whole story: one
// no-op entry point. There is deliberately no `strip_quarantine` stub here --
// nothing would call it, and CI builds Linux with `-D warnings`, where an
// uncalled function is a hard error.
#[cfg(not(target_os = "macos"))]
fn strip_quarantine_once(_mpv_bin: &std::path::Path, _lib_dir: &std::path::Path) {}

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
fn pick_best_server(
    servers: &[crate::scraper::client::StreamServer],
    target_quality: u32,
) -> Option<&crate::scraper::client::StreamServer> {
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

/// The sub/dub/explicit-pick preference logic, factored out so a post-restart
/// retry (see the 403-triggered scraper restart in `resolve_stream_for_provider`)
/// can re-run it against a freshly-fetched server list instead of falling
/// back to a cruder pick that would ignore the user's translation preference.
fn select_server<'a>(
    servers: &'a [crate::scraper::client::StreamServer],
    server: &Option<String>,
    translation_type: &str,
    target_quality: u32,
) -> Option<&'a crate::scraper::client::StreamServer> {
    if let Some(ref s_name) = server {
        servers.iter().find(|s| s.name == *s_name)
            .or_else(|| pick_best_server(servers, target_quality))
    } else if translation_type == "dub" {
        pick_best_server_in_group(servers, &["dub"], target_quality)
            .or_else(|| pick_best_server_in_group(servers, &["hard_sub"], target_quality))
            .or_else(|| pick_best_server_in_group(servers, &["soft_sub"], target_quality))
            .or_else(|| pick_best_server(servers, target_quality))
    } else {
        pick_best_server_in_group(servers, &["hard_sub"], target_quality)
            .or_else(|| {
                servers.iter()
                    .filter(|s| get_stream_group(s) == "soft_sub" && s.subtitle_url.is_some())
                    .find(|s| resolution_rank(s) == target_quality)
                    .or_else(|| pick_best_server_in_group(servers, &["soft_sub"], target_quality))
            })
            .or_else(|| pick_best_server_in_group(servers, &["dub"], target_quality))
            .or_else(|| pick_best_server(servers, target_quality))
    }
}

/// Playback candidates in the order they should be tried: the server the
/// preference logic above actually chose, then every other server best-first as
/// retry material. Deduped by URL, since the scraper's several extraction
/// passes routinely surface the same URL under different names.
///
/// The primary stays first no matter how it ranks — sub/dub preference and an
/// explicit user pick both outrank raw speed, and this must not quietly
/// override either.
fn candidate_order<'a>(
    servers: &'a [crate::scraper::client::StreamServer],
    primary: Option<&'a crate::scraper::client::StreamServer>,
) -> Vec<&'a crate::scraper::client::StreamServer> {
    let mut rest: Vec<&crate::scraper::client::StreamServer> = servers.iter().collect();
    rest.sort_by_key(|s| quality_sort_key(s));

    let mut out = Vec::with_capacity(servers.len());
    let mut seen = std::collections::HashSet::new();
    for s in primary.into_iter().chain(rest) {
        if !s.url.is_empty() && seen.insert(s.url.as_str()) {
            out.push(s);
        }
    }
    out
}

/// Outcome of a stream liveness probe.
///
/// Deliberately biased toward `Alive`: a false negative skips a server that
/// would have played fine, which is strictly worse than the status quo, so only
/// an unambiguous rejection counts as dead. See `probe_stream`.
enum StreamProbe {
    Alive,
    Dead(String),
}

/// Whether a URL is an HLS playlist rather than media bytes.
///
/// anineko's jwplayer hosts serve playlists as `master.txt`, so extension
/// alone is not enough.
fn looks_like_playlist(url: &str) -> bool {
    let path = url.split('?').next().unwrap_or(url);
    path.ends_with(".m3u8") || path.ends_with("master.txt")
}

/// What one hop down an HLS playlist leads to.
#[derive(Debug, PartialEq)]
enum PlaylistStep {
    /// A master playlist, and the variant a player would actually choose.
    Variant(String),
    /// A media playlist's segment URIs, in playback order.
    Segments(Vec<String>),
    /// Not a playlist shape this understands. The caller must not invent a
    /// verdict from it.
    Unknown,
}

/// Read one playlist, resolving its URIs against its own URL.
///
/// A master playlist yields the **highest-bandwidth** variant, not the first
/// one. That is not cosmetic: on anineko's HD-1 the ad-CDN revocations are
/// per-variant, and on a measured episode 360p (the first entry) had 1 dead
/// segment in 10 while 720p and 1080p each had 5. mpv and hls.js both climb to
/// 1080p, so probing the first variant measures a stream nobody watches and
/// passes a server that plays as a handful of disconnected chunks.
fn parse_playlist(base_url: &str, body: &str) -> PlaylistStep {
    let base = match reqwest::Url::parse(base_url) {
        Ok(u) => u,
        Err(_) => return PlaylistStep::Unknown,
    };
    let resolve = |uri: &str| base.join(uri).ok().map(|u| u.to_string());

    let mut best_variant: Option<(u64, String)> = None;
    let mut pending_bandwidth: Option<u64> = None;
    let mut segments = Vec::new();

    for line in body.lines().map(str::trim) {
        if line.is_empty() {
            continue;
        }
        if let Some(attrs) = line.strip_prefix("#EXT-X-STREAM-INF:") {
            // Missing/unparseable BANDWIDTH sorts last but still competes, so a
            // master playlist without the attribute still yields a variant.
            pending_bandwidth = Some(parse_bandwidth(attrs).unwrap_or(0));
            continue;
        }
        if line.starts_with('#') {
            continue;
        }
        match pending_bandwidth.take() {
            Some(bw) => {
                if let Some(url) = resolve(line) {
                    let better = match best_variant {
                        Some((best, _)) => bw > best,
                        None => true,
                    };
                    if better {
                        best_variant = Some((bw, url));
                    }
                }
            }
            None => {
                if let Some(url) = resolve(line) {
                    segments.push(url);
                }
            }
        }
    }

    if let Some((_, url)) = best_variant {
        return PlaylistStep::Variant(url);
    }
    if segments.is_empty() {
        return PlaylistStep::Unknown;
    }
    PlaylistStep::Segments(segments)
}

/// `BANDWIDTH=2800000` out of an `#EXT-X-STREAM-INF` attribute list.
fn parse_bandwidth(attrs: &str) -> Option<u64> {
    for attr in attrs.split(',') {
        if let Some((key, value)) = attr.split_once('=') {
            if key.trim() == "BANDWIDTH" {
                return value.trim().parse().ok();
            }
        }
    }
    None
}

/// Indices to sample from a segment list: spread across the whole playlist, so
/// a partially revoked stream can't hide behind a healthy opening.
fn sample_indices(len: usize, wanted: usize) -> Vec<usize> {
    if len == 0 || wanted == 0 {
        return Vec::new();
    }
    if wanted == 1 || len == 1 {
        return vec![0];
    }
    let wanted = wanted.min(len);
    let mut out: Vec<usize> = (0..wanted)
        .map(|i| i * (len - 1) / (wanted - 1))
        .collect();
    out.dedup();
    out
}

/// Ask an upstream whether it is actually serving media. Resolution can hand
/// back a URL that 404s or whose signed token has expired — that isn't a
/// resolve *error*, so nothing used to catch it, and mpv opened onto a stream
/// that never flowed.
///
/// For HLS this walks down to a real segment before judging, which is the
/// whole point. A playlist is a small static file and answers 200 long after
/// the media behind it is gone: anineko's HD-1 serves its segments from an
/// abused ad CDN that revokes them per-asset, so `master.m3u8` returned 200
/// while every segment returned `403 {"code":1004,"error":"domain forbidden"}`.
/// Probing only the playlist called that alive, the resolve "succeeded", the
/// fallback-provider chain never fired, and hls.js fed 40-byte JSON error
/// bodies into MSE — which the user sees as "Media failed to decode", pointing
/// at codecs instead of at a dead upstream. Measured across ten episodes, four
/// were dead this way.
///
/// Sends the same headers the player will (referer/user-agent matter to several
/// of these CDNs), and treats only "this URL will not serve media" answers as
/// dead. A timeout is explicitly *not* one of them: a slow CDN is still a
/// playable CDN, and mpv waits far longer than this probe does. Likewise a
/// playlist that can't be parsed is left Alive rather than punished — the bias
/// toward Alive is deliberate, since a false negative skips a server that would
/// have played.
async fn probe_stream(
    client: &reqwest::Client,
    url: &str,
    headers: Option<&HashMap<String, String>>,
) -> StreamProbe {
    const PROBE_TIMEOUT: std::time::Duration = std::time::Duration::from_millis(2500);
    /// master -> variant -> segment. Two hops is the deepest real HLS goes;
    /// the cap also stops a self-referential playlist from looping.
    const MAX_PLAYLIST_HOPS: usize = 2;
    /// Segments sampled from a media playlist, spread across it and issued
    /// concurrently, so this still costs one `PROBE_TIMEOUT` on the play path.
    ///
    /// Eight rather than four because the revocations are scattered: a 4-sample
    /// probe of HD-1's 1080p variant measured 1 dead, under any sane threshold,
    /// on a stream that is ~40% revoked. At 8 the same streams read 3/8 and 4/8
    /// while HD-2 reads 0/8 on both audio groups.
    const MEDIA_SAMPLES: usize = 8;
    /// Fraction of sampled segments that must be dead before the server is.
    /// Loose enough that one expired segment is still a live server, which is
    /// the `StreamProbe` bias toward Alive applied to a sample.
    const DEAD_SAMPLE_NUMERATOR: usize = 1;
    const DEAD_SAMPLE_DENOMINATOR: usize = 4;

    let with_headers = |mut req: reqwest::RequestBuilder| {
        if let Some(headers) = headers {
            for (key, val) in headers {
                req = req.header(key, val);
            }
        }
        req
    };

    // Walk playlists down to whatever they ultimately point at.
    let mut target = url.to_string();
    let mut segments: Vec<String> = Vec::new();
    for _ in 0..MAX_PLAYLIST_HOPS {
        if !looks_like_playlist(&target) {
            break;
        }
        let req = with_headers(client.get(&target)).timeout(PROBE_TIMEOUT);
        match req.send().await {
            Ok(resp) => {
                let status = resp.status();
                if probe_status_is_dead(status.as_u16()) {
                    return StreamProbe::Dead(format!("playlist HTTP {}", status));
                }
                let body = match resp.text().await {
                    Ok(b) => b,
                    // Fetched fine but unreadable: not evidence of death.
                    Err(_) => return StreamProbe::Alive,
                };
                match parse_playlist(&target, &body) {
                    PlaylistStep::Variant(next) => target = next,
                    PlaylistStep::Segments(segs) => {
                        segments = segs;
                        break;
                    }
                    // An empty or unrecognised playlist. Don't guess.
                    PlaylistStep::Unknown => return StreamProbe::Alive,
                }
            }
            Err(e) if e.is_timeout() => return StreamProbe::Alive,
            Err(e) => return StreamProbe::Dead(e.to_string()),
        }
    }

    // Range-probe the media itself. For HLS that means several segments spread
    // across the episode, not just the first: HD-1's ad CDN revokes segments
    // individually, so a stream that plays as a few disconnected chunks still
    // serves segment 0 quite happily.
    let targets: Vec<String> = if segments.is_empty() {
        vec![target]
    } else {
        sample_indices(segments.len(), MEDIA_SAMPLES)
            .into_iter()
            .map(|i| segments[i].clone())
            .collect()
    };
    let probed = targets.len();

    let results = futures_util::future::join_all(targets.iter().map(|t| {
        let req = with_headers(client.get(t))
            .header("range", "bytes=0-1")
            .timeout(PROBE_TIMEOUT);
        async move { req.send().await }
    }))
    .await;

    let mut dead = 0usize;
    // Segments whose death is a property of the asset, not of the moment.
    let mut revoked = 0usize;
    // Segments that actually answered. A timeout is not evidence either way —
    // a slow CDN is still a playable CDN, and mpv waits far longer than this —
    // so it must not count as alive when the ratio below is taken, or eight
    // concurrent requests to a slow host would dilute a real verdict into a
    // pass.
    let mut answered = 0usize;
    let mut reason = String::new();
    for result in results {
        match result {
            Ok(resp) => {
                answered += 1;
                let status = resp.status();
                if probe_status_is_dead(status.as_u16()) {
                    dead += 1;
                    if probe_status_is_permanent(status.as_u16()) {
                        revoked += 1;
                    }
                    reason = format!("HTTP {}", status);
                }
            }
            Err(e) if e.is_timeout() => {}
            Err(e) => {
                answered += 1;
                dead += 1;
                reason = e.to_string();
            }
        }
    }

    // One revoked segment condemns the stream. The sample is 8 segments out of
    // ~150, so finding even one means the episode has a hole the player will
    // stop at — which is the symptom this exists to catch: HD-1 played "six
    // seconds or six minutes and never a full one", the length decided by
    // where its first revoked segment fell. Requiring two of them measured 2/8
    // on a run where the same streams read 3/8 and 4/8 on either side of it,
    // sitting right on the threshold for a bug that is not marginal at all.
    //
    // A transient death (5xx) still needs the sample to agree, and a
    // single-target probe (a plain mp4, or a playlist with one entry) keeps the
    // old all-or-nothing verdict — there is no sample to average.
    let dead_enough = if probed <= 1 {
        dead >= 1
    } else {
        revoked >= 1 || (dead > 1 && dead * DEAD_SAMPLE_DENOMINATOR >= answered * DEAD_SAMPLE_NUMERATOR)
    };
    if dead_enough {
        StreamProbe::Dead(format!("{}/{} answered segments dead, last: {}", dead, answered, reason))
    } else {
        StreamProbe::Alive
    }
}

/// Elapsed time of each stage of a stream resolve, logged as one line when the
/// resolve finishes.
///
/// Exists because "why did pressing play take 30 seconds" was previously
/// unanswerable: the work spans a Python sidecar that may need respawning, a
/// Cloudflare challenge, a title search loop with its own sleeps, a stream
/// fetch, and now a liveness probe — and nothing recorded which of those the
/// time went to. Every tuning constant around this path (the sidecar idle
/// timeout, the inter-query sleep, the probe timeout, the breaker thresholds)
/// is a guess until this says otherwise.
#[derive(Default)]
struct ResolveTimings {
    /// Fetching streams for an already-cached slug.
    cached_slug_ms: u128,
    /// Searching the provider for a slug and validating candidates.
    slug_resolve_ms: u128,
    /// Probing candidate servers for liveness.
    probe_ms: u128,
    /// How many servers were probed before one answered.
    probes: usize,
}

impl ResolveTimings {
    fn log(&self, provider: &str, media_id: i64, episode: i64, outcome: &str, total_ms: u128) {
        log::info!(
            "[resolve] provider={} media={} ep={} outcome={} total={}ms \
             cached_slug={}ms slug_resolve={}ms probe={}ms probes={}",
            provider, media_id, episode, outcome, total_ms,
            self.cached_slug_ms, self.slug_resolve_ms, self.probe_ms, self.probes
        );
    }
}

/// Whether an HTTP status means "this URL will not serve media".
///
/// Everything not listed is treated as alive on purpose: 405 (host dislikes
/// Range), 429, an unfollowed redirect and every 2xx all mean "keep going",
/// because mpv may succeed where this probe didn't and skipping a working
/// server is worse than probing one that turns out to be dead.
fn probe_status_is_dead(status: u16) -> bool {
    matches!(status, 403 | 404 | 410 | 451) || (500..600).contains(&status)
}

/// Whether a dead status is a property of the asset rather than of the moment.
///
/// 403/404/410/451 are the CDN saying this particular object is gone or
/// forbidden, and it answers the same way every time — anineko's HD-1 returned
/// byte-identical `403 {"code":1004,"error":"domain forbidden"}` for the same
/// segments across repeated passes minutes apart. One of those inside an
/// episode is a hole the player cannot get past, so one is enough to condemn
/// the stream.
///
/// A 5xx is not: it may be the host having a bad second, and condemning a
/// server on one of those would skip a stream that plays. Those still need the
/// sample to agree.
fn probe_status_is_permanent(status: u16) -> bool {
    matches!(status, 403 | 404 | 410 | 451)
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

/// Titles and release year for a film, from TMDB.
///
/// The anime counterpart (`torrent::gather_media_info`) reads AniList, which
/// has never heard of these ids. Both titles are offered because a film
/// released here under a translated name is often seeded under its original
/// one, and vice versa.
/// `resolve_stream_impl` needs the same titles and year the play path uses.
pub(crate) async fn gather_movie_info_pub(
    state: &AppState,
    media_id: i64,
    frontend_title: Option<String>,
) -> (Vec<String>, Option<i32>) {
    gather_movie_info(state, media_id, frontend_title).await
}

async fn gather_movie_info(
    state: &AppState,
    media_id: i64,
    frontend_title: Option<String>,
) -> (Vec<String>, Option<i32>) {
    let mut titles: Vec<String> = vec![];
    let mut year = None;

    if let Ok(detail) = super::cinema::tmdb_detail_impl(state, media_id).await {
        year = detail
            .get("seasonYear")
            .and_then(|v| v.as_i64())
            .map(|y| y as i32);
        if let Some(t) = detail.get("title") {
            for key in ["english", "romaji"] {
                if let Some(v) = t.get(key).and_then(|v| v.as_str()) {
                    if !v.is_empty() && !titles.iter().any(|e| e == v) {
                        titles.push(v.to_string());
                    }
                }
            }
        }
    }

    // Whatever the detail page was displaying, as a last resort — the lookup
    // above can fail on a cold cache with no network.
    if let Some(t) = frontend_title {
        if !t.is_empty() && !titles.contains(&t) {
            titles.push(t);
        }
    }

    (titles, year)
}

pub(crate) async fn resolve_stream_for_provider(
    state: &AppState,
    media_id: i64,
    episode_number: i64,
    provider_name: &str,
    server: &Option<String>,
    title: Option<String>,
    client: crate::state::StreamClient,
) -> Result<(String, Option<std::collections::HashMap<String, String>>, Option<String>), String> {
    let started = std::time::Instant::now();
    let mut timings = ResolveTimings::default();

    // A film or series takes the torrent path regardless of which anime
    // provider is configured: the scraper providers index anime and will never
    // carry either, and `general.provider` describes the other world entirely.
    if crate::media_id::source_of(media_id).is_cinema() {
        let proxy_port = *state.inner.proxy_port.lock().unwrap_or_else(|e| e.into_inner());
        let (titles, year) = gather_movie_info(state, media_id, title).await;
        if titles.is_empty() {
            return Err("No title to search for".into());
        }

        // A series is searched by the season and episode a release name
        // spells, recovered from the stored absolute number.
        if crate::media_id::source_of(media_id) == crate::media_id::MediaSource::TmdbTv {
            let seasons = super::cinema::season_map_for(state, media_id).await?;
            let Some((season, episode)) =
                crate::torrent::series::absolute_to_season_episode(episode_number, &seasons)
            else {
                return Err(format!(
                    "Episode {} is past the end of this series",
                    episode_number
                ));
            };
            let url = state
                .torrent
                .resolve(
                    &state.http_client,
                    crate::torrent::ResolveTarget {
                        media_id,
                        episode: episode_number,
                        titles: &titles,
                        // A season pack is matched by filename inside the
                        // torrent, which needs the episode number the files
                        // use — that is the within-season one, not the
                        // absolute one the app stores.
                        allow_episodeless: false,
                        episode_count: None,
                        prefer_dub: false,
                        browser_client: client.is_browser(),
                        chosen_name: server.clone(),
                        movie: None,
                        series: Some(crate::torrent::series::EpisodeCriteria {
                            season,
                            episode,
                            browser_client: client.is_browser(),
                        }),
                    },
                    proxy_port,
                )
                .await;
            timings.log(
                "cinema",
                media_id,
                episode_number,
                if url.is_ok() { "ok" } else { "failed" },
                started.elapsed().as_millis(),
            );
            return url.map(|u| (u, None, None));
        }

        let url = state
            .torrent
            .resolve(
                &state.http_client,
                crate::torrent::ResolveTarget {
                    media_id,
                    // A film is its own single episode. `allow_episodeless` is
                    // what stops the shared candidate loop from demanding an
                    // episode number the release names never carry.
                    episode: 1,
                    titles: &titles,
                    allow_episodeless: true,
                    episode_count: Some(1),
                    // Sub versus dub is an anime distinction; a film has one
                    // audio track and the release names say nothing about it.
                    prefer_dub: false,
                    browser_client: client.is_browser(),
                    chosen_name: server.clone(),
                    movie: Some(crate::torrent::cinema::MovieCriteria {
                        year,
                        browser_client: client.is_browser(),
                    }),
                    series: None,
                },
                proxy_port,
            )
            .await;
        timings.log(
            "cinema",
            media_id,
            1,
            if url.is_ok() { "ok" } else { "failed" },
            started.elapsed().as_millis(),
        );
        return url.map(|u| (u, None, None));
    }

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
                    episode_count,
                    prefer_dub,
                    browser_client: client.is_browser(),
                    // The stream picker passes the chosen release name back as
                    // `server`; honor it. Auto-play (Continue button) sends
                    // None and takes the best-scored candidate.
                    chosen_name: server.clone(),
                    movie: None,
                    series: None,
                },
                proxy_port,
            )
            .await;
        // Torrents skip every stage below (no slug, no scraper, and prebuffer
        // is a far stronger liveness check than the probe), so this line is
        // just the total — but it keeps one grep-able marker for every play.
        timings.log(
            provider_name,
            media_id,
            episode_number,
            if url.is_ok() { "ok" } else { "failed" },
            started.elapsed().as_millis(),
        );
        return url.map(|u| (u, None, None));
    }

    // Read any cached slug in a scoped block so the (non-Sync) DB connection is
    // dropped before the first await — otherwise this future is !Send.
    let cached_slug = {
        let db = state.open_db()?;
        crate::registry::service::get_provider_slug(&db, media_id, provider_name)
    };

    let mut resolved_slug = cached_slug.clone();
    let mut servers = match cached_slug {
        Some(ref s) => {
            let t = std::time::Instant::now();
            let res = state
                .scraper_manager
                .get_streams(s, episode_number as i32, provider_name)
                .await
                .unwrap_or_default();
            timings.cached_slug_ms = t.elapsed().as_millis();
            res
        }
        None => Vec::new(),
    };

    // No cached slug, or the cached one yielded nothing (the provider renamed
    // or dropped the show): resolve it fresh, with stream validation. The
    // resolver validates every candidate by fetching its streams and returns
    // them, so calling get_streams on the slug it hands back would repeat the
    // request it just made — this path used to do exactly that, on top of the
    // probe above, which is how one play could pay for the same episode's
    // get_streams three times over.
    if servers.is_empty() {
        let t = std::time::Instant::now();
        if let Ok(Some((slug, validated))) = super::media::resolve_and_save_provider_slug_for_episode(
            state,
            media_id,
            provider_name,
            false,
            title.clone(),
            Some(episode_number as i32),
        )
        .await
        {
            resolved_slug = Some(slug);
            servers = validated;
        }
        timings.slug_resolve_ms = t.elapsed().as_millis();
    }

    if servers.is_empty() {
        timings.log(provider_name, media_id, episode_number, "no-servers", started.elapsed().as_millis());
        return Err(format!("No stream URL found on {}", provider_name));
    }

    // Doodstream (currently fronted by playmogo.com; the underlying platform
    // rotates its domain regularly) is not a direct stream at all -- checked
    // live, anineko's own player embeds it the same way: a raw <iframe> onto
    // the embed page, which loads the real file itself via an obfuscated,
    // short-lived token exchange the embed's own JS runs client-side. The
    // "url" the scraper hands back for it is that embed page, not media, and
    // mpv given a webpage exits immediately -- a hard crash, not a dead-server
    // probe failure, so nothing here previously caught it before it reached
    // mpv. Dropped for the same reason as the browser_ok filter below: a
    // clean "nothing playable" here lets the fallback-provider chain fire,
    // which is the recoverable outcome.
    let before = servers.len();
    servers.retain(|s| !s.name.eq_ignore_ascii_case("doodstream"));
    if servers.len() != before {
        log::info!("Dropped Doodstream from {} candidates: embed-only, not a direct stream", provider_name);
    }
    if servers.is_empty() {
        timings.log(provider_name, media_id, episode_number, "no-servers", started.elapsed().as_millis());
        return Err(format!("No stream URL found on {}", provider_name));
    }

    // A browser can only play what the proxy is willing to fetch, and most of
    // anineko's servers resolve onto rotating throwaway CDN hosts that
    // `ALLOWED_DOMAINS` can never cover. Those are refused before a frame
    // decodes, so drop them here rather than ranking, probing and handing one
    // over — a clean "nothing playable on X" lets the fallback-provider chain
    // fire, which is the recoverable outcome.
    //
    // Hard filter rather than a penalty, unlike the codec scoring in
    // torrent::search: an unreachable host is a certainty, not a guess from a
    // release name. Providers that don't report the field send None and are
    // kept, so this can only ever narrow a provider that opted in.
    if client.is_browser() {
        let before = servers.len();
        servers.retain(|s| s.browser_ok.unwrap_or(true));
        if servers.len() != before {
            log::info!(
                "Dropped {} of {} {} server(s) the proxy can't reach for a browser client",
                before - servers.len(), before, provider_name
            );
        }
        if servers.is_empty() {
            timings.log(provider_name, media_id, episode_number, "none-browser-playable", started.elapsed().as_millis());
            return Err(format!(
                "No mobile-playable stream on {} (all servers resolve to hosts the proxy can't reach)",
                provider_name
            ));
        }
    }

    let translation_type = effective_translation_type(state, media_id).await;
    let data_saver = state.config.read().await.stream.data_saver;
    let target_quality: u32 = if data_saver { 720 } else { 1080 };

    let selected_server = select_server(&servers, server, &translation_type, target_quality);

    // Picking a server used to be the end of it: one URL went to mpv, and if
    // it was dead (404, expired token, CDN refusing us) nothing noticed —
    // that's not a resolve *error*, so the fallback-provider chain in
    // start_playback never fired either, and the user got an mpv window onto a
    // stream that never flowed. Probe down the ranked list instead, so a dead
    // server costs a couple of hundred milliseconds rather than the play.
    const MAX_PROBES: usize = 4;
    let ordered = candidate_order(&servers, selected_server);
    if ordered.is_empty() {
        timings.log(provider_name, media_id, episode_number, "no-servers", started.elapsed().as_millis());
        return Err(format!("No stream URL found on {}", provider_name));
    }

    let probe_start = std::time::Instant::now();
    let mut last_dead = String::new();
    let mut saw_forbidden = false;
    for (idx, cand) in ordered.iter().take(MAX_PROBES).enumerate() {
        timings.probes = idx + 1;
        match probe_stream(&state.http_client, &cand.url, cand.headers.as_ref()).await {
            StreamProbe::Alive => {
                if idx > 0 {
                    log::info!(
                        "Stream probe: {} preferred server(s) on {} were dead, playing '{}' instead",
                        idx, provider_name, cand.name
                    );
                }
                timings.probe_ms = probe_start.elapsed().as_millis();
                timings.log(provider_name, media_id, episode_number, "ok", started.elapsed().as_millis());
                return Ok((cand.url.clone(), cand.headers.clone(), cand.subtitle_url.clone()));
            }
            StreamProbe::Dead(reason) => {
                log::warn!(
                    "Stream probe: server '{}' on {} is dead ({})",
                    cand.name, provider_name, reason
                );
                if reason.contains("403") {
                    saw_forbidden = true;
                }
                last_dead = reason;
            }
        }
    }
    timings.probe_ms = probe_start.elapsed().as_millis();

    // A 403 among an otherwise-dead sweep looks like a stale session (an
    // expired Cloudflare clearance, or signed CDN URLs handed back from an
    // old scrape) rather than the provider actually being gone -- see
    // `force_restart`'s doc comment. Worth one retry with a fresh sidecar
    // before giving up and falling to the next provider, since the whole
    // point is that a fresh scrape produces different (live) URLs.
    if saw_forbidden {
        if let Some(ref slug) = resolved_slug {
            log::warn!(
                "{}: every probed server was dead including a 403 -- forcing a scraper restart and retrying once",
                provider_name
            );
            state.scraper_manager.force_restart().await;
            if let Ok(fresh_servers) = state
                .scraper_manager
                .get_streams(slug, episode_number as i32, provider_name)
                .await
            {
                if !fresh_servers.is_empty() {
                    let retry_selected = select_server(&fresh_servers, server, &translation_type, target_quality);
                    let retry_ordered = candidate_order(&fresh_servers, retry_selected);
                    for cand in retry_ordered.iter().take(MAX_PROBES) {
                        if let StreamProbe::Alive = probe_stream(&state.http_client, &cand.url, cand.headers.as_ref()).await {
                            log::info!("{}: session restart recovered a playable stream ('{}')", provider_name, cand.name);
                            timings.log(provider_name, media_id, episode_number, "ok-after-restart", started.elapsed().as_millis());
                            return Ok((cand.url.clone(), cand.headers.clone(), cand.subtitle_url.clone()));
                        }
                        last_dead = "still dead after session restart".to_string();
                    }
                }
            }
        }
    }

    timings.log(provider_name, media_id, episode_number, "all-dead", started.elapsed().as_millis());

    // Every server we probed answered with an unambiguous rejection. Report it
    // as a resolve failure so the caller moves on to the fallback provider —
    // returning the best-ranked dead URL anyway would just reproduce the bug
    // this probe exists to catch.
    Err(format!(
        "No playable stream on {} ({} of {} servers probed, last error: {})",
        provider_name,
        ordered.len().min(MAX_PROBES),
        ordered.len(),
        last_dead
    ))
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
    preload_episode_impl(state.inner(), media_id, episode_number, provider, title, crate::state::StreamClient::Mpv).await
}

pub async fn preload_episode_impl(
    state: &AppState,
    media_id: i64,
    episode_number: i64,
    provider: Option<String>,
    title: Option<String>,
    client: crate::state::StreamClient,
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
    if is_torrent_backed(&provider_name, media_id) && state.config.read().await.stream.data_saver {
        log::info!(
            "Low data mode: skipping torrent preload for media {} ep {}",
            media_id, episode_number
        );
        return Ok(());
    }

    // Already preloaded for this exact target — skip.
    {
        let slot = state.preloaded_stream.lock().await;
        if let Some(ref p) = *slot {
            if p.media_id == media_id && p.episode_number == episode_number && p.provider == provider_name && p.client == client {
                return Ok(());
            }
        }
    }

    // Nothing in the slot yet doesn't mean nothing is coming: the slot is only
    // filled when a resolve *finishes*, so the check above can't see a resolve
    // that is still running. Claim the target instead — see
    // AppStateInner::preloading.
    let Some(guard) = state.claim_preload(media_id, episode_number, &provider_name) else {
        log::info!(
            "Preload for media {} ep {} ({}) already in flight; skipping",
            media_id, episode_number, provider_name
        );
        return Ok(());
    };

    let state_inner = state.clone();
    tokio::spawn(async move {
        // Held for the whole resolve; dropping it releases the claim however
        // this task ends.
        let _guard = guard;
        match resolve_stream_for_provider(&state_inner, media_id, episode_number, &provider_name, &None, title, client).await {
            Ok((raw_url, headers, subtitle_url)) => {
                let mut slot = state_inner.preloaded_stream.lock().await;
                *slot = Some(crate::state::PreloadedStream {
                    media_id,
                    episode_number,
                    provider: provider_name.clone(),
                    client,
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

    // `current_playback` is deliberately NOT written here. It used to be, and
    // that made the slot describe an episode that had not started and might
    // never start:
    //
    //  - A resolve that fails returns Err below with the slot already moved on.
    //    `player_next_handler` computes the next episode from that slot, so the
    //    following Shift+N jumped past the episode that just failed.
    //  - Resolving can take tens of seconds. Progress/pause callbacks arriving
    //    from the still-playing previous episode during that window were
    //    attributed to this one.
    //  - The IPC-failure recovery path further down reads the slot to save the
    //    outgoing episode's position before respawning mpv — but the write here
    //    had already reset `last_position` to 0, so that save never fired.
    //
    // Every path that actually commits mpv to this episode (IPC reuse, fresh
    // spawn) writes the slot itself. The superseded-start bails deliberately
    // leave the previous episode's record alone, since the newer start owns it.
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
    // Kept so the superseded-start bails further down can hand the preloaded
    // entry back to the slot they took it out of — otherwise the racing call
    // that actually wins finds an empty slot and re-scrapes from scratch,
    // losing the instant transition in the one case it was built for.
    let mut consumed_preload: Option<crate::state::PreloadedStream> = None;

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
        //
        // The age limit was 15 minutes, which is generous for the signed CDN
        // URLs several of these providers hand out — an auto-next landing on an
        // expired one produced exactly the "next episode doesn't start" symptom,
        // and worse, taking the preload skips the resolve *and* its
        // fallback-provider chain, so nothing recovered. Three minutes covers
        // the case this exists for (the near-end preload, which fires at 85% of
        // an episode), and the probe below covers the rest.
        const PRELOAD_MAX_AGE: std::time::Duration = std::time::Duration::from_secs(3 * 60);

        // Auto-next routinely arrives while the near-end preload for the same
        // episode is still resolving. The slot is only filled on completion, so
        // checking it here would find nothing and this call would start a
        // second, competing resolve of the identical episode — both were
        // observed finishing within a second of each other, and on nyaa that
        // is two `add_torrent` + `update_only_files` rounds against one live
        // torrent, churning the piece selection out from under whatever mpv is
        // reading. Wait for the work already in progress instead.
        //
        // Bounded, and a timeout just falls through to resolving normally, so
        // a preload that never finishes cannot wedge playback.
        if state.preload_in_flight(media_id, episode_number, &provider_name) {
            // Was 20s. Observed live: a torrent resolve that had to wait out
            // nyaa's own rate limiting took 22s end to end, and a second one
            // -- competing with a duplicate resolve this exact guard exists
            // to prevent -- took 44s. At 20s the wait gives up before either
            // would have finished, falls through to "resolve normally", and
            // creates the identical race the comment above describes: two
            // add_torrent rounds against the same swarm, each also doubling
            // the nyaa search volume, which is a real contributor to the rate
            // limiting slowing both down in the first place. 60s comfortably
            // covers what was actually observed, with the fallback below
            // still standing as the ceiling for a preload that is genuinely
            // stuck rather than just slow.
            const PRELOAD_WAIT: std::time::Duration = std::time::Duration::from_secs(60);
            log::info!(
                "Waiting for the in-flight preload of media {} ep {} instead of resolving it twice",
                media_id, episode_number
            );
            let deadline = std::time::Instant::now() + PRELOAD_WAIT;
            while std::time::Instant::now() < deadline {
                tokio::time::sleep(std::time::Duration::from_millis(150)).await;
                if !state.preload_in_flight(media_id, episode_number, &provider_name) {
                    break;
                }
                // A newer start superseded this one; stop waiting and let the
                // guards further down bail out.
                if state.playback_generation.load(std::sync::atomic::Ordering::SeqCst) != playback_gen {
                    break;
                }
            }
        }

        let preloaded = {
            let mut slot = state.preloaded_stream.lock().await;
            match slot.take() {
                Some(p)
                    if p.media_id == media_id
                        && p.episode_number == episode_number
                        && p.provider == provider_name
                        // A browser-bound preload may be a release mpv would
                        // never have been given, and vice versa; taking the
                        // wrong one silently plays the wrong file.
                        && p.client == crate::state::StreamClient::Mpv
                        && p.at.elapsed() < PRELOAD_MAX_AGE =>
                {
                    Some(p)
                }
                other => {
                    *slot = other;
                    None
                }
            }
        };

        // Fresh enough is not the same as still working, so confirm the
        // preloaded URL is actually serving before committing mpv to it. A
        // dead one falls through to the full resolve (and therefore to the
        // fallback-provider chain) instead of being handed over blind. It is
        // deliberately not put back in the slot — it has been proven dead.
        //
        // A torrent-backed preload's failure mode isn't "CDN URL expired" —
        // it's "evicted from the session" (see torrent/mod.rs's cache cap) —
        // so it gets a direct, local, no-network-round-trip check instead of
        // probe_stream's HTTP range probe (built for, and only meaningful
        // against, an external CDN).
        let preloaded = match preloaded {
            Some(p) if p.raw_url.contains("/torrent-stream") => {
                let torrent_id = p.raw_url
                    .split("t=")
                    .nth(1)
                    .and_then(|s| s.split('&').next())
                    .and_then(|s| s.parse::<usize>().ok());
                let live = match torrent_id {
                    Some(id) => state.torrent.is_live(id).await,
                    None => false,
                };
                if live {
                    Some(p)
                } else {
                    log::warn!(
                        "Preloaded torrent stream for media {} ep {} is no longer in the session; re-resolving",
                        media_id, episode_number
                    );
                    None
                }
            }
            Some(p) => {
                match probe_stream(&state.http_client, &p.raw_url, p.headers.as_ref()).await {
                    StreamProbe::Alive => Some(p),
                    StreamProbe::Dead(reason) => {
                        log::warn!(
                            "Preloaded stream for media {} ep {} is dead ({}); re-resolving",
                            media_id, episode_number, reason
                        );
                        None
                    }
                }
            }
            None => None,
        };

        let (raw_stream_url, headers, sub_url) = if let Some(p) = preloaded {
            log::info!("Using preloaded stream for media {} ep {}", media_id, episode_number);
            consumed_preload = Some(p.clone());
            (p.raw_url, p.headers, p.subtitle_url)
        } else {
            let candidates = provider_fallback_chain(media_id, &provider_name, fallback_provider, secondary_fallback);
            let mut tried = Vec::new();
            let mut last_err = String::new();
            let mut resolved = None;

            for prov in candidates {
                if prov.is_empty() || prov == "none" || tried.contains(&prov) {
                    continue;
                }
                tried.push(prov.clone());

                match resolve_stream_for_provider(&state, media_id, episode_number, &prov, &server, title.clone(), crate::state::StreamClient::Mpv).await {
                    Ok(res) => {
                        if prov != provider_name {
                            // Note: don't write the working provider into
                            // current_playback here — at this point it still
                            // holds the *previous* episode's record, and this
                            // launch overwrites it wholesale further down.
                            // Reassigning provider_name below is what actually
                            // makes the fallback stick (and what auto-next and
                            // the near-end preload later read back).
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

    // Only now that a playable stream exists. Setting presence before the
    // resolve meant a play that failed to find any stream still advertised the
    // episode on Discord, with a running countdown, for an episode nobody was
    // watching.
    state.discord.set_presence(&title_str, episode_number, &episode_title_str, total_eps, resume_seconds, 0, false);

    // Sync AniList watching list after confirming stream is available — but
    // only when the entry isn't already CURRENT. Previously this fired a
    // SaveMediaListEntry on every episode launch; now it just moves
    // Planning/Paused/etc. into Watching and is a no-op for an already-watching
    // series.
    // Cinema ids have no AniList entry to move into Watching, and sending one
    // would edit whichever anime happens to share the number.
    if state.anilist_client.has_token() && media_id > 0 && crate::media_id::is_anilist(media_id) {
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
    // AniSkip indexes anime openings and endings, so it has nothing for a
    // film — and asking anyway is not free: the resolver falls back to a
    // Jikan title search and then retries mpv's IPC socket for several
    // seconds before giving up.
    if crate::media_id::is_anilist(media_id) {
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
    }

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
        //
        // `sub-file` is not a plain scalar option: mpv expands it to
        // `sub-files-append` (visible verbatim in mpv.log: "Setting option
        // 'sub-files-append' = ..."). So the per-file value below *adds* to
        // whatever the global sub-files list already holds — which, after a
        // launch that passed --sub-file, is the previous episode's VTT. That
        // left the next episode with two external subtitle tracks (the stale
        // one usually winning auto-selection), and when the next episode had
        // no VTT at all (torrent, dub server, a fallback provider) the stale
        // track survived on its own with nothing to override it. Clear the
        // list first, exactly like the referrer/user-agent/http-header-fields
        // resets above do, so each episode starts from an empty one.
        commands.push(serde_json::json!({
            "command": ["set_property", "sub-files", ""]
        }));
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
        //
        // The reverse transition needs an explicit reset, but only in one
        // case: mpv reverts per-file options when a file ends, so a torrent
        // episode loaded *through this path* doesn't leak its settings
        // onward. What does leak is a torrent episode that launched the mpv
        // process — those CLI args are globals for that process's lifetime.
        // An auto-next off such an episode onto a non-torrent stream (a
        // fallback provider, a mixed-provider series) then inherited
        // cache-pause-initial=yes and cache-pause-wait=30, so mpv sat
        // buffering 30s of an ordinary HLS stream before showing a frame —
        // the "doesn't play immediately" symptom. Restore what a fresh
        // non-torrent launch would have had: mpv's own defaults, plus copies
        // of the two demuxer values mpv.conf sets. Those copies are the
        // tradeoff — editing mpv.conf no longer reaches this path, so change
        // both together.
        if is_torrent_stream {
            load_options.push_str(
                ",network-timeout=0,cache=yes,cache-pause=yes,cache-pause-initial=yes,\
                 cache-pause-wait=30,demuxer-max-bytes=1GiB,demuxer-max-back-bytes=256MiB,\
                 demuxer-readahead-secs=120,force-seekable=yes",
            );
        } else {
            load_options.push_str(
                ",network-timeout=60,cache=auto,cache-pause=yes,cache-pause-initial=no,\
                 cache-pause-wait=1,demuxer-max-bytes=128MiB,demuxer-max-back-bytes=48MiB,\
                 demuxer-readahead-secs=15,force-seekable=no",
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

        // Last request wins. Resolving a stream can take tens of seconds (a
        // cold torrent worst-case is ~85s), and nothing upstream serialized
        // starts: pressing Shift+N while an auto-next was still resolving, or
        // clicking another episode in the app, left two resolvers racing to
        // send their own `loadfile … replace` at whatever moment each
        // finished. The later one could land first and then be stomped by the
        // older one, so mpv ended up on an episode nobody asked for while
        // current_playback described the other. `playback_generation` already
        // marks which start is newest (the AniSkip pusher checks it) — check
        // it here too, right before the IPC write that actually changes what
        // mpv is playing.
        if state.playback_generation.load(std::sync::atomic::Ordering::SeqCst) != playback_gen {
            log::info!(
                "Superseded by a newer playback start; not sending loadfile for media {} ep {}",
                media_id, episode_number
            );
            restore_preload(&state, consumed_preload.take()).await;
            return Ok(PlaybackStart { stream_url });
        }

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

    // Same last-request-wins check as the IPC reuse path above, before the
    // irreversible part (killing the running mpv and spawning a new one).
    if state.playback_generation.load(std::sync::atomic::Ordering::SeqCst) != playback_gen {
        log::info!(
            "Superseded by a newer playback start; not launching mpv for media {} ep {}",
            media_id, episode_number
        );
        restore_preload(&state, consumed_preload.take()).await;
        return Ok(PlaybackStart { stream_url });
    }

    kill_current_mpv().await;

    log::info!("Launching mpv command: {:?}", cmd);
    let mut child = cmd
        .spawn()
        .map_err(|e| format!("Failed to launch mpv: {}", e))?;

    let pid = child.id().unwrap_or(0);
    log::info!("Launched mpv pid={} with stream: {}", pid, stream_url);
    let spawn_instant = std::time::Instant::now();

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
            // `None` status means "exited, but we never saw how" (monitor lost
            // the handle, or try_wait itself failed) — not treated as a crash.
            let (exited, exit_status) = {
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
                        Ok(Some(status)) => {
                            let _ = guard.take();
                            (true, Some(status))
                        }
                        Ok(None) => (false, None),
                        Err(e) => {
                            log::warn!(
                                "mpv exit monitor: try_wait failed for media {} ep {}, treating as exited: {}",
                                monitor_media_id, monitor_episode, e
                            );
                            let _ = guard.take();
                            (true, None)
                        }
                    },
                    None => (true, None),
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

                // mpv surviving the initial 500ms grace check only proves the
                // process didn't crash instantly — it can still die a few
                // seconds later (bad/expired stream URL, dylib load failure,
                // Cloudflare hiccup) after the loading modal has already
                // dismissed itself on the earlier `active:true`. Without this,
                // that later failure was silent: the modal was long gone and
                // nothing told the user mpv never actually opened.
                //
                // Gate on a non-zero exit code, not just the time window:
                // quitting mpv within a few seconds (wrong episode, changed
                // one's mind) is completely normal and exits 0, and reporting
                // that as a failure would fire constantly.
                let crashed = exit_status.is_some_and(|s| !s.success());
                if crashed && spawn_instant.elapsed() < std::time::Duration::from_secs(8) {
                    log::warn!(
                        "mpv exited with {:?} only {:?} after launch (media {} ep {}) — surfacing as a failed launch",
                        exit_status, spawn_instant.elapsed(), monitor_media_id, monitor_episode
                    );
                    let _ = app_handle.emit("playback_loading_status", serde_json::json!({
                        "status": "error",
                        "step": 0,
                        "message": "Player closed unexpectedly. Try another server or provider.",
                        "media_id": monitor_media_id,
                        "episode_number": monitor_episode,
                    }));
                }

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

    // A torrent-backed stream's `file-loaded` can be minutes away (see
    // wait_for_mpv_window's doc comment) — firing `active:true` right here,
    // as soon as the process merely survived its first 500ms, is the "fake"
    // dismissal: the loading modal closes while mpv still shows no window at
    // all. Gate it on the real readiness signal instead, in the background so
    // this command still returns immediately. Non-torrent providers keep the
    // old instant behavior; their streams don't have this failure mode.
    if is_torrent_stream {
        let ready_app = app.clone();
        let ready_state = (*state).clone();
        let ready_ipc_path = get_ipc_path();
        tokio::spawn(async move {
            let wait_started = std::time::Instant::now();
            // 10 minutes: generous enough for a genuinely slow swarm to
            // deliver whatever the demuxer's probe seeked to, without leaving
            // the modal open forever if `file-loaded` is somehow never seen.
            let loaded = wait_for_mpv_window(&ready_ipc_path, std::time::Duration::from_secs(600)).await;
            log::info!(
                "torrent: mpv readiness wait for media {} ep {} finished in {:?}, loaded={}",
                media_id, episode_number, wait_started.elapsed(), loaded
            );

            if ready_state.playback_generation.load(std::sync::atomic::Ordering::SeqCst) != playback_gen {
                // A newer start_playback already took over `active`; let it
                // own the signal instead of stomping on it from here.
                log::info!("torrent: readiness wait superseded for media {} ep {}; not emitting", media_id, episode_number);
                return;
            }

            if !loaded {
                // Either mpv exited before loading -- the exit monitor above
                // already emitted `active:false` and any failure message --
                // or the wait timed out. Only the timeout-while-still-alive
                // case needs an emit here, so the UI isn't stuck behind the
                // modal forever despite mpv actually running.
                let still_running = matches!(CURRENT_MPV.lock(), Ok(guard) if guard.is_some());
                if !still_running {
                    log::info!("torrent: mpv no longer running for media {} ep {}; exit monitor owns active:false", media_id, episode_number);
                    return;
                }
                log::warn!("torrent: readiness wait timed out but mpv is still running for media {} ep {}; emitting active:true anyway", media_id, episode_number);
            }
            emit_playback_active(&ready_app, true);
        });
    } else {
        emit_playback_active(&app, true);
    }

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

    // Everything past this point talks to AniList, including the cache lookup
    // below — `get_user_list_progress` is keyed by bare media_id, so a cinema
    // id would read a slot that means nothing. The local write above is
    // correct for every catalog (resume has to work in cinema mode too); the
    // AniList half simply has nowhere to go for a movie or a series.
    if !crate::media_id::is_anilist(media_id) {
        // Cinema mode's library lives in SQLite rather than on a tracking
        // service. Trakt would have been the counterpart to AniList here, but
        // creating an API application for it now requires a paid account, so
        // the local table -- which has existed unused since before cinema mode
        // -- carries watched state instead.
        if duration > 0 && is_watched(stop_time, duration) {
            let source = crate::media_id::source_of(media_id);
            // A film is one episode, so finishing it finishes the title. A
            // series is only complete once the last episode is watched, and
            // total_episodes is what the caller counted.
            let complete = source == crate::media_id::MediaSource::TmdbMovie
                || (total_episodes > 0 && episode_number >= total_episodes);
            if let Err(e) = super::media::add_to_library_impl(
                state,
                user_id,
                media_id,
                if source == crate::media_id::MediaSource::TmdbMovie { "MOVIE" } else { "TV" }.to_string(),
                Some(if complete { "COMPLETED" } else { "CURRENT" }.to_string()),
                None,
                Some(episode_number as i32),
                None,
            )
            .await
            {
                log::error!("Failed to record cinema library entry for {}: {}", media_id, e);
            }
        }
        return Ok(());
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
    use super::{
        candidate_order, is_torrent_backed, is_watched, looks_like_playlist, parse_playlist,
        probe_status_is_dead, probe_status_is_permanent, provider_fallback_chain, resume_position,
        sample_indices, PlaylistStep,
    };
    use crate::scraper::client::StreamServer;

    fn server(name: &str, url: &str, quality: &str) -> StreamServer {
        StreamServer {
            name: name.to_string(),
            url: url.to_string(),
            quality: Some(quality.to_string()),
            is_m3u8: None,
            headers: None,
            group: None,
            subtitle_url: None,
            browser_ok: None,
        }
    }

    /// The browser filter is `retain(|s| s.browser_ok.unwrap_or(true))`, and
    /// the `unwrap_or(true)` is the load-bearing half: providers that don't
    /// report the field (mkissa, and any older frozen sidecar still in the
    /// wild) must keep working exactly as before rather than silently
    /// resolving to nothing on mobile.
    #[test]
    fn browser_filter_keeps_servers_that_dont_report_the_field() {
        let mut servers = vec![
            server("HD-1", "https://vivibebe.site/public/stream/a/master.m3u8", "1080p"),
            server("StreamHG", "https://x.rivercrestlearningstudio.store/a/master.txt", "1080p"),
            server("Legacy", "https://mp4upload.com/a.mp4", "1080p"),
        ];
        servers[0].browser_ok = Some(true);
        servers[1].browser_ok = Some(false);
        // servers[2] leaves it None — a provider predating the field.

        servers.retain(|s| s.browser_ok.unwrap_or(true));
        assert_eq!(
            servers.iter().map(|s| s.name.as_str()).collect::<Vec<_>>(),
            ["HD-1", "Legacy"],
        );
    }

    /// Doodstream's resolved "url" is an embed page, confirmed by inspecting
    /// anineko's own player (it iframes the identical URL rather than
    /// resolving it further) -- mpv given that url exits immediately, a hard
    /// crash rather than the dead-server case the probe below already
    /// recovers from. Name match, case-insensitive: the scraper's own label
    /// for it, seen as both "Doodstream" and "DoodStream" across responses.
    #[test]
    fn doodstream_is_dropped_before_it_can_reach_mpv() {
        let servers = vec![
            server("HD-2", "https://vivibebe.site/public/stream/b/master.m3u8", "1080p"),
            server("DoodStream", "https://playmogo.com/e/lw8bsfx2aj15", "1080p"),
            server("Earnvids", "https://earnvids.example/a.mp4", "1080p"),
        ];
        let mut filtered = servers;
        filtered.retain(|s| !s.name.eq_ignore_ascii_case("doodstream"));
        assert_eq!(
            filtered.iter().map(|s| s.name.as_str()).collect::<Vec<_>>(),
            ["HD-2", "Earnvids"],
        );
    }

    #[test]
    fn dropping_doodstream_from_an_all_doodstream_list_fails_cleanly() {
        // The scenario that actually crashed: every preferred server was
        // dead, and Doodstream -- the only one left -- was not really a
        // candidate either. The right outcome is an empty list (which the
        // caller turns into "No stream URL found"), not a fallback onto the
        // one entry that was never playable.
        let servers = vec![server("Doodstream", "https://playmogo.com/e/x", "1080p")];
        let mut filtered = servers;
        filtered.retain(|s| !s.name.eq_ignore_ascii_case("doodstream"));
        assert!(filtered.is_empty());
    }

    #[test]
    fn playlist_detection_covers_the_hosts_in_use() {
        assert!(looks_like_playlist("https://vivibebe.site/public/stream/a/master.m3u8"));
        // anineko's jwplayer hosts serve playlists named master.txt.
        assert!(looks_like_playlist("https://x.example.com/a/hls3/01/master.txt"));
        // A query string must not hide the extension.
        assert!(looks_like_playlist("https://x.example.com/a/master.m3u8?t=abc"));
        // Media, and the local torrent endpoint, are not playlists.
        assert!(!looks_like_playlist("https://p16-ad-sg.ibyteimg.com/obj/ad-site-i18n/abc"));
        assert!(!looks_like_playlist("http://127.0.0.1:13370/torrent-stream?t=0&f=0"));
    }

    #[test]
    fn playlist_entries_resolve_against_the_playlist_url() {
        let master = "https://vivibebe.site/public/stream/a5be/master.m3u8";
        // Relative variants, as vivibebe writes them. The probe must follow the
        // *highest* bandwidth, not the first listed: HD-1's ad CDN revokes
        // segments per variant, and 360p (listed first) stays healthy while the
        // 1080p the player actually plays is half dead.
        let body = concat!(
            "#EXTM3U\n",
            "#EXT-X-STREAM-INF:BANDWIDTH=800000,RESOLUTION=640x360,NAME=\"360p\"\n",
            "321843360.m3u8\n",
            "#EXT-X-STREAM-INF:BANDWIDTH=5500000,RESOLUTION=1920x1080,NAME=\"1080p\"\n",
            "3218431080.m3u8\n",
        );
        assert_eq!(
            parse_playlist(master, body),
            PlaylistStep::Variant(
                "https://vivibebe.site/public/stream/a5be/3218431080.m3u8".into()
            )
        );
        // Absolute segments on a different host — the case that matters, since
        // the segments live on an ad CDN, not on the playlist's host.
        let body = concat!(
            "#EXTM3U\n",
            "#EXTINF:18.2,\nhttps://p16-ad-sg.ibyteimg.com/obj/ad-site-i18n/a\n",
            "#EXTINF:18.2,\nhttps://p16-ad-sg.ibyteimg.com/obj/ad-site-i18n/b\n",
        );
        assert_eq!(
            parse_playlist(master, body),
            PlaylistStep::Segments(vec![
                "https://p16-ad-sg.ibyteimg.com/obj/ad-site-i18n/a".into(),
                "https://p16-ad-sg.ibyteimg.com/obj/ad-site-i18n/b".into(),
            ])
        );
        // Comments/tags only, or empty: nothing to probe, so the caller must
        // fall back to Alive rather than invent a verdict.
        assert_eq!(
            parse_playlist(master, "#EXTM3U\n#EXT-X-ENDLIST\n"),
            PlaylistStep::Unknown
        );
        assert_eq!(parse_playlist(master, ""), PlaylistStep::Unknown);
        // A master without BANDWIDTH still has to yield a variant rather than
        // being mistaken for a segment list.
        assert_eq!(
            parse_playlist(master, "#EXTM3U\n#EXT-X-STREAM-INF:RESOLUTION=1x1\nv.m3u8\n"),
            PlaylistStep::Variant("https://vivibebe.site/public/stream/a5be/v.m3u8".into())
        );
    }

    #[test]
    fn segment_samples_span_the_whole_playlist() {
        // First, last and two in between: a stream whose opening plays and
        // whose middle is revoked must not pass on the strength of segment 0.
        assert_eq!(sample_indices(148, 8), vec![0, 21, 42, 63, 84, 105, 126, 147]);
        // Short playlists degrade to "every segment", never out of bounds.
        assert_eq!(sample_indices(3, 8), vec![0, 1, 2]);
        assert_eq!(sample_indices(1, 8), vec![0]);
        assert!(sample_indices(0, 8).is_empty());
    }

    #[test]
    fn probe_treats_only_definitive_rejections_as_dead() {
        for dead in [403, 404, 410, 451, 500, 502, 503] {
            assert!(probe_status_is_dead(dead), "{} should be dead", dead);
        }
        // A false negative skips a server that plays fine, so everything
        // ambiguous has to stay alive: 2xx, an unfollowed redirect, a host that
        // rejects Range with 405, and rate limiting.
        for alive in [200, 206, 302, 405, 416, 429] {
            assert!(!probe_status_is_dead(alive), "{} should be alive", alive);
        }
        // Only the per-asset rejections are permanent enough that a single one
        // condemns a stream. A 5xx may be the host having a bad second, and
        // still needs the rest of the sample to agree.
        for permanent in [403, 404, 410, 451] {
            assert!(probe_status_is_permanent(permanent), "{} is per-asset", permanent);
        }
        for transient in [500, 502, 503] {
            assert!(!probe_status_is_permanent(transient), "{} is transient", transient);
        }
    }

    #[test]
    fn candidate_order_keeps_the_chosen_server_first() {
        // wixstatic outranks mp4upload on speed, but the preference logic
        // picked the mp4upload one (sub/dub group, or an explicit user pick).
        // Probing must not quietly override that choice.
        let servers = vec![
            server("fast", "https://wixstatic.com/a.mp4", "1080p"),
            server("chosen", "https://mp4upload.com/b.mp4", "1080p"),
        ];
        let ordered = candidate_order(&servers, Some(&servers[1]));
        assert_eq!(
            ordered.iter().map(|s| s.name.as_str()).collect::<Vec<_>>(),
            vec!["chosen", "fast"]
        );
    }

    #[test]
    fn candidate_order_dedupes_by_url_and_ranks_the_rest() {
        // The scraper's four extraction passes routinely surface one URL under
        // several names; retrying the same dead URL twice would waste a probe.
        let servers = vec![
            server("slow", "https://elsewhere.example/c.mp4", "1080p"),
            server("dupe-of-fast", "https://wixstatic.com/a.mp4", "1080p"),
            server("fast", "https://wixstatic.com/a.mp4", "1080p"),
        ];
        let ordered = candidate_order(&servers, Some(&servers[2]));
        assert_eq!(
            ordered.iter().map(|s| s.url.as_str()).collect::<Vec<_>>(),
            vec!["https://wixstatic.com/a.mp4", "https://elsewhere.example/c.mp4"]
        );
    }

    #[test]
    fn candidate_order_drops_empty_urls() {
        // The nyaa picker emits sentinel entries with an empty url, resolved
        // lazily on pick — probing one would be a guaranteed wasted request.
        let servers = vec![
            server("sentinel", "", "1080p"),
            server("real", "https://wixstatic.com/a.mp4", "1080p"),
        ];
        let ordered = candidate_order(&servers, None);
        assert_eq!(ordered.len(), 1);
        assert_eq!(ordered[0].name, "real");
    }

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
    fn a_cinema_play_counts_as_torrent_backed_whatever_the_anime_provider_is() {
        let film = crate::media_id::encode(crate::media_id::MediaSource::TmdbMovie, 693134).unwrap();
        let series = crate::media_id::encode(crate::media_id::MediaSource::TmdbTv, 94997).unwrap();

        // The guards this feeds (Low Data Mode, on both the detail-page
        // preload and the auto-next preload) used to ask only whether the
        // provider was nyaa. `general.provider` describes the anime world, so
        // with anineko configured a film would start a real torrent download
        // with Low Data Mode on -- the exact thing the guard exists to stop.
        assert!(is_torrent_backed("anineko", film));
        assert!(is_torrent_backed("anineko", series));
        assert!(is_torrent_backed("nyaa", film));

        // Anime is unchanged: still decided by the provider alone.
        assert!(is_torrent_backed("nyaa", 21202));
        assert!(!is_torrent_backed("anineko", 21202));
        assert!(!is_torrent_backed("mangakatana", 21202));
    }

    #[test]
    fn a_cinema_id_never_retries_under_a_second_anime_provider_label() {
        // Observed live: a film failed once under "nyaa", then the loop tried
        // it again under "anineko" -- same is_cinema() branch, same apibay
        // search, same failure, a second full timeout, and a log line
        // claiming anineko had an opinion about a TMDB id it has never seen.
        let film = crate::media_id::encode(crate::media_id::MediaSource::TmdbMovie, 693134).unwrap();
        let chain = provider_fallback_chain(film, "nyaa", "anineko".into(), "none".into());
        assert_eq!(chain, vec!["nyaa".to_string()]);
    }

    #[test]
    fn an_anime_id_still_gets_the_full_fallback_chain() {
        let chain = provider_fallback_chain(21202, "nyaa", "anineko".into(), "none".into());
        assert_eq!(chain, vec!["nyaa".to_string(), "anineko".to_string(), "none".to_string()]);
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

