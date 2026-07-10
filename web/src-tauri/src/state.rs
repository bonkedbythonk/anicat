use serde::{Deserialize, Serialize};
use std::sync::Arc;
use tokio::sync::RwLock;

#[derive(Debug, Clone, Serialize, Deserialize, Default)]
pub struct AppConfig {
    #[serde(default)]
    pub general: GeneralConfig,
    #[serde(default)]
    pub stream: StreamConfig,
    #[serde(default)]
    pub api: ApiConfig,
    #[serde(default)]
    pub mobile: MobileConfig,
}

#[derive(Debug, Clone, Serialize, Deserialize, Default)]
pub struct GeneralConfig {
    #[serde(default = "default_provider")]
    pub provider: String,
    #[serde(default = "default_true")]
    pub autoplay: bool,
    #[serde(default = "default_false")]
    pub autoskip: bool,
    #[serde(default = "default_true")]
    pub anime_preview: bool,
    #[serde(default = "default_title_language")]
    pub preferred_title_language: String,
    #[serde(default)]
    pub downloads_path: String,
    #[serde(default = "default_time_format")]
    pub time_format: String,
    #[serde(default = "default_false")]
    pub discord: bool,
    #[serde(default = "default_media_api")]
    pub media_api: String,
    #[serde(default = "default_manga_provider")]
    pub manga_provider: String,
    #[serde(default = "default_fallback_provider")]
    pub fallback_provider: String,
}

#[derive(Debug, Clone, Serialize, Deserialize, Default)]
pub struct StreamConfig {
    #[serde(default = "default_false")]
    pub data_saver: bool,
    #[serde(default = "default_shader_profile")]
    pub shader_profile: String,
    #[serde(default = "default_interpolation")]
    pub interpolation: String,
    #[serde(default = "default_translation_type")]
    pub translation_type: String,
}

#[derive(Debug, Clone, Serialize, Deserialize, Default)]
pub struct ApiConfig {
    #[serde(default)]
    pub anilist_token: Option<String>,
    #[serde(default)]
    pub anilist_username: Option<String>,
}

/// Settings for the LAN-facing mobile PWA. This is an anti-accidental-entry
/// gate for a trusted home network, not a security boundary — the PIN is
/// stored and compared in plaintext intentionally (hashing a 4-6 digit PIN
/// would not meaningfully raise the bar, and it keeps the "show current PIN"
/// round-trip in Settings trivial).
#[derive(Debug, Clone, Serialize, Deserialize, Default)]
pub struct MobileConfig {
    #[serde(default)]
    pub pin: Option<String>,
    #[serde(default = "default_false")]
    pub lan_access_enabled: bool,
}

fn default_translation_type() -> String {
    "sub".into()
}

fn default_provider() -> String {
    "mkissa".into()
}
fn default_true() -> bool {
    true
}
fn default_false() -> bool {
    false
}
fn default_title_language() -> String {
    "romaji".into()
}
fn default_time_format() -> String {
    "12h".into()
}
fn default_media_api() -> String {
    "anilist".into()
}
fn default_manga_provider() -> String {
    "mangakatana".into()
}
fn default_fallback_provider() -> String {
    "anineko".into()
}
fn default_shader_profile() -> String {
    "balanced".into()
}
fn default_interpolation() -> String {
    "off".into()
}

#[derive(Clone)]
pub struct AppState {
    pub inner: Arc<AppStateInner>,
}

#[derive(Debug, Clone)]
pub struct CurrentPlayback {
    pub media_id: i64,
    pub episode_number: i64,
    pub provider: String,
    pub title: String,
    pub episode_title: String,
    pub cover_image: String,
    pub total_episodes: i64,
    pub last_position: i64,
    pub last_duration: i64,
    pub paused: bool,
}

