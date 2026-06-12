use std::collections::HashMap;
use std::path::PathBuf;

use serde_json::Value;
use tauri::State;
use tauri::Manager;

use crate::anilist::queries;
use crate::anilist::responses::{MediaResponse, PageResponse};
use crate::cache::AniListCache;
use crate::registry;
use crate::state::AppState;

#[tauri::command]
pub async fn search_media(
    state: State<'_, AppState>,
    query: String,
    page: Option<i64>,
    media_type: Option<String>,
    status: Option<String>,
    genre: Option<String>,
    year: Option<i64>,
    min_score: Option<i64>,
) -> Result<Value, String> {
    log::info!("search_media: query='{}', page={:?}, media_type={:?}, status={:?}, genre={:?}, year={:?}, min_score={:?}", query, page, media_type, status, genre, year, min_score);
    let _has_token = state.anilist_client.has_token();
    let mut vars = HashMap::new();
    vars.insert("page".to_string(), serde_json::json!(page.unwrap_or(1)));
    vars.insert("perPage".to_string(), serde_json::json!(20));
    vars.insert("search".to_string(), if query.is_empty() { serde_json::json!(null) } else { serde_json::json!(query) });
    vars.insert("type".to_string(), serde_json::json!(media_type.unwrap_or_else(|| "ANIME".to_string())));
    if let Some(s) = status {
        vars.insert("status".to_string(), serde_json::json!(s));
    }
    if let Some(g) = genre {
        if !g.is_empty() {
            vars.insert("genre".to_string(), serde_json::json!(vec![g]));
        }
    }
    if let Some(y) = year {
        vars.insert("seasonYear".to_string(), serde_json::json!(y));
    }
    if let Some(s) = min_score {
        vars.insert("averageScoreGreater".to_string(), serde_json::json!(s));
    }

    let result: PageResponse<crate::anilist::types::MediaItem> = state
        .anilist_client
        .execute(queries::MEDIA_SEARCH_QUERY, vars)
        .await?;

    let val = serde_json::to_value(result).map_err(|e| e.to_string())?;
    if let Some(_m) = val.get("Page").and_then(|p| p.get("media")).and_then(|m| m.as_array()) {
    }
    Ok(val)
}

#[tauri::command]
pub async fn get_media_detail(
    state: State<'_, AppState>,
    media_id: i64,
    media_type: Option<String>,
) -> Result<Value, String> {
    let mut vars = HashMap::new();
    vars.insert("id".to_string(), serde_json::json!(media_id));
    vars.insert("type".to_string(), serde_json::json!(media_type.unwrap_or_else(|| "ANIME".to_string())));

    let result: MediaResponse = state
        .anilist_client
        .execute(queries::MEDIA_DETAIL_QUERY, vars)
        .await?;

    serde_json::to_value(result).map_err(|e| e.to_string())
}

#[tauri::command]
pub async fn get_trending(
    state: State<'_, AppState>,
    page: Option<i64>,
    media_type: Option<String>,
) -> Result<Value, String> {
    let mtype = media_type.unwrap_or_else(|| "ANIME".to_string());
    let key = AniListCache::key("get_trending", &[("page", &page.unwrap_or(1).to_string()), ("type", &mtype)]);
    if let Some(cached) = state.cache.get(&key) { return Ok(cached); }

    let mut vars = HashMap::new();
    vars.insert("page".to_string(), serde_json::json!(page.unwrap_or(1)));
    vars.insert("perPage".to_string(), serde_json::json!(20));
    vars.insert("type".to_string(), serde_json::json!(mtype));

    let result: PageResponse<crate::anilist::types::MediaItem> = state
        .anilist_client
        .execute(queries::MEDIA_TRENDING_QUERY, vars)
        .await?;

    let val = serde_json::to_value(result).map_err(|e| e.to_string())?;
    state.cache.set(key, val.clone(), "get_trending");
    Ok(val)
}

#[tauri::command]
pub async fn get_seasonal(
    state: State<'_, AppState>,
    season: Option<String>,
    season_year: Option<i64>,
    page: Option<i64>,
    media_type: Option<String>,
) -> Result<Value, String> {
    let s = season.clone().unwrap_or_else(|| "SPRING".to_string());
    let y = season_year.unwrap_or(2026);
    let mtype = media_type.unwrap_or_else(|| "ANIME".to_string());
    let key = AniListCache::key("get_seasonal", &[("season", &s), ("year", &y.to_string()), ("page", &page.unwrap_or(1).to_string()), ("type", &mtype)]);
    if let Some(cached) = state.cache.get(&key) { return Ok(cached); }

    let mut vars = HashMap::new();
    vars.insert("page".to_string(), serde_json::json!(page.unwrap_or(1)));
    vars.insert("perPage".to_string(), serde_json::json!(20));
    vars.insert("season".to_string(), serde_json::json!(s));
    vars.insert("seasonYear".to_string(), serde_json::json!(y));
    vars.insert("type".to_string(), serde_json::json!(mtype));

    let result: PageResponse<crate::anilist::types::MediaItem> = state
        .anilist_client
        .execute(queries::MEDIA_SEASONAL_QUERY, vars)
        .await?;

    let val = serde_json::to_value(result).map_err(|e| e.to_string())?;
    state.cache.set(key, val.clone(), "get_seasonal");
    Ok(val)
}

