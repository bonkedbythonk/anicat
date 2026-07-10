mod anilist;
mod cache;
mod commands;
mod discord;
mod proxy;
mod registry;
mod scraper;
mod state;
mod torrent;
mod util;

use state::AppState;
use tauri::Manager;

#[cfg_attr(mobile, tauri::mobile_entry_point)]
pub fn run() {
    // Truncate log files on startup so they are fresh. The log directory is
    // platform-specific, so resolve it per OS (each branch owns its base dir).
    #[cfg(target_os = "macos")]
    let log_dir = dirs::home_dir().map(|home| home.join("Library/Logs/com.anicat.app"));
    #[cfg(target_os = "windows")]
    let log_dir = dirs::data_dir().map(|appdata| appdata.join("com.anicat.app").join("logs"));
    #[cfg(target_os = "linux")]
    let log_dir = dirs::cache_dir().map(|cache| cache.join("com.anicat.app").join("logs"));

    if let Some(log_dir) = log_dir {
        for name in &["Anicat.log", "anicat.log"] {
            let log_file = log_dir.join(name);
            if log_file.exists() {
                let _ = std::fs::write(&log_file, "");
            }
        }
    }

    // Install a tracing subscriber (off unless RUST_LOG says otherwise).
    // librqbit and its DHT emit via `tracing`; with no subscriber present,
    // `tracing` falls back to the `log` crate, and tauri-plugin-log then
    // renders every transient peer/DHT error to the console. Owning the
    // subscriber — even a silent one — stops that fallback entirely.
    {
        let filter = tracing_subscriber::EnvFilter::try_from_default_env()
            .unwrap_or_else(|_| tracing_subscriber::EnvFilter::new("off"));
        let _ = tracing_subscriber::fmt()
            .with_env_filter(filter)
            .with_writer(std::io::stderr)
            .try_init();
    }

    let app_state = AppState::new();

    tauri::Builder::default()
        .plugin(tauri_plugin_shell::init())
        .plugin(tauri_plugin_notification::init())
        .plugin(tauri_plugin_log::Builder::default()
            .level(log::LevelFilter::Warn)
            .level_for("anicat", log::LevelFilter::Info)
            .build())
        .plugin(tauri_plugin_global_shortcut::Builder::default().build())
        .manage(app_state.clone())
        .setup(move |app| {
            let state = app.state::<AppState>();
            let client = state.http_client.clone();
            let app_handle = app.handle().clone();
            let app_state_clone = app_state.clone();

            let proxy_port_arc = app_state.inner.proxy_port.clone();
            let handle1 = tauri::async_runtime::spawn(async move {
                let bound = proxy::server::start_proxy(client, app_handle, app_state_clone).await;
                if let Ok(mut port) = proxy_port_arc.lock() {
                    *port = bound.port();
                }
                log::info!("HLS proxy started on {}", bound);
            });

            let app_handle_clone = app.handle().clone();
            let app_state_clone2 = app_state.clone();
            let handle2 = tauri::async_runtime::spawn(async move {
                commands::media::start_download_worker(app_handle_clone, app_state_clone2).await;
            });

            tauri::async_runtime::spawn(async move {
                if let Err(e) = handle1.await {
                    log::error!("HLS proxy task panicked: {:?}", e);
                }
                if let Err(e) = handle2.await {
                    log::error!("Download worker task panicked: {:?}", e);
                }
            });

            Ok(())
        })
        .invoke_handler(tauri::generate_handler![
            commands::config::get_config,
            commands::config::update_config,
            commands::media::search_media,
            commands::media::get_media_detail,
            commands::media::get_trending,
            commands::media::get_seasonal,
            commands::media::get_upcoming,
            commands::media::get_media_characters,
            commands::media::get_smart_playlist,
            commands::media::get_episodes,
            commands::media::get_chapter_pages,
            commands::media::resolve_stream,
            commands::media::search_provider,
            commands::media::map_provider_slug,
            commands::media::clear_provider_cache,
            commands::media::debug_provider_streams,
            commands::media::get_library,
            commands::media::add_to_library,
            commands::media::remove_from_library,
            commands::media::add_to_queue,
            commands::media::get_queue,
            commands::media::remove_from_queue,
            commands::media::retry_queue,
            commands::user::get_user_list,
            commands::user::get_user_profile,
            commands::user::save_media_list_entry,
            commands::user::delete_media_list_entry,
            commands::user::toggle_favourite,
            commands::user::get_notifications,
            commands::user::mark_notifications_read,
            commands::user::get_airing_schedule,
            commands::playback::start_playback,
            commands::playback::stop_playback,
            commands::playback::play_trailer,
            commands::playback::preload_episode,
            commands::playback::get_watched_episodes,
            commands::playback::get_all_last_watched,
            commands::health::check_health,
            commands::health::get_app_version,
            commands::health::log_frontend,
            commands::health::get_logs,
            commands::health::open_logs_folder,
            commands::health::open_in_browser,
            commands::health::check_update,
            commands::health::trigger_update,
            commands::health::relaunch_app,
            commands::health::get_proxy_port,
            commands::auth::start_anilist_auth,
        ])
        .build(tauri::generate_context!())
        .expect("error while running tauri application")
        .run(|app_handle, event| {
            // Tauri exits the process via process::exit on window close, which
            // skips Rust destructors — so the scraper's async Drop never runs.
            // Kill it (and its PyInstaller child) explicitly here so it does not
            // linger after the app closes.
            if let tauri::RunEvent::Exit = event {
                app_handle.state::<AppState>().scraper_manager.shutdown_blocking();
            }
        });
}
