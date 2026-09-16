//! What every route and the player share. Wave 2 (player loop, tray, page)
//! builds on this; keep its fields stable.

use std::path::PathBuf;
use std::sync::{Arc, Mutex};

use anicat_core::ffi::AnicatEngine;

use crate::player::Player;
use crate::writer::Writer;

#[derive(Clone)]
pub struct AppState {
    pub engine: Arc<AnicatEngine>,
    /// Every progress and list write goes through this; see `writer.rs`.
    pub writer: Writer,
    pub player: Arc<Player>,
    pub data_dir: PathBuf,
    /// The port the API bound, after the fallback scan.
    pub port: u16,
    /// Whether stdout and stderr were redirected into `anicat.log`.
    pub log_redirected: bool,
    /// The token the engine holds. The engine can take one but not report
    /// whether it has one, and the page needs to know which state to draw.
    pub token: Arc<Mutex<Option<String>>>,
    /// For the GitHub release check; core's client is private to it.
    pub http: reqwest::Client,
}

impl AppState {
    pub fn signed_in(&self) -> bool {
        self.token.lock().map(|t| t.is_some()).unwrap_or(false)
    }
}
