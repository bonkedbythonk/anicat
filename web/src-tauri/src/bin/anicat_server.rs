//! Headless build of anicat's backend for self-hosting (e.g. on a Raspberry
//! Pi, reachable over Tailscale) without the desktop Tauri window. Serves
//! the same `/mobile-api/*` + mobile PWA surface the desktop app exposes on
//! the LAN today, just running continuously under systemd instead of only
//! while the desktop app happens to be open. See PI_SETUP.md at the repo
//! root for the full deployment walkthrough.
//!
//! Deliberately out of scope here (desktop-only, never reached by
//! mobile-api): mpv playback, the download queue, AniList OAuth login (do
//! that once on desktop or any browser — the resulting token lives in
//! config.toml, which this binary reads from the same place), and native OS
//! notifications.

use anicat::state::AppState;

#[tokio::main]
async fn main() {
    env_logger::Builder::from_env(env_logger::Env::default().default_filter_or("info"))
        .init();

    if handle_cli_args() {
        return;
    }

    let app_state = AppState::new();
    let client = app_state.http_client.clone();

    let bound = anicat::proxy::server::start_proxy(client, None, app_state.clone()).await;
    log::info!("anicat-server listening on {}", bound);

    tokio::spawn(anicat::commands::notifications::start_airing_notification_worker(
        None,
        app_state.clone(),
    ));

    wait_for_shutdown_signal().await;
    log::info!("Shutting down — stopping scraper subprocess");
    app_state.scraper_manager.shutdown_blocking();
}

/// `anicat-server add-user <display_name> <pin>` registers a friend and
/// exits without starting the server — no authenticated HTTP admin surface
/// exists on purpose (smallest possible attack surface, and whoever can run
/// this already has shell access to the machine, a stronger trust boundary
/// than anything in-app could add). Returns `true` if a subcommand ran (so
/// `main` should not go on to start the server).
fn handle_cli_args() -> bool {
    let args: Vec<String> = std::env::args().skip(1).collect();
    match args.first().map(String::as_str) {
        None => false,
        Some("add-user") => {
            let (Some(display_name), Some(pin)) = (args.get(1), args.get(2)) else {
                eprintln!("usage: anicat-server add-user <display_name> <pin>");
                std::process::exit(2);
            };
            let db_path = registry_db_path();
            if let Some(parent) = db_path.parent() {
                if let Err(e) = std::fs::create_dir_all(parent) {
                    eprintln!("failed to create {}: {}", parent.display(), e);
                    std::process::exit(1);
                }
            }
            let conn = match rusqlite::Connection::open(&db_path) {
                Ok(c) => c,
                Err(e) => {
                    eprintln!("failed to open {}: {}", db_path.display(), e);
                    std::process::exit(1);
                }
            };
            if let Err(e) = anicat::registry::service::initialize(&conn) {
                eprintln!("failed to initialize database: {}", e);
                std::process::exit(1);
            }
            match anicat::registry::service::create_user(&conn, display_name, pin) {
                Ok(id) => println!("Created user '{}' with id {}", display_name, id),
                Err(e) => {
                    eprintln!("failed to create user: {}", e);
                    std::process::exit(1);
                }
            }
            true
        }
        Some(other) => {
            eprintln!("Unknown subcommand: {other}");
            std::process::exit(2);
        }
    }
}

/// Mirrors `AppState::new()`'s db_path resolution (`state.rs`) — deliberately
/// not reusing `AppState::new()` itself here, since that also spawns the
/// scraper manager, connects Discord, etc., none of which `add-user` needs.
fn registry_db_path() -> std::path::PathBuf {
    dirs::config_dir()
        .unwrap_or_else(|| std::path::PathBuf::from("."))
        .join("anicat")
        .join("registry.db")
}

#[cfg(unix)]
async fn wait_for_shutdown_signal() {
    use tokio::signal::unix::{signal, SignalKind};
    let mut sigterm = signal(SignalKind::terminate()).expect("failed to install SIGTERM handler");
    tokio::select! {
        _ = tokio::signal::ctrl_c() => log::info!("Received SIGINT"),
        _ = sigterm.recv() => log::info!("Received SIGTERM"),
    }
}

#[cfg(not(unix))]
async fn wait_for_shutdown_signal() {
    let _ = tokio::signal::ctrl_c().await;
    log::info!("Received Ctrl-C");
}
