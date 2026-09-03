//! Serving a torrent release to a browser engine that cannot open one.
//!
//! Releases are Matroska, and WebKit has no Matroska support at all, in any
//! codec. That is the entire reason this module exists: the builtin `<video>`
//! player runs on the webview's engine, so without a remux the only anime
//! provider there is would be unplayable in it and the player would tell the
//! viewer to switch to mpv.
//!
//! The container is the whole problem: a simulcast release is already H.264
//! High 8-bit with AAC-LC audio, which is to say already exactly what iOS
//! plays — just in the wrong box. So ffmpeg copies the streams into fragmented
//! MP4 and serves them as HLS, which Safari plays natively. No decoding, no
//! encoding, no quality loss.
//!
//! Measured on the Pi 3 this runs on: stream copy is free, while decoding the
//! HEVC 10-bit a BD release ships runs at 1.15x realtime — so anything that
//! needs the video decoded (a transcode, or burning in subtitles) is out of
//! reach on this hardware and is refused rather than attempted. See
//! `playable_without_transcode`.
//!
//! ffmpeg reads through the app's own `/torrent-stream` endpoint rather than
//! off disk, so librqbit's piece prioritisation and read-ahead keep working
//! exactly as they do for mpv: the remux pulls the file in play order and the
//! swarm is asked for what is about to be needed.

use std::collections::HashMap;
use std::path::{Path, PathBuf};
use std::sync::atomic::{AtomicU64, Ordering};
use std::sync::Arc;

use axum::{
    body::Body,
    extract::{Path as AxumPath, Query, State},
    http::{header, StatusCode},
    response::Response,
};

use super::server::ProxyState;

/// How long a session may go unread before it is torn down.
const IDLE_TIMEOUT_SECS: u64 = 900;

/// How long to wait for ffmpeg to produce a playable playlist before giving
/// up. The first segment cannot appear until the torrent has delivered enough
/// of the file to fill it, so this is bounded by the swarm rather than by
/// ffmpeg.
const FIRST_SEGMENT_TIMEOUT_SECS: u64 = 45;

/// Sessions allowed to run at once. Each is an ffmpeg process and a directory
/// of segments; the Pi has four cores and a nearly-full SD card, and a third
/// concurrent viewer is better served by being told to use another provider
/// than by all three stuttering.
const MAX_SESSIONS: usize = 2;

/// Video codecs a browser can play once the container is fixed, with no
/// decoding on our side.
///
/// HEVC is included deliberately: iOS has played it in fMP4 since iOS 11, and
/// the release groups that ship BD encodes ship it. What is *not* here is the
/// 10-bit H.264 (Hi10P) endemic to older fansub releases — no browser decodes
/// it, on any platform, and no remux changes that.
fn playable_video(codec: &str, pix_fmt: &str) -> bool {
    match codec {
        "h264" => !pix_fmt.contains("10") && !pix_fmt.contains("p10"),
        "hevc" | "h265" => true,
        _ => false,
    }
}

/// Audio a browser can play as-is. Everything else is re-encoded to AAC,
/// which costs about a quarter of one core in real time (measured at 3.8x
/// realtime on the Pi 3) — affordable, unlike touching the video.
fn playable_audio(codec: &str) -> bool {
    matches!(codec, "aac" | "mp3" | "opus")
}

/// What ffprobe says about the file, reduced to the three decisions that
/// follow from it.
#[derive(Debug, Clone)]
pub struct MediaLayout {
    pub video_ok: bool,
    pub audio_copy: bool,
    pub audio_index: usize,
    /// Index of the first text subtitle track *among subtitle streams*, for
    /// `-map 0:s:N`. Image subtitles (PGS, VobSub) are skipped: converting
    /// them needs OCR, and burning them in needs the video decoded.
    pub text_subtitle: Option<usize>,
    pub video_codec: String,
    pub audio_codec: String,
}

