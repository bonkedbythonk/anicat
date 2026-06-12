use std::collections::HashMap;

use serde::Serialize;
use serde_json::Value;
use tauri::{AppHandle, Emitter, Manager, State};

use crate::state::AppState;

static CURRENT_MPV: std::sync::Mutex<Option<tokio::process::Child>> = std::sync::Mutex::new(None);

pub async fn kill_current_mpv() {
    let child = {
        if let Ok(mut guard) = CURRENT_MPV.lock() {
            guard.take()
        } else {
            None
        }
    };

    if let Some(mut c) = child {
        log::info!("Killing previous mpv instance");
        let _ = c.kill().await;
    }
}

#[derive(Serialize)]
pub struct PlaybackStart {
    pub stream_url: String,
}

fn resolve_mpv_path(app: &AppHandle) -> Result<(String, String, String), String> {
    let resource_dir = app.path().resource_dir().map_err(|e| e.to_string())?;

    let prod_config = resource_dir.join("mpv_config");
    let config_dir = if prod_config.exists() {
        prod_config.to_string_lossy().to_string()
    } else {
        std::path::Path::new(env!("CARGO_MANIFEST_DIR"))
            .join("resources")
            .join("mpv_config")
            .to_string_lossy()
            .to_string()
    };

    if cfg!(target_os = "macos") {
        if let Ok(path) = std::process::Command::new("which")
            .arg("mpv")
            .output()
            .map(|o| String::from_utf8_lossy(&o.stdout).trim().to_string())
        {
            if !path.is_empty() && std::path::Path::new(&path).exists() {
                log::info!("Found system mpv at: {}", path);
                return Ok((path, config_dir, String::new()));
            }
        }
    }

    let mpv_name = if cfg!(target_os = "windows") {
        "mpv.exe"
    } else {
        "mpv"
    };
    let mpv_bin = resource_dir.join(mpv_name);
    if !mpv_bin.exists() {
        let dev_path = std::path::Path::new(env!("CARGO_MANIFEST_DIR"))
            .join("resources")
            .join(mpv_name);
        if dev_path.exists() {
            let dev_lib_dir = std::path::Path::new(env!("CARGO_MANIFEST_DIR"))
                .join("resources")
                .join("lib");
            return Ok((
                dev_path.to_string_lossy().to_string(),
                config_dir,
                dev_lib_dir.to_string_lossy().to_string(),
            ));
        }
        return Err(format!(
            "mpv binary not found at {} or in dev resources",
            mpv_bin.display()
        ));
    }

    let lib_dir = resource_dir.join("lib");

    Ok((
        mpv_bin.to_string_lossy().to_string(),
        config_dir,
        lib_dir.to_string_lossy().to_string(),
    ))
}

fn get_stream_group(server: &crate::scraper::client::StreamServer) -> &str {
    if let Some(ref group) = server.group {
        return group;
    }
    let name = server.name.to_lowercase();
    if name.contains("dub") {
        "dub"
    } else if name.contains("sub") {
        "hard_sub"
    } else {
        "hard_sub"
    }
}