#[derive(Clone)]
pub struct AppStateInner {
    pub config: Arc<RwLock<AppConfig>>,
    pub config_path: String,
    pub db_path: String,
    pub anilist_client: crate::anilist::AniListClient,
    pub http_client: reqwest::Client,
    pub scraper_manager: Arc<crate::scraper::ScraperManager>,
    pub cache: crate::cache::AniListCache,
    pub current_playback: Arc<tokio::sync::Mutex<Option<CurrentPlayback>>>,
    pub discord: crate::discord::DiscordClient,
    pub proxy_port: Arc<std::sync::Mutex<u16>>,
    pub user_list_lock: Arc<tokio::sync::Mutex<()>>,
    /// Last (media_id, episode_number, recorded_at) written by
    /// record_playback_progress. One stop/next event triggers several
    /// independent recorders (stop handler, shutdown handler, exit monitor);
    /// this collapses them so only the first does the work.
    pub last_progress_record: Arc<tokio::sync::Mutex<Option<(i64, i64, std::time::Instant)>>>,
    /// Next episode's stream resolved ahead of time (near the end of the
    /// current episode) so auto-next is instant instead of waiting on a scrape.
    pub preloaded_stream: Arc<tokio::sync::Mutex<Option<PreloadedStream>>>,
    /// Incremented on every start_playback. Background tasks (notably the
    /// AniSkip resolver, which keeps retrying IPC for a few seconds) capture
    /// the value at spawn and bail if it no longer matches — otherwise a task
    /// from the previous episode clobbers the current episode's script-opts
    /// (current_episode, skip_times), breaking next/prev and AniSkip.
    pub playback_generation: Arc<std::sync::atomic::AtomicU64>,
    /// Embedded torrent engine for the "nyaa" provider. Lazy: no torrent
    /// session (DHT, listeners) exists until the first torrent playback.
    pub torrent: Arc<crate::torrent::TorrentManager>,
}

#[derive(Debug, Clone)]
pub struct PreloadedStream {
    pub media_id: i64,
    pub episode_number: i64,
    pub provider: String,
    pub raw_url: String,
    pub headers: Option<std::collections::HashMap<String, String>>,
    pub at: std::time::Instant,
}

impl AppState {
    pub fn new() -> Self {
        let config_dir = dirs::config_dir()
            .unwrap_or_else(|| std::path::PathBuf::from("."))
            .join("anicat");
        let config_path = config_dir.join("config.toml");
        let mut config = Self::load_config(&config_path);

        let mut config_was_empty = false;
        if config.general.downloads_path.is_empty() {
            config_was_empty = true;
            if let Some(download_dir) = dirs::download_dir() {
                config.general.downloads_path = download_dir.to_string_lossy().to_string();
            } else if let Some(home_dir) = dirs::home_dir() {
                config.general.downloads_path = home_dir.join("Downloads").to_string_lossy().to_string();
            }
        }

        if config_was_empty {
            if let Ok(toml_str) = toml::to_string_pretty(&config) {
                if let Some(parent) = config_path.parent() {
                    let _ = std::fs::create_dir_all(parent);
                }
                let _ = std::fs::write(&config_path, toml_str);
            }
        }

        let db_path = config_dir
            .join("registry.db")
            .to_string_lossy()
            .to_string();

        {
            let db_path = db_path.clone();
            std::thread::spawn(move || {
                if let Ok(conn) = rusqlite::Connection::open(&db_path) {
                    let _ = crate::registry::service::initialize(&conn);
                }
            })
            .join()
            .ok();
        }

        // Pin rustls explicitly: if a dependency ever enables reqwest's
        // default-tls feature again, the implicit default would flip to
        // macOS SecureTransport, which can't complete a handshake with some
        // of the APIs we rely on (api.aniskip.com).
        let http_client = reqwest::Client::builder()
            .user_agent("Anicat/5.0")
            .use_rustls_tls()
            .build()
            .unwrap_or_default();

        let anilist_client = crate::anilist::AniListClient::new(
            http_client.clone(),
            config.api.anilist_token.clone(),
        );
        if let Some(ref username) = config.api.anilist_username {
            anilist_client.set_username(Some(username.clone()));
        }

        let (scraper_python, scraper_script) = resolve_scraper_paths();
        let scraper_manager = crate::scraper::ScraperManager::new(
            http_client.clone(),
            scraper_python,
            scraper_script,
        );

        let discord = crate::discord::DiscordClient::new();
        if config.general.discord {
            discord.connect();
        }

        let app_state = Self {
            inner: Arc::new(AppStateInner {
                config: Arc::new(RwLock::new(config)),
                config_path: config_path.to_string_lossy().to_string(),
                db_path,
                anilist_client,
                http_client,
                scraper_manager: Arc::new(scraper_manager),
                cache: crate::cache::AniListCache::new(),
                current_playback: Arc::new(tokio::sync::Mutex::new(None)),
                discord,
                proxy_port: Arc::new(std::sync::Mutex::new(13370)),
                user_list_lock: Arc::new(tokio::sync::Mutex::new(())),
                last_progress_record: Arc::new(tokio::sync::Mutex::new(None)),
                preloaded_stream: Arc::new(tokio::sync::Mutex::new(None)),
                playback_generation: Arc::new(std::sync::atomic::AtomicU64::new(0)),
                torrent: Arc::new(crate::torrent::TorrentManager::new()),
            }),
        };

        app_state
    }