/// Ask ffprobe what is in the file. Reads over HTTP from our own range
/// endpoint, so it only pulls the header.
pub async fn probe(input_url: &str, prefer_dub: bool) -> Result<MediaLayout, String> {
    let out = tokio::process::Command::new("ffprobe")
        .args([
            "-v", "error",
            "-show_entries", "stream=index,codec_type,codec_name,pix_fmt:stream_tags=language,title",
            "-of", "csv=p=0",
            input_url,
        ])
        .output()
        .await
        .map_err(|e| format!("ffprobe failed to run: {e}"))?;
    if !out.status.success() {
        return Err(format!(
            "ffprobe exited {}: {}",
            out.status,
            String::from_utf8_lossy(&out.stderr).trim()
        ));
    }
    let text = String::from_utf8_lossy(&out.stdout);
    let mut video: Option<(String, String)> = None;
    let mut audio_streams: Vec<(usize, String, String)> = Vec::new();
    let mut audio_counter = 0usize;
    let mut subtitle_index = 0usize;
    let mut text_subtitle = None;
    for line in text.lines() {
        let fields: Vec<&str> = line.split(',').collect();
        if fields.len() < 3 {
            continue;
        }
        let codec = fields[1].to_string();
        let kind = fields[2];
        match kind {
            "video" if video.is_none() => {
                if codec == "mjpeg" || codec == "png" {
                    continue;
                }
                let pix_fmt = fields.get(3).unwrap_or(&"").to_string();
                video = Some((codec, pix_fmt));
            }
            "audio" => {
                let tags = fields.get(3..).unwrap_or(&[]).join(" ").to_lowercase();
                audio_streams.push((audio_counter, codec, tags));
                audio_counter += 1;
            }
            "subtitle" => {
                if text_subtitle.is_none() && matches!(codec.as_str(), "ass" | "ssa" | "subrip" | "webvtt" | "mov_text") {
                    text_subtitle = Some(subtitle_index);
                }
                subtitle_index += 1;
            }
            _ => {}
        }
    }
    let (video_codec, pix_fmt) = video.ok_or_else(|| "no video stream".to_string())?;

    let is_eng_tagged = |tags: &str| tags.contains("eng") || tags.contains("en") || tags.contains("dub");
    let is_jpn_tagged = |tags: &str| tags.contains("jpn") || tags.contains("ja") || tags.contains("japanese");
    let (audio_index, audio_codec) = if audio_streams.is_empty() {
        (0, String::new())
    } else if prefer_dub {
        if let Some((idx, c, _)) = audio_streams.iter().find(|(_, _, tags)| is_eng_tagged(tags)) {
            (*idx, c.clone())
        } else if let Some((idx, c, _)) = audio_streams.iter().find(|(_, _, tags)| !is_jpn_tagged(tags)) {
            // No track says "eng"/"dub", but on a dual-audio release with
            // incomplete tagging, blindly taking index 0 is a coin flip — one
            // that landed wrong for at least one real release (Chivalry of a
            // Failed Knight served dub while set to Subtitled, the mirror of
            // this case). Prefer any track that isn't confidently the
            // *other* language over guessing index 0 outright.
            (*idx, c.clone())
        } else {
            (audio_streams[0].0, audio_streams[0].1.clone())
        }
    } else {
        if let Some((idx, c, _)) = audio_streams.iter().find(|(_, _, tags)| is_jpn_tagged(tags)) {
            (*idx, c.clone())
        } else if let Some((idx, c, _)) = audio_streams.iter().find(|(_, _, tags)| !is_eng_tagged(tags)) {
            (*idx, c.clone())
        } else {
            (audio_streams[0].0, audio_streams[0].1.clone())
        }
    };

    Ok(MediaLayout {
        video_ok: playable_video(&video_codec, &pix_fmt),
        audio_copy: playable_audio(&audio_codec),
        audio_index,
        text_subtitle,
        video_codec,
        audio_codec,
    })
}

struct Session {
    dir: PathBuf,
    child: tokio::process::Child,
    last_read: std::time::Instant,
    /// What this session is of, so a second request for the same episode at
    /// the same offset reuses it instead of starting a second ffmpeg.
    key: (usize, usize, i64),
}

impl Session {
    fn touch(&mut self) {
        self.last_read = std::time::Instant::now();
    }
}