#[tauri::command]
pub async fn start_playback(
    app: AppHandle,
    state: State<'_, AppState>,
    media_id: i64,
    episode_number: i64,
    provider: Option<String>,
    server: Option<String>,
    title: Option<String>,
    episode_title: Option<String>,
    cover_image: Option<String>,
    total_episodes: Option<i64>,
) -> Result<PlaybackStart, String> {
    let provider_name = provider.unwrap_or_else(|| "anineko".to_string());

    let title_str = title.clone().unwrap_or_default();
    let episode_title_str = episode_title.clone().unwrap_or_default();
    let cover_image_str = cover_image.clone().unwrap_or_default();
    let total_eps = total_episodes.unwrap_or(0);

    {
        let mut guard = state.current_playback.lock().await;
        *guard = Some(crate::state::CurrentPlayback {
            media_id,
            episode_number,
            provider: provider_name.clone(),
            title: title_str.clone(),
            episode_title: episode_title_str.clone(),
            cover_image: cover_image_str.clone(),
        });
    }

    state.discord.set_presence(&title_str, episode_number, &episode_title_str, total_eps);

    let db = state.open_db()?;

    let local_file_path = {
        let mut path_found = None;
        if let Ok(items) = crate::registry::service::get_all_queue(&db) {
            if let Some(item) = items.iter().find(|i| i.media_id == media_id && i.episode_number == episode_number && i.status == "completed") {
                let downloads_path = {
                    let cfg = state.config.read().await;
                    let path = cfg.general.downloads_path.clone();
                    if path.is_empty() {
                        dirs::download_dir().unwrap_or_else(|| std::path::PathBuf::from(".")).to_string_lossy().to_string()
                    } else {
                        path
                    }
                };
                let safe_title: String = item.media_title.chars().filter(|c| c.is_alphanumeric() || *c == ' ' || *c == '-' || *c == '_').collect();
                let filename_mp4 = format!("{} - Episode {}.mp4", safe_title.trim(), episode_number);
                let filepath_mp4 = std::path::Path::new(&downloads_path).join(&filename_mp4);
                let filename_ts = format!("{} - Episode {}.ts", safe_title.trim(), episode_number);
                let filepath_ts = std::path::Path::new(&downloads_path).join(&filename_ts);

                if filepath_mp4.exists() {
                    path_found = Some(filepath_mp4.to_string_lossy().to_string());
                } else if filepath_ts.exists() {
                    path_found = Some(filepath_ts.to_string_lossy().to_string());
                }
            }
        }
        path_found
    };

    let stream_url = if let Some(local_path) = local_file_path {
        log::info!("Playing offline local download: {}", local_path);
        local_path
    } else {
        let slug = crate::registry::service::get_provider_slug(&db, media_id, &provider_name)
            .ok_or_else(|| format!("No provider mapping for media {}", media_id))?;

        let servers = state
            .scraper_manager
            .get_streams(&slug, episode_number as i32)
            .await?;

        let raw_stream_url = if let Some(ref s_name) = server {
            servers.iter().find(|s| s.name == *s_name)
                .or_else(|| servers.first())
                .map(|s| s.url.clone())
                .unwrap_or_default()
        } else {
            let translation_type = {
                let cfg = state.config.read().await;
                cfg.stream.translation_type.clone()
            };
            let best_server = if translation_type == "dub" {
                servers.iter().find(|s| get_stream_group(s) == "dub")
                    .or_else(|| servers.iter().find(|s| get_stream_group(s) == "hard_sub" || get_stream_group(s) == "soft_sub"))
                    .or_else(|| servers.first())
            } else {
                servers.iter().find(|s| get_stream_group(s) == "hard_sub" || get_stream_group(s) == "soft_sub")
                    .or_else(|| servers.iter().find(|s| get_stream_group(s) == "dub"))
                    .or_else(|| servers.first())
            };
            best_server.map(|s| s.url.clone()).unwrap_or_default()
        };

        if raw_stream_url.is_empty() {
            return Err("No stream URL found".to_string());
        }

        let mut stream_url = raw_stream_url.clone();
        if stream_url.contains("vibeplayer.site") || stream_url.contains("m3u8") {
            let encoded_url = crate::proxy::server::percent_encode(&stream_url);
            stream_url = format!("http://127.0.0.1:13370/proxy?url={}", encoded_url);
            log::info!("Proxied stream URL: {}", stream_url);
        }
        stream_url
    };

    let mal_id = {
        let mut vars = HashMap::new();
        vars.insert("id".to_string(), serde_json::json!(media_id));
        vars.insert("type".to_string(), serde_json::json!("ANIME"));
        let res: Result<crate::anilist::responses::MediaResponse, String> = state
            .anilist_client
            .execute(crate::anilist::queries::MEDIA_DETAIL_QUERY, vars)
            .await;
        res.ok().and_then(|r| r.media.and_then(|m| m.id_mal))
    };

    let mut skip_times_arg = String::new();
    if let Some(m_id) = mal_id {
        let client = reqwest::Client::new();
        let url = format!(
            "https://api.aniskip.com/v2/skip-times/{}/{}?types[]=op&types[]=ed&episodeLength=0",
            m_id, episode_number
        );
        log::info!("Fetching AniSkip times from: {}", url);
        if let Ok(resp) = client.get(&url).send().await {
            #[derive(serde::Deserialize)]
            struct AniSkipResult {
                #[serde(default)]
                results: Vec<AniSkipTime>,
            }
            #[derive(serde::Deserialize)]
            struct AniSkipTime {
                #[serde(rename = "skipType")]
                skip_type: String,
                interval: AniSkipInterval,
            }
            #[derive(serde::Deserialize)]
            struct AniSkipInterval {
                #[serde(rename = "startTime")]
                start_time: f64,
                #[serde(rename = "endTime")]
                end_time: f64,
            }
            if let Ok(aniskip_res) = resp.json::<AniSkipResult>().await {
                let mut parts = Vec::new();
                for result in aniskip_res.results {
                    parts.push(format!(
                        "{},{},{}",
                        result.skip_type,
                        result.interval.start_time.floor(),
                        result.interval.end_time.floor()
                    ));
                }
                if !parts.is_empty() {
                    skip_times_arg = parts.join(";");
                    log::info!("Found AniSkip times: {}", skip_times_arg);
                }
            }
        }
    }

    let (mpv_bin, config_dir, lib_dir) = resolve_mpv_path(&app)?;
    log::info!("mpv binary: {}", mpv_bin);
    log::info!("mpv config: {}", config_dir);
    log::info!("mpv lib dir: {}", lib_dir);

    let mut cmd = tokio::process::Command::new(&mpv_bin);
    cmd.arg(format!("--config-dir={}", config_dir));
    cmd.arg("--force-window=yes");
    cmd.arg("--ontop");

    let autoskip = {
        let cfg = state.config.read().await;
        cfg.general.autoskip
    };
    let mut script_opts = Vec::new();
    if !skip_times_arg.is_empty() {
        script_opts.push(format!("anicat_ui-skip_times={}", skip_times_arg));
    }
    script_opts.push(format!("anicat_ui-autoskip={}", if autoskip { "yes" } else { "no" }));
    cmd.arg(format!("--script-opts={}", script_opts.join(",")));

    let shader_profile = state
        .config
        .read()
        .await
        .stream
        .shader_profile
        .clone();
    if shader_profile != "off" {
        let shader_dir = std::path::Path::new(&config_dir).join("shaders");
        let use_cnn_l = shader_profile == "maximum_quality";
        let use_cnn_m = shader_profile == "balanced";
        if use_cnn_l || use_cnn_m {
            let cnn = if use_cnn_l { "L" } else { "M" };
            let shaders = [
                shader_dir.join("Anime4K_Clamp_Highlights.glsl"),
                shader_dir.join(&format!("Anime4K_Restore_CNN_{}.glsl", cnn)),
                shader_dir.join(&format!("Anime4K_Upscale_CNN_x2_{}.glsl", cnn)),
                shader_dir.join("Anime4K_AutoDownscalePre_x2.glsl"),
                shader_dir.join("Anime4K_AutoDownscalePre_x4.glsl"),
            ];
            let shader_arg: Vec<String> = shaders
                .iter()
                .filter_map(|p| p.to_str().map(|s| s.to_string()))
                .collect();
            if !shader_arg.is_empty() {
                cmd.arg(format!("--glsl-shaders={}", shader_arg.join(":")));
            }
        }
    }

    cmd.arg(&stream_url);

    if cfg!(target_os = "macos") && !lib_dir.is_empty() {
        cmd.env("DYLD_LIBRARY_PATH", &lib_dir);
        let icd_path = std::path::Path::new(&lib_dir).join("vk_icd.json");
        cmd.env("VK_ICD_FILENAMES", icd_path);
    }
    if cfg!(target_os = "linux") {
        cmd.env("LD_LIBRARY_PATH", &lib_dir);
    }

    kill_current_mpv().await;

    let mut child = cmd
        .spawn()
        .map_err(|e| format!("Failed to launch mpv: {}", e))?;

    let pid = child.id().unwrap_or(0);
    log::info!("Launched mpv pid={} with stream: {}", pid, stream_url);

    tokio::time::sleep(std::time::Duration::from_millis(500)).await;
    match child.try_wait() {
        Ok(Some(status)) => {
            log::error!("mpv exited immediately with status {:?}", status);
            return Err(format!("mpv exited immediately: {:?}", status));
        }
        Ok(None) => {
            log::info!("mpv pid={} is running", pid);
        }
        Err(e) => {
            log::warn!("Failed to check mpv status: {}", e);
        }
    }

    if let Ok(mut guard) = CURRENT_MPV.lock() {
        *guard = Some(child);
    }

    let discord = state.discord.clone();
    let anilist_client = state.anilist_client.clone();
    let db_path = state.db_path.clone();
    let monitor_media_id = media_id;
    let monitor_episode = episode_number;
    let app_handle = app.clone();
    let start_time = std::time::Instant::now();
    tokio::spawn(async move {
        loop {
            tokio::time::sleep(std::time::Duration::from_millis(500)).await;
            let exited = {
                let mut guard = match CURRENT_MPV.lock() {
                    Ok(g) => g,
                    Err(_) => return,
                };
                match guard.as_mut() {
                    Some(child) => match child.try_wait() {
                        Ok(Some(_)) => {
                            let _ = guard.take();
                            true
                        }
                        Ok(None) => false,
                        Err(_) => {
                            let _ = guard.take();
                            true
                        }
                    },
                    None => true,
                }
            };
            if exited {
                let elapsed = start_time.elapsed().as_secs_f64();
                // Record in local registry — always, for resume tracking
                if let Ok(db) = rusqlite::Connection::open(&db_path) {
                    let _ = crate::registry::service::record_watched_episode(
                        &db, monitor_media_id, monitor_episode, 0, 0,
                    );
                }
                // Only mark as watched on AniList if mpv ran for at least 60 seconds
                if elapsed >= 60.0 {
                    let mut vars = HashMap::new();
                    vars.insert("mediaId".to_string(), serde_json::json!(monitor_media_id));
                    vars.insert("status".to_string(), serde_json::json!("CURRENT"));
                    vars.insert("progress".to_string(), serde_json::json!(monitor_episode));
                    let _: Result<Value, String> = anilist_client.execute(
                        crate::anilist::queries::SAVE_MEDIA_LIST_ENTRY_MUTATION,
                        vars,
                    ).await;
                } else {
                    log::info!("mpv exited after {:.1}s — skipping AniList progress update", elapsed);
                }
                // Notify frontend
                let _ = app_handle.emit("progress_updated", serde_json::json!({
                    "media_id": monitor_media_id,
                    "episode_number": monitor_episode,
                }));
                discord.clear_presence();
                log::info!("mpv exited, progress recorded, Discord presence cleared");
                break;
            }
        }
    });

    Ok(PlaybackStart { stream_url })
}

