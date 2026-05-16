use tauri::{
    menu::{Menu, MenuItem},
    tray::TrayIconBuilder,
    Manager,
};
use tauri_plugin_shell::process::CommandEvent;
use tauri_plugin_shell::ShellExt;

#[tauri::command]
async fn open_logs_folder(app: tauri::AppHandle) -> Result<(), String> {
    let log_path = app.path().app_log_dir().map_err(|e| e.to_string())?;
    
    // Create directory if it doesn't exist
    if !log_path.exists() {
        std::fs::create_dir_all(&log_path).map_err(|e| e.to_string())?;
    }
    
    #[cfg(target_os = "macos")]
    std::process::Command::new("open")
        .arg(&log_path)
        .spawn()
        .map_err(|e| e.to_string())?;
        
    #[cfg(target_os = "windows")]
    std::process::Command::new("explorer")
        .arg(&log_path)
        .spawn()
        .map_err(|e| e.to_string())?;

    #[cfg(target_os = "linux")]
    std::process::Command::new("xdg-open")
        .arg(&log_path)
        .spawn()
        .map_err(|e| e.to_string())?;

    Ok(())
}

#[cfg_attr(mobile, tauri::mobile_entry_point)]
pub fn run() {
    tauri::Builder::default()
        .plugin(tauri_plugin_shell::init())
        .plugin(tauri_plugin_log::Builder::default().build())
        .invoke_handler(tauri::generate_handler![open_logs_folder])
        .setup(|app| {
            // Setup Tray Menu
            let quit_i = MenuItem::with_id(app, "quit", "Quit Anicat", true, None::<&str>)?;
            let show_i = MenuItem::with_id(app, "show", "Show Dashboard", true, None::<&str>)?;
            let menu = Menu::with_items(app, &[&show_i, &quit_i])?;

            let tray_icon = tauri::image::Image::from_bytes(include_bytes!("../icons/tray-icon.png"))?;
            let _tray = TrayIconBuilder::new()
                .icon(tray_icon)
                .icon_as_template(true)
                .menu(&menu)
                .on_menu_event(|app, event| match event.id.as_ref() {
                    "quit" => {
                        app.exit(0);
                    }
                    "show" => {
                        if let Some(window) = app.get_webview_window("main") {
                            let _ = window.show();
                            let _ = window.set_focus();
                        }
                    }
                    _ => {}
                })
                .build(app)?;

            let shell = app.shell();
            let sidecar_name = "anicat-server";
            
            match shell.sidecar(sidecar_name) {
                Ok(sidecar) => {
                    match sidecar.spawn() {
                        Ok((mut rx, child)) => {
                            app.manage(child);
                            tauri::async_runtime::spawn(async move {
                                while let Some(event) = rx.recv().await {
                                    match event {
                                        CommandEvent::Stdout(line) => {
                                            log::info!("sidecar-out: {}", String::from_utf8_lossy(&line).trim());
                                        }
                                        CommandEvent::Stderr(line) => {
                                            log::error!("sidecar-err: {}", String::from_utf8_lossy(&line).trim());
                                        }
                                        CommandEvent::Terminated(payload) => {
                                            log::warn!("sidecar-terminated: {:?}", payload);
                                        }
                                        _ => {}
                                    }
                                }
                            });
                        }
                        Err(e) => {
                            log::error!("Failed to spawn sidecar {}: {}", sidecar_name, e);
                        }
                    }
                }
                Err(e) => {
                    log::error!("Failed to find sidecar {}: {}", sidecar_name, e);
                }
            }

            Ok(())
        })
        .run(tauri::generate_context!())
        .expect("error while running tauri application");
}