/// Owns the running ffmpeg processes and their segment directories.
pub struct RemuxManager {
    root: PathBuf,
    sessions: tokio::sync::Mutex<HashMap<u64, Session>>,
    next_id: AtomicU64,
    available: tokio::sync::OnceCell<bool>,
}

impl RemuxManager {
    pub fn new() -> Self {
        // A sibling of the torrent cache, never inside it: `cleanup_cache`
        // walks that directory against a 3GB cap and evicts by age, which for
        // segments beside the file ffmpeg is reading would mean deleting the
        // stream out from under playback.
        let root = dirs::cache_dir()
            .unwrap_or_else(std::env::temp_dir)
            .join("anicat")
            .join("remux-sessions");
        let _ = std::fs::remove_dir_all(&root);
        Self {
            root,
            sessions: tokio::sync::Mutex::new(HashMap::new()),
            next_id: AtomicU64::new(1),
            available: tokio::sync::OnceCell::new(),
        }
    }

    /// Whether ffmpeg and ffprobe are both on PATH, answered once and
    /// remembered. Without them the whole path is unavailable and callers keep
    /// the behaviour they had before.
    pub async fn is_available(&self) -> bool {
        *self
            .available
            .get_or_init(|| async {
                let found = Self::probe_binaries().await;
                if !found {
                    log::info!("remux: ffmpeg/ffprobe not found; torrent playback stays desktop-only");
                }
                found
            })
            .await
    }

    async fn probe_binaries() -> bool {
        for bin in ["ffmpeg", "ffprobe"] {
            let ok = tokio::process::Command::new(bin)
                .arg("-version")
                .stdout(std::process::Stdio::null())
                .stderr(std::process::Stdio::null())
                .status()
                .await
                .map(|s| s.success())
                .unwrap_or(false);
            if !ok {
                return false;
            }
        }
        true
    }

    /// Start (or reuse) a session and return the path the player should load.
    pub async fn start(
        &self,
        input_url: &str,
        torrent_id: usize,
        file_id: usize,
        start_seconds: i64,
        prefer_dub: bool,
    ) -> Result<String, String> {
        let key = (torrent_id, file_id, start_seconds);
        {
            let mut sessions = self.sessions.lock().await;
            self.reap_locked(&mut sessions).await;
            if let Some((id, session)) = sessions.iter_mut().find(|(_, s)| s.key == key) {
                session.touch();
                return Ok(format!("/hls/{}/stream_0/index.m3u8", id));
            }
            if sessions.len() >= MAX_SESSIONS {
                return Err(format!(
                    "already remuxing {} streams; the Pi can't keep up with another",
                    sessions.len()
                ));
            }
        }

        let layout = probe(input_url, prefer_dub).await?;
        if !layout.video_ok {
            return Err(format!(
                "{} video in this release can't be played by a browser without re-encoding it, which this machine is too slow to do",
                layout.video_codec
            ));
        }

        let id = self.next_id.fetch_add(1, Ordering::Relaxed);
        let dir = self.root.join(id.to_string()).join("stream_0");
        std::fs::create_dir_all(&dir).map_err(|e| format!("segment dir: {e}"))?;
        let session_root = self.root.join(id.to_string());

        let mut child = spawn_ffmpeg(input_url, &session_root, &layout, start_seconds)?;
        // Taken before the child is stored: `stop`/`reap_locked` own it from
        // here for `.kill()`, and stderr is a separate handle that doesn't
        // need mutable access to the child to read, so draining it doesn't
        // race whichever of those tears the process down.
        if let Some(stderr) = child.stderr.take() {
            tokio::spawn(log_ffmpeg_stderr(id, stderr));
        }
        {
            let mut sessions = self.sessions.lock().await;
            sessions.insert(
                id,
                Session { dir: session_root.clone(), child, last_read: std::time::Instant::now(), key },
            );
        }

        // Hand the player a playlist only once ffmpeg has written one. Safari
        // treats a 404 on the master playlist as a hard failure rather than
        // something to retry, so returning early would surface as "this
        // episode is broken" on what is really a slow first segment.
        let first_segment = dir.join("index.m3u8");
        let deadline =
            std::time::Instant::now() + std::time::Duration::from_secs(FIRST_SEGMENT_TIMEOUT_SECS);
        while std::time::Instant::now() < deadline {
            if playlist_has_segment(&first_segment) {
                log::info!(
                    "remux: session {} ready ({} video copied, audio {})",
                    id,
                    layout.video_codec,
                    if layout.audio_copy { "copied" } else { "re-encoded to aac" },
                );
                return Ok(format!("/hls/{}/stream_0/index.m3u8", id));
            }
            tokio::time::sleep(std::time::Duration::from_millis(250)).await;
        }
        self.stop(id).await;
        Err("timed out waiting for the first segment".into())
    }

