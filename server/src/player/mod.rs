//! The external player. `POST /api/play` resolves a stream and hands it to
//! `Player::play`; everything after that (spawning mpv, its IPC, progress,
//! 85% watched, 75% preload, the playlist advance) happens here.

mod ipc;
mod mpv;
mod policy;
pub mod routes;
mod session;

use std::sync::{Arc, Mutex};

use anicat_core::ffi::{AnicatEngine, FfiCatalog, StreamHandle};
use serde::Serialize;

use crate::writer::Writer;

/// What the route knew when it asked for a play, beyond the stream itself.
#[derive(Debug, Clone)]
pub struct PlayRequest {
    pub catalog: FfiCatalog,
    pub catalog_id: i64,
    pub episode: i64,
    /// For mpv's window title.
    pub title: Option<String>,
    pub prefer_dub: bool,
    /// Where to start, in seconds; 0 for the beginning.
    pub start_seconds: f64,
    /// The recorded duration, when there is one.
    #[allow(dead_code)] // mpv reports the real one as soon as the file loads
    pub duration_seconds: Option<f64>,
}

/// `GET /api/player`. The page codes against these exact field names.
#[derive(Debug, Clone, Default, Serialize)]
pub struct Snapshot {
    pub active: bool,
    pub catalog: Option<FfiCatalog>,
    pub catalog_id: Option<i64>,
    pub episode: Option<i64>,
    pub title: Option<String>,
    pub position: Option<f64>,
    pub duration: Option<f64>,
    pub paused: Option<bool>,
    pub next_ready: bool,
}

pub struct Player {
    engine: Arc<AnicatEngine>,
    writer: Writer,
    /// Held across a whole play or stop: two plays racing would each find no
    /// mpv and start one, and both would claim the same pipe name.
    session: tokio::sync::Mutex<Option<session::Handle>>,
    /// Read by `GET /api/player` without touching the session, so a stalled
    /// mpv cannot hang the page's polling.
    snapshot: Arc<Mutex<Snapshot>>,
}

impl Player {
    pub fn new(engine: Arc<AnicatEngine>, writer: Writer) -> Self {
        Self {
            engine,
            writer,
            session: tokio::sync::Mutex::new(None),
            snapshot: Arc::default(),
        }
    }

    /// Plays a resolved stream: into the running mpv when there is one, in a
    /// new one otherwise. One mpv, one playing file, one pin.
    pub async fn play(&self, handle: &StreamHandle, request: &PlayRequest) -> Result<(), String> {
        let mut slot = self.session.lock().await;
        if let Some(live) = slot.as_ref().filter(|h| !h.join.is_finished()) {
            let (reply, answer) = tokio::sync::oneshot::channel();
            let sent = live.cmd.send(session::Cmd::Replace {
                url: handle.url.clone(),
                request: request.clone(),
                reply,
            });
            if sent.is_ok() {
                match answer.await {
                    Ok(result) => return result,
                    // The session ended between the check and the command:
                    // mpv was closed a moment ago. Start a new one below.
                    Err(_) => log::info!("[player] mpv exited while taking a new file, starting another"),
                }
            }
        }
        if let Some(old) = slot.take() {
            // Its finish (final write, then pause) has to land before the new
            // mpv starts reading, or the pause lands on the new stream.
            let _ = old.join.await;
        }
        log::info!(
            "[player] play {:?}:{} episode {} at {:.0}s",
            request.catalog,
            request.catalog_id,
            request.episode,
            request.start_seconds
        );
        let started = session::start(
            self.engine.clone(),
            self.writer.clone(),
            self.snapshot.clone(),
            handle.url.clone(),
            request.clone(),
        )
        .await?;
        *slot = Some(started);
        Ok(())
    }

    /// Quits mpv, if one is running, and waits for its session to write the
    /// final position. `playback_stopped` then releases the playing-file pin
    /// and pauses the torrent session; without it librqbit keeps pulling the
    /// episode, and any preload, at full speed with nobody watching.
    pub async fn stop(&self) {
        log::info!("[player] stop");
        let mut slot = self.session.lock().await;
        if let Some(live) = slot.take() {
            let _ = live.cmd.send(session::Cmd::Quit);
            let _ = live.join.await;
        }
        self.engine.playback_stopped().await;
    }

    pub fn snapshot(&self) -> Snapshot {
        self.snapshot.lock().map(|s| s.clone()).unwrap_or_default()
    }
}
