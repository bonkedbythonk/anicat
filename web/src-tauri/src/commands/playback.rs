use std::collections::HashMap;

use serde::Serialize;
use serde_json::Value;
use tauri::{AppHandle, Emitter, Manager, State};

use crate::source::{StreamSource, TorrentIndex};
use crate::util::percent_encode;
use crate::state::AppState;

static CURRENT_MPV: std::sync::Mutex<Option<tokio::process::Child>> = std::sync::Mutex::new(None);

/// Which mpv process the exit monitor below is allowed to speak for.
///
/// Bumped by `kill_current_mpv`, so every monitor can tell "the process I was
/// watching exited" from "the process I was watching was replaced". The two
/// look identical from inside the monitor -- `CURRENT_MPV` is empty either
/// way -- and treating the second as the first is what made auto-next fail
/// intermittently.
///
/// Any start that cannot hand its stream to a running mpv over IPC kills the
/// old process and spawns a new one. The old instance's monitor then observes
/// an empty `CURRENT_MPV`, waits its 2s "let the Lua script report position"
/// grace, and runs a teardown that by then belongs to the *new* episode:
/// `current_playback = None`, `emit_playback_active(false)`, and
/// `torrent.pause_all()`. Every player callback silently no-ops afterwards --
/// the next `next` request logs "No current playback session found for next
/// episode request", and the torrent sits paused at whatever percentage it
/// had reached, neither downloading nor seeding, while mpv plays on out of
/// its already-buffered bytes.
static MPV_GENERATION: std::sync::atomic::AtomicU64 = std::sync::atomic::AtomicU64::new(0);

/// When mpv was last handed an actual file to open.
///
/// The exit monitor reports a launch failure only when mpv dies within a few
/// seconds of being given something to play. That used to be the same instant
/// as the spawn, because the stream URL was in the argv -- but the window is
/// now put on screen *before* the stream is resolved, so the process is
/// routinely tens of seconds old by the time a `loadfile` reaches it. Measured
/// from the spawn, a cold play whose stream mpv could not open fell outside
/// the window and reported nothing at all, while `--idle=once` quit the player
/// and the ordinary teardown dismissed the toast on the way out.
static MPV_FILE_HANDOVER: std::sync::Mutex<Option<std::time::Instant>> =
    std::sync::Mutex::new(None);

/// The `MPV_GENERATION` of a window that was raised idle and has not been
/// handed a file yet; 0 when there is no such window.
///
/// Not the same question as "did *this* call raise the window". A start that
/// is superseded leaves its idle window up on purpose, for the newer start to
/// reuse -- so when it is the *newer* start whose resolve comes back empty,
/// the window to take down is one it never spawned. Tracking the window rather
/// than the caller is what stops that case leaving a black `--ontop` window
/// with nothing behind it and nobody who considers it theirs.
static IDLE_MPV_GENERATION: std::sync::atomic::AtomicU64 =
    std::sync::atomic::AtomicU64::new(0);

/// Records that mpv has just been given a file. Called from every path that
/// commits a running player to a stream.
fn record_mpv_file_handover() {
    {
        let mut guard = match MPV_FILE_HANDOVER.lock() {
            Ok(g) => g,
            Err(e) => e.into_inner(),
        };
        *guard = Some(std::time::Instant::now());
    }
    // Whatever window is up, it is no longer an empty one waiting on a
    // resolve, so nothing may take it down as if it were.
    IDLE_MPV_GENERATION.store(0, std::sync::atomic::Ordering::SeqCst);
}

/// The instant the running mpv was given a file, or its spawn instant when it
/// has not been given one yet. A handover recorded before this process started
/// belongs to the previous player, so it is ignored rather than trusted.
fn mpv_launch_reference(spawn_instant: std::time::Instant) -> std::time::Instant {
    let guard = match MPV_FILE_HANDOVER.lock() {
        Ok(g) => g,
        Err(e) => e.into_inner(),
    };
    match *guard {
        Some(at) if at > spawn_instant => at,
        _ => spawn_instant,
    }
}

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

/// Tells the webview what the backend now holds for one episode.
///
/// The store's `preloadStatus` map is push-fed and never polled while a detail
/// page is open, so every path that empties, refuses or refills the single
/// preload slot has to call this. A missing "idle" is not a cosmetic drift: the
/// episode list refuses to re-preload anything the map still calls "ready", so
/// one unreported eviction leaves that episode cold *and* unwarmable for the
/// rest of the session.
pub(crate) fn emit_preload_status(
    app: Option<&AppHandle>,
    media_id: i64,
    episode_number: i64,
    status: &str,
) {
    let Some(app) = app else { return };
    let _ = app.emit(
        "stream_preload_status",
        serde_json::json!({
            "media_id": media_id,
            "episode_number": episode_number,
            "status": status,
        }),
    );
}

/// Puts a preloaded stream back after a start that took it out of the slot
/// but then bailed (superseded by a newer start). Only fills an empty slot:
/// whatever a later preload has already put there is fresher by definition.
async fn restore_preload(
    state: &AppState,
    app: Option<&AppHandle>,
    entry: Option<crate::state::PreloadedStream>,
) {
    let Some(entry) = entry else { return };
    let (media_id, episode_number) = (entry.media_id, entry.episode_number);
    let restored = {
        let mut slot = state.preloaded_stream.lock().await;
        if slot.is_none() {
            *slot = Some(entry);
            true
        } else {
            false
        }
    };
    // Taking it out already reported it gone, so a successful put-back has to
    // report it back — otherwise the survivor of a double press finds the
    // stream ready in the slot while the webview still calls that episode cold.
    if restored {
        emit_preload_status(app, media_id, episode_number, "ready");
    }
}

/// A short, honest reason a transition failed, for the player's OSD.
///
/// Every failure of the next/prev path used to arrive as "No more episodes
/// available." -- the same sentence the *genuine* end of a season uses. A
/// resolve that found nothing, a swarm with no seeders, a player that died on
/// launch and an actually-finished show were indistinguishable, so the honest
/// report "next episode is unreliable" reached the user as "the app thinks the
/// show is over" and the real cause was never looked for.
///
/// The full error is already in the log; this is the one line that fits on an
/// OSD, so it names the episode (which says outright that the show is *not*
/// over) and buckets the cause. The fallback carries the real error text
/// rather than a vague apology, truncated so a long provider-chain message
/// can't paint over the video.
pub(crate) fn transition_failure_message(episode: i64, err: &str) -> String {
    let lower = err.to_lowercase();
    let reason = if lower.contains("no stream") || lower.contains("no torrent") || lower.contains("no hd torrent") || lower.contains("not found inside torrent") {
        "no release found".to_string()
    } else if lower.contains("pre-buffer") || lower.contains("no seeders") || lower.contains("timed out") || lower.contains("dead") {
        "source timed out".to_string()
    } else if lower.contains("mpv exited") {
        "the player failed to start".to_string()
    } else {
        const MAX: usize = 90;
        let mut short: String = err.chars().take(MAX).collect();
        if err.chars().count() > MAX {
            short.push('\u{2026}');
        }
        short
    };
    format!("Episode {} failed to load: {}.", episode, reason)
}

/// How long a reused mpv gets to report that it opened the new episode.
///
/// Generous on purpose. The stream was pre-buffered before the URL was handed
/// over, so a healthy transition confirms in seconds -- but opening an MKV over
/// the torrent-stream endpoint can mean seeking to read a Cues element near the
/// end of the file, which on a thin swarm is genuinely slow. Rolling the
/// counter back on an episode that was merely slow would be a worse bug than
/// the one this fixes, so the bound sits well past the player's own 100s
/// give-up window: past this, the transition has definitively not happened.
const LOAD_CONFIRM_TIMEOUT: std::time::Duration = std::time::Duration::from_secs(180);

/// Waits for mpv's own `file-loaded` for this exact episode (see
/// `/player/loaded`). `false` means it never arrived.
async fn confirm_playing(
    state: &AppState,
    media_id: i64,
    episode_number: i64,
    playback_gen: u64,
) -> bool {
    let deadline = std::time::Instant::now() + LOAD_CONFIRM_TIMEOUT;
    while std::time::Instant::now() < deadline {
        {
            let slot = state.confirmed_playing.lock().await;
            if *slot == Some((media_id, episode_number)) {
                return true;
            }
        }
        // A newer start owns the player now; this one's outcome is no longer
        // anyone's business and rolling anything back would fight it.
        if state.playback_generation.load(std::sync::atomic::Ordering::SeqCst) != playback_gen {
            return true;
        }
        tokio::time::sleep(std::time::Duration::from_millis(250)).await;
    }
    false
}

