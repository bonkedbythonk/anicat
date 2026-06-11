mod anilist;
mod commands;
mod proxy;
mod registry;
mod scraper;
mod state;

use state::AppState;
use tauri::Manager;

#[cfg_attr(mobile, tauri::mobile_entry_point)]
pub fn run() {
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

            tauri::async_runtime::spawn(async move {
                let bound = proxy::server::start_proxy(client).await;
                log::info!("HLS proxy started on {}", bound);
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
            commands::user::get_user_list,
            commands::user::get_user_profile,
            commands::user::save_media_list_entry,
            commands::user::delete_media_list_entry,
            commands::user::get_notifications,
            commands::user::mark_notifications_read,
            commands::user::get_airing_schedule,
            commands::playback::start_playback,
            commands::playback::stop_playback,
            commands::playback::get_watched_episodes,
            commands::health::check_health,
            commands::health::get_app_version,
            commands::health::log_frontend,
            commands::auth::start_anilist_auth,
        ])
        .run(tauri::generate_context!())
        .expect("error while running tauri application");
}
