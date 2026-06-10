use tauri::Emitter;

#[tauri::command]
pub async fn start_anilist_auth(app: tauri::AppHandle) -> Result<(), String> {
    let auth_url = "https://anilist.co/api/v2/oauth/authorize?client_id=20148&response_type=token";

    open::that(auth_url).map_err(|e| format!("Failed to open browser: {}", e))?;

    // Let frontend know auth was initiated
    let _ = app.emit("anilist-auth-started", serde_json::json!({}));

    Ok(())
}