#[tauri::command]
pub async fn get_upcoming(
    state: State<'_, AppState>,
    page: Option<i64>,
    media_type: Option<String>,
) -> Result<Value, String> {
    let mtype = media_type.unwrap_or_else(|| "ANIME".to_string());
    let key = AniListCache::key("get_upcoming", &[("page", &page.unwrap_or(1).to_string()), ("type", &mtype)]);
    if let Some(cached) = state.cache.get(&key) { return Ok(cached); }

    let mut vars = HashMap::new();
    vars.insert("page".to_string(), serde_json::json!(page.unwrap_or(1)));
    vars.insert("perPage".to_string(), serde_json::json!(20));
    vars.insert("type".to_string(), serde_json::json!(mtype));

    let result: PageResponse<crate::anilist::types::MediaItem> = state
        .anilist_client
        .execute(queries::MEDIA_UPCOMING_QUERY, vars)
        .await?;

    let val = serde_json::to_value(result).map_err(|e| e.to_string())?;
    state.cache.set(key, val.clone(), "get_upcoming");
    Ok(val)
}

#[tauri::command]
pub async fn get_media_characters(
    state: State<'_, AppState>,
    media_id: i64,
) -> Result<Value, String> {
    let mut vars = HashMap::new();
    vars.insert("id".to_string(), serde_json::json!(media_id));
    vars.insert("page".to_string(), serde_json::json!(1));
    vars.insert("perPage".to_string(), serde_json::json!(25));

    let result: crate::anilist::responses::CharacterResponse = state
        .anilist_client
        .execute(queries::MEDIA_CHARACTERS_QUERY, vars)
        .await?;

    serde_json::to_value(result).map_err(|e| e.to_string())
}

#[tauri::command]
pub async fn get_smart_playlist(
    state: State<'_, AppState>,
) -> Result<Value, String> {
    let key = "get_smart_playlist|action".to_string();
    if let Some(cached) = state.cache.get(&key) { return Ok(cached); }

    let mut vars = HashMap::new();
    vars.insert("genre".to_string(), serde_json::json!(["Action"]));
    vars.insert("sort".to_string(), serde_json::json!(["SCORE_DESC"]));

    let result: PageResponse<crate::anilist::types::MediaItem> = state
        .anilist_client
        .execute(queries::SMART_PLAYLIST_QUERY, vars)
        .await?;

    let val = serde_json::to_value(result).map_err(|e| e.to_string())?;
    state.cache.set(key, val.clone(), "get_smart_playlist");
    Ok(val)
}

#[tauri::command]
pub async fn get_episodes(
    app: tauri::AppHandle,
    state: State<'_, AppState>,
    media_id: i64,
    provider: Option<String>,
    title: Option<String>,
) -> Result<Value, String> {
    let provider_name = provider.unwrap_or_else(|| "anineko".to_string());
    let is_manga = provider_name == "mangakatana";

    let db = state.open_db().map_err(|e| e.to_string())?;
    let slug = registry::service::get_provider_slug(&db, media_id, &provider_name);

    let mut episodes = if let Some(slug) = slug {
        let res = if is_manga {
            state.scraper_manager.get_manga(&slug).await.map(|info| info.episodes)
        } else {
            state.scraper_manager.get_anime(&slug).await.map(|info| info.episodes)
        };
        match res {
            Ok(eps) => eps,
            Err(e) => {
                log::error!("Scraper auto-search error for media_id={}, provider={}, title={}: {}", media_id, provider_name, title.as_deref().unwrap_or(""), e);
                let _ = registry::service::clear_provider_cache(&db, media_id);
                use tauri::Emitter;
                let _ = app.emit("show_notification", serde_json::json!({ "message": format!("Failed to load episodes: {}", e) }));
                vec![]
            }
        }
    } else {
        // No mapping yet — auto-search by media title (frontend must pass this)
        let Some(title) = title.filter(|t| !t.is_empty()) else {
            return serde_json::to_value(Vec::<crate::scraper::Episode>::new())
                .map_err(|e| e.to_string());
        };

        let results = if is_manga {
            state.scraper_manager.search_manga(&title).await.unwrap_or_default()
        } else {
            state.scraper_manager.search(&title).await.unwrap_or_default()
        };

        if let Some(best) = find_best_match(&title, results, |r| &r.title) {
            let _ = registry::service::set_provider_slug(
                &db, media_id, &provider_name, &best.id,
            );
            let res = if is_manga {
                state.scraper_manager.get_manga(&best.id).await.map(|info| info.episodes)
            } else {
                state.scraper_manager.get_anime(&best.id).await.map(|info| info.episodes)
            };
            res.unwrap_or_default()
        } else {
            vec![]
        }
    };

    // Query download statuses from DB
    if let Ok(mut stmt) = db.prepare("SELECT episode_number, status FROM download_queue WHERE media_id = ?1") {
        if let Ok(status_rows) = stmt.query_map(rusqlite::params![media_id], |row| {
            Ok((row.get::<_, i64>(0)?, row.get::<_, String>(1)?))
        }) {
            let mut status_map = std::collections::HashMap::new();
            for row in status_rows {
                if let Ok((ep_num, status)) = row {
                    status_map.insert(ep_num, status);
                }
            }
            for ep in &mut episodes {
                if let Some(status) = status_map.get(&(ep.number as i64)) {
                    ep.download_status = Some(status.clone());
                }
            }
        }
    }

    serde_json::to_value(episodes).map_err(|e| e.to_string())
}

