//! The seam the external player plugs into. Wave 1 stub.
//!
//! `POST /api/play` resolves a stream and then calls `Player::play`; the
//! route never touches mpv itself. Wave 2 replaces the bodies of `play` and
//! `stop` (spawn mpv, IPC, tick handling, 85% watched, 75% preload) and
//! keeps these signatures, so `routes.rs` does not change.

use std::sync::Arc;

use anicat_core::ffi::{AnicatEngine, FfiCatalog, StreamHandle};

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
    pub duration_seconds: Option<f64>,
}

pub struct Player {
    engine: Arc<AnicatEngine>,
    #[allow(dead_code)] // wave 2 records progress through it
    writer: Writer,
}

impl Player {
    pub fn new(engine: Arc<AnicatEngine>, writer: Writer) -> Self {
        Self { engine, writer }
    }

    /// Hands a resolved stream to the player. The stub only logs.
    pub async fn play(&self, handle: &StreamHandle, request: &PlayRequest) -> Result<(), String> {
        log::info!(
            "[player] stub play {:?}:{} ep {} ({:?}, dub {}) at {:.0}s of {:?} -> {}",
            request.catalog,
            request.catalog_id,
            request.episode,
            request.title,
            request.prefer_dub,
            request.start_seconds,
            request.duration_seconds,
            handle.url
        );
        Ok(())
    }

    /// The player has stopped reading. Releases the playing-file pin and
    /// pauses the torrent session; without it librqbit keeps pulling the
    /// episode, and any preload, at full speed with nobody watching. This
    /// call stays when wave 2 adds killing mpv around it.
    pub async fn stop(&self) {
        log::info!("[player] stop");
        self.engine.playback_stopped().await;
    }
}
