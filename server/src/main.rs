//! Anicat for Windows (and, for development, macOS): the Rust engine behind
//! a local HTTP API and one HTML page. See docs/WINDOWS_PLAN.md.

mod config;
mod error;
mod logging;
mod player;
mod routes;
mod state;
mod version;
mod writer;

use std::sync::{Arc, Mutex};

use anicat_core::ffi::AnicatEngine;

use crate::player::Player;
use crate::state::AppState;
use crate::writer::Writer;

/// Fixed so a bookmark keeps working across launches.
const PREFERRED_PORT: u16 = 47111;
/// Successors tried when the preferred port is taken.
const PORT_FALLBACKS: u16 = 10;

#[tokio::main]
async fn main() {
    let data_dir = config::data_dir();
    // First, before the engine: `AnicatEngine::new` installs env_logger, and
    // nothing said before the redirect reaches the file.
    let log_redirected = logging::start(&data_dir);

    let token = config::load_token(&data_dir);
    let proxy = config::tmdb_proxy();
    let engine = match AnicatEngine::new(
        data_dir.to_string_lossy().into_owned(),
        token.clone(),
        None,
        proxy.clone(),
    ) {
        Ok(e) => e,
        Err(e) => {
            eprintln!("engine failed to start: {e}");
            std::process::exit(1);
        }
    };
    log::info!(
        "Anicat server {} on {} {}, data at {}, signed in: {}, TMDB proxy: {}",
        version::current(),
        std::env::consts::OS,
        std::env::consts::ARCH,
        data_dir.display(),
        token.is_some(),
        proxy.is_some(),
    );

    // Off the path to the first request: DHT bootstrap is seconds, and the
    // page should load while it runs. A first play otherwise pays for it.
    {
        let engine = engine.clone();
        tokio::spawn(async move { engine.warm_up().await });
    }

    let (listener, port) = match bind().await {
        Some(pair) => pair,
        None => {
            log::error!(
                "no free port in 127.0.0.1:{}..={}",
                PREFERRED_PORT,
                PREFERRED_PORT + PORT_FALLBACKS
            );
            std::process::exit(1);
        }
    };

    let writer = Writer::spawn(engine.clone());
    let player = Arc::new(Player::new(engine.clone(), writer.clone()));
    let http = reqwest::Client::builder()
        // GitHub's API refuses requests with no User-Agent.
        .user_agent(format!("Anicat-Server/{} (+https://github.com/bonkedbythonk/anicat)", version::current()))
        .build()
        .expect("reqwest client");
    let state = AppState {
        engine,
        writer,
        player: player.clone(),
        data_dir,
        port,
        log_redirected,
        token: Arc::new(Mutex::new(token)),
        http,
    };

    log::info!("listening on http://127.0.0.1:{port}/");
    let app = routes::router(state);
    let shutdown = async move {
        let _ = tokio::signal::ctrl_c().await;
        // Pauses the session on the way out, as Quit will in wave 2.
        player.stop().await;
    };
    if let Err(e) = axum::serve(listener, app).with_graceful_shutdown(shutdown).await {
        log::error!("server stopped: {e}");
    }
}

/// Loopback only. Anything wider publishes the viewer's watch history and
/// download cache to the LAN, which is why the range server binds the same.
async fn bind() -> Option<(tokio::net::TcpListener, u16)> {
    for port in PREFERRED_PORT..=PREFERRED_PORT + PORT_FALLBACKS {
        match tokio::net::TcpListener::bind(("127.0.0.1", port)).await {
            Ok(l) => return Some((l, port)),
            Err(e) => log::warn!("127.0.0.1:{port} unavailable: {e}"),
        }
    }
    None
}