#[tauri::command]
pub async fn resolve_stream(
    state: State<'_, AppState>,
    media_id: i64,
    episode_number: i32,
    provider: Option<String>,
) -> Result<Value, String> {
    let provider_name = provider.unwrap_or_else(|| "anineko".to_string());

    let db = state.open_db()?;
    let slug = registry::service::get_provider_slug(&db, media_id, &provider_name)
        .ok_or_else(|| format!("No provider mapping for media {}", media_id))?;

    let servers = state
        .scraper_manager
        .get_streams(&slug, episode_number)
        .await?;

    let result = serde_json::json!({ "streams": servers });
    Ok(result)
}

#[tauri::command]
pub async fn search_provider(
    state: State<'_, AppState>,
    query: String,
) -> Result<Vec<crate::scraper::AnimeRef>, String> {
    state.scraper_manager.search(&query).await
}

#[tauri::command]
pub async fn map_provider_slug(
    state: State<'_, AppState>,
    media_id: i64,
    provider: String,
    slug: String,
) -> Result<(), String> {
    let db = state.open_db()?;
    registry::service::set_provider_slug(&db, media_id, &provider, &slug)
}

#[tauri::command]
pub async fn clear_provider_cache(
    state: State<'_, AppState>,
    media_id: i64,
) -> Result<(), String> {
    let db = state.open_db()?;
    registry::service::clear_provider_cache(&db, media_id)
}

#[tauri::command]
pub async fn debug_provider_streams(
    state: State<'_, AppState>,
    media_id: i64,
    episode_number: i32,
    provider: Option<String>,
) -> Result<serde_json::Value, String> {
    let provider_name = provider.unwrap_or_else(|| "anineko".to_string());
    let db = state.open_db()?;
    let slug = match registry::service::get_provider_slug(&db, media_id, &provider_name) {
        Some(s) => s,
        None => {
            // Auto-search: get title from AniList, search AniNeko, save slug
            let mut vars = std::collections::HashMap::new();
            vars.insert("id".to_string(), serde_json::json!(media_id));
            vars.insert("type".to_string(), serde_json::json!("ANIME"));
            let detail: crate::anilist::responses::MediaResponse = state
                .anilist_client
                .execute(crate::anilist::queries::MEDIA_DETAIL_QUERY, vars)
                .await
                .map_err(|e| format!("Failed to get anime title: {}", e))?;
            let title = detail.media
                .and_then(|m| m.title)
                .and_then(|t| t.english.or(t.romaji))
                .unwrap_or_default();
            if title.is_empty() {
                return Err(format!("No title found for media {}", media_id));
            }
            let results = state.scraper_manager.search(&title).await.unwrap_or_default();
            match find_best_match(&title, results, |r| &r.title) {
                Some(best) => {
                    let _ = registry::service::set_provider_slug(&db, media_id, &provider_name, &best.id);
                    best.id
                }
                None => {
                    return Err(format!(
                        r#"{{"error":"no_slug","media_id":{},"provider":"{}","hint":"AniNeko search for '{}' returned no results"}}"#,
                        media_id, provider_name, title
                    ));
                }
            }
        }
    };
    let mut result = state.scraper_manager.debug_streams(&slug, episode_number).await?;
    if let Some(obj) = result.as_object_mut() {
        obj.insert("resolved_slug".to_string(), serde_json::json!(slug));
        obj.insert("provider".to_string(), serde_json::json!(provider_name));
    }
    Ok(result)
}