#[tauri::command]
pub async fn record_playback_progress(
    state: &AppState,
    media_id: i64,
    episode_number: i64,
    stop_time: i64,
    duration: i64,
) -> Result<(), String> {
    let db = state.open_db()?;
    let _ = crate::registry::service::record_watched_episode(
        &db,
        media_id,
        episode_number,
        stop_time,
        duration,
    );

    if duration > 0 {
        let percentage = (stop_time as f64 / duration as f64) * 100.0;
        if percentage >= 80.0 {
            let mut vars = HashMap::new();
            vars.insert("mediaId".to_string(), serde_json::json!(media_id));
            vars.insert("status".to_string(), serde_json::json!("CURRENT"));
            vars.insert("progress".to_string(),
                serde_json::json!(episode_number),
            );

            let _: Value = state
                .anilist_client
                .execute(
                    crate::anilist::queries::SAVE_MEDIA_LIST_ENTRY_MUTATION,
                    vars,
                )
                .await?;
        }
    }

    Ok(())
}

#[tauri::command]
pub async fn stop_playback(
    state: State<'_, AppState>,
    media_id: i64,
    episode_number: i64,
    stop_time: i64,
    duration: i64,
) -> Result<(), String> {
    kill_current_mpv().await;

    state.discord.clear_presence();

    record_playback_progress(&state, media_id, episode_number, stop_time, duration).await?;

    Ok(())
}

use crate::registry::WatchEntry;

#[tauri::command]
pub async fn get_watched_episodes(
    state: State<'_, AppState>,
    media_id: i64,
) -> Result<Vec<WatchEntry>, String> {
    let db = state.open_db()?;
    crate::registry::service::get_watched_episodes(&db, media_id)
}