    /// Read a file out of a session's directory, refreshing its idle timer.
    async fn read(&self, id: u64, rel: &str) -> Option<(Vec<u8>, &'static str)> {
        let dir = {
            let mut sessions = self.sessions.lock().await;
            let session = sessions.get_mut(&id)?;
            session.touch();
            session.dir.clone()
        };
        // Path traversal guard: the player only ever asks for names ffmpeg
        // wrote, and anything with a separator or a parent reference in it is
        // not one of those.
        if rel.contains("..") || rel.starts_with('/') {
            return None;
        }
        let path = dir.join(rel);
        let bytes = tokio::fs::read(&path).await.ok()?;
        Some((bytes, content_type_for(rel)))
    }

    pub async fn stop(&self, id: u64) {
        let session = self.sessions.lock().await.remove(&id);
        if let Some(mut session) = session {
            let _ = session.child.kill().await;
            let _ = std::fs::remove_dir_all(&session.dir);
            log::info!("remux: session {} stopped", id);
        }
    }

    /// Tear down every session for a torrent — called when playback stops, so
    /// segments don't outlive the thing they were made for.
    pub async fn stop_for_torrent(&self, torrent_id: usize) {
        let ids: Vec<u64> = {
            let sessions = self.sessions.lock().await;
            sessions
                .iter()
                .filter(|(_, s)| s.key.0 == torrent_id)
                .map(|(id, _)| *id)
                .collect()
        };
        for id in ids {
            self.stop(id).await;
        }
    }

    async fn reap_locked(&self, sessions: &mut HashMap<u64, Session>) {
        let now = std::time::Instant::now();
        let idle: Vec<u64> = sessions
            .iter()
            .filter(|(_, s)| now.duration_since(s.last_read).as_secs() > IDLE_TIMEOUT_SECS)
            .map(|(id, _)| *id)
            .collect();
        for id in idle {
            if let Some(mut session) = sessions.remove(&id) {
                let _ = session.child.kill().await;
                let _ = std::fs::remove_dir_all(&session.dir);
                log::info!("remux: session {} reaped after {}s idle", id, IDLE_TIMEOUT_SECS);
            }
        }
    }

    /// Background sweep, so a session whose viewer simply closed the player is
    /// cleaned up without anyone asking. Each one holds an ffmpeg process
    /// writing several megabytes a minute, so nothing may rely on a tidy exit.
    pub fn spawn_reaper(self: &Arc<Self>) {
        let manager = Arc::clone(self);
        tokio::spawn(async move {
            loop {
                tokio::time::sleep(std::time::Duration::from_secs(30)).await;
                let mut sessions = manager.sessions.lock().await;
                manager.reap_locked(&mut sessions).await;
            }
        });
    }
}

impl Default for RemuxManager {
    fn default() -> Self {
        Self::new()
    }
}

/// Has ffmpeg written a playlist with at least one segment in it?
fn playlist_has_segment(path: &Path) -> bool {
    std::fs::read_to_string(path)
        .map(|text| text.contains(".m4s"))
        .unwrap_or(false)
}