#[tauri::command]
pub async fn get_chapter_pages(
    state: State<'_, AppState>,
    media_id: i64,
    chapter_number: String,
) -> Result<Value, String> {
    let provider_name = "mangakatana".to_string();

    let db = state.open_db().map_err(|e| e.to_string())?;
    let slug = registry::service::get_provider_slug(&db, media_id, &provider_name)
        .ok_or_else(|| format!("No provider mapping for media {}", media_id))?;

    let pages = state
        .scraper_manager
        .get_chapter_pages(&slug, &chapter_number)
        .await?;

    Ok(pages)
}

// ── Local library commands ────────────────────────────────

#[tauri::command]
pub async fn get_library(
    state: State<'_, AppState>,
) -> Result<Vec<crate::registry::LibraryEntry>, String> {
    let db = state.open_db()?;
    registry::service::get_all_library(&db)
}

#[tauri::command]
pub async fn add_to_library(
    state: State<'_, AppState>,
    media_id: i64,
    media_type: String,
    status: Option<String>,
    score: Option<f64>,
    progress: Option<i32>,
    notes: Option<String>,
) -> Result<(), String> {
    let db = state.open_db()?;
    registry::service::upsert_library_entry(
        &db,
        media_id,
        &media_type,
        status.as_deref(),
        score,
        progress,
        notes.as_deref(),
    )
}

#[tauri::command]
pub async fn remove_from_library(
    state: State<'_, AppState>,
    media_id: i64,
) -> Result<(), String> {
    let db = state.open_db()?;
    registry::service::delete_library_entry(&db, media_id)
}

fn notify_download(app_handle: &tauri::AppHandle, message: &str) {
    use tauri::Emitter;
    let _ = app_handle.emit("show_notification", serde_json::json!({ "message": message }));
}

fn update_status_and_emit(
    app_handle: &tauri::AppHandle,
    db: &rusqlite::Connection,
    media_id: i64,
    episode_number: i64,
    status: &str,
    error_message: Option<&str>,
) -> Result<(), String> {
    crate::registry::service::update_queue_status(db, media_id, episode_number, status, error_message)?;
    use tauri::Emitter;
    let _ = app_handle.emit("download_status_change", serde_json::json!({
        "media_id": media_id,
        "episode_number": episode_number,
        "status": status,
        "error_message": error_message
    }));
    Ok(())
}

pub async fn start_download_worker(app_handle: tauri::AppHandle, state: crate::state::AppState) {
    log::info!("Download worker started");
    
    // Reset any stuck 'downloading' states to 'queued' on startup
    if let Ok(db) = state.open_db() {
        let _ = db.execute(
            "UPDATE download_queue SET status = 'queued' WHERE status = 'downloading'",
            [],
        );
    }

    loop {
        tokio::time::sleep(tokio::time::Duration::from_secs(2)).await;

        let db = match state.open_db() {
            Ok(d) => d,
            Err(e) => {
                log::error!("Download worker failed to open db: {}", e);
                continue;
            }
        };

        // Check if there is already an active download
        let active_count: Result<i64, _> = db.query_row(
            "SELECT COUNT(*) FROM download_queue WHERE status = 'downloading'",
            [],
            |row| row.get(0),
        );

        match active_count {
            Ok(count) if count > 0 => {
                // Downloader is busy, wait for next tick
                continue;
            }
            Err(e) => {
                log::error!("Failed to check active downloads: {}", e);
                continue;
            }
            _ => {}
        }

        // Fetch the next queued item
        let next_item: Result<(i64, i64, String), _> = db.query_row(
            "SELECT media_id, episode_number, media_title FROM download_queue WHERE status = 'queued' ORDER BY id ASC LIMIT 1",
            [],
            |row| Ok((row.get::<_, i64>(0)?, row.get::<_, i64>(1)?, row.get::<_, String>(2)?)),
        );

        if let Ok((media_id, ep_num, title)) = next_item {
            log::info!("Download worker: Starting download for media_id={}, episode={}", media_id, ep_num);
            download_episode(
                app_handle.clone(),
                state.clone(),
                media_id,
                ep_num,
                title,
            ).await;
        }
    }
}

