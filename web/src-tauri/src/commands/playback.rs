use std::collections::HashMap;

use serde::Serialize;
use serde_json::Value;
use tauri::{AppHandle, Emitter, Manager, State};

use crate::util::percent_encode;
use crate::state::AppState;

static CURRENT_MPV: std::sync::Mutex<Option<tokio::process::Child>> = std::sync::Mutex::new(None);

/// An episode counts as "watched" once playback passes this fraction of its
/// duration. The same line decides completion (advancing AniList progress) and
/// stops offering a resume — there is exactly one watched threshold.
const WATCHED_THRESHOLD_PCT: f64 = 85.0;

fn get_ipc_path() -> String {
    if cfg!(target_os = "windows") {
        r"\\.\pipe\anicat-mpv".to_string()
    } else {
        let uid = std::env::var("USER").unwrap_or_else(|_| "user".to_string());
        format!("/tmp/anicat-mpv-{}.sock", uid)
    }
}

async fn try_send_ipc(ipc_path: &str, commands: Vec<serde_json::Value>) -> Result<(), String> {
    use tokio::io::AsyncWriteExt;

    #[cfg(unix)]
    {
        let mut stream = tokio::net::UnixStream::connect(ipc_path)
            .await
            .map_err(|e| e.to_string())?;
        for cmd in commands {
            let line = format!("{}\n", cmd.to_string());
            stream.write_all(line.as_bytes())
                .await
                .map_err(|e| e.to_string())?;
        }
        let _ = stream.flush().await;
        let _ = stream.shutdown().await;
        tokio::time::sleep(std::time::Duration::from_millis(20)).await;
        return Ok(());
    }

    #[cfg(windows)]
    {
        use tokio::net::windows::named_pipe::ClientOptions;
        let mut client = ClientOptions::new()
            .open(ipc_path)
            .map_err(|e| e.to_string())?;
        for cmd in commands {
            let line = format!("{}\n", cmd.to_string());
            client.write_all(line.as_bytes())
                .await
                .map_err(|e| e.to_string())?;
        }
        let _ = client.flush().await;
        let _ = client.shutdown().await;
        tokio::time::sleep(std::time::Duration::from_millis(20)).await;
        return Ok(());
    }

    #[cfg(not(any(unix, windows)))]
    {
        let _ = ipc_path;
        let _ = commands;
        Err("Unsupported platform".to_string())
    }
}

pub async fn cancel_mpv_next(message: &str) -> Result<(), String> {
    let ipc_path = get_ipc_path();
    let cmd_osd = serde_json::json!({
        "command": ["show-text", message, 3000]
    });
    let cmd_cancel = serde_json::json!({
        "command": ["script-message", "anicat-cancel-next"]
    });
    try_send_ipc(&ipc_path, vec![cmd_osd, cmd_cancel]).await
}

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

    #[cfg(unix)]
    {
        let path = get_ipc_path();
        let _ = std::fs::remove_file(path);
    }
}

#[derive(Serialize)]
pub struct PlaybackStart {
    pub stream_url: String,
}

fn resolve_mpv_path(app: &AppHandle) -> Result<(String, String, String), String> {
    let resource_dir = app.path().resource_dir().map_err(|e| e.to_string())?;

    let base_dir = if resource_dir.join("resources").exists() {
        resource_dir.join("resources")
    } else {
        resource_dir.clone()
    };

    let prod_config = base_dir.join("mpv_config");
    let config_dir = if prod_config.exists() {
        prod_config.to_string_lossy().to_string()
    } else {
        std::path::Path::new(env!("CARGO_MANIFEST_DIR"))
            .join("resources")
            .join("mpv_config")
            .to_string_lossy()
            .to_string()
    };

    // Prefer a system-installed mpv if present (Homebrew on macOS; winget,
    // scoop, or choco on Windows), falling back to the bundled binary below.
    let mpv_query = if cfg!(target_os = "windows") { "mpv.exe" } else { "mpv" };
    if let Some(path) = crate::util::find_on_path(mpv_query) {
        log::info!("Found system mpv at: {}", path);
        return Ok((path, config_dir, String::new()));
    }

    let mpv_name = if cfg!(target_os = "windows") {
        "mpv.exe"
    } else {
        "mpv"
    };
    let mpv_bin = base_dir.join(mpv_name);
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

    let lib_dir = base_dir.join("lib");

    Ok((
        mpv_bin.to_string_lossy().to_string(),
        config_dir,
        lib_dir.to_string_lossy().to_string(),
    ))
}