fn spawn_ffmpeg(
    input_url: &str,
    session_root: &Path,
    layout: &MediaLayout,
    start_seconds: i64,
) -> Result<tokio::process::Child, String> {
    let mut cmd = tokio::process::Command::new("ffmpeg");
    cmd.arg("-nostdin").args(["-loglevel", "error"]);
    // Before -i, so the seek is a keyframe jump rather than a decode from
    // zero; our range endpoint turns it into a piece-priority jump in the
    // swarm, exactly as an mpv seek does.
    if start_seconds > 0 {
        cmd.args(["-ss", &start_seconds.to_string()]);
    }
    // Only for a network input. These are options on ffmpeg's *http* protocol,
    // and ffmpeg rejects an option the input's protocol doesn't define rather
    // than ignoring it: against a plain path, ffmpeg 8 answers "Option
    // reconnect not found." and exits before writing a single segment, so the
    // caller sat out its whole timeout and reported "timed out waiting for the
    // first segment" with no clue why (stderr is /dev/null here). The real
    // input is normally the proxy's own `/torrent-stream` URL, which is why
    // this survived -- a local path only shows up when something remuxes a
    // file on disk.
    if input_url.starts_with("http://") || input_url.starts_with("https://") {
        cmd.args([
            "-reconnect", "1",
            "-reconnect_at_eof", "1",
            "-reconnect_streamed", "1",
            "-reconnect_delay_max", "10",
        ]);
    }
    cmd.args(["-i", input_url]);
    cmd.args(["-map", "0:v:0", "-map", &format!("0:a:{}", layout.audio_index)]);
    let stream_map = String::from("v:0,a:0");
    cmd.args(["-c:v", "copy"]);
    if layout.audio_copy {
        cmd.args(["-c:a", "copy"]);
    } else {
        cmd.args(["-c:a", "aac", "-b:a", "192k", "-ac", "2"]);
    }
    cmd.args([
        "-f", "hls",
        "-hls_time", "6",
        "-hls_playlist_type", "event",
        "-hls_list_size", "0",
        "-hls_segment_type", "fmp4",
        "-hls_fmp4_init_filename", "init.mp4",
        "-var_stream_map", &stream_map,
        "-master_pl_name", "master.m3u8",
    ]);
    cmd.arg("-hls_segment_filename")
        .arg(session_root.join("stream_%v").join("seg%05d.m4s"));
    cmd.arg(session_root.join("stream_%v").join("index.m3u8"));
    // stderr is piped, not discarded: `start` reads it in the background and
    // logs whatever ffmpeg said the moment the pipe closes (natural exit,
    // crash, or our own kill all close it the same way). Without this, an
    // ffmpeg that stopped remuxing partway through an episode -- server
    // closed the connection, a codec it didn't expect mid-stream, anything --
    // left no trace at all: "timed out waiting for the first segment" already
    // has a comment noting the same blind spot for the startup case.
    cmd.stdout(std::process::Stdio::null())
        .stderr(std::process::Stdio::piped())
        .kill_on_drop(true);
    cmd.spawn().map_err(|e| format!("ffmpeg failed to start: {e}"))
}

/// Drains an ffmpeg session's stderr and logs the tail once the pipe closes.
///
/// `-loglevel error` keeps this to genuine problems, so a healthy session
/// logs nothing at all; a session that stopped remuxing early -- the case
/// this exists for -- logs the reason instead of leaving a truncated episode
/// with no explanation anywhere. Capped rather than buffered whole: a
/// crash-looping process could otherwise write stderr forever into a task
/// nothing ever reads back except at exit.
async fn log_ffmpeg_stderr(id: u64, stderr: tokio::process::ChildStderr) {
    use tokio::io::AsyncBufReadExt;
    const TAIL_LINES: usize = 40;
    let mut lines = tokio::io::BufReader::new(stderr).lines();
    let mut tail: std::collections::VecDeque<String> = std::collections::VecDeque::with_capacity(TAIL_LINES);
    while let Ok(Some(line)) = lines.next_line().await {
        if tail.len() == TAIL_LINES {
            tail.pop_front();
        }
        tail.push_back(line);
    }
    if !tail.is_empty() {
        log::warn!(
            "remux: session {} ffmpeg stderr:\n{}",
            id,
            Vec::from(tail).join("\n")
        );
    }
}

fn content_type_for(name: &str) -> &'static str {
    if name.ends_with(".m3u8") {
        "application/vnd.apple.mpegurl"
    } else if name.ends_with(".m4s") || name.ends_with(".mp4") {
        "video/mp4"
    } else if name.ends_with(".vtt") {
        "text/vtt"
    } else {
        "application/octet-stream"
    }
}