async fn download_episode(
    app_handle: tauri::AppHandle,
    state: crate::state::AppState,
    media_id: i64,
    episode_number: i64,
    title: String,
) {
    let notify = |msg: &str| notify_download(&app_handle, msg);

    // Update status to downloading
    if let Ok(db) = state.open_db() {
        let _ = update_status_and_emit(&app_handle, &db, media_id, episode_number, "downloading", None);
    }

    // Get stream URL
    let provider = "anineko";
    let slug = {
        let db = match state.open_db() {
            Ok(d) => d,
            Err(_) => {
                notify("Failed to open database");
                return;
            }
        };
        match crate::registry::service::get_provider_slug(&db, media_id, provider) {
            Some(s) => s,
            None => {
                let err = format!("No provider mapping for media {}", media_id);
                let _ = update_status_and_emit(&app_handle, &db, media_id, episode_number, "failed", Some(&err));
                notify(&err);
                return;
            }
        }
    };

    let servers = match state.scraper_manager.get_streams(&slug, episode_number as i32).await {
        Ok(s) => s,
        Err(e) => {
            let err = format!("Failed to get stream: {}", e);
            if let Ok(db) = state.open_db() {
                let _ = update_status_and_emit(&app_handle, &db, media_id, episode_number, "failed", Some(&err));
            }
            notify(&err);
            return;
        }
    };

    let raw_url = match servers.first() {
        Some(s) => s.url.clone(),
        None => {
            let err = "No stream URL found".to_string();
            if let Ok(db) = state.open_db() {
                let _ = update_status_and_emit(&app_handle, &db, media_id, episode_number, "failed", Some(&err));
            }
            notify(&err);
            return;
        }
    };

    if !raw_url.starts_with("http://") && !raw_url.starts_with("https://") {
        let err = "Invalid stream URL scheme".to_string();
        if let Ok(db) = state.open_db() {
            let _ = update_status_and_emit(&app_handle, &db, media_id, episode_number, "failed", Some(&err));
        }
        notify(&err);
        return;
    }

    notify(&format!("Downloading episode {}...", episode_number));

    // Determine download path
    let downloads_path = {
        let cfg = state.config.read().await;
        let path = cfg.general.downloads_path.clone();
        if path.is_empty() {
            dirs::download_dir().unwrap_or_else(|| PathBuf::from(".")).to_string_lossy().to_string()
        } else {
            path
        }
    };

    let safe_title: String = title.chars().filter(|c| c.is_alphanumeric() || *c == ' ' || *c == '-' || *c == '_').collect();
    let filename = format!("{} - Episode {}.mp4", safe_title.trim(), episode_number);
    let filepath = std::path::Path::new(&downloads_path).join(&filename);

    if filepath.exists() {
        let _ = tokio::fs::remove_file(&filepath).await;
    }
    let filepath_ts = std::path::Path::new(&downloads_path).join(format!("{} - Episode {}.ts", safe_title.trim(), episode_number));
    if filepath_ts.exists() {
        let _ = tokio::fs::remove_file(&filepath_ts).await;
    }
    let filepath_part = std::path::Path::new(&downloads_path).join(format!("{} - Episode {}.mp4.part", safe_title.trim(), episode_number));
    if filepath_part.exists() {
        let _ = tokio::fs::remove_file(&filepath_part).await;
    }

    // Try to run yt-dlp directly if installed globally to start downloads instantly
    let mut cmd = if tokio::process::Command::new("yt-dlp").arg("--version").output().await.is_ok() {
        tokio::process::Command::new("yt-dlp")
    } else if std::path::Path::new("/opt/homebrew/bin/yt-dlp").exists() {
        tokio::process::Command::new("/opt/homebrew/bin/yt-dlp")
    } else if std::path::Path::new("/usr/local/bin/yt-dlp").exists() {
        tokio::process::Command::new("/usr/local/bin/yt-dlp")
    } else {
        let manifest_dir = std::path::Path::new(env!("CARGO_MANIFEST_DIR"));
        let dev_venv_yt = manifest_dir.join("../../.venv/bin/yt-dlp");
        let dev_venv_yt_win = manifest_dir.join("../../.venv/Scripts/yt-dlp.exe");

        let python_path = state.scraper_manager.python_path();
        let py_path = std::path::Path::new(python_path);
        let py_venv_yt = if py_path.is_absolute() {
            if let Some(parent) = py_path.parent() {
                let bin_yt = parent.join("yt-dlp");
                let exe_yt = parent.join("yt-dlp.exe");
                if bin_yt.exists() {
                    Some(bin_yt)
                } else if exe_yt.exists() {
                    Some(exe_yt)
                } else {
                    None
                }
            } else {
                None
            }
        } else {
            None
        };

        if dev_venv_yt.exists() {
            tokio::process::Command::new(dev_venv_yt)
        } else if dev_venv_yt_win.exists() {
            tokio::process::Command::new(dev_venv_yt_win)
        } else if let Some(p) = py_venv_yt {
            tokio::process::Command::new(p)
        } else if python_path.contains("uv") {
            let mut c = tokio::process::Command::new("uv");
            c.arg("run")
             .arg("yt-dlp");
            c
        } else {
            let mut c = tokio::process::Command::new(python_path);
            c.arg("-m")
             .arg("yt_dlp");
            c
        }
    };

    cmd.arg(&raw_url);

    // Pass custom HTTP headers if present (e.g. Referer, User-Agent)
    if let Some(ref server) = servers.first() {
        if let Some(ref headers) = server.headers {
            for (key, val) in headers {
                cmd.arg("--http-header").arg(format!("{}: {}", key, val));
            }
        }
    }

    cmd.arg("-o").arg(&filepath);
    cmd.arg("--force-overwrites");
    cmd.arg("--no-playlist");
    cmd.stdout(std::process::Stdio::piped());
    cmd.stderr(std::process::Stdio::piped());

    log::info!("Spawning download command: {:?}", cmd);

    // Run the download command
    let mut child = match cmd.spawn() {
        Ok(c) => c,
        Err(e) => {
            let err_msg = e.to_string();
            log::error!("Failed to spawn download process: {}", err_msg);
            if let Ok(db) = state.open_db() {
                let _ = update_status_and_emit(&app_handle, &db, media_id, episode_number, "failed", Some(&err_msg));
            }
            notify(&format!("Download process failed: {}", err_msg));
            return;
        }
    };

    let stdout = child.stdout.take().unwrap();
    let stderr = child.stderr.take().unwrap();

    use tokio::io::{AsyncBufReadExt, AsyncReadExt, BufReader};
    let mut stdout_reader = BufReader::new(stdout);
    let mut stderr_reader = BufReader::new(stderr).lines();

    let app_handle_clone = app_handle.clone();
    let state_clone = state.clone();

    // Spawn a task to read stdout and parse progress
    let stdout_handle = tokio::spawn(async move {
        let mut last_progress = -1.0;
        let mut buf = [0u8; 4096];
        let mut accumulator = Vec::new();

        while let Ok(n) = stdout_reader.read(&mut buf).await {
            if n == 0 {
                break;
            }
            accumulator.extend_from_slice(&buf[..n]);

            while let Some(pos) = accumulator.iter().position(|&b| b == b'\n' || b == b'\r') {
                let line_bytes = &accumulator[..pos];
                let line = String::from_utf8_lossy(line_bytes).into_owned();
                accumulator.drain(..=pos);

                let trimmed = line.trim();
                if trimmed.is_empty() {
                    continue;
                }

                let is_progress = is_progress_line(&line);

                if !is_progress {
                    log::info!("[yt-dlp stdout] {}", line);
                } else {
                    if let Some(pos) = line.find('%') {
                        let prefix = &line[..pos];
                        if let Some(start_pos) = prefix.rfind(|c: char| c.is_whitespace() || c == ']') {
                            let pct_str = prefix[start_pos + 1..].trim();
                            if let Ok(pct) = pct_str.parse::<f64>() {
                                if (pct - last_progress).abs() >= 1.0 || pct >= 100.0 {
                                    last_progress = pct;
                                    if let Ok(db) = state_clone.open_db() {
                                        let _ = crate::registry::service::update_queue_progress(&db, media_id, episode_number, pct);
                                    }
                                    use tauri::Emitter;
                                    let _ = app_handle_clone.emit("download_progress", serde_json::json!({
                                        "media_id": media_id,
                                        "episode_number": episode_number,
                                        "progress": pct
                                    }));
                                }
                            }
                        } else {
                            let pct_str = prefix.trim();
                            if let Ok(pct) = pct_str.parse::<f64>() {
                                if (pct - last_progress).abs() >= 1.0 || pct >= 100.0 {
                                    last_progress = pct;
                                    if let Ok(db) = state_clone.open_db() {
                                        let _ = crate::registry::service::update_queue_progress(&db, media_id, episode_number, pct);
                                    }
                                    use tauri::Emitter;
                                    let _ = app_handle_clone.emit("download_progress", serde_json::json!({
                                        "media_id": media_id,
                                        "episode_number": episode_number,
                                        "progress": pct
                                    }));
                                }
                            }
                        }
                    }
                }
            }
        }

        if !accumulator.is_empty() {
            let line = String::from_utf8_lossy(&accumulator).into_owned();
            let trimmed = line.trim();
            if !trimmed.is_empty() && !is_progress_line(&line) {
                log::info!("[yt-dlp stdout] {}", line);
            }
        }
    });

    let mut stderr_content = String::new();
    while let Ok(Some(line)) = stderr_reader.next_line().await {
        log::error!("[yt-dlp stderr] {}", line);
        stderr_content.push_str(&line);
        stderr_content.push('\n');
    }
    let _ = stdout_handle.await;

    match child.wait().await {
        Ok(status) => {
            log::info!("yt-dlp exited with status: {}", status);
            if status.success() {
                if let Ok(db) = state.open_db() {
                    let _ = update_status_and_emit(&app_handle, &db, media_id, episode_number, "completed", None);
                    let _ = crate::registry::service::update_queue_progress(&db, media_id, episode_number, 100.0);
                }
                notify(&format!("Downloaded: {}", filename));
                // Emit final 100% progress event
                use tauri::Emitter;
                let _ = app_handle.emit("download_progress", serde_json::json!({
                    "media_id": media_id,
                    "episode_number": episode_number,
                    "progress": 100.0
                }));
            } else {
                let err_msg = stderr_content.trim();
                let short_err = if err_msg.is_empty() {
                    "yt-dlp exited with error status".to_string()
                } else {
                    err_msg.lines().next().unwrap_or("Unknown error").to_string()
                };
                if let Ok(db) = state.open_db() {
                    let _ = update_status_and_emit(&app_handle, &db, media_id, episode_number, "failed", Some(&short_err));
                }
                notify(&format!("Download failed for episode {}: {}", episode_number, short_err));
            }
        }
        Err(e) => {
            let err_msg = e.to_string();
            log::error!("Failed to wait for download process: {}", err_msg);
            if let Ok(db) = state.open_db() {
                let _ = update_status_and_emit(&app_handle, &db, media_id, episode_number, "failed", Some(&err_msg));
            }
            notify(&format!("Download process failed: {}", err_msg));
        }
    }
}