/// Puts the episode bookkeeping back after a transition mpv never completed,
/// on both sides: the backend's `current_playback` and the player's own
/// `current_episode` script-opt, which is what the next/prev handlers read to
/// decide where to go next.
async fn rollback_failed_transition(
    state: &AppState,
    app: &AppHandle,
    outgoing: Option<crate::state::CurrentPlayback>,
    media_id: i64,
    episode_number: i64,
    playback_gen: u64,
) {
    if state.playback_generation.load(std::sync::atomic::Ordering::SeqCst) != playback_gen {
        return;
    }
    log::warn!(
        "mpv never reported opening media {} ep {}; rolling the episode back",
        media_id, episode_number
    );

    let restored_episode = outgoing.as_ref().map(|pb| pb.episode_number);
    {
        let mut guard = state.current_playback.lock().await;
        // Only if nothing newer has claimed the slot in the meantime.
        let stale = guard
            .as_ref()
            .map(|pb| pb.media_id == media_id && pb.episode_number == episode_number)
            .unwrap_or(false);
        if stale {
            *guard = outgoing;
        }
    }

    if let Some(episode) = restored_episode {
        // `change-list … append` rather than a whole-map `set_property`: the
        // other keys in script-opts are still correct and a replace would drop
        // every one this call didn't happen to know about.
        let put_back = serde_json::json!({
            "command": [
                "change-list", "script-opts", "append",
                format!("anicat_ui-current_episode={}", episode)
            ]
        });
        if let Err(e) = try_send_ipc(&get_ipc_path(), vec![put_back]).await {
            log::error!("Failed to roll the player's episode number back: {}", e);
        }
    }

    let message = transition_failure_message(episode_number, "the player did not open the stream");
    if let Err(e) = cancel_mpv_next(&message).await {
        log::error!("Failed to report the failed transition to mpv: {}", e);
    }
    use tauri::Emitter;
    let _ = app.emit("show_notification", serde_json::json!({ "message": message }));
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

#[tauri::command]
pub async fn mpv_ipc_command(command: Vec<serde_json::Value>) -> Result<(), String> {
    let ipc_path = get_ipc_path();
    let payload = serde_json::json!({ "command": command });
    try_send_ipc(&ipc_path, vec![payload]).await
}

/// Tells the webview whether the external mpv window is open. Low Data Mode
/// uses this to pause background traffic (home polling, hover prefetch) while
/// a stream is running. Emitted on successful playback start (fresh spawn or
/// IPC reuse) and from the exit monitor when mpv closes.
fn emit_playback_active(app: &AppHandle, active: bool) {
    let _ = app.emit("anicat_playback_state", serde_json::json!({ "active": active }));
}

/// Whether a monitor holding `generation` is still speaking for the mpv
/// process that is actually running.
fn mpv_generation_is_current(generation: u64) -> bool {
    MPV_GENERATION.load(std::sync::atomic::Ordering::SeqCst) == generation
}

/// The generation a freshly launched mpv owns.
fn current_mpv_generation() -> u64 {
    MPV_GENERATION.load(std::sync::atomic::Ordering::SeqCst)
}

pub async fn kill_current_mpv() {
    // Before the handle is taken, so a monitor that wakes up mid-kill already
    // sees a generation it doesn't own rather than an empty CURRENT_MPV it
    // mistakes for its own process exiting.
    MPV_GENERATION.fetch_add(1, std::sync::atomic::Ordering::SeqCst);
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

pub(crate) fn resolve_mpv_path(app: &AppHandle) -> Result<(String, String, String), String> {
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
        // macOS: the same binary, but launched from inside the mpv.app that
        // scripts/make_mpv_app.sh assembles, so it has an Info.plist and the
        // Dock shows anicat's player icon instead of the generic placeholder.
        // Its dylibs still live in the flat lib/ beside the bundle: the load
        // commands read `@executable_path/lib`, which points nowhere two
        // directories deeper, so the DYLD_LIBRARY_PATH set at spawn is what
        // actually resolves them.
        #[cfg(target_os = "macos")]
        {
            let app_dir = base.join("mpv.app");
            let app_bin = app_dir.join("Contents").join("MacOS").join("mpv");
            if app_bin.exists() {
                log::info!("Using bundled mpv.app at: {}", app_bin.display());
                strip_quarantine_once(&app_dir, &lib_dir);
                return Ok((
                    app_bin.to_string_lossy().to_string(),
                    config_dir,
                    strip_verbatim_prefix(lib_dir.to_string_lossy().to_string()),
                ));
            }
        }
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
        let known = [
            "/Applications/mpv.app/Contents/MacOS/mpv",
            "/opt/homebrew/bin/mpv",
            "/usr/local/bin/mpv",
            "/usr/bin/mpv",
        ];
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
    let dev_resources = std::path::Path::new(env!("CARGO_MANIFEST_DIR")).join("resources");
    let dev_lib_dir = dev_resources.join("lib");
    #[cfg(target_os = "macos")]
    {
        let dev_app_dir = dev_resources.join("mpv.app");
        let dev_app_bin = dev_app_dir.join("Contents").join("MacOS").join("mpv");
        if dev_app_bin.exists() {
            log::info!("Using dev-tree mpv.app at: {}", dev_app_bin.display());
            strip_quarantine_once(&dev_app_dir, &dev_lib_dir);
            return Ok((
                dev_app_bin.to_string_lossy().to_string(),
                config_dir,
                dev_lib_dir.to_string_lossy().to_string(),
            ));
        }
    }
    let dev_path = dev_resources.join(mpv_name);
    if dev_path.exists() {
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

/// Move the last launch's mpv log aside, right before mpv truncates it.
///
/// mpv rewrites --log-file from scratch on every launch, and auto-next
/// relaunches it per episode, so by the time anyone goes looking the log of
/// the player that actually misbehaved is gone -- an mpv that grew to 140 GB
/// and was jetsam-killed left nothing at all behind. One kept generation
/// covers "the player before this one", which is the case that matters.
/// Called only from the launch path: `mpv_log_path` itself is read in log
/// messages and must stay free of side effects.
fn rotate_mpv_log(current: &str) {
    let path = std::path::Path::new(current);
    if !path.exists() {
        return;
    }
    let _ = std::fs::rename(path, path.with_file_name("mpv.prev.log"));
}

/// The complete `anicat_ui-` script-opts map, built in exactly one place.
///
/// `set_property script-opts` *replaces* the map rather than merging into it,
/// so a key one writer sets and another forgets is deleted from the running
/// player instead of left alone -- `shader_profile` was once exactly that, and
/// a reused mpv silently dropped upscaling for the rest of a binge. Three
/// callers write the whole map (the idle launch, the full launch, and the
/// episode-transition IPC batch); building it here is what stops them
/// drifting. The key set has to stay equal to the `opts` table main.lua
/// declares.
///
/// `skip_times` is always present, empty included: without the key the Lua
/// observer falls back to whatever the *previous* episode's value was.
// One argument per key by design: the map is the point, and hiding half of it
// behind a struct would put the drift this function exists to prevent back one
// level down.
#[allow(clippy::too_many_arguments)]
fn build_script_opts(
    proxy_port: u16,
    media_id: i64,
    skip_times: &str,
    autoskip: bool,
    auto_next: bool,
    episode_number: i64,
    total_episodes: i64,
    shader_profile: &str,
) -> String {
    // Where the Lua script sends its callbacks. It used to hardcode 13370, but
    // the proxy only *prefers* that port -- when something else already holds
    // it, `proxy::server::start` falls back to an OS-assigned one (and says so
    // in the log). The stream URL is built from the real port, so video played
    // perfectly while every callback went to whatever else owned 13370: no
    // progress, no resume position, no watched detection, no preload, and
    // next/prev doing nothing at all. Exactly the "playback works but the app
    // forgets everything" report, and invisible unless you thought to check
    // `lsof -i :13370`.
    let parts = [
        format!("anicat_ui-proxy_port={}", proxy_port),
        format!("anicat_ui-media_id={}", media_id),
        // Commas are mpv's own --script-opts delimiter, so an encoded comma is
        // the only way a multi-segment skip list survives the parse.
        format!("anicat_ui-skip_times={}", skip_times.replace(',', "%2C")),
        format!("anicat_ui-autoskip={}", if autoskip { "yes" } else { "no" }),
        format!("anicat_ui-auto_next={}", if auto_next { "yes" } else { "no" }),
        format!("anicat_ui-current_episode={}", episode_number),
        format!("anicat_ui-total_episodes={}", total_episodes),
        format!("anicat_ui-shader_profile={}", shader_profile),
    ];
    parts.join(",")
}

/// Adds the Anime4K chain to a launch command when upscaling is on.
///
/// Shared by both launch paths because `--glsl-shaders` is a process-global
/// the episode-transition batch never re-sends -- it asks the Lua script to
/// reconcile against mpv's live value instead -- so whichever launch actually
/// starts the player is the only chance to set it.
fn apply_shader_args(cmd: &mut tokio::process::Command, config_dir: &str, shader_profile: &str) {
    if shader_profile == "off" {
        return;
    }
    let shader_dir = std::path::Path::new(config_dir).join("shaders");
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

/// Points the child at the bundled mpv's own dylibs.
///
/// Shared by both launch paths: on macOS the bundled binary's load commands
/// read `@executable_path/lib`, which resolves nowhere from inside mpv.app, so
/// a launch without this simply fails to start.
fn apply_mpv_env(cmd: &mut tokio::process::Command, lib_dir: &str) {
    if cfg!(target_os = "macos") && !lib_dir.is_empty() {
        cmd.env("DYLD_LIBRARY_PATH", lib_dir);
        let icd_path = std::path::Path::new(lib_dir).join("vk_icd.json");
        cmd.env("VK_ICD_FILENAMES", icd_path);
    }
    if cfg!(target_os = "linux") {
        cmd.env("LD_LIBRARY_PATH", lib_dir);
    }
    if cfg!(target_os = "windows") && !lib_dir.is_empty() {
        // Windows resolves DLLs via the exe directory and PATH; prepend the
        // bundled lib dir so any mpv DLLs there are found.
        let existing = std::env::var("PATH").unwrap_or_default();
        cmd.env("PATH", format!("{};{}", lib_dir, existing));
    }
}

/// Ceiling on the mpv child's memory footprint before the watchdog kills it.
///
/// An mpv left paused in the background with the lid shut grew to 139.9 GB
/// (2.2 GB resident, 136.6 GB compressed, 47k VM regions, and only 209s of
/// CPU across its whole life -- a slow leak of ~3 MB buffers, not a busy
/// loop) and the kernel jetsam-killed the machine out from under everything
/// else. mpv's own legitimate ceiling here is the demuxer cache the launch
/// args set: 1 GiB forward + 256 MiB back, plus the Anime4K render chain's
/// textures. 6 GiB leaves that room several times over, so anything above it
/// is the leak and not playback.
#[cfg(target_os = "macos")]
const MPV_FOOTPRINT_LIMIT_BYTES: u64 = 6 * 1024 * 1024 * 1024;

/// How many 500ms monitor ticks between footprint samples. The leak took
/// hours, so 10s is far more often than it needs to be looked at.
#[cfg(target_os = "macos")]
const MPV_FOOTPRINT_SAMPLE_TICKS: u32 = 20;

/// The process's memory footprint in bytes, as Activity Monitor reports it.
///
/// Deliberately not RSS: the runaway mpv was only 2.2 GB *resident*, with the
/// other 136.6 GB sitting in the compressor. `ri_phys_footprint` is the field
/// that counts those compressed pages, so RSS would have read as healthy the
/// entire time.
#[cfg(target_os = "macos")]
fn process_footprint_bytes(pid: u32) -> Option<u64> {
    let mut info: libc::rusage_info_v2 = unsafe { std::mem::zeroed() };
    let rc = unsafe {
        libc::proc_pid_rusage(
            pid as libc::c_int,
            libc::RUSAGE_INFO_V2,
            &mut info as *mut _ as *mut libc::rusage_info_t,
        )
    };
    if rc == 0 {
        Some(info.ri_phys_footprint)
    } else {
        None
    }
}

#[cfg(not(target_os = "macos"))]
fn process_footprint_bytes(_pid: u32) -> Option<u64> {
    None
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
    exclude_urls: Option<&[String]>,
) -> Result<(String, Option<std::collections::HashMap<String, String>>, Option<String>), String> {
    let started = std::time::Instant::now();
    let mut timings = ResolveTimings::default();

    // One decision for the whole function: which backend serves this request.
    // Every arm below returns, so what follows the block is the scraper path.
    if let StreamSource::Torrent(index) = StreamSource::resolve(media_id, provider_name) {
        let proxy_port = *state.inner.proxy_port.lock().unwrap_or_else(|e| e.into_inner());
        return match index {
            // A series is searched by the season and episode a release name
            // spells, recovered from the stored absolute number.
            TorrentIndex::Series => {
                let (titles, _year) = gather_movie_info(state, media_id, title).await;
                if titles.is_empty() {
                    return Err("No title to search for".into());
                }
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
                            entry: Default::default(),
                            sibling_titles: &[],
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
                url.map(|u| (u, None, None))
            }
            TorrentIndex::Movie => {
                let (titles, year) = gather_movie_info(state, media_id, title).await;
                if titles.is_empty() {
                    return Err("No title to search for".into());
                }
                let url = state
                    .torrent
                    .resolve(
                        &state.http_client,
                        crate::torrent::ResolveTarget {
                            media_id,
                            // A film is its own single episode.
                            // `allow_episodeless` is what stops the shared
                            // candidate loop from demanding an episode number
                            // the release names never carry.
                            episode: 1,
                            titles: &titles,
                            allow_episodeless: true,
                            episode_count: Some(1),
                            // Sub versus dub is an anime distinction; a film
                            // has one audio track and the release names say
                            // nothing about it.
                            prefer_dub: false,
                            browser_client: client.is_browser(),
                            chosen_name: server.clone(),
                            movie: Some(crate::torrent::cinema::MovieCriteria {
                                year,
                                browser_client: client.is_browser(),
                            }),
                            series: None,
                            entry: crate::torrent::layout::EntryHint {
                                kind: crate::torrent::layout::EntryKind::Movie,
                                ..Default::default()
                            },
                            sibling_titles: &[],
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
                url.map(|u| (u, None, None))
            }
            // Search Nyaa/SubsPlease, start the embedded torrent session, and
            // hand mpv the local range-stream URL.
            TorrentIndex::Anime => {
                let prefer_dub = effective_translation_type(state, media_id).await == "dub";
                let crate::torrent::MediaInfo { titles, episode_count, hint, siblings } =
                    crate::torrent::gather_media_info(state, media_id, title).await;
                // Movies/OVAs (single "episode") legitimately have no episode
                // number in their release names.
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
                            // The stream picker passes the chosen release name
                            // back as `server`; honor it. Auto-play (Continue
                            // button) sends None and takes the best-scored
                            // candidate.
                            chosen_name: server.clone(),
                            movie: None,
                            series: None,
                            entry: hint,
                            sibling_titles: &siblings,
                        },
                        proxy_port,
                    )
                    .await;
                // Torrents skip every stage below (no slug, no scraper, and
                // prebuffer is a far stronger liveness check than the probe),
                // so this line is just the total — but it keeps one grep-able
                // marker for every play.
                timings.log(
                    provider_name,
                    media_id,
                    episode_number,
                    if url.is_ok() { "ok" } else { "failed" },
                    started.elapsed().as_millis(),
                );
                url.map(|u| (u, None, None))
            }
        };
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
    let mut ordered = candidate_order(&servers, selected_server);
    if let Some(excluded) = exclude_urls {
        if !excluded.is_empty() {
            ordered.retain(|cand| {
                !excluded.iter().any(|u| {
                    u == &cand.url || cand.url.contains(u) || u.contains(&cand.url)
                })
            });
        }
    }
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
            if let Ok(mut fresh_servers) = state
                .scraper_manager
                .get_streams(slug, episode_number as i32, provider_name)
                .await
            {
                fresh_servers.retain(|s| !s.name.eq_ignore_ascii_case("doodstream"));
                if client.is_browser() {
                    fresh_servers.retain(|s| s.browser_ok.unwrap_or(true));
                }
                if !fresh_servers.is_empty() {
                    let retry_selected = select_server(&fresh_servers, server, &translation_type, target_quality);
                    let mut retry_ordered = candidate_order(&fresh_servers, retry_selected);
                    if let Some(excluded) = exclude_urls {
                        if !excluded.is_empty() {
                            retry_ordered.retain(|cand| {
                                !excluded.iter().any(|u| {
                                    u == &cand.url || cand.url.contains(u) || u.contains(&cand.url)
                                })
                            });
                        }
                    }
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
    app: AppHandle,
    state: State<'_, AppState>,
    media_id: i64,
    episode_number: i64,
    provider: Option<String>,
    title: Option<String>,
    speculative: Option<bool>,
) -> Result<(), String> {
    // Absent means primary: the detail page's Continue warm-up and every other
    // caller predate the flag, and a preload the user is about to consume is
    // the safer thing to assume of an unlabelled one. Only the episode list's
    // hover/focus guess sends `true`.
    let priority = if speculative.unwrap_or(false) {
        crate::state::PreloadPriority::Speculative
    } else {
        crate::state::PreloadPriority::Primary
    };
    preload_episode_impl(
        state.inner(),
        media_id,
        episode_number,
        provider,
        title,
        crate::state::PreloadOrigin { client: crate::state::StreamClient::Mpv, priority },
        Some(app),
    )
    .await
}

#[tauri::command]
pub async fn get_preload_status(
    state: State<'_, AppState>,
    media_id: i64,
    episode_number: i64,
    provider: Option<String>,
) -> Result<String, String> {
    let provider_name = match provider {
        Some(p) if !p.is_empty() => p,
        _ => state.config.read().await.general.provider.clone(),
    };

    // Check preloaded_stream slot
    {
        let slot = state.preloaded_stream.lock().await;
        if let Some(ref p) = *slot {
            if p.media_id == media_id && p.episode_number == episode_number && p.provider == provider_name {
                return Ok("ready".to_string());
            }
        }
    }

    // Check if in flight
    if state.preload_in_flight(media_id, episode_number, &provider_name) {
        return Ok("fetching".to_string());
    }

    Ok("idle".to_string())
}

pub async fn preload_episode_impl(
    state: &AppState,
    media_id: i64,
    episode_number: i64,
    provider: Option<String>,
    title: Option<String>,
    origin: crate::state::PreloadOrigin,
    app: Option<AppHandle>,
) -> Result<(), String> {
    let crate::state::PreloadOrigin { client, priority } = origin;
    let provider_name = match provider {
        Some(p) if !p.is_empty() => p,
        _ => state.config.read().await.general.provider.clone(),
    };

    // Low Data Mode: a nyaa preload starts an actual torrent download, not
    // just URL resolution — on a slow connection that competes with whatever
    // is currently streaming, and browsing detail pages would kick off
    // downloads for episodes that may never be played. Resolve at play time
    // instead. Scraper providers stay preloaded either way (cheap requests).
    if StreamSource::resolve(media_id, &provider_name).is_torrent()
        && state.config.read().await.stream.data_saver
    {
        log::info!(
            "Low data mode: skipping torrent preload for media {} ep {}",
            media_id, episode_number
        );
        return Ok(());
    }

    let translation_type = effective_translation_type(state, media_id).await;

    // Already preloaded for this exact target — skip.
    {
        let mut slot = state.preloaded_stream.lock().await;
        if let Some(p) = slot.as_mut() {
            if p.media_id == media_id && p.episode_number == episode_number && p.provider == provider_name && p.client == client && p.translation_type == translation_type {
                // The entry stays, but it inherits the better claim on the
                // slot: an episode first warmed on a hover and then asked for
                // as the Continue episode is one the user is about to play, and
                // leaving it marked speculative would let the next hover evict
                // exactly the stream that was about to be consumed.
                p.priority = p.priority.max(priority);
                emit_preload_status(app.as_ref(), media_id, episode_number, "ready");
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
        emit_preload_status(app.as_ref(), media_id, episode_number, "fetching");
        return Ok(());
    };

    emit_preload_status(app.as_ref(), media_id, episode_number, "fetching");

    let state_inner = state.clone();
    let app_handle = app;
    tokio::spawn(async move {
        // Held for the whole resolve; dropping it releases the claim however
        // this task ends.
        let _guard = guard;
        match resolve_stream_for_provider(&state_inner, media_id, episode_number, &provider_name, &None, title, client, None).await {
            Ok((raw_url, headers, subtitle_url)) => {
                // Decided against whatever is already in the slot rather than
                // written over it. The resolve itself is never wasted even when
                // the slot is refused: the torrent manager caches the
                // resolution, so playing the refused episode still takes the
                // reuse path instead of searching again.
                let (decision, occupant_is_this_episode) = {
                    let mut slot = state_inner.preloaded_stream.lock().await;
                    let decision = crate::state::preload_write_decision(slot.as_ref(), priority);
                    // A refusal normally means this episode is not held — but a
                    // competing write during the resolve can have put this very
                    // episode there, and reporting "idle" for an entry that is
                    // sitting ready is the same class of lie as the silent
                    // overwrite this whole path exists to stop.
                    let occupant_is_this_episode = slot
                        .as_ref()
                        .is_some_and(|p| p.media_id == media_id && p.episode_number == episode_number);
                    if let crate::state::PreloadWrite::Store { .. } = decision {
                        *slot = Some(crate::state::PreloadedStream {
                            media_id,
                            episode_number,
                            provider: provider_name.clone(),
                            client,
                            translation_type,
                            priority,
                            raw_url,
                            headers,
                            subtitle_url,
                            at: std::time::Instant::now(),
                        });
                    }
                    (decision, occupant_is_this_episode)
                };
                match decision {
                    crate::state::PreloadWrite::Store { evicted } => {
                        log::info!("Preloaded stream for media {} ep {} ({})", media_id, episode_number, provider_name);
                        if let Some((ev_media, ev_ep)) = evicted {
                            log::info!(
                                "Preload of media {} ep {} evicted the entry for media {} ep {}",
                                media_id, episode_number, ev_media, ev_ep
                            );
                            emit_preload_status(app_handle.as_ref(), ev_media, ev_ep, "idle");
                        }
                        emit_preload_status(app_handle.as_ref(), media_id, episode_number, "ready");
                    }
                    crate::state::PreloadWrite::Refused => {
                        log::info!(
                            "Speculative preload of media {} ep {} resolved, but the slot holds a preload the user is likelier to play; not storing it",
                            media_id, episode_number
                        );
                        let status = if occupant_is_this_episode { "ready" } else { "idle" };
                        emit_preload_status(app_handle.as_ref(), media_id, episode_number, status);
                    }
                }
            }
            Err(e) => {
                log::warn!("preload_episode: media {} ep {} ({}) failed: {}", media_id, episode_number, provider_name, e);
                emit_preload_status(app_handle.as_ref(), media_id, episode_number, "idle");
            }
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

/// Watches one mpv process for the rest of its life: the runaway-memory
/// watchdog, the crashed-on-launch report, and the teardown that saves the
/// final position, clears Discord and pauses the torrent.
///
/// Spawned by whichever path put the process on screen -- which, since the
/// window is raised before the stream resolves, is usually the idle launch and
/// not the call that hands mpv a file. `spawn_instant` is therefore only the
/// floor for the crash window; `mpv_launch_reference` prefers the later
/// handover.
fn spawn_mpv_exit_monitor(
    app_handle: AppHandle,
    app_state_clone: AppState,
    monitor_media_id: i64,
    monitor_episode: i64,
    mpv_gen: u64,
    spawn_instant: std::time::Instant,
) {
    let discord = app_state_clone.discord.clone();
    tokio::spawn(async move {
        let mut warned_still_alive = false;
        let mut ticks: u32 = 0;
        loop {
            tokio::time::sleep(std::time::Duration::from_millis(500)).await;
            ticks = ticks.wrapping_add(1);
            #[cfg(target_os = "macos")]
            if ticks.is_multiple_of(MPV_FOOTPRINT_SAMPLE_TICKS) {
                // Killed rather than merely reported: by the time a leaking
                // mpv is noticeable the machine is already swapping, and
                // there is no message anyone gets to read. It is killed
                // through the same CURRENT_MPV handle the rest of this loop
                // uses, so the next tick sees an exited child and runs the
                // ordinary teardown -- progress is saved, Discord cleared.
                // Sampled and killed under one lock: releasing it between
                // the two would let a transition swap in a newer mpv, and the
                // kill would land on the episode that just started instead of
                // the leaking one it was measured against.
                let killed = {
                    let mut guard = match CURRENT_MPV.lock() {
                        Ok(g) => g,
                        Err(e) => e.into_inner(),
                    };
                    match guard.as_mut() {
                        Some(child) => match child.id().and_then(process_footprint_bytes) {
                            Some(bytes) if bytes > MPV_FOOTPRINT_LIMIT_BYTES => {
                                let _ = child.start_kill();
                                Some(bytes)
                            }
                            _ => None,
                        },
                        None => None,
                    }
                };
                if let Some(bytes) = killed {
                    log::error!(
                        "mpv watchdog: footprint {} MB exceeds the {} MB limit for media {} ep {}; killed it before the kernel kills the machine. Its log is at {:?}",
                        bytes / (1024 * 1024),
                        MPV_FOOTPRINT_LIMIT_BYTES / (1024 * 1024),
                        monitor_media_id,
                        monitor_episode,
                        mpv_log_path(),
                    );
                }
            }
            if !mpv_generation_is_current(mpv_gen) {
                log::info!(
                    "mpv exit monitor for media {} ep {} superseded by a newer player; stopping without teardown",
                    monitor_media_id, monitor_episode
                );
                return;
            }
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
                let since_handover = mpv_launch_reference(spawn_instant).elapsed();
                if crashed && since_handover < std::time::Duration::from_secs(8) {
                    log::warn!(
                        "mpv exited with {:?} only {:?} after it was handed the stream (media {} ep {}) — surfacing as a failed launch",
                        exit_status, since_handover, monitor_media_id, monitor_episode
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
                // Re-checked after the sleep as well: a new episode can start
                // inside that window, and everything below this point (the
                // progress fallback, `active:false`, `pause_all`, clearing
                // `current_playback`) would otherwise land on it.
                if !mpv_generation_is_current(mpv_gen) {
                    log::info!(
                        "mpv exit monitor for media {} ep {}: a newer player started during teardown; leaving its session alone",
                        monitor_media_id, monitor_episode
                    );
                    return;
                }
                // Last line of defence, and deliberately not covered by the
                // generation check: the monitor also concludes "exited" from
                // a `try_wait` error, and this teardown is destructive enough
                // (it clears `current_playback` and pauses the torrent
                // underneath a running player) that a wrong conclusion costs
                // the rest of the session. A live mpv answers its IPC socket;
                // a dead one has unlinked it, and `kill_current_mpv` removes
                // it explicitly. Seen in the wild as a torrent stuck paused
                // at a partial percentage with zero peers while playback ran
                // on out of the 1GiB demuxer cache, and every later player
                // callback -- including auto-next -- refused with "No current
                // playback session found".
                if try_send_ipc(&get_ipc_path(), vec![]).await.is_ok() {
                    // Keep watching rather than returning: the player is
                    // alive now, but whatever it eventually does still needs
                    // the progress save and the torrent pause below. Warned
                    // once so an abnormal state doesn't fill the log at the
                    // poll rate.
                    if !warned_still_alive {
                        log::warn!(
                            "mpv exit monitor for media {} ep {} thought the player exited, but its IPC socket still answers; not tearing the session down",
                            monitor_media_id, monitor_episode
                        );
                        warned_still_alive = true;
                    }
                    continue;
                }

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
                // `anicat_playback_state{active:false}` below deliberately does
                // NOT touch the loading toast (StreamLoadingModal treats a bare
                // `false` as a normal close, not a signal). That's right for
                // mpv dying before it ever got this far. It's wrong for mpv
                // dying *mid a next/prev transition it already reused this same
                // process for* -- e.g. someone hits the OSC's window-close
                // button right as auto-next hands off to episode N+1. The
                // 8-second crashed-launch branch above never sees this case
                // (this isn't a fresh spawn), so nothing ever told the toast
                // the transition it was showing "Starting..." for isn't coming.
                // Confirmed live: the toast sat on "Starting..." indefinitely
                // after exactly this happened, with mpv already gone and
                // nothing left running to resolve it. Clear it unconditionally
                // here too -- a stream that already finished loading dismissed
                // this itself via `status: "ready"` well before the process
                // exit reaches this point, so the only toast still up here is
                // one with no other way to close.
                let _ = app_handle.emit("playback_loading_status", serde_json::json!({
                    "status": "done",
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
}

/// How long the "finding a source" notice stays on the idle player's OSD.
///
/// Five minutes, and deliberately far longer than any resolve that finishes:
/// the notice is meant to be cleared by the episode actually opening (main.lua
/// runs `mp.osd_message('', 0)` on `file-loaded` for exactly this) rather than
/// by expiring, and a resolve that fails takes the whole window down instead.
/// The worst case it has to outlast is a ~85s cold torrent chain sitting
/// behind the 60s wait on an in-flight preload.
const IDLE_NOTICE_MS: i64 = 300_000;

/// Puts an mpv window on screen before there is anything to play, and hands it
/// to the same `loadfile ... replace` path auto-next already uses.
///
/// mpv used to be spawned with the stream URL already in its argv, so the
/// window could not appear until the resolve had finished -- routinely several
/// seconds on a torrent, sometimes tens of them, with the viewer looking at a
/// toast the whole time. An idle player costs a few hundred milliseconds, so
/// the cold play becomes the warm play and the resolve happens behind a window
/// that is already up.
///
/// Only options mpv cannot be told later belong in this argv. The transition
/// batch re-sends the whole script-opts map and `loadfile` carries its own
/// per-file options, so everything stream-specific -- the URL, the headers,
/// `--sub-file`, the torrent cache tuning, `--start` -- is deliberately absent
/// and would only leak into later episodes if it were here. What is *not*
/// re-sent, and so has to be set here or is lost for the whole session, is the
/// config dir, the IPC socket, `--alang`, `--keep-open` and the shader chain.
#[allow(clippy::too_many_arguments)] // same launch context start_playback carries
async fn spawn_idle_mpv(
    app: &AppHandle,
    state: &AppState,
    mpv_bin: &str,
    config_dir: &str,
    lib_dir: &str,
    media_id: i64,
    episode_number: i64,
    title: &str,
    total_episodes: i64,
) -> Result<(), String> {
    let (autoskip, autoplay, shader_profile) = {
        let cfg = state.config.read().await;
        (cfg.general.autoskip, cfg.general.autoplay, cfg.stream.shader_profile.clone())
    };
    let proxy_port = *state.inner.proxy_port.lock().unwrap_or_else(|e| e.into_inner());
    let translation_type = effective_translation_type(state, media_id).await;

    let mut cmd = tokio::process::Command::new(mpv_bin);
    crate::util::suppress_console_tokio(&mut cmd);
    cmd.arg(format!("--config-dir={}", config_dir));
    if let Some(log_path) = mpv_log_path() {
        // Overwritten each launch; records script + shader load results.
        rotate_mpv_log(&log_path);
        cmd.arg(format!("--log-file={}", log_path));
    }
    // `once`, not `yes`. Both idle at start, but `yes` also refuses to quit
    // when the playlist runs out -- which with autoplay off is the end of
    // every episode, leaving a blank window where mpv used to exit and
    // stranding the exit monitor's teardown (the final position save, the
    // Discord clear, the torrent pause) behind a process that never dies.
    // Verified against the bundled mpv 0.40: with `once` the player idles
    // before the first loadfile and exits after that file finishes, and
    // `--keep-open=yes` still holds it open at EOF.
    cmd.arg("--idle=once");
    cmd.arg("--force-window=yes");
    // Neither fullscreen nor ontop, and minimized outright: mpv.conf sets
    // fullscreen=yes globally, so without this override the idle window took
    // over the whole screen -- solid black, since nothing is loaded yet --
    // for however long the resolve took. Reported directly: "I see mpv start
    // up but it's fully black". Promoted to fullscreen+ontop, and
    // un-minimized, in the same IPC batch that sends the file (see the
    // `window-minimized` commands below), so the transition the viewer
    // actually sees is unchanged: the app's own loading UI stays in front
    // until there is something worth looking at.
    cmd.arg("--fullscreen=no");
    cmd.arg("--window-minimized=yes");
    cmd.arg(format!("--input-ipc-server={}", get_ipc_path()));

    // mpv.conf's slang=en,eng,English exists because mpv's own default only
    // auto-selects a track carrying the container's "default" flag, and a lot
    // of multi-audio releases flag none of theirs. The same gap exists for the
    // *audio* track on a dual-audio release, which is how a file silently
    // played dub audio while set to Subtitled. It is a launch-only option --
    // the transition batch never re-sends it -- so the preference in force
    // when the window opens is the one that lasts.
    if translation_type == "dub" {
        cmd.arg("--alang=eng,en,English");
    } else {
        cmd.arg("--alang=jpn,ja,Japanese");
    }

    if !title.is_empty() {
        let media_title = format!("{} - Episode {}", title, episode_number);
        cmd.arg(format!("--force-media-title={}", media_title));
        cmd.arg(format!("--title={}", media_title));
    }

    // No `--start=`: the transition batch always passes an explicit per-file
    // `start=`, and a global one here would re-apply this episode's resume
    // position to every later episode of the binge.
    let script_opts = build_script_opts(
        proxy_port,
        media_id,
        "",
        autoskip,
        autoplay,
        episode_number,
        total_episodes,
        &shader_profile,
    );
    log::info!("[aniskip] idle mpv script-opts: {}", script_opts);
    cmd.arg(format!("--script-opts={}", script_opts));

    if autoplay {
        cmd.arg("--keep-open=yes");
    }
    apply_shader_args(&mut cmd, config_dir, &shader_profile);
    apply_mpv_env(&mut cmd, lib_dir);

    // Check, bump and store under one lock, with nothing awaited inside it, so
    // two starts racing here cannot put up two windows. The bump comes before
    // the store for the reason `kill_current_mpv` does it in that order: a
    // monitor for a previous player still inside its 2s teardown grace would
    // otherwise take this brand-new window for the process it was watching and
    // run that teardown against it -- clearing `current_playback`, pausing the
    // torrent and emitting `active:false` under a player that just opened.
    let (pid, mpv_gen) = {
        let mut guard = match CURRENT_MPV.lock() {
            Ok(g) => g,
            Err(e) => e.into_inner(),
        };
        if guard.is_some() {
            return Err("an mpv is already running".to_string());
        }
        MPV_GENERATION.fetch_add(1, std::sync::atomic::Ordering::SeqCst);
        #[cfg(unix)]
        {
            // A player that died without unlinking its socket leaves a file
            // mpv's bind then fails on, and every Lua callback and transition
            // after that goes nowhere. `kill_current_mpv` removes it on the
            // path it owns; this is the path it doesn't.
            let _ = std::fs::remove_file(get_ipc_path());
        }
        let child = match cmd.spawn() {
            Ok(c) => c,
            Err(e) => return Err(format!("Failed to launch mpv: {}", e)),
        };
        let pid = child.id().unwrap_or(0);
        *guard = Some(child);
        let gen = MPV_GENERATION.load(std::sync::atomic::Ordering::SeqCst);
        // Registered under the same lock that created it, so a resolve that
        // comes back empty can find "the window nobody has fed yet" without
        // having to be the call that raised it.
        IDLE_MPV_GENERATION.store(gen, std::sync::atomic::Ordering::SeqCst);
        (pid, gen)
    };
    let spawn_instant = std::time::Instant::now();
    log::info!(
        "Launched an idle mpv pid={} for media {} ep {}; the window is up while the stream resolves",
        pid, media_id, episode_number
    );

    // No blocking liveness check here, unlike the full launch. The resolve now
    // runs where that 500ms sleep used to, so waiting it out would hand back
    // exactly the delay this exists to remove -- and the monitor below polls
    // at the same 500ms, takes a died-on-launch child out of `CURRENT_MPV`,
    // and reports it to the frontend. By the time the resolve returns, an mpv
    // that failed to start is already gone from the slot, so the reuse check
    // finds no player and falls through to the ordinary launch, which does
    // still block and still fails the play with a real error.
    spawn_mpv_exit_monitor(
        app.clone(),
        state.clone(),
        media_id,
        episode_number,
        mpv_gen,
        spawn_instant,
    );

    // The window is `--ontop`, so it covers the app -- and with it the loading
    // toast that was until now the only thing saying anything was happening.
    // Put the same sentence where the viewer is actually looking.
    let notice = format!("Finding a source for episode {}...", episode_number);
    let ipc_path = get_ipc_path();
    tokio::spawn(async move {
        let cmd = serde_json::json!({ "command": ["show-text", notice, IDLE_NOTICE_MS] });
        // Retried on the same 5x150ms shape the transition path uses: mpv
        // creates its IPC socket a moment after the process starts, so the
        // first attempt lands before there is anything to connect to.
        for _ in 0..5 {
            if try_send_ipc(&ipc_path, vec![cmd.clone()]).await.is_ok() {
                return;
            }
            tokio::time::sleep(std::time::Duration::from_millis(150)).await;
        }
        log::warn!("Could not put the loading notice on the idle player's OSD");
    });

    Ok(())
}

/// Takes down an idle window this start put on screen, when the resolve it was
/// covering found nothing to play.
///
/// Without it the viewer is left with a black `--ontop` window over an app
/// that has already given up, and no way to tell that from a slow stream.
///
/// Two guards, because they answer different questions and only one of them is
/// the obvious one. `IDLE_MPV_GENERATION` says the running player is still an
/// empty window: a newer start does not kill the window, it *reuses* it, so
/// the process generation alone is unchanged while the player is busy opening
/// somebody else's episode, and a resolve that lost thirty seconds to a dead
/// swarm would come back and take that episode down. `playback_generation`
/// says this call is still the one the app is waiting on. Both are read here
/// rather than by the caller, to sit as close to the kill as they can.
///
/// Does nothing when there is no idle window -- a transition that fails while
/// an episode is playing must leave that episode alone.
async fn close_idle_mpv(app: &AppHandle, state: &AppState, playback_gen: u64) {
    let idle_gen = IDLE_MPV_GENERATION.load(std::sync::atomic::Ordering::SeqCst);
    if idle_gen == 0 || !mpv_generation_is_current(idle_gen) {
        return;
    }
    if state.playback_generation.load(std::sync::atomic::Ordering::SeqCst) != playback_gen {
        log::info!("A newer start owns the idle window now; leaving it up for it");
        return;
    }
    log::info!("No stream to play; taking the idle mpv window back down");
    IDLE_MPV_GENERATION.store(0, std::sync::atomic::Ordering::SeqCst);
    kill_current_mpv().await;
    emit_playback_active(app, false);
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
    let provider_name = match provider {
        Some(p) if !p.is_empty() => p,
        _ => state.config.read().await.general.provider.clone(),
    };

    let title_str = title.clone().unwrap_or_default();
    let episode_title_str = episode_title.clone().unwrap_or_default();
    let cover_image_str = cover_image.clone().unwrap_or_default();
    let mut total_eps = total_episodes.unwrap_or(0);
    // New playback generation. Background tasks spawned below (the AniSkip
    // resolver) capture this and abort if a later start_playback supersedes
    // them, so a previous episode's slow IPC retry can't overwrite the current
    // episode's script-opts.
    let playback_gen = state
        .playback_generation
        .fetch_add(1, std::sync::atomic::Ordering::SeqCst)
        + 1;

    // A caller with no episode count leaves the player unable to tell a finale
    // from a middle episode: the Lua script's last-episode branch reads
    // `total_episodes`, and 0 means "there is always a next one". The downloads
    // list plays with nothing but a media id and an episode number, and a show
    // finished from there neither stopped at the end nor completed on AniList.
    // The catalog knows the count, and the lookup is served from the 1hr
    // media_detail cache on every path that already opened the detail page.
    //
    // Placed after the generation claim, and skipped when this start is already
    // superseded: a cold cache makes this a live AniList request, and a
    // superseded start must bail before it spends anything.
    if total_eps <= 0
        && crate::media_id::is_anilist(media_id)
        && state.playback_generation.load(std::sync::atomic::Ordering::SeqCst) == playback_gen
    {
        match super::media::fetch_media_detail_cached(state.inner(), media_id, false).await {
            Ok(d) => {
                if let Some(n) = d.media.as_ref().and_then(|m| m.episodes) {
                    total_eps = n as i64;
                }
            }
            Err(e) => log::warn!(
                "No episode count for media {} and the catalog lookup failed ({}); playing without one",
                media_id, e
            ),
        }
    }

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

    // Resolved before the stream rather than after it, because the window now
    // goes up first: a build with no usable mpv has to fail before anything
    // spends thirty seconds finding a release it can't play.
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

    // Raise the window now, and let the resolve below happen behind it. The
    // stream reaches it through the same `loadfile ... replace` batch
    // auto-next already uses, so a cold play becomes the warm play; see
    // `spawn_idle_mpv`. A resolve that comes back with nothing takes the
    // window back down through `close_idle_mpv`, which keys off
    // `IDLE_MPV_GENERATION` rather than anything held here.
    //
    // Skipped when an mpv is already up (auto-next and every other transition
    // reuse it further down) and when the episode is a completed download,
    // which resolves in microseconds and would only get a black window
    // flashed at it on the way to the same place.
    let mpv_already_up = {
        // Scoped so the guard is released before `spawn_idle_mpv` takes the
        // same lock. The check is advisory anyway -- `spawn_idle_mpv` re-checks
        // it under the lock it spawns in, which is the one that decides.
        match CURRENT_MPV.lock() {
            Ok(guard) => guard.is_some(),
            Err(e) => e.into_inner().is_some(),
        }
    };
    if local_file_path.is_none()
        && !mpv_already_up
        && state.playback_generation.load(std::sync::atomic::Ordering::SeqCst) == playback_gen
    {
        match spawn_idle_mpv(
            &app,
            &state,
            &mpv_bin,
            &config_dir,
            &lib_dir,
            media_id,
            episode_number,
            &title_str,
            total_eps,
        )
        .await
        {
            Ok(()) => {
                // Deliberately no `emit_playback_active(true)` here. The
                // window is up, but minimized and not fullscreen (see
                // `spawn_idle_mpv`), so there is nothing on screen yet worth
                // dismissing the app's own loading UI for -- that now happens
                // where it always used to, when the reuse path below actually
                // sends the file and un-minimizes the player. A resolve that
                // fails instead returns Err, and the frontend's catch keeps
                // its own modal up with the real reason -- it was never
                // dismissed in the first place.
            }
            Err(e) => {
                // Not fatal: the full launch further down still spawns mpv
                // with the stream in its argv, exactly as before this existed.
                log::warn!("Could not raise an idle mpv window: {}", e);
            }
        }
    }

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
        // Instant transition: if the previous episode preloaded this one's
        // stream, use it and skip the scrape entirely. Stale or mismatched
        // entries fall through to a normal resolve.
        //
        // The age limit was 15 minutes, which is generous for the signed CDN
        // URLs several of these providers hand out — an auto-next landing on an
        // expired one produced exactly the "next episode doesn't start" symptom,
        // and worse, taking the preload skips the resolve entirely, so nothing
        // recovered. Three minutes covers the case this exists for (the
        // near-end preload, which fires at 85% of an episode), and the probe
        // below covers the rest.
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

        // Superseded while waiting above -- a second press, or a sub/dub toggle.
        // Bailing here rather than carrying on to the check further down is the
        // point: everything between the two is work this call's result will
        // never be used for, and one piece of it (taking the preloaded entry
        // out of the slot) actively takes that result *away* from the call that
        // superseded it. Pressing next twice because the first press felt slow
        // used to convert an instant preloaded transition into a full cold
        // resolve for exactly that reason.
        if state.playback_generation.load(std::sync::atomic::Ordering::SeqCst) != playback_gen {
            log::info!(
                "Superseded by a newer playback start; not resolving media {} ep {}",
                media_id, episode_number
            );
            return Ok(PlaybackStart { stream_url: String::new() });
        }

        // Claim this target for as long as this start owns it, using the same
        // registry the preloads use. Two presses landing on the same episode
        // (which is what happens when the second arrives before the first has
        // written `current_playback`) then make the second *wait* on the
        // first's resolve at the guard above, instead of starting a second
        // `add_torrent` round against the torrent the player is already
        // reading. Whichever one is superseded puts its stream back in the
        // slot on the way out, so the survivor finds it ready rather than
        // resolving the same episode again.
        //
        // Best-effort: if the claim is somehow already held despite the wait
        // above, carry on unclaimed rather than failing a play outright.
        let _start_claim = state.claim_preload(media_id, episode_number, &provider_name);

        // Recomputed here rather than reused from earlier in the function: a
        // mid-playback sub/dub toggle writes the new preference and then
        // calls start_playback for the very episode that may already have a
        // preload cached under the *old* preference (the near-end preload
        // fires long before a toggle could happen). Without this check the
        // reuse below would hand back the stale-translation stream and the
        // toggle would silently do nothing.
        let translation_type = effective_translation_type(&state, media_id).await;

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
                        && p.translation_type == translation_type
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
        // Consuming empties the slot as surely as an eviction does, and the
        // webview has no other way to learn it: without this the episode just
        // played stays "ready" in its map forever, and the list then refuses to
        // warm it again. A start that is superseded and hands the entry back
        // re-emits "ready" from `restore_preload`.
        if preloaded.is_some() {
            emit_preload_status(Some(&app), media_id, episode_number, "idle");
        }

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
            // The probe above is a network round-trip, so the supersede can
            // land during it. Checked again before the expensive half: on nyaa
            // a resolve is a full search plus a swarm handshake.
            if state.playback_generation.load(std::sync::atomic::Ordering::SeqCst) != playback_gen {
                log::info!(
                    "Superseded by a newer playback start; abandoning the resolve for media {} ep {}",
                    media_id, episode_number
                );
                restore_preload(&state, Some(&app), consumed_preload.take()).await;
                return Ok(PlaybackStart { stream_url: String::new() });
            }

            match resolve_stream_for_provider(&state, media_id, episode_number, &provider_name, &server, title.clone(), crate::state::StreamClient::Mpv, None).await {
                Ok(res) => res,
                Err(e) => {
                    log::warn!("Provider '{}' failed for media {} ep {}: {}", provider_name, media_id, episode_number, e);
                    // The one exit between raising the window and handing mpv
                    // a file. Leaving it up would park a black `--ontop`
                    // window over an app that has already given up.
                    close_idle_mpv(&app, &state, playback_gen).await;
                    return Err(format!("No stream found (last error: {})", e));
                }
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

    // This episode, and not the preloads queued behind it, is the one about to
    // be read. Pinning it exempts its file from the torrent's two-file
    // selection window, which the episode list's hover guess would otherwise
    // push it out of mid-play (see `TorrentManager::playing_file`). Done here,
    // before mpv is handed anything, because the pin also re-selects a file
    // that has *already* been dropped -- the case a preloaded URL taken
    // straight out of the slot would otherwise play into, since that path
    // never re-enters `resolve`. A no-op for every non-torrent provider.
    state.torrent.set_playing(media_id, episode_number).await;

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

    let mut cmd = tokio::process::Command::new(&mpv_bin);
    crate::util::suppress_console_tokio(&mut cmd);
    cmd.arg(format!("--config-dir={}", config_dir));
    if let Some(log_path) = mpv_log_path() {
        // Overwritten each launch; records script + shader load results.
        rotate_mpv_log(&log_path);
        cmd.arg(format!("--log-file={}", log_path));
    }
    cmd.arg("--force-window=yes");
    cmd.arg("--ontop");
    cmd.arg(format!("--input-ipc-server={}", get_ipc_path()));

    // mpv.conf's slang=en,eng,English exists because mpv's own default only
    // auto-selects a track carrying the container's "default" flag, and a lot
    // of multi-audio releases flag none of theirs (see the comment there for
    // the [Judas]-with-fifteen-untracked-subs example that prompted it). The
    // exact same gap exists for the *audio* track on a dual-audio release —
    // no --alang was ever set, so an untagged/wrongly-first-tagged dual-audio
    // file silently played whatever track happened to be first in the
    // container, regardless of the sub/dub preference (reported: Chivalry of
    // a Failed Knight serving dub audio while set to Subtitled). Unlike
    // subtitle language, this has to track the *current* preference rather
    // than a fixed default, since a dub-preferring user needs the opposite
    // list.
    let translation_type = effective_translation_type(&state, media_id).await;
    if translation_type == "dub" {
        cmd.arg("--alang=eng,en,English");
    } else {
        cmd.arg("--alang=jpn,ja,Japanese");
    }

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
    let shader_profile = {
        let cfg = state.config.read().await;
        cfg.stream.shader_profile.clone()
    };
    let proxy_port = *state.inner.proxy_port.lock().unwrap_or_else(|e| e.into_inner());
    let script_opts_str = build_script_opts(
        proxy_port,
        media_id,
        &skip_times_arg,
        autoskip,
        autoplay,
        episode_number,
        total_eps,
        &shader_profile,
    );
    log::info!("[aniskip] mpv script-opts: {}", script_opts_str);
    cmd.arg(format!("--script-opts={}", script_opts_str));

    if autoplay {
        cmd.arg("--keep-open=yes");
    }

    apply_shader_args(&mut cmd, &config_dir, &shader_profile);

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
        // One option, two jobs that want opposite values. Mid-playback it is
        // the rebuffer runway, and 30s is right there: resuming after the 3s
        // it used to be meant any starved stretch played as a
        // play-3s/freeze/play-3s stutter loop. But `cache-pause-initial`
        // reuses the same number as the *startup* gate, and 30s of media is
        // ~19MB at 1080p — on a thin swarm that is a minute or more of the
        // window sitting frozen on its first frame before anything moves,
        // which is most of what "mpv takes ages to start" actually was.
        //
        // So launch with the short gate and let the Lua script raise it to
        // TORRENT_REBUFFER_WAIT once playback is genuinely under way (see
        // restore_rebuffer_wait in scripts/anicat_ui/main.lua) — the startup
        // gate and the rebuffer runway stop having to be the same number.
        // 10s is still over 3x the value that caused the stutter loop, so a
        // stream that stalls before the script's handover is no worse off
        // than it was under the old behavior. Keep the two constants in
        // step: this one and the Lua one are a pair.
        cmd.arg("--cache-pause-wait=10");
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

    apply_mpv_env(&mut cmd, &lib_dir);

    let has_active_mpv = {
        if let Ok(guard) = CURRENT_MPV.lock() {
            guard.is_some()
        } else {
            false
        }
    };

    let mut reused = false;
    // The episode currently on screen, captured before the reuse path
    // overwrites it, so a transition mpv never completes can be walked back to
    // it rather than leaving the counter one ahead of reality.
    let mut outgoing: Option<crate::state::CurrentPlayback> = None;
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

        let (autoskip, autoplay, shader_profile) = {
            let cfg = state.config.read().await;
            (cfg.general.autoskip, cfg.general.autoplay, cfg.stream.shader_profile.clone())
        };
        let reuse_proxy_port =
            *state.inner.proxy_port.lock().unwrap_or_else(|e| e.into_inner());
        // Sets the whole script-opts map, so every key a launch argv sends has
        // to be re-sent here or it is *removed* from the reused player rather
        // than left alone -- shader_profile was the one that wasn't. Built by
        // the same function both launch paths use, so the three writers cannot
        // fall out of step.
        let script_opts_parts = build_script_opts(
            reuse_proxy_port,
            media_id,
            &skip_times_arg,
            autoskip,
            autoplay,
            episode_number,
            total_eps,
            &shader_profile,
        );

        commands.push(serde_json::json!({
            "command": ["set_property", "script-opts", script_opts_parts]
        }));

        // Re-apply the upscaling setting for the new episode, the same way the
        // launch path applies it via --glsl-shaders.
        //
        // Only the launch path ever did. `glsl-shaders` is a global property
        // that survives `loadfile ... replace`, which is right for a Ctrl+1
        // toggle (that writes the flip back to config, so the two agree), but
        // wrong for a change made in Settings while mpv is open: config moved
        // and the running player never heard about it. Auto-next then carried
        // the stale render graph into every remaining episode of the binge,
        // and only closing mpv resynced it. Config is the source of truth at
        // the start of an episode here exactly as it is at launch.
        //
        // Sent as a script-message rather than as a `glsl-shaders` write so
        // the decision can be made against mpv's live value: setting the
        // property rebuilds the render graph even when the value is
        // unchanged, which on this transition would stall the first frames of
        // the episode that just started for the overwhelmingly common case of
        // nothing having changed at all.
        commands.push(serde_json::json!({
            "command": ["script-message", "anicat-set-shader-profile", shader_profile]
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
        //
        // Cleared with `change-list ... clr`, not by setting the property to
        // an empty string: `sub-files` is a list, and mpv reads "" as a
        // one-element list holding an empty filename rather than as an empty
        // list. Verified against a live mpv over this same IPC socket --
        // set_property to "" leaves the property reading `[""]`, and mpv then
        // dutifully tries to open it, which is the "Cannot open file ''" /
        // "Can not open external file ." pair in the log on every torrent
        // episode. `clr` leaves it `[]`.
        commands.push(serde_json::json!({
            "command": ["change-list", "sub-files", "clr", ""]
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
        // cache-pause-initial=yes and a torrent-sized cache-pause-wait (the
        // Lua handover above has by then raised it back to 30), so mpv sat
        // buffering half a minute of an ordinary HLS stream before a frame —
        // the "doesn't play immediately" symptom. Restore what a fresh
        // non-torrent launch would have had: mpv's own defaults, plus copies
        // of the two demuxer values mpv.conf sets. Those copies are the
        // tradeoff — editing mpv.conf no longer reaches this path, so change
        // both together.
        if is_torrent_stream {
            load_options.push_str(
                ",network-timeout=0,cache=yes,cache-pause=yes,cache-pause-initial=yes,\
                 cache-pause-wait=10,demuxer-max-bytes=1GiB,demuxer-max-back-bytes=256MiB,\
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

        // Promotes the idle window `spawn_idle_mpv` deliberately left
        // minimized and windowed -- so the black screen the resolve used to
        // sit behind is never shown -- to what a fresh cold launch (or every
        // later episode of a binge) already has by the time there is
        // something to look at. A no-op the rest of the time: an mpv that was
        // already fullscreen/ontop/mapped just gets told what it already is.
        commands.push(serde_json::json!({
            "command": ["set_property", "window-minimized", false]
        }));
        commands.push(serde_json::json!({
            "command": ["set_property", "fullscreen", true]
        }));
        commands.push(serde_json::json!({
            "command": ["set_property", "ontop", true]
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
            restore_preload(&state, Some(&app), consumed_preload.take()).await;
            return Ok(PlaybackStart { stream_url });
        }

        // Cleared before the send so the confirmation wait below can only be
        // satisfied by *this* transition's file-loaded, never by the one that
        // is still on screen.
        {
            let mut slot = state.confirmed_playing.lock().await;
            *slot = None;
        }
        outgoing = state.current_playback.lock().await.clone();

        let ipc_path = get_ipc_path();
        log::info!("Connecting to running MPV at {} via IPC...", ipc_path);
        // Retry a few times — mpv may be briefly busy loading the stream.
        let mut ipc_ok = false;
        for attempt in 0..5 {
            if try_send_ipc(&ipc_path, commands.clone()).await.is_ok() {
                log::info!("Sent stream to running MPV via IPC (attempt {})", attempt + 1);
                // The moment this player was committed to a file. The exit
                // monitor's crashed-on-launch window is measured from here and
                // not from the spawn: the window is raised before the resolve,
                // so by now the process can be a whole binge old, and a stream
                // mpv dies on would otherwise fall outside the window and be
                // reported nowhere.
                record_mpv_file_handover();
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
        emit_playback_active(&app, true);
        // The write above is optimistic and has to be: the callbacks for the
        // new episode start arriving immediately and need something to report
        // against. Confirm it in the background -- a successful IPC send only
        // means mpv received the loadfile, and an mpv that then fails to open
        // the stream used to leave the counter permanently one ahead, so the
        // next press skipped the episode that never played. Backgrounded so
        // the transition still returns at once.
        let confirm_state = (*state).clone();
        let confirm_app = app.clone();
        tokio::spawn(async move {
            if !confirm_playing(&confirm_state, media_id, episode_number, playback_gen).await {
                rollback_failed_transition(
                    &confirm_state,
                    &confirm_app,
                    outgoing,
                    media_id,
                    episode_number,
                    playback_gen,
                )
                .await;
            }
        });
        return Ok(PlaybackStart { stream_url });
    }

    // Same last-request-wins check as the IPC reuse path above, before the
    // irreversible part (killing the running mpv and spawning a new one).
    if state.playback_generation.load(std::sync::atomic::Ordering::SeqCst) != playback_gen {
        log::info!(
            "Superseded by a newer playback start; not launching mpv for media {} ep {}",
            media_id, episode_number
        );
        restore_preload(&state, Some(&app), consumed_preload.take()).await;
        return Ok(PlaybackStart { stream_url });
    }

    kill_current_mpv().await;
    // Claimed after the kill bumped it, so this launch owns every generation
    // check until something kills mpv again.
    let mpv_gen = current_mpv_generation();

    log::info!("Launching mpv command: {:?}", cmd);
    let mut child = cmd
        .spawn()
        .map_err(|e| format!("Failed to launch mpv: {}", e))?;

    let pid = child.id().unwrap_or(0);
    log::info!("Launched mpv pid={} with stream: {}", pid, stream_url);
    let spawn_instant = std::time::Instant::now();
    // This launch carries the URL in its argv, so spawning it *is* the
    // handover. Stamped anyway rather than left to the fallback, so the rule
    // stays "every path that gives mpv a file records it" with no exception to
    // remember.
    record_mpv_file_handover();

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

    spawn_mpv_exit_monitor(
        app.clone(),
        (*state).clone(),
        media_id,
        episode_number,
        mpv_gen,
        spawn_instant,
    );

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
            // regress AniList progress. It bounds the number written and, when
            // there is provably nothing left to say, skips the write -- but it
            // is deliberately not a plain "progress already covers this episode"
            // early return any more. A rewatch reaches its finale with progress
            // already sitting at N (start_playback puts the entry back to
            // CURRENT the moment you replay it), so that return made the second
            // completion unreachable and left the show in Watching permanently.
            // Only an entry that is *also* already COMPLETED has nothing left to
            // write; the status half is re-checked once the finale test below
            // has run.
            let cached_progress = state.cache.get_user_list_progress(media_id);
            let already_covered = cached_progress.map(|c| episode_number <= c).unwrap_or(false);
            let already_completed = state
                .cache
                .get_user_list_status(media_id)
                .map(|s| s.eq_ignore_ascii_case("COMPLETED"))
                .unwrap_or(false);
            if already_covered && already_completed {
                log::info!(
                    "Skipping progress write for media {} ep {}: AniList already at {:?} and COMPLETED",
                    media_id, episode_number, cached_progress
                );
                return Ok(());
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
            // Never below what AniList already has: a COMPLETED write for an
            // episode the entry has passed must not walk the number back. This
            // is safe only because of the `already_covered` skip further down:
            // that is what keeps an ordinary mid-series write from writing back
            // a number higher than the episode just watched.
            let mut write_progress = episode_number.max(cached_progress.unwrap_or(0));
            // A caller that passed no count at all (total_episodes == 0 -- the
            // downloads list plays an episode with nothing else to hand) says
            // nothing about whether this is the finale, and treating it as
            // "not the finale" is how a show finished from there stayed in
            // Watching. An unknown count asks AniList instead of assuming.
            if total_episodes <= 0 || episode_number >= total_episodes {
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

            // The other half of the forward-only guard: with progress already
            // covering this episode, a non-completion write would only rewrite
            // the same number.
            if already_covered && status != "COMPLETED" {
                log::info!(
                    "Skipping progress write for media {} ep {}: AniList already at {:?} and this is not a completion",
                    media_id, episode_number, cached_progress
                );
                return Ok(());
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

/// Non-HTTP counterpart to the `/player/pause|resume|progress|stop` handlers
/// in `proxy/server.rs`, for `AniCatPlayer.tsx` (the desktop builtin `<video>`
/// player) to call via `invoke()` instead of a loopback HTTP round trip. Those
/// HTTP routes stay, and keep this exact same logic, because mpv's Lua script
/// can only speak HTTP -- this command exists for the caller that *can* speak
/// Tauri IPC directly instead.
///
/// `"stop"` deliberately does NOT reuse the `stop_playback` command above:
/// that one also kills mpv and calls `torrent.pause_all()`, which is right
/// when mpv (the only other reader of that torrent) is going away, but wrong
/// here -- closing the builtin player's `<video>` element does not mean the
/// torrent has no more readers. A background `remux.rs` ffmpeg session for
/// the same torrent+file often keeps running well past that (transcoding
/// takes real time even though stream-copy is cheap), and pausing the
/// torrent out from under it starves the still-running remux of new bytes.
/// Observed live: closing the builtin player mid-remux froze the HLS
/// playlist's growth, which the player then read as "this episode is only
/// as long as whatever was buffered at the moment of the pause".
#[tauri::command]
pub async fn report_builtin_player_state(
    app: AppHandle,
    state: State<'_, AppState>,
    action: String,
    pos: i64,
    duration: i64,
) -> Result<(), String> {
    match action.as_str() {
        "stop" => {
            let play_info = {
                let mut guard = state.current_playback.lock().await;
                if let Some(ref mut pb) = *guard {
                    pb.last_position = pos;
                    pb.last_duration = duration;
                }
                guard.clone()
            };
            if let Some(play_info) = play_info {
                if pos > 0 && duration > 0 {
                    let state_clone = state.inner().clone();
                    let media_id = play_info.media_id;
                    let ep_num = play_info.episode_number;
                    let total_eps = play_info.total_episodes;
                    tokio::spawn(async move {
                        match record_playback_progress(&state_clone, 0, media_id, ep_num, pos, duration, total_eps).await {
                            Ok(()) => {
                                let _ = app.emit("progress_updated", serde_json::json!({
                                    "media_id": media_id,
                                    "episode_number": ep_num,
                                }));
                            }
                            Err(e) => log::error!("Failed to record progress on builtin player stop: {}", e),
                        }
                    });
                }
            }
        }
        "pause" => {
            let play_info = {
                let mut guard = state.current_playback.lock().await;
                if let Some(ref mut pb) = *guard {
                    pb.last_position = pos;
                    pb.last_duration = duration;
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
                state.discord.set_presence(
                    &play_info.title,
                    play_info.episode_number,
                    &play_info.episode_title,
                    play_info.total_episodes,
                    pos,
                    duration,
                    true,
                );
            }
        }
        "resume" => {
            let play_info = {
                let mut guard = state.current_playback.lock().await;
                if let Some(ref mut pb) = *guard {
                    pb.last_position = pos;
                    pb.last_duration = duration;
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
                state.discord.set_presence(
                    &play_info.title,
                    play_info.episode_number,
                    &play_info.episode_title,
                    play_info.total_episodes,
                    pos,
                    duration,
                    false,
                );
            }
        }
        "progress" => {
            let (play_info, persist_info) = {
                let mut guard = state.current_playback.lock().await;
                if let Some(ref mut pb) = *guard {
                    pb.last_position = pos;
                    pb.last_duration = duration;
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
            if let Some((media_id, episode_number)) = persist_info {
                if pos > 0 && duration > 0 {
                    if let Ok(db) = state.open_db() {
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
                state.discord.set_presence(
                    &pb.title,
                    pb.episode_number,
                    &pb.episode_title,
                    pb.total_episodes,
                    pos,
                    duration,
                    false,
                );
            }
        }
        other => return Err(format!("unknown player action '{}'", other)),
    }
    Ok(())
}

/// Put a torrent release through ffmpeg and hand back the HLS path, or `None`
/// to fall through to serving the file as it is.
async fn remux_torrent_stream(
    manager: &crate::proxy::remux::RemuxManager,
    loopback_url: &str,
    path_and_query: &str,
    prefer_dub: bool,
) -> Option<String> {
    if !manager.is_available().await {
        return None;
    }
    // "/torrent-stream?t=1&f=5" -- the ids the session is keyed by, so two
    // requests for one episode share an ffmpeg instead of racing.
    let query = path_and_query.split_once('?').map(|(_, q)| q).unwrap_or("");
    let mut torrent_id = None;
    let mut file_id = None;
    for pair in query.split('&') {
        match pair.split_once('=') {
            Some(("t", v)) => torrent_id = v.parse().ok(),
            Some(("f", v)) => file_id = v.parse().ok(),
            _ => {}
        }
    }
    let (torrent_id, file_id) = (torrent_id?, file_id?);
    match manager.start(loopback_url, torrent_id, file_id, 0, prefer_dub).await {
        Ok(url) => Some(url),
        Err(e) => {
            log::warn!("remux: falling back to the raw file: {}", e);
            None
        }
    }
}

/// Non-HTTP counterpart to `/mobile-api/playback/resolve` (deleted with the
/// mobile PWA), kept for `AniCatPlayer.tsx` -- the desktop builtin `<video>`
/// player, which is the default `playerType` for a fresh install. Unlike mpv,
/// it has no IPC to push a resolved stream into, so this hands back a URL the
/// `<video>` element can load directly, the same way the HTTP endpoint did.
#[tauri::command]
pub async fn resolve_builtin_player_stream(
    app: AppHandle,
    state: State<'_, AppState>,
    media_id: i64,
    episode_number: i64,
    provider: Option<String>,
    title: Option<String>,
    episode_title: Option<String>,
    cover_image: Option<String>,
    total_episodes: Option<i64>,
    exclude_urls: Option<Vec<String>>,
) -> Result<Value, String> {
    let state = state.inner();
    let provider_name = match provider.clone() {
        Some(p) if !p.is_empty() => p,
        _ => state.config.read().await.general.provider.clone(),
    };
    let title_str = title.clone().unwrap_or_default();
    let episode_title_str = episode_title.clone().unwrap_or_default();
    let cover_image_str = cover_image.clone().unwrap_or_default();
    let total_eps = total_episodes.unwrap_or(0);

    let translation_type = effective_translation_type(state, media_id).await;
    const PRELOAD_MAX_AGE: std::time::Duration = std::time::Duration::from_secs(30 * 60);

    let preloaded = {
        let mut slot = state.preloaded_stream.lock().await;
        match slot.take() {
            Some(p)
                if p.media_id == media_id
                    && p.episode_number == episode_number
                    && p.provider == provider_name
                    && p.client == crate::state::StreamClient::Browser
                    && p.translation_type == translation_type
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
    // Same reason as the mpv path: the slot is now empty for this episode, and
    // the store only ever learns that from this event.
    if preloaded.is_some() {
        emit_preload_status(Some(&app), media_id, episode_number, "idle");
    }

    let (raw_url, stream_headers, raw_subtitle_url, resolved_provider) = if let Some(p) = preloaded {
        log::info!(
            "Using preloaded browser stream for media {} ep {} ({})",
            media_id, episode_number, p.provider
        );
        (p.raw_url, p.headers, p.subtitle_url, p.provider)
    } else {
        match resolve_stream_for_provider(
            state,
            media_id,
            episode_number,
            &provider_name,
            &None,
            title.clone(),
            crate::state::StreamClient::Browser,
            exclude_urls.as_deref(),
        )
        .await
        {
            Ok((url, headers, subtitle_url)) => (url, headers, subtitle_url, provider_name.clone()),
            Err(e) => {
                log::warn!("Builtin player provider '{}' failed for media {} ep {}: {}", provider_name, media_id, episode_number, e);
                return Err(format!("No playable stream found (last error: {})", e));
            }
        }
    };

    let torrent_path = raw_url.strip_prefix("http://127.0.0.1:").and_then(|rest| {
        rest.split_once('/').map(|(_, tail)| format!("/{tail}"))
    }).filter(|p| p.starts_with("/torrent-stream"));
    let mut remuxed = false;
    let prefer_dub = translation_type == "dub";
    let mut stream_url = if let Some(path_and_query) = torrent_path {
        match remux_torrent_stream(&state.remux, &raw_url, &path_and_query, prefer_dub).await {
            Some(url) => {
                remuxed = true;
                url
            }
            None => path_and_query,
        }
    } else {
        format!("/proxy?url={}", percent_encode(&raw_url))
    };
    if let Some(referer) = stream_headers.as_ref().and_then(|h| {
        h.get("Referer").or_else(|| h.get("referer")).or_else(|| h.get("REFERER"))
    }) {
        if stream_url.starts_with("/proxy") {
            stream_url.push_str(&format!("&referer={}", percent_encode(referer)));
        }
    }

    // Same pin as the mpv path: the builtin player (and the remux feeding it)
    // reads the torrent file just as mpv does, so a preload resolving into the
    // same pack must not be able to deselect it.
    state.torrent.set_playing(media_id, episode_number).await;

    {
        let mut guard = state.current_playback.lock().await;
        *guard = Some(crate::state::CurrentPlayback {
            media_id,
            episode_number,
            provider: resolved_provider,
            title: title_str,
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
        if let Ok(db) = state.open_db() {
            if let Ok(entries) = crate::registry::service::get_watched_episodes(&db, 0, media_id) {
                if let Some(entry) = entries.iter().find(|e| e.episode_number == episode_number) {
                    sec = resume_position(entry.stop_time, entry.duration);
                }
            }
        }
        if sec > 0 {
            if let Some(anilist_progress) = state.cache.get_user_list_progress(media_id) {
                if anilist_progress >= episode_number {
                    sec = 0;
                }
            }
        }
        sec
    };

    if state.anilist_client.has_token() && media_id > 0 {
        let already_current = state
            .cache
            .get_user_list_status(media_id)
            .map(|s| s.eq_ignore_ascii_case("CURRENT"))
            .unwrap_or(false);
        if !already_current {
            let anilist = state.anilist_client.clone();
            let cache = state.cache.clone();
            tokio::spawn(async move {
                let mut vars = std::collections::HashMap::new();
                vars.insert("mediaId".to_string(), serde_json::json!(media_id));
                vars.insert("status".to_string(), serde_json::json!("CURRENT"));
                if let Err(e) = anilist
                    .execute::<serde_json::Value>(crate::anilist::queries::SAVE_MEDIA_LIST_ENTRY_MUTATION, vars)
                    .await
                {
                    log::warn!("Failed to sync AniList watching list from builtin player: {}", e);
                } else {
                    cache.update_user_list_progress(media_id, None, Some("CURRENT"), None);
                }
            });
        }
    }

    let subtitle_url = raw_subtitle_url.as_ref().map(|sub| {
        let mut url = format!("/proxy?url={}", percent_encode(sub));
        if let Some(referer) = stream_headers.as_ref().and_then(|h| {
            h.get("Referer").or_else(|| h.get("referer")).or_else(|| h.get("REFERER"))
        }) {
            url.push_str(&format!("&referer={}", percent_encode(referer)));
        }
        url
    });

    Ok(serde_json::json!({
        "stream_url": stream_url,
        "resume_seconds": if remuxed { 0 } else { resume_seconds },
        "subtitle_url": if remuxed { None } else { subtitle_url },
    }))
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
    /// The backend and the player script are two halves of one contract:
    /// `set_property script-opts` replaces the whole map, so a key the backend
    /// stops sending is *deleted* from the running player rather than left
    /// alone (this is how a reused mpv once lost its shader profile for the
    /// rest of a binge), and a key it sends that the script never declares is
    /// read by nothing. Asserted against the script that actually ships, so
    /// the two cannot drift silently in either direction.
    #[test]
    fn every_script_opt_sent_is_one_the_player_declares() {
        let sent: std::collections::BTreeSet<String> =
            super::build_script_opts(13370, 1, "op,0,90", true, false, 3, 12, "on")
                .split(',')
                .map(|part| {
                    part.split('=')
                        .next()
                        .unwrap()
                        .trim_start_matches("anicat_ui-")
                        .to_string()
                })
                .collect();

        let lua = std::fs::read_to_string(
            std::path::Path::new(env!("CARGO_MANIFEST_DIR"))
                .join("resources/mpv_config/scripts/anicat_ui/main.lua"),
        )
        .expect("the player script ships in-tree");
        let table = lua
            .split_once("local opts = {")
            .expect("main.lua declares an opts table")
            .1
            .split_once("\n}")
            .expect("the opts table is closed")
            .0;
        let declared: std::collections::BTreeSet<String> = table
            .lines()
            .map(str::trim)
            .filter(|line| !line.starts_with("--"))
            .filter_map(|line| line.split_once('=').map(|(key, _)| key.trim().to_string()))
            .filter(|key| !key.is_empty())
            .collect();

        assert_eq!(sent, declared);
    }

    /// Commas are mpv's own `--script-opts` delimiter, so an unencoded skip
    /// list is parsed as several truncated keys instead of one value -- which
    /// is why the count above would still pass while every skip segment after
    /// the first was lost.
    #[test]
    fn a_multi_segment_skip_list_survives_the_delimiter() {
        let opts = super::build_script_opts(13370, 1, "op,0,90;ed,1300,1390", true, true, 3, 12, "on");
        assert!(opts.contains("anicat_ui-skip_times=op%2C0%2C90;ed%2C1300%2C1390"));
        assert_eq!(opts.split(',').count(), 8, "one part per declared key: {}", opts);
    }

    /// Guards the `rusage_info_v2` layout and the double-pointer argument of
    /// `proc_pid_rusage`: get either wrong and the call still returns 0 while
    /// `ri_phys_footprint` reads back as garbage or zero, so the watchdog
    /// would silently never fire.
    #[cfg(target_os = "macos")]
    #[test]
    fn footprint_of_this_process_is_plausible() {
        let bytes = super::process_footprint_bytes(std::process::id())
            .expect("proc_pid_rusage failed for our own pid");
        assert!(
            bytes > 1024 * 1024 && bytes < 64 * 1024 * 1024 * 1024,
            "implausible footprint: {} bytes",
            bytes
        );
    }

    /// The exit monitor of a replaced mpv must not run its teardown: doing so
    /// clears the `current_playback` of the episode that replaced it and
    /// pauses its torrent, which is how auto-next intermittently ended with
    /// "No current playback session found for next episode request" and a
    /// torrent stalled at a partial percentage.
    #[tokio::test]
    async fn a_replaced_mpv_monitor_stops_speaking_for_the_player() {
        let first = super::current_mpv_generation();
        assert!(super::mpv_generation_is_current(first));
        // What the kill-and-respawn path does before launching the new mpv.
        super::kill_current_mpv().await;
        assert!(
            !super::mpv_generation_is_current(first),
            "the killed player's monitor still believes it owns the session"
        );
        let second = super::current_mpv_generation();
        assert!(super::mpv_generation_is_current(second));
    }
    use super::{
        candidate_order, is_watched, looks_like_playlist, parse_playlist,
        probe_status_is_dead, probe_status_is_permanent, resume_position,
        sample_indices, transition_failure_message, PlaylistStep,
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

    /// The confirmation is what a completed transition looks like; its absence
    /// is what a failed one looks like.
    #[tokio::test]
    async fn a_reported_open_confirms_the_transition() {
        let state = crate::state::AppState::new();
        let gen = state.playback_generation.load(std::sync::atomic::Ordering::SeqCst);
        {
            let mut slot = state.confirmed_playing.lock().await;
            *slot = Some((20977, 6));
        }
        assert!(super::confirm_playing(&state, 20977, 6, gen).await);
    }

    /// A different episode's confirmation must not satisfy this one -- that is
    /// the whole failure mode, an episode counted as playing when it never
    /// opened. Kept fast by superseding rather than waiting out the 180s bound.
    #[tokio::test]
    async fn another_episodes_open_does_not_confirm_this_one() {
        let state = crate::state::AppState::new();
        let gen = state.playback_generation.load(std::sync::atomic::Ordering::SeqCst);
        {
            let mut slot = state.confirmed_playing.lock().await;
            *slot = Some((20977, 5));
        }
        // Bump the generation so the wait exits on "someone newer owns this"
        // rather than on a match -- if ep 5 satisfied a wait for ep 6 the call
        // would return before this even mattered.
        state.playback_generation.fetch_add(1, std::sync::atomic::Ordering::SeqCst);
        assert!(super::confirm_playing(&state, 20977, 6, gen).await);
        let slot = state.confirmed_playing.lock().await;
        assert_eq!(*slot, Some((20977, 5)), "the wait must not have written anything");
    }

    /// The whole point of the message is that it is *not* the end-of-season
    /// one: it names the episode that failed, which says outright that the
    /// show has more.
    #[test]
    fn a_failed_transition_never_reads_as_the_end_of_the_show() {
        let cases = [
            "No stream found (last error: No HD torrent found for 'X' episode 6)",
            "All torrent candidates failed (last error: no seeders (pre-buffer timed out))",
            "mpv exited immediately: ExitStatus(unix_wait_status(256))",
            "something nobody has seen before",
        ];
        for err in cases {
            let msg = transition_failure_message(6, err);
            assert!(msg.starts_with("Episode 6 failed to load: "), "{msg}");
            assert!(
                !msg.contains("No more episodes"),
                "the end-of-season sentence must never come out of a failure: {msg}"
            );
        }
    }

    #[test]
    fn a_failure_reason_says_which_kind_of_failure_it_was() {
        assert!(transition_failure_message(6, "No HD torrent found for 'X' episode 6")
            .contains("no release found"));
        assert!(transition_failure_message(6, "no seeders (pre-buffer timed out)")
            .contains("source timed out"));
        assert!(transition_failure_message(6, "mpv exited immediately: status 1")
            .contains("the player failed to start"));
    }

    /// An unrecognised error is passed through rather than replaced with an
    /// apology -- but bounded, so a provider-chain message can't cover the
    /// video it is being shown over.
    #[test]
    fn an_unknown_failure_keeps_its_own_words_but_not_all_of_them() {
        let short = transition_failure_message(6, "disk is full");
        assert!(short.contains("disk is full"), "{short}");
        assert!(!short.contains('\u{2026}'), "{short}");

        let long = transition_failure_message(6, &"z".repeat(400));
        assert!(long.chars().count() < 140, "{} chars: {}", long.chars().count(), long);
        assert!(long.contains('\u{2026}'), "{long}");
    }

    /// The browser filter is `retain(|s| s.browser_ok.unwrap_or(true))`, and
    /// the `unwrap_or(true)` is the load-bearing half: a provider that doesn't
    /// report the field — including any older frozen sidecar still in the wild
    /// — must keep working exactly as before rather than silently resolving to
    /// nothing.
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

