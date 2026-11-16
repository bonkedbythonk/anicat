//! What every route and the player share.

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
    /// The token the engine holds. `AnicatEngine` can take one but exposes
    /// no way to read it or ask whether it has one, and the page needs to
    /// know which state to draw; `set_token` also restores the previous
    /// token when AniList rejects a pasted one.
    pub token: Arc<Mutex<Option<String>>>,
    /// For the GitHub release check; core's client is private to it.
    pub http: reqwest::Client,
}

impl AppState {
    pub fn signed_in(&self) -> bool {
        self.token.lock().map(|t| t.is_some()).unwrap_or(false)
    }
}

#[cfg(test)]
impl AppState {
    /// A real engine on a fresh registry in the temp dir; nothing here
    /// touches the network until a route asks AniList or TMDB something.
    pub fn for_test(name: &str, token: Option<&str>) -> Self {
        let data_dir = std::env::temp_dir().join(format!("anicat-server-test-{name}-{}", std::process::id()));
        let _ = std::fs::remove_dir_all(&data_dir);
        std::fs::create_dir_all(&data_dir).expect("temp dir");
        let engine = AnicatEngine::new(data_dir.to_string_lossy().into_owned(), None, None, None).expect("engine");
        let writer = Writer::spawn(engine.clone());
        let http = reqwest::Client::new();
        let prefs = Arc::new(crate::player::prefs::PrefsStore::load(&data_dir));
        let player = Arc::new(Player::new(engine.clone(), writer.clone(), prefs, http.clone()));
        Self {
            engine,
            writer,
            player,
            data_dir,
            port: 0,
            log_redirected: false,
            token: Arc::new(Mutex::new(token.map(str::to_string))),
            http,
        }
    }
}