#[tauri::command]
pub async fn add_to_queue(
    app: tauri::AppHandle,
    state: State<'_, AppState>,
    media_id: i64,
    episodes: Vec<i64>,
    title: Option<String>,
    cover_image: Option<String>,
) -> Result<(), String> {
    log::info!("add_to_queue invoked: media_id={}, episodes={:?}, title={:?}, cover_image={:?}", media_id, episodes, title, cover_image);
    let db = state.open_db()?;
    let title_str = title.clone().unwrap_or_else(|| format!("Media {}", media_id));
    
    // Download cover image if it's an online URL to allow offline loading
    let cover_str = if let Some(ref url) = cover_image {
        if url.starts_with("http") {
            let app_data_dir = app.path().app_data_dir()
                .unwrap_or_else(|_| std::path::PathBuf::from("."));
            let covers_dir = app_data_dir.join("covers");
            let _ = std::fs::create_dir_all(&covers_dir);
            let dest_path = covers_dir.join(format!("{}.jpg", media_id));
            
            match state.http_client.get(url).send().await {
                Ok(resp) => {
                    if let Ok(bytes) = resp.bytes().await {
                        if std::fs::write(&dest_path, bytes).is_ok() {
                            log::info!("Saved local cover image to: {:?}", dest_path);
                            dest_path.to_string_lossy().to_string()
                        } else {
                            url.clone()
                        }
                    } else {
                        url.clone()
                    }
                }
                Err(e) => {
                    log::warn!("Failed to download cover image: {}", e);
                    url.clone()
                }
            }
        } else {
            url.clone()
        }
    } else {
        "".to_string()
    };

    for ep in episodes {
        crate::registry::service::add_to_queue(&db, media_id, ep, &title_str, &cover_str)?;
        use tauri::Emitter;
        let _ = app.emit("download_status_change", serde_json::json!({
            "media_id": media_id,
            "episode_number": ep,
            "status": "queued"
        }));
    }
    Ok(())
}

