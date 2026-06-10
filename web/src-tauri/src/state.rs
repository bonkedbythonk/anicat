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
}

#[derive(Debug, Clone, Serialize, Deserialize, Default)]
pub struct GeneralConfig {
    #[serde(default = "default_provider")]
    pub provider: String,
    #[serde(default = "default_true")]
    pub autoplay: bool,
    #[serde(default = "default_true")]
    pub autoskip: bool,
    #[serde(default = "default_true")]
    pub anime_preview: bool,
    #[serde(default = "default_title_language")]
    pub preferred_title_language: String,
    #[serde(default)]
    pub downloads_path: String,
}

#[derive(Debug, Clone, Serialize, Deserialize, Default)]
pub struct StreamConfig {
    #[serde(default = "default_player_type")]
    pub player_type: String,
    #[serde(default = "default_quality")]
    pub preferred_quality: String,
    #[serde(default = "default_false")]
    pub data_saver: bool,
}

#[derive(Debug, Clone, Serialize, Deserialize, Default)]
pub struct ApiConfig {
    #[serde(default)]
    pub anilist_token: Option<String>,
}

fn default_provider() -> String {
    "gogoanime".into()
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
fn default_player_type() -> String {
    "embedded".into()
}
fn default_quality() -> String {
    "1080p".into()
}

#[derive(Clone)]
pub struct AppState {
    pub inner: Arc<AppStateInner>,
}

#[derive(Clone)]
pub struct AppStateInner {
    pub config: Arc<RwLock<AppConfig>>,
    pub config_path: String,
    pub db_path: String,
    pub anilist_client: crate::anilist::AniListClient,
    pub http_client: reqwest::Client,
    pub scraper_manager: Arc<crate::scraper::ScraperManager>,
}

impl AppState {
    pub fn new() -> Self {
        let config_dir = dirs::config_dir()
            .unwrap_or_else(|| std::path::PathBuf::from("."))
            .join("anicat");
        let config_path = config_dir.join("config.toml");
        let config = Self::load_config(&config_path);

        let db_path = config_dir
            .join("registry.db")
            .to_string_lossy()
            .to_string();

        // Initialize database
        {
            let db_path = db_path.clone();
            std::thread::spawn(move || {
                if let Ok(conn) = rusqlite::Connection::open(&db_path) {
                    let _ = conn.execute_batch(
                        "CREATE TABLE IF NOT EXISTS media_records (
                            media_id INTEGER PRIMARY KEY,
                            provider_mapping TEXT NOT NULL DEFAULT '{}',
                            updated_at TEXT NOT NULL DEFAULT (datetime('now'))
                        );
                        CREATE TABLE IF NOT EXISTS watched_episodes (
                            media_id INTEGER NOT NULL,
                            episode_number INTEGER NOT NULL,
                            stop_time INTEGER NOT NULL DEFAULT 0,
                            duration INTEGER NOT NULL DEFAULT 0,
                            watched_at TEXT NOT NULL DEFAULT (datetime('now')),
                            PRIMARY KEY (media_id, episode_number)
                        );",
                    );
                }
            })
            .join()
            .ok();
        }

        let http_client = reqwest::Client::builder()
            .user_agent("Anicat/5.0")
            .build()
            .unwrap_or_default();

        let anilist_client = crate::anilist::AniListClient::new(
            http_client.clone(),
            config.api.anilist_token.clone(),
        );

        let scraper_python = std::env::var("ANICAT_SCRAPER_PYTHON")
            .unwrap_or_else(|_| "python3".to_string());
        let scraper_script = std::env::var("ANICAT_SCRAPER_SCRIPT")
            .unwrap_or_else(|_| {
                let exe = std::env::current_exe().unwrap_or_default();
                let exe_dir = exe.parent().unwrap_or(std::path::Path::new("."));
                exe_dir
                    .join("..")
                    .join("scraper")
                    .join("main.py")
                    .to_string_lossy()
                    .to_string()
            });
        let scraper_manager = crate::scraper::ScraperManager::new(
            http_client.clone(),
            scraper_python,
            scraper_script,
        );

        Self {
            inner: Arc::new(AppStateInner {
                config: Arc::new(RwLock::new(config)),
                config_path: config_path.to_string_lossy().to_string(),
                db_path,
                anilist_client,
                http_client,
                scraper_manager: Arc::new(scraper_manager),
            }),
        }
    }

    fn load_config(path: &std::path::Path) -> AppConfig {
        match std::fs::read_to_string(path) {
            Ok(contents) => toml::from_str(&contents).unwrap_or_default(),
            Err(_) => AppConfig::default(),
        }
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

// Implement Deref for convenience in command handlers
impl std::ops::Deref for AppState {
    type Target = AppStateInner;
    fn deref(&self) -> &Self::Target {
        &self.inner
    }
}