/// Serve one file of a session. Ungated for the same reason `/proxy` and
/// `/torrent-stream` are: a `<video>` element fetches these itself and cannot
/// be made to carry a token, and what they expose is bytes of a torrent this
/// app is already streaming.
pub async fn session_file_handler(
    State(state): State<ProxyState>,
    AxumPath((id, file)): AxumPath<(u64, String)>,
) -> Response {
    // The master playlist points at "stream_0/index.m3u8"; the player then
    // asks for that path relative to the master's own directory.
    match state.app_state.inner.remux.read(id, &file).await {
        Some((bytes, content_type)) => Response::builder()
            .status(StatusCode::OK)
            .header(header::CONTENT_TYPE, content_type)
            .header(header::ACCESS_CONTROL_ALLOW_ORIGIN, "*")
            .header(header::ACCESS_CONTROL_ALLOW_METHODS, "GET, HEAD, OPTIONS")
            // Playlists grow while ffmpeg writes; a cached one strands the
            // player at whatever length it had on first fetch.
            .header(header::CACHE_CONTROL, "no-store")
            .body(Body::from(bytes))
            .unwrap(),
        None => Response::builder()
            .status(StatusCode::NOT_FOUND)
            .header(header::ACCESS_CONTROL_ALLOW_ORIGIN, "*")
            .body(Body::from("no such remux session"))
            .unwrap(),
    }
}

/// The nested form: `/hls/{id}/stream_0/index.m3u8`.
pub async fn session_nested_handler(
    State(state): State<ProxyState>,
    AxumPath((id, dir, file)): AxumPath<(u64, String, String)>,
) -> Response {
    if dir.contains("..") {
        return Response::builder()
            .status(StatusCode::BAD_REQUEST)
            .header(header::ACCESS_CONTROL_ALLOW_ORIGIN, "*")
            .body(Body::from("bad path"))
            .unwrap();
    }
    let rel = format!("{dir}/{file}");
    match state.app_state.inner.remux.read(id, &rel).await {
        Some((bytes, content_type)) => Response::builder()
            .status(StatusCode::OK)
            .header(header::CONTENT_TYPE, content_type)
            .header(header::ACCESS_CONTROL_ALLOW_ORIGIN, "*")
            .header(header::ACCESS_CONTROL_ALLOW_METHODS, "GET, HEAD, OPTIONS")
            .header(header::CACHE_CONTROL, "no-store")
            .body(Body::from(bytes))
            .unwrap(),
        None => Response::builder()
            .status(StatusCode::NOT_FOUND)
            .header(header::ACCESS_CONTROL_ALLOW_ORIGIN, "*")
            .body(Body::from("no such remux session file"))
            .unwrap(),
    }
}

#[derive(serde::Deserialize)]
pub struct StopQuery {
    id: u64,
}