#[tauri::command]
pub async fn get_queue(
    app: tauri::AppHandle,
    state: State<'_, AppState>,
) -> Result<Vec<crate::registry::service::QueueItem>, String> {
    let db = state.open_db()?;
    let mut res = crate::registry::service::get_all_queue(&db)?;
    
    // Migrate old cover paths to the sandboxed app_data_dir/covers
    let app_data_dir = app.path().app_data_dir().unwrap_or_else(|_| std::path::PathBuf::from("."));
    let new_covers_dir = app_data_dir.join("covers");
    let _ = std::fs::create_dir_all(&new_covers_dir);

    for item in &mut res {
        if item.cover_image.contains("/anicat/covers/") {
            let old_path = std::path::PathBuf::from(&item.cover_image);
            if old_path.exists() {
                if let Some(file_name) = old_path.file_name() {
                    let new_path = new_covers_dir.join(file_name);
                    if !new_path.exists() {
                        let _ = std::fs::copy(&old_path, &new_path);
                    }
                    let new_path_str = new_path.to_string_lossy().to_string();
                    let _ = db.execute(
                        "UPDATE download_queue SET cover_image = ?1 WHERE media_id = ?2",
                        rusqlite::params![new_path_str, item.media_id],
                    );
                    item.cover_image = new_path_str;
                }
            }
        }
    }

    log::debug!("get_queue returning {} items: {:?}", res.len(), res);
    Ok(res)
}