fn server_speed_rank(server: &crate::scraper::client::StreamServer) -> u8 {
    let url = server.url.to_lowercase();
    if url.contains("tools.fast4speed.rsvp") { return 0; }
    if url.contains("wixstatic.com") || url.contains("wixmp.com") { return 1; }
    if url.contains("sharepoint") || url.contains("fast4speed") { return 2; }
    if url.contains("mp4upload") || url.contains("youtu-chan") { return 3; }
    4
}

fn pick_best_server<'a>(servers: &'a [crate::scraper::client::StreamServer]) -> Option<&'a crate::scraper::client::StreamServer> {
    servers.iter().min_by_key(|s| server_speed_rank(s))
}

fn pick_best_server_in_group<'a>(servers: &'a [crate::scraper::client::StreamServer], groups: &[&str]) -> Option<&'a crate::scraper::client::StreamServer> {
    servers.iter().filter(|s| {
        let g = get_stream_group(s);
        groups.contains(&g)
    }).min_by_key(|s| server_speed_rank(s))
}
fn get_stream_group(server: &crate::scraper::client::StreamServer) -> &str {
    if let Some(ref group) = server.group {
        if group == "sub" {
            return "hard_sub";
        }
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

/// Human-facing provider name for notifications.
pub(crate) fn provider_label(provider: &str) -> &str {
    match provider {
        "allanime" => "AllAnime",
        "anineko" => "AniNeko",
        "mangakatana" => "MangaKatana",
        other => other,
    }
}

/// Resolve a playable stream URL (+ headers) for one provider: find/auto-map
/// its slug, scrape the episode, and pick the best server for the configured
/// sub/dub preference. Returns Err with a reason if anything in that chain
/// fails, so the caller can try a fallback provider.
pub(crate) async fn resolve_stream_for_provider(
    state: &AppState,
    media_id: i64,
    episode_number: i64,
    provider_name: &str,
    server: &Option<String>,
    title: Option<String>,
) -> Result<(String, Option<std::collections::HashMap<String, String>>), String> {
    // Read any cached slug in a scoped block so the (non-Sync) DB connection is
    // dropped before the first await — otherwise this future is !Send.
    let cached_slug = {
        let db = state.open_db()?;
        crate::registry::service::get_provider_slug(&db, media_id, provider_name)
    };
    let slug = match cached_slug {
        Some(s) => Some(s),
        None => super::media::resolve_and_save_provider_slug(
            state,
            media_id,
            provider_name,
            false,
            title,
        )
        .await
        .ok()
        .flatten(),
    }
    .ok_or_else(|| format!("No provider mapping for media {} on {}", media_id, provider_name))?;

    let servers = state
        .scraper_manager
        .get_streams(&slug, episode_number as i32, provider_name)
        .await?;

    let selected_server = if let Some(ref s_name) = server {
        servers.iter().find(|s| s.name == *s_name)
            .or_else(|| pick_best_server(&servers))
    } else {
        let translation_type = {
            let cfg = state.config.read().await;
            cfg.stream.translation_type.clone()
        };
        if translation_type == "dub" {
            pick_best_server_in_group(&servers, &["dub"])
                .or_else(|| pick_best_server_in_group(&servers, &["hard_sub", "soft_sub"]))
                .or_else(|| pick_best_server(&servers))
        } else {
            pick_best_server_in_group(&servers, &["hard_sub", "soft_sub"])
                .or_else(|| pick_best_server_in_group(&servers, &["dub"]))
                .or_else(|| pick_best_server(&servers))
        }
    };

    let raw_stream_url = selected_server.map(|s| s.url.clone()).unwrap_or_default();
    let headers = selected_server.and_then(|s| s.headers.clone());
    if raw_stream_url.is_empty() {
        return Err(format!("No stream URL found on {}", provider_name));
    }
    Ok((raw_stream_url, headers))
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
    let mut provider_name = provider.unwrap_or_else(|| "allanime".to_string());

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
            total_episodes: total_eps,
            last_position: 0,
            last_duration: 0,
            paused: false,
        });
    }

    let db = state.open_db()?;

    let resume_seconds = {
        // An episode past the watched threshold is finished — don't drop the
        // user back near the end of something they already completed. Also
        // ignore trivially small positions so a brief sample doesn't start the
        // episode in the middle.
        const MIN_RESUME_SECONDS: i64 = 30;
        let mut sec = 0;
        if let Ok(entries) = crate::registry::service::get_watched_episodes(&db, media_id) {
            if let Some(entry) = entries.iter().find(|e| e.episode_number == episode_number) {
                let duration = entry.duration;
                if duration > 0 {
                    let pct = (entry.stop_time as f64 / duration as f64) * 100.0;
                    if pct < WATCHED_THRESHOLD_PCT && entry.stop_time >= MIN_RESUME_SECONDS {
                        sec = entry.stop_time;
                        log::info!("Found resume position: {}s (duration: {}s, {:.1}%)", sec, duration, pct);
                    }
                }
            }
        }
        // Reconcile the two sources of truth: local watch_history says where you
        // stopped, but AniList progress is the authority on what's *watched*. If
        // AniList already counts this episode (progress >= episode_number), don't
        // drop back into the middle of it — start fresh. Fixes the "resumes
        // mid-episode instead of starting over" case after a desync or a watch on
        // another device.
        if sec > 0 {
            if let Some(anilist_progress) = state.cache.get_user_list_progress(media_id) {
                if anilist_progress >= episode_number {
                    log::info!(
                        "Suppressing resume for media {} ep {}: AniList progress {} already covers it",
                        media_id, episode_number, anilist_progress
                    );
                    sec = 0;
                }
            }
        }
        sec
    };

    state.discord.set_presence(&title_str, episode_number, &episode_title_str, total_eps, resume_seconds, 0, false);

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

    let mut stream_headers = None;

    let stream_url = if let Some(local_path) = local_file_path {
        log::info!("Playing offline local download: {}", local_path);
        local_path
    } else {
        // Try the primary provider; if it can't produce a playable stream
        // (provider down, no slug match, no servers), fall back to the
        // configured fallback provider instead of failing the play button.
        let fallback_provider = {
            let cfg = state.config.read().await;
            cfg.general.fallback_provider.clone()
        };

        // Instant transition: if the previous episode preloaded this one's
        // stream, use it and skip the scrape entirely. Stale or mismatched
        // entries fall through to a normal resolve.
        let preloaded = {
            let mut slot = state.preloaded_stream.lock().await;
            match slot.take() {
                Some(p)
                    if p.media_id == media_id
                        && p.episode_number == episode_number
                        && p.provider == provider_name
                        && p.at.elapsed() < std::time::Duration::from_secs(15 * 60) =>
                {
                    Some(p)
                }
                other => {
                    *slot = other;
                    None
                }
            }
        };

        let (raw_stream_url, headers) = if let Some(p) = preloaded {
            log::info!("Using preloaded stream for media {} ep {}", media_id, episode_number);
            (p.raw_url, p.headers)
        } else {
            match resolve_stream_for_provider(
            &state, media_id, episode_number, &provider_name, &server, title.clone(),
        )
        .await
        {
            Ok(res) => res,
            Err(primary_err) => {
                let has_fallback = !fallback_provider.is_empty()
                    && fallback_provider != "none"
                    && fallback_provider != provider_name;
                if has_fallback {
                    log::warn!(
                        "Primary provider '{}' failed ({}); trying fallback '{}'",
                        provider_name, primary_err, fallback_provider
                    );
                    match resolve_stream_for_provider(
                        &state, media_id, episode_number, &fallback_provider, &server, title.clone(),
                    )
                    .await
                    {
                        Ok(res) => {
                            // Switch the live session to the working provider so
                            // auto-next/prev and Discord follow it, and tell the user.
                            let working = fallback_provider.clone();
                            {
                                let mut guard = state.current_playback.lock().await;
                                if let Some(ref mut pb) = *guard {
                                    pb.provider = working.clone();
                                }
                            }
                            use tauri::Emitter;
                            let _ = app.emit("show_notification", serde_json::json!({
                                "message": format!(
                                    "{} unavailable — playing from {}",
                                    provider_label(&provider_name),
                                    provider_label(&fallback_provider),
                                )
                            }));
                            provider_name = working;
                            res
                        }
                        Err(fb_err) => {
                            return Err(format!(
                                "No stream from {} or {}: {} / {}",
                                provider_label(&provider_name),
                                provider_label(&fallback_provider),
                                primary_err, fb_err
                            ));
                        }
                    }
                } else {
                    return Err(primary_err);
                }
            }
            }
        };

        stream_headers = headers;

        let mut stream_url = raw_stream_url.clone();
        if stream_url.contains("vibeplayer.site") || stream_url.contains("m3u8") {
            let proxy_port = *state.inner.proxy_port.lock().unwrap_or_else(|e| e.into_inner());
            let encoded_url = percent_encode(&stream_url);
            stream_url = format!("http://127.0.0.1:{}/proxy?url={}", proxy_port, encoded_url);
            log::info!("Proxied stream URL: {}", stream_url);
        }
        stream_url
    };

    // Sync AniList watching list after confirming stream is available — but
    // only when the entry isn't already CURRENT. Previously this fired a
    // SaveMediaListEntry on every episode launch; now it just moves
    // Planning/Paused/etc. into Watching and is a no-op for an already-watching
    // series.
    if state.anilist_client.has_token() && media_id > 0 {
        let already_current = state
            .cache
            .get_user_list_status(media_id)
            .map(|s| s.eq_ignore_ascii_case("CURRENT"))
            .unwrap_or(false);
        if !already_current {
            let anilist = state.anilist_client.clone();
            let cache = state.cache.clone();
            let m_id = media_id;
            tokio::spawn(async move {
                let mut vars = std::collections::HashMap::new();
                vars.insert("mediaId".to_string(), serde_json::json!(m_id));
                vars.insert("status".to_string(), serde_json::json!("CURRENT"));
                if let Err(e) = anilist
                    .execute::<serde_json::Value>(
                        crate::anilist::queries::SAVE_MEDIA_LIST_ENTRY_MUTATION,
                        vars,
                    )
                    .await
                {
                    log::warn!("Failed to sync AniList watching list: {}", e);
                } else {
                    cache.update_user_list_progress(m_id, None, Some("CURRENT"), None);
                }
            });
        }
    }

    let skip_times_arg = String::new();
    let state_clone = (*state).clone();
    let title_clone = title_str.clone();
    tokio::spawn(async move {
        let mal_id = {
            let mut vars = HashMap::new();
            vars.insert("id".to_string(), serde_json::json!(media_id));
            vars.insert("type".to_string(), serde_json::json!("ANIME"));
            let res: Result<crate::anilist::responses::MediaResponse, String> = state_clone
                .anilist_client
                .execute(crate::anilist::queries::MEDIA_DETAIL_QUERY, vars)
                .await;
            let mut found = None;
            if let Ok(r) = res {
                if let Some(media) = r.media {
                    log::info!("[aniskip] AniList media id={}, id_mal={:?}, title_romaji={:?}, title_english={:?}",
                        media.id, media.id_mal,
                        media.title.as_ref().and_then(|t| t.romaji.as_deref()),
                        media.title.as_ref().and_then(|t| t.english.as_deref()));
                    // 1. Direct idMal from AniList
                    if let Some(id) = media.id_mal {
                        log::info!("[aniskip] Using MAL ID {} from AniList", id);
                        found = Some(id);
                    // 2. Fallback: search Jikan by title
                    } else if let Some(search_title) = media.title.as_ref()
                        .and_then(|t| t.english.as_deref().or(t.romaji.as_deref()))
                        .filter(|t| !t.is_empty())
                        .or_else(|| if !title_clone.is_empty() { Some(&title_clone as &str) } else { None })
                    {
                        let jikan_url = format!(
                            "https://api.jikan.moe/v4/anime?q={}&limit=1&sfw",
                            percent_encode(search_title)
                        );
                        log::info!("[aniskip] Jikan searching by title '{}' url={}", search_title, jikan_url);
                        match reqwest::Client::new()
                            .get(&jikan_url)
                            .timeout(std::time::Duration::from_secs(5))
                            .send()
                            .await
                        {
                            Ok(resp) => {
                                let status = resp.status();
                                log::info!("[aniskip] Jikan response status: {}", status);
                                if let Ok(body) = resp.text().await {
                                    if let Ok(jikan_res) = serde_json::from_str::<serde_json::Value>(&body) {
                                        if let Some(data) = jikan_res["data"].as_array() {
                                            found = data.first().and_then(|f| f["mal_id"].as_i64());
                                        }
                                    }
                                }
                            }
                            Err(e) => log::warn!("[aniskip] Jikan request error: {}", e),
                        }
                    }
                }
            }
            found
        };

        let mut bg_skip_times_arg = String::new();
        if let Some(m_id) = mal_id {
            let client = reqwest::Client::new();
            let url = format!(
                "https://api.aniskip.com/v2/skip-times/{}/{}?types[]=op&types[]=ed&episodeLength=0",
                m_id, episode_number
            );
            log::info!("[aniskip] Fetching AniSkip times from: {}", url);
            match client.get(&url).timeout(std::time::Duration::from_millis(5000)).send().await {
                Ok(resp) => {
                    let status = resp.status();
                    if status.is_success() {
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
                                bg_skip_times_arg = parts.join(";");
                                log::info!("[aniskip] Found skip times in background: {}", bg_skip_times_arg);
                            }
                        }
                    }
                }
                Err(e) => log::warn!("[aniskip] AniSkip request error: {}", e),
            }
        }

        if !bg_skip_times_arg.is_empty() {
            let (autoskip, autoplay) = {
                let cfg = state_clone.config.read().await;
                (cfg.general.autoskip, cfg.general.autoplay)
            };
            let mut script_opts = Vec::new();
            let encoded = bg_skip_times_arg.replace(",", "%2C");
            script_opts.push(format!("anicat_ui-skip_times={}", encoded));
            script_opts.push(format!("anicat_ui-autoskip={}", if autoskip { "yes" } else { "no" }));
            script_opts.push(format!("anicat_ui-auto_next={}", if autoplay { "yes" } else { "no" }));
            script_opts.push(format!("anicat_ui-current_episode={}", episode_number));
            script_opts.push(format!("anicat_ui-total_episodes={}", total_eps));
            let script_opts_str = script_opts.join(",");

            let ipc_path = get_ipc_path();
            let cmd = serde_json::json!({
                "command": ["set_property", "script-opts", script_opts_str]
            });
            
            // Retry sending over IPC in case MPV is still launching
            for i in 0..15 {
                tokio::time::sleep(std::time::Duration::from_millis(200)).await;
                if try_send_ipc(&ipc_path, vec![cmd.clone()]).await.is_ok() {
                    log::info!("[aniskip] Dynamically loaded skip times via IPC on attempt {}", i + 1);
                    break;
                }
            }
        }
    });

    let (mpv_bin, config_dir, lib_dir) = resolve_mpv_path(&app)?;
    log::info!("mpv binary: {}", mpv_bin);
    log::info!("mpv config: {}", config_dir);
    log::info!("mpv lib dir: {}", lib_dir);

    // Self-healing permission setup for mpv binary
    #[cfg(unix)]
    {
        use std::os::unix::fs::PermissionsExt;
        if let Ok(metadata) = std::fs::metadata(&mpv_bin) {
            let mut perms = metadata.permissions();
            if perms.mode() & 0o111 == 0 {
                perms.set_mode(0o755);
                let _ = std::fs::set_permissions(&mpv_bin, perms);
                log::info!("Set executable permissions for mpv binary");
            }
        }
    }

    let mut cmd = tokio::process::Command::new(&mpv_bin);
    crate::util::suppress_console_tokio(&mut cmd);
    cmd.arg(format!("--config-dir={}", config_dir));
    cmd.arg("--force-window=yes");
    cmd.arg("--ontop");
    cmd.arg(format!("--input-ipc-server={}", get_ipc_path()));

    if resume_seconds > 0 {
        cmd.arg(format!("--start={}", resume_seconds));
    }

    if !title_str.is_empty() {
        let media_title = format!("{} - Episode {}", title_str, episode_number);
        cmd.arg(format!("--force-media-title={}", media_title));
        cmd.arg(format!("--title={}", media_title));
    }

    let (autoskip, autoplay) = {
        let cfg = state.config.read().await;
        (cfg.general.autoskip, cfg.general.autoplay)
    };
    let mut script_opts = Vec::new();
    if !skip_times_arg.is_empty() {
        // Encode commas as %2C to avoid mpv --script-opts comma delimiter issue
        let encoded = skip_times_arg.replace(",", "%2C");
        script_opts.push(format!("anicat_ui-skip_times={}", encoded));
    }
    let shader_profile = state
        .config
        .read()
        .await
        .stream
        .shader_profile
        .clone();
    script_opts.push(format!("anicat_ui-autoskip={}", if autoskip { "yes" } else { "no" }));
    script_opts.push(format!("anicat_ui-auto_next={}", if autoplay { "yes" } else { "no" }));
    script_opts.push(format!("anicat_ui-current_episode={}", episode_number));
    script_opts.push(format!("anicat_ui-total_episodes={}", total_eps));
    script_opts.push(format!("anicat_ui-shader_profile={}", shader_profile));
    let script_opts_str = script_opts.join(",");
    log::info!("[aniskip] mpv script-opts: {}", script_opts_str);
    cmd.arg(format!("--script-opts={}", script_opts_str));

    if autoplay {
        cmd.arg("--keep-open=yes");
    }

    if shader_profile != "off" {
        let shader_dir = std::path::Path::new(&config_dir).join("shaders");
        let shader_names = [
            "Anime4K_Clamp_Highlights.glsl",
            "Anime4K_Restore_CNN_Soft_S.glsl",
            "Anime4K_Upscale_CNN_x2_S.glsl",
            "Anime4K_AutoDownscalePre_x2.glsl",
            "Anime4K_AutoDownscalePre_x4.glsl",
            "Anime4K_Thin_HQ.glsl",
            "Anime4K_Darken_HQ.glsl",
        ];
        let shader_arg: Vec<String> = shader_names
            .iter()
            .map(|n| shader_dir.join(n))
            .filter_map(|p| p.to_str().map(|s| s.to_string()))
            .collect();
        if !shader_arg.is_empty() {
            cmd.arg(format!("--glsl-shaders={}", shader_arg.join(":")));
        }
    }

    if let Some(ref headers) = stream_headers {
        let mut fields = Vec::new();
        for (key, val) in headers {
            let key_lower = key.to_lowercase();
            if key_lower == "referer" {
                cmd.arg(format!("--referrer={}", val));
            } else if key_lower == "user-agent" {
                cmd.arg(format!("--user-agent={}", val));
            } else {
                fields.push(format!("{}: {}", key, val));
            }
        }
        if !fields.is_empty() {
            cmd.arg(format!("--http-header-fields={}", fields.join(",")));
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
    if cfg!(target_os = "windows") && !lib_dir.is_empty() {
        // Windows resolves DLLs via the exe directory and PATH; prepend the
        // bundled lib dir so any mpv DLLs there are found.
        let existing = std::env::var("PATH").unwrap_or_default();
        cmd.env("PATH", format!("{};{}", lib_dir, existing));
    }

    let has_active_mpv = {
        if let Ok(guard) = CURRENT_MPV.lock() {
            guard.is_some()
        } else {
            false
        }
    };

    let mut reused = false;
    if has_active_mpv {
        let mut commands = Vec::new();

        if let Some(ref headers) = stream_headers {
            let mut fields = Vec::new();
            for (key, val) in headers {
                let key_lower = key.to_lowercase();
                if key_lower == "referer" {
                    commands.push(serde_json::json!({
                        "command": ["set_property", "referrer", val]
                    }));
                } else if key_lower == "user-agent" {
                    commands.push(serde_json::json!({
                        "command": ["set_property", "user-agent", val]
                    }));
                } else {
                    fields.push(format!("{}: {}", key, val));
                }
            }
            if !fields.is_empty() {
                commands.push(serde_json::json!({
                    "command": ["set_property", "http-header-fields", fields.join(",")]
                }));
            }
        } else {
            commands.push(serde_json::json!({
                "command": ["set_property", "referrer", ""]
            }));
            commands.push(serde_json::json!({
                "command": ["set_property", "user-agent", ""]
            }));
            commands.push(serde_json::json!({
                "command": ["set_property", "http-header-fields", ""]
            }));
        }

        let (autoskip, autoplay) = {
            let cfg = state.config.read().await;
            (cfg.general.autoskip, cfg.general.autoplay)
        };
        let mut script_opts_parts = Vec::new();
        if !skip_times_arg.is_empty() {
            script_opts_parts.push(format!("anicat_ui-skip_times={}", skip_times_arg.replace(",", "%2C")));
        }
        script_opts_parts.push(format!("anicat_ui-autoskip={}", if autoskip { "yes" } else { "no" }));
        script_opts_parts.push(format!("anicat_ui-auto_next={}", if autoplay { "yes" } else { "no" }));
        script_opts_parts.push(format!("anicat_ui-current_episode={}", episode_number));
        script_opts_parts.push(format!("anicat_ui-total_episodes={}", total_eps));
        
        commands.push(serde_json::json!({
            "command": ["set_property", "script-opts", script_opts_parts.join(",")]
        }));

        if !title_str.is_empty() {
            let media_title = format!("{} - Episode {}", title_str, episode_number);
            commands.push(serde_json::json!({
                "command": ["set_property", "force-media-title", media_title]
            }));
        }

        // Always pass an explicit start position. The first episode launches
        // mpv with a global --start=<resume> option; without a per-file start
        // here, `loadfile … replace` re-applies that global start to the next
        // episode, dropping the user into it at the previous episode's
        // position. resume_seconds is 0 for a fresh episode, so this starts it
        // at the beginning; for a partially-watched one it resumes correctly.
        let load_cmd = vec![
            serde_json::json!("loadfile"),
            serde_json::json!(stream_url),
            serde_json::json!("replace"),
            serde_json::json!("0"), // index argument
            serde_json::json!(format!("start={}", resume_seconds)),
        ];
        commands.push(serde_json::json!({
            "command": load_cmd
        }));

        commands.push(serde_json::json!({
            "command": ["set_property", "pause", false]
        }));

        let ipc_path = get_ipc_path();
        log::info!("Connecting to running MPV at {} via IPC...", ipc_path);
        if try_send_ipc(&ipc_path, commands).await.is_ok() {
            log::info!("Successfully sent stream URL to running MPV via IPC!");
            reused = true;
        } else {
            log::warn!("Failed to communicate with MPV over IPC, will restart player");
        }
    }

    if reused {
        let mut guard = state.current_playback.lock().await;
        *guard = Some(crate::state::CurrentPlayback {
            media_id,
            episode_number,
            provider: provider_name.clone(),
            title: title_str.clone(),
            episode_title: episode_title_str.clone(),
            cover_image: cover_image_str.clone(),
            total_episodes: total_eps,
            last_position: 0,
            last_duration: 0,
            paused: false,
        });
        return Ok(PlaybackStart { stream_url });
    }

    kill_current_mpv().await;

    log::info!("Launching mpv command: {:?}", cmd);
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

    {
        let mut guard = state.current_playback.lock().await;
        *guard = Some(crate::state::CurrentPlayback {
            media_id,
            episode_number,
            provider: provider_name.clone(),
            title: title_str.clone(),
            episode_title: episode_title_str.clone(),
            cover_image: cover_image_str.clone(),
            total_episodes: total_eps,
            last_position: 0,
            last_duration: 0,
            paused: false,
        });
    }

    let discord = state.discord.clone();
    let monitor_media_id = media_id;
    let monitor_episode = episode_number;
    let app_handle = app.clone();
    let app_state_clone = (*state).clone();
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
                let (monitor_media_id, monitor_episode) = {
                    let guard = app_state_clone.current_playback.lock().await;
                    if let Some(ref pb) = *guard {
                        (pb.media_id, pb.episode_number)
                    } else {
                        (monitor_media_id, monitor_episode)
                    }
                };

                // Give the Lua script time to send position via player/stop
                tokio::time::sleep(std::time::Duration::from_millis(2000)).await;

                // If player_stop already saved position, current_playback is None.
                // If still set, save last known position as a fallback.
                let should_save = {
                    let guard = app_state_clone.current_playback.lock().await;
                    guard.is_some()
                };
                if should_save {
                    let (last_pos, last_dur, total_eps) = {
                        let guard = app_state_clone.current_playback.lock().await;
                        if let Some(ref pb) = *guard {
                            (pb.last_position, pb.last_duration, pb.total_episodes)
                        } else {
                            (0, 0, 0)
                        }
                    };
                    if last_pos > 0 {
                        let _ = crate::commands::playback::record_playback_progress(
                            &app_state_clone,
                            monitor_media_id,
                            monitor_episode,
                            last_pos,
                            last_dur,
                            total_eps,
                        )
                        .await;
                        log::info!("Saved last known playback position: {}s / {}s", last_pos, last_dur);
                    }
                }

                // Notify frontend
                let _ = app_handle.emit("progress_updated", serde_json::json!({
                    "media_id": monitor_media_id,
                    "episode_number": monitor_episode,
                }));
                discord.clear_presence();
                {
                    let mut guard = app_state_clone.current_playback.lock().await;
                    *guard = None;
                }
                log::info!("mpv exited, Discord presence cleared");
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
    total_episodes: i64,
) -> Result<(), String> {
    // Dedupe the burst of recorders one stop/next event produces (stop handler,
    // shutdown handler, exit monitor). The first writes; the rest, arriving for
    // the same episode within a few seconds, are dropped. The first recorder
    // (the stop handler) carries the most accurate position, so keeping it is
    // also the right choice for resume.
    {
        const DEDUPE_WINDOW: std::time::Duration = std::time::Duration::from_secs(3);
        let mut last = state.last_progress_record.lock().await;
        if let Some((m, ep, at)) = *last {
            if m == media_id && ep == episode_number && at.elapsed() < DEDUPE_WINDOW {
                log::info!("Deduping duplicate progress record for media {} ep {}", media_id, episode_number);
                return Ok(());
            }
        }
        *last = Some((media_id, episode_number, std::time::Instant::now()));
    }

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
        // Completion is the ONLY automatic way AniList progress advances: you
        // played the episode past the watched threshold. Navigation (next/prev)
        // records the real position but never forces this.
        if percentage >= WATCHED_THRESHOLD_PCT {
            // Serialize automatic writes with manual list edits and with each
            // other, so the many concurrent recorders fired by one stop/next
            // event (player_stop, shutdown handler, process-exit monitor) can't
            // race into an out-of-order AniList write.
            let _lock = state.user_list_lock.lock().await;

            // Forward-only guard: never let a stale or out-of-order completion
            // regress AniList progress. If the cache knows the current progress
            // and it already covers this episode, skip the write entirely.
            if let Some(current) = state.cache.get_user_list_progress(media_id) {
                if episode_number <= current {
                    log::info!(
                        "Skipping progress write for media {} ep {}: AniList already at {}",
                        media_id, episode_number, current
                    );
                    return Ok(());
                }
            }

            let status = if total_episodes > 0 && episode_number >= total_episodes {
                "COMPLETED"
            } else {
                "CURRENT"
            };

            let mut vars = HashMap::new();
            vars.insert("mediaId".to_string(), serde_json::json!(media_id));
            vars.insert("status".to_string(), serde_json::json!(status));
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

            state.cache.update_user_list_progress(media_id, Some(episode_number), Some(status), None);
            state.cache.invalidate("get_user_list");
            state.cache.invalidate("get_airing_schedule");
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

    let total_episodes = {
        let guard = state.current_playback.lock().await;
        guard.as_ref().map(|p| p.total_episodes).unwrap_or(0)
    };
    record_playback_progress(&state, media_id, episode_number, stop_time, duration, total_episodes).await?;

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

#[tauri::command]
pub async fn get_all_last_watched(
    state: State<'_, AppState>,
) -> Result<HashMap<i64, String>, String> {
    let db = state.open_db()?;
    crate::registry::service::get_all_last_watched(&db)
}