/// Explicit teardown, so closing the player doesn't leave ffmpeg running for
/// the full idle timeout.
pub async fn stop_handler(State(state): State<ProxyState>, Query(q): Query<StopQuery>) -> StatusCode {
    state.app_state.inner.remux.stop(q.id).await;
    StatusCode::NO_CONTENT
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn only_codecs_a_browser_can_decode_are_accepted() {
        // The simulcast case: 8-bit H.264, which is what a browser wants.
        assert!(playable_video("h264", "yuv420p"));
        // BD releases ship HEVC, which iOS decodes in fMP4 -- the container
        // was the problem, not the codec.
        assert!(playable_video("hevc", "yuv420p10le"));
        // Hi10P: no browser on any platform decodes 10-bit H.264, and no
        // remux changes that. Accepting it would produce a session that
        // burns CPU and then plays nothing.
        assert!(!playable_video("h264", "yuv420p10le"));
        assert!(!playable_video("av1", "yuv420p"));
        assert!(!playable_video("vp9", "yuv420p"));
    }

    #[test]
    fn audio_is_copied_only_when_a_browser_can_decode_it() {
        assert!(playable_audio("aac"));
        assert!(playable_audio("opus"));
        // Everything a BD release ships: re-encode, which is affordable.
        assert!(!playable_audio("ac3"));
        assert!(!playable_audio("eac3"));
        assert!(!playable_audio("flac"));
        assert!(!playable_audio("dts"));
        assert!(!playable_audio("truehd"));
    }

    /// Build a small H.264 + AAC file, which is what a simulcast release is,
    /// and put it through the real thing.
    async fn fixture(path: &std::path::Path) -> bool {
        if !RemuxManager::probe_binaries().await {
            eprintln!("skipping: ffmpeg/ffprobe not installed");
            return false;
        }
        let status = tokio::process::Command::new("ffmpeg")
            .args([
                "-nostdin", "-loglevel", "error", "-y",
                "-f", "lavfi", "-i", "testsrc=size=320x240:rate=25:duration=8",
                "-f", "lavfi", "-i", "sine=frequency=440:duration=8",
                "-c:v", "libx264", "-pix_fmt", "yuv420p", "-c:a", "aac",
            ])
            .arg(path)
            .status()
            .await;
        status.map(|s| s.success()).unwrap_or(false)
    }

    #[tokio::test]
    async fn a_session_produces_a_playlist_a_player_can_load() {
        let dir = std::env::temp_dir().join(format!("anicat-remux-test-{}", std::process::id()));
        let _ = std::fs::create_dir_all(&dir);
        let input = dir.join("episode.mkv");
        if !fixture(&input).await {
            return;
        }

        let layout = probe(input.to_str().unwrap(), false).await.expect("probe failed");
        assert!(layout.video_ok, "h264 8-bit should need no re-encoding");
        assert!(layout.audio_copy, "aac should be copied, not re-encoded");

        let manager = RemuxManager::new();
        let url = manager
            .start(input.to_str().unwrap(), 42, 7, 0, false)
            .await
            .expect("session failed to start");
        assert!(url.starts_with("/hls/"), "{url}");
        let id: u64 = url.trim_start_matches("/hls/").split('/').next().unwrap().parse().unwrap();

        // The master playlist has to name both the video rendition and the
        // audio codecs, or Safari refuses it outright.
        let (master, content_type) = manager.read(id, "master.m3u8").await.expect("no master playlist");
        let master = String::from_utf8(master).unwrap();
        assert_eq!(content_type, "application/vnd.apple.mpegurl");
        assert!(master.contains("#EXTM3U"), "{master}");
        assert!(master.contains("stream_0/index.m3u8"), "{master}");

        // And the segments it points at must actually be readable.
        let (media, _) = manager.read(id, "stream_0/index.m3u8").await.expect("no media playlist");
        let media = String::from_utf8(media).unwrap();
        assert!(media.contains(".m4s"), "{media}");
        let segment = media.lines().find(|l| l.ends_with(".m4s")).unwrap();
        let (bytes, ct) = manager
            .read(id, &format!("stream_0/{segment}"))
            .await
            .expect("segment missing");
        assert_eq!(ct, "video/mp4");
        assert!(!bytes.is_empty());

        // Asking again for the same episode at the same offset reuses the
        // session rather than starting a second ffmpeg beside it.
        let again = manager.start(input.to_str().unwrap(), 42, 7, 0, false).await.unwrap();
        assert_eq!(again, url);

        // A path that climbs out of the session directory is refused however
        // it is spelled.
        assert!(manager.read(id, "../../../etc/passwd").await.is_none());

        manager.stop(id).await;
        assert!(manager.read(id, "master.m3u8").await.is_none(), "session outlived its stop");
        assert!(!manager.root.join(id.to_string()).exists(), "segments outlived their session");
        let _ = std::fs::remove_dir_all(&dir);
    }

    #[test]
    fn segments_live_outside_the_torrent_cache() {
        // `cleanup_cache` walks the torrent cache against a 3GB cap and
        // evicts by age. Segments written beside the file being read would
        // put playback and the evictor in each other's way.
        let manager = RemuxManager::new();
        let torrents = dirs::cache_dir()
            .unwrap_or_else(std::env::temp_dir)
            .join("anicat")
            .join("torrent-streams");
        assert!(!manager.root.starts_with(&torrents), "{:?}", manager.root);
    }
}