    fn load_config(path: &std::path::Path) -> AppConfig {
        let mut config: AppConfig = match std::fs::read_to_string(path) {
            Ok(contents) => toml::from_str(&contents).unwrap_or_default(),
            Err(_) => AppConfig::default(),
        };
        // allanime was renamed to mkissa (same allanime.day backend, new
        // anti-scrape crypto). Old dead providers collapse onto it too.
        if matches!(
            config.general.provider.as_str(),
            "gogoanime" | "anizone" | "animepahe" | "allanime"
        ) {
            config.general.provider = "mkissa".into();
        }
        if config.general.fallback_provider == "allanime" {
            config.general.fallback_provider = "mkissa".into();
        }
        config
    }

    pub async fn save_config(&self) -> Result<(), Box<dyn std::error::Error>> {
        let config = self.inner.config.read().await;
        let toml_str = toml::to_string_pretty(&*config)?;
        if let Some(parent) = std::path::Path::new(&self.inner.config_path).parent() {
            std::fs::create_dir_all(parent)?;
        }
        std::fs::write(&self.inner.config_path, toml_str)?;
        Ok(())
    }

    pub fn open_db(&self) -> Result<rusqlite::Connection, String> {
        rusqlite::Connection::open(&self.inner.db_path).map_err(|e| e.to_string())
    }
}

impl std::ops::Deref for AppState {
    type Target = AppStateInner;
    fn deref(&self) -> &Self::Target {
        &self.inner
    }
}

fn find_bundled_binary(exe_dir: &std::path::Path) -> Option<String> {
    let base_dir = if exe_dir.join("resources").exists() {
        exe_dir.join("resources")
    } else {
        exe_dir.to_path_buf()
    };
    let bin_name = if cfg!(target_os = "windows") {
        "anicat-scraper.exe"
    } else {
        "anicat-scraper"
    };
    // --onedir layout: scraper-bin/anicat-scraper/anicat-scraper
    let onedir_bin = base_dir.join("scraper-bin").join("anicat-scraper").join(bin_name);
    if onedir_bin.exists() {
        log::info!("[scraper] using bundled binary (onedir): {}", onedir_bin.display());
        return Some(onedir_bin.to_string_lossy().to_string());
    }
    // Legacy --onefile layout: scraper-bin/anicat-scraper
    let onefile_bin = base_dir.join("scraper-bin").join(bin_name);
    if onefile_bin.exists() {
        log::info!("[scraper] using bundled binary (onefile): {}", onefile_bin.display());
        return Some(onefile_bin.to_string_lossy().to_string());
    }
    None
}

fn resolve_scraper_paths() -> (String, String) {
    // Check env overrides first
    let env_python = std::env::var("ANICAT_SCRAPER_PYTHON").ok();
    let env_script = std::env::var("ANICAT_SCRAPER_SCRIPT").ok();

    if let (Some(py), Some(script)) = (env_python.as_ref(), env_script.as_ref()) {
        return (py.clone(), script.clone());
    }

    // Try to find bundled binary relative to the executable
    if let Ok(exe) = std::env::current_exe() {
        let exe_dir = exe.parent().unwrap_or(&exe).to_path_buf();

        // Check ../Resources (release bundle layout)
        if let Some(resource_dir) = exe_dir.parent()
            .and_then(|d| { let r = d.join("Resources"); if r.exists() { Some(r) } else { None } })
        {
            if let Some(bin_path) = find_bundled_binary(&resource_dir) {
                return (String::new(), bin_path);
            }
        }

        // Check alongside the exe (dev layout: target/debug/resources/...)
        #[cfg(not(debug_assertions))]
        if let Some(bin_path) = find_bundled_binary(&exe_dir) {
            return (String::new(), bin_path);
        }
    }

    // Dev fallback: use Python via uv
    let python_path = env_python.unwrap_or_else(|| {
        let candidates = [
            "uv",
            "/opt/homebrew/bin/uv",
            &format!("{}/.local/bin/uv", std::env::var("HOME").unwrap_or_default()),
            "python3", "python",
        ];
        for cmd in &candidates {
            if !cmd.is_empty() && std::process::Command::new(cmd).arg("--version")
                .stdout(std::process::Stdio::null())
                .stderr(std::process::Stdio::null())
                .status().is_ok() {
                return cmd.to_string();
            }
        }
        "python3".to_string()
    });

    let script_path = env_script.unwrap_or_else(|| {
        let manifest_dir = std::path::Path::new(env!("CARGO_MANIFEST_DIR"));
        let fallback = manifest_dir.join("..").join("..").join("scraper").join("main.py");
        log::warn!("[scraper] falling back to dev path: {:?}", fallback);
        fallback.to_string_lossy().to_string()
    });

    (python_path, script_path)
}