#[tauri::command]
pub async fn remove_from_queue(
    app: tauri::AppHandle,
    state: State<'_, AppState>,
    media_id: i64,
    episode_number: i64,
) -> Result<(), String> {
    let db = state.open_db()?;
    
    // Attempt to delete downloaded files
    let queue_items = crate::registry::service::get_all_queue(&db)?;
    let item = queue_items.iter().find(|i| i.media_id == media_id && i.episode_number == episode_number);
    if let Some(i) = item {
        let downloads_path = {
            let cfg = state.config.read().await;
            let path = cfg.general.downloads_path.clone();
            if path.is_empty() {
                dirs::download_dir().unwrap_or_else(|| PathBuf::from(".")).to_string_lossy().to_string()
            } else {
                path
            }
        };
        let safe_title: String = i.media_title.chars().filter(|c| c.is_alphanumeric() || *c == ' ' || *c == '-' || *c == '_').collect();
        let filename = format!("{} - Episode {}.mp4", safe_title.trim(), episode_number);
        let filepath = std::path::Path::new(&downloads_path).join(&filename);
        if filepath.exists() {
            let _ = std::fs::remove_file(filepath);
        }
        let filename_ts = format!("{} - Episode {}.ts", safe_title.trim(), episode_number);
        let filepath_ts = std::path::Path::new(&downloads_path).join(&filename_ts);
        if filepath_ts.exists() {
            let _ = std::fs::remove_file(filepath_ts);
        }
    }

    crate::registry::service::remove_from_queue(&db, media_id, episode_number)?;

    use tauri::Emitter;
    let _ = app.emit("download_status_change", serde_json::json!({
        "media_id": media_id,
        "episode_number": episode_number,
        "status": "removed"
    }));
    Ok(())
}

#[tauri::command]
pub async fn retry_queue(
    app: tauri::AppHandle,
    state: State<'_, AppState>,
) -> Result<(), String> {
    let db = state.open_db()?;
    let all_items = crate::registry::service::get_all_queue(&db)?;
    let failed_items: Vec<_> = all_items.into_iter().filter(|i| i.status == "failed").collect();
    
    crate::registry::service::retry_queue(&db)?;

    use tauri::Emitter;
    for item in failed_items {
        let _ = app.emit("download_status_change", serde_json::json!({
            "media_id": item.media_id,
            "episode_number": item.episode_number,
            "status": "queued"
        }));
    }
    Ok(())
}

// ── Smart Similarity Matcher for Anime/Manga Searches ──────

fn normalize_title(title: &str) -> String {
    title
        .chars()
        .filter(|c| c.is_alphanumeric())
        .collect::<String>()
        .to_lowercase()
}

fn levenshtein_distance(s1: &str, s2: &str) -> usize {
    let v1: Vec<char> = s1.chars().collect();
    let v2: Vec<char> = s2.chars().collect();
    let len1 = v1.len();
    let len2 = v2.len();

    if len1 == 0 { return len2; }
    if len2 == 0 { return len1; }

    let mut dp = vec![vec![0; len2 + 1]; len1 + 1];

    for i in 0..=len1 {
        dp[i][0] = i;
    }
    for j in 0..=len2 {
        dp[0][j] = j;
    }

    for i in 1..=len1 {
        for j in 1..=len2 {
            let cost = if v1[i - 1] == v2[j - 1] { 0 } else { 1 };
            dp[i][j] = std::cmp::min(
                std::cmp::min(dp[i - 1][j] + 1, dp[i][j - 1] + 1),
                dp[i - 1][j - 1] + cost,
            );
        }
    }

    dp[len1][len2]
}

fn calculate_similarity(target: &str, candidate: &str) -> f64 {
    let target_norm = normalize_title(target);
    let candidate_norm = normalize_title(candidate);

    if target_norm.is_empty() || candidate_norm.is_empty() {
        return 0.0;
    }

    if target_norm == candidate_norm {
        return 1.0;
    }

    // Check if one is a substring of another
    if candidate_norm.contains(&target_norm) {
        let ratio = target_norm.len() as f64 / candidate_norm.len() as f64;
        return ratio * 0.9;
    }

    if target_norm.contains(&candidate_norm) {
        let ratio = candidate_norm.len() as f64 / target_norm.len() as f64;
        return ratio * 0.8;
    }

    let lev = levenshtein_distance(&target_norm, &candidate_norm);
    let max_len = std::cmp::max(target_norm.len(), candidate_norm.len()) as f64;
    1.0 - (lev as f64 / max_len)
}

fn find_best_match<T, F>(target: &str, candidates: Vec<T>, get_title: F) -> Option<T>
where
    F: Fn(&T) -> &str,
{
    let mut best_candidate = None;
    let mut best_score = 0.4_f64;

    for candidate in candidates {
        let score = calculate_similarity(target, get_title(&candidate));
        if score > best_score {
            best_score = score;
            best_candidate = Some(candidate);
        }
    }

    best_candidate
}

fn is_progress_line(line: &str) -> bool {
    let trimmed = line.trim();
    if trimmed.is_empty() {
        return true;
    }
    let has_progress_keywords = trimmed.contains('%') 
        || trimmed.contains("ETA") 
        || trimmed.contains("frag") 
        || trimmed.contains("KiB/s") 
        || trimmed.contains("MiB/s") 
        || trimmed.contains("B/s");
        
    (trimmed.contains("[download]") && has_progress_keywords)
        || (trimmed.starts_with(|c: char| c.is_ascii_digit() || c == '.') && trimmed.contains('%'))
        || (trimmed.contains('%') && (trimmed.contains("at") || trimmed.contains("ETA")))
}

