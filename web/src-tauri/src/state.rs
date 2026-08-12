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
    #[serde(default = "default_secondary_fallback_provider")]
    pub secondary_fallback_provider: String,
    /// Switches the mobile-facing auth gate from the single shared PIN
    /// (`MobileConfig.pin`, `mobile_auth::require_mobile_auth`) to per-user
    /// login (`proxy::session::require_user_session`) once at least one
    /// friend account has been added via `anicat-server add-user`. Off by
    /// default so a desktop-only user who never adds anyone sees zero
    /// behavior change.
    #[serde(default = "default_false")]
    pub multi_user: bool,
}

#[derive(Debug, Clone, Serialize, Deserialize, Default)]
pub struct StreamConfig {
    #[serde(default = "default_false")]
    pub data_saver: bool,
    #[serde(default = "default_shader_profile")]
    pub shader_profile: String,
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
    "nyaa".into()
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
// nyaa + anineko are the only selectable sources, and they're already the
// primary/first-fallback defaults — nothing is left for a second fallback.
fn default_secondary_fallback_provider() -> String {
    "none".into()
}
fn default_shader_profile() -> String {
    "balanced".into()
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
    /// Preload targets with a resolve currently in flight. `preloaded_stream`
    /// is only filled once a resolve *finishes*, so on its own it can't stop
    /// two callers for the same episode — the detail page warming the Continue
    /// episode and the player's near-end `/player/preload` — from both passing
    /// the "already preloaded?" check and both scraping. For scraper providers
    /// that's duplicated work; on nyaa it's worse, since a second
    /// `add_torrent` + `update_only_files` against the same swarm churns the
    /// piece selection out from under the episode currently streaming (see the
    /// `update_only_files` comment in `torrent/mod.rs`).
    ///
    /// A `std::sync` mutex on purpose: the set is tiny, never held across an
    /// await, and `PreloadGuard`'s `Drop` has to release the claim
    /// synchronously.
    pub preloading: Arc<std::sync::Mutex<std::collections::HashSet<PreloadKey>>>,
    /// Incremented on every start_playback. Background tasks (notably the
    /// AniSkip resolver, which keeps retrying IPC for a few seconds) capture
    /// the value at spawn and bail if it no longer matches — otherwise a task
    /// from the previous episode clobbers the current episode's script-opts
    /// (current_episode, skip_times), breaking next/prev and AniSkip.
    pub playback_generation: Arc<std::sync::atomic::AtomicU64>,
    /// Embedded torrent engine for the "nyaa" provider. Lazy: no torrent
    /// session (DHT, listeners) exists until the first torrent playback.
    pub torrent: Arc<crate::torrent::TorrentManager>,
    /// Per-user AniList client/cache, lazily populated the first time
    /// `AppState::scoped_for_user` sees a given `user_id`. Never touched for
    /// `user_id == 0` (the desktop/single-user sentinel) — that path returns
    /// the real global fields above directly instead of an entry here, since
    /// user 0 isn't a distinct account, it's the existing single-tenant app.
    pub user_anilist: Arc<tokio::sync::Mutex<std::collections::HashMap<i64, Arc<UserAniList>>>>,
    /// Per-user playback session state, same lazy/sentinel-exempt rules as
    /// `user_anilist` above. Exists so two friends watching different shows
    /// concurrently don't clobber each other's resume position or "now
    /// playing" state the way a single shared `current_playback` would.
    pub user_playback: Arc<tokio::sync::Mutex<std::collections::HashMap<i64, Arc<UserPlaybackState>>>>,
}

/// A registered friend's own AniList session — isolated from the desktop
/// owner's `anilist_client`/`cache` and from every other registered user's,
/// so one person's list/cache data can never leak into another's response.
pub struct UserAniList {
    pub client: crate::anilist::AniListClient,
    pub cache: crate::cache::AniListCache,
}

/// Mirrors the playback-session fields on `AppStateInner` (`current_playback`,
/// `preloaded_stream`, `playback_generation`, `last_progress_record`), scoped
/// to one registered user instead of being process-global.
pub struct UserPlaybackState {
    pub current_playback: Arc<tokio::sync::Mutex<Option<CurrentPlayback>>>,
    pub preloaded_stream: Arc<tokio::sync::Mutex<Option<PreloadedStream>>>,
    pub preloading: Arc<std::sync::Mutex<std::collections::HashSet<PreloadKey>>>,
    pub playback_generation: Arc<std::sync::atomic::AtomicU64>,
    pub last_progress_record: Arc<tokio::sync::Mutex<Option<(i64, i64, std::time::Instant)>>>,
}

impl UserPlaybackState {
    fn new() -> Self {
        Self {
            current_playback: Arc::new(tokio::sync::Mutex::new(None)),
            preloaded_stream: Arc::new(tokio::sync::Mutex::new(None)),
            preloading: Arc::new(std::sync::Mutex::new(std::collections::HashSet::new())),
            playback_generation: Arc::new(std::sync::atomic::AtomicU64::new(0)),
            last_progress_record: Arc::new(tokio::sync::Mutex::new(None)),
        }
    }
}

/// What identifies one preload target: the episode *and* the provider, since
/// the same episode resolved through two providers is two different streams.
pub type PreloadKey = (i64, i64, String);

/// Releases a preload claim taken by [`AppState::claim_preload`] when the
/// resolve that took it finishes, however it finishes — completion, an error
/// return, or the task being dropped.
pub struct PreloadGuard {
    set: Arc<std::sync::Mutex<std::collections::HashSet<PreloadKey>>>,
    key: PreloadKey,
}

impl Drop for PreloadGuard {
    fn drop(&mut self) {
        self.set
            .lock()
            .unwrap_or_else(|e| e.into_inner())
            .remove(&self.key);
    }
}

/// What will actually play the stream being resolved.
///
/// It decides which releases are acceptable, not just how the URL is handed
/// back: mpv decodes anything, while a browser `<video>` element cannot touch
/// HEVC, AV1 or 10-bit H.264 — all common in Nyaa releases. Every resolve path
/// carries this so release scoring, the torrent resolution cache and the
/// preload slot all agree on who the stream is for.
///
/// Derived from the call site rather than sent by the client: `/mobile-api/*`
/// is only ever reachable from the PWA, and the Tauri commands only ever from
/// the desktop window, so neither can misreport it.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum StreamClient {
    Mpv,
    Browser,
}

impl StreamClient {
    pub fn is_browser(self) -> bool {
        self == StreamClient::Browser
    }
}

#[derive(Debug, Clone)]
pub struct PreloadedStream {
    pub media_id: i64,
    pub episode_number: i64,
    pub provider: String,
    /// A stream preloaded for mpv may be a release the phone cannot decode
    /// (and vice versa for nothing, since mpv accepts everything). The slot is
    /// keyed by media/episode/provider only, so consumers must also match on
    /// this or a desktop preload gets handed to the PWA.
    pub client: StreamClient,
    pub raw_url: String,
    pub headers: Option<std::collections::HashMap<String, String>>,
    pub subtitle_url: Option<String>,
    pub at: std::time::Instant,
}

impl Default for AppState {
    fn default() -> Self {
        Self::new()
    }
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
        //
        // Deliberately NO client-level `.timeout()` here: this client is also
        // ProxyState's client, which streams full video/HLS bodies to mpv and
        // the phone over `/proxy` — reqwest's client timeout bounds the whole
        // request including body transfer, so it would cut off any stream
        // that legitimately runs longer than the timeout (i.e. most
        // episodes). AniListClient, which has the actual hang problem, gets
        // its own bounded timeout instead — see anilist/client.rs.
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
                preloading: Arc::new(std::sync::Mutex::new(std::collections::HashSet::new())),
                playback_generation: Arc::new(std::sync::atomic::AtomicU64::new(0)),
                torrent: Arc::new(crate::torrent::TorrentManager::new()),
                user_anilist: Arc::new(tokio::sync::Mutex::new(std::collections::HashMap::new())),
                user_playback: Arc::new(tokio::sync::Mutex::new(std::collections::HashMap::new())),
            }),
        };

        app_state
    }

    fn load_config(path: &std::path::Path) -> AppConfig {
        let mut config: AppConfig = match std::fs::read_to_string(path) {
            Ok(contents) => toml::from_str(&contents).unwrap_or_else(|e| {
                log::error!(
                    "Config at {:?} failed to parse, falling back to defaults (settings reset): {}",
                    path, e
                );
                AppConfig::default()
            }),
            Err(e) if e.kind() == std::io::ErrorKind::NotFound => AppConfig::default(),
            Err(e) => {
                log::error!(
                    "Failed to read config at {:?}, falling back to defaults (settings reset): {}",
                    path, e
                );
                AppConfig::default()
            }
        };
        // Providers that no longer exist as a selectable option collapse onto
        // anineko. mkissa (formerly allanime) is retired from the UI but its
        // scraper is kept in-tree, so a config left pointing at it would
        // otherwise select a source the user can no longer see or change.
        const RETIRED_PROVIDERS: &[&str] =
            &["gogoanime", "anizone", "animepahe", "allanime", "mkissa"];
        if RETIRED_PROVIDERS.contains(&config.general.provider.as_str()) {
            config.general.provider = "anineko".into();
        }
        if RETIRED_PROVIDERS.contains(&config.general.fallback_provider.as_str()) {
            // Someone whose primary *and* fallback were both the retired
            // provider would otherwise end up with anineko twice — deduped
            // down to a single source, leaving them no fallback at all.
            config.general.fallback_provider = if config.general.provider == "anineko" {
                "nyaa".into()
            } else {
                "anineko".into()
            };
        }
        if RETIRED_PROVIDERS.contains(&config.general.secondary_fallback_provider.as_str()) {
            config.general.secondary_fallback_provider = "none".into();
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

    /// Claims `(media_id, episode_number, provider)` as a preload target,
    /// returning a guard that releases the claim on drop. `None` means another
    /// resolve for the exact same target is already in flight and this caller
    /// should do nothing — see `AppStateInner::preloading` for why the
    /// `preloaded_stream` slot alone can't catch that.
    pub fn claim_preload(
        &self,
        media_id: i64,
        episode_number: i64,
        provider: &str,
    ) -> Option<PreloadGuard> {
        let key: PreloadKey = (media_id, episode_number, provider.to_string());
        let mut set = self
            .inner
            .preloading
            .lock()
            .unwrap_or_else(|e| e.into_inner());
        if !set.insert(key.clone()) {
            return None;
        }
        Some(PreloadGuard {
            set: self.inner.preloading.clone(),
            key,
        })
    }

    /// Is a preload for this exact target still resolving?
    ///
    /// Lets `start_playback` wait for work already in progress instead of
    /// racing it. The two used to duplicate each other whenever auto-next
    /// arrived before the near-end preload had finished — same episode
    /// resolved twice, and on nyaa that means two `add_torrent` +
    /// `update_only_files` rounds against one live torrent.
    pub fn preload_in_flight(&self, media_id: i64, episode_number: i64, provider: &str) -> bool {
        self.inner
            .preloading
            .lock()
            .unwrap_or_else(|e| e.into_inner())
            .contains(&(media_id, episode_number, provider.to_string()))
    }

    pub fn open_db(&self) -> Result<rusqlite::Connection, String> {
        rusqlite::Connection::open(&self.inner.db_path).map_err(|e| {
            log::error!("Failed to open registry DB at {:?}: {}", self.inner.db_path, e);
            e.to_string()
        })
    }

    /// Returns an `AppState` scoped to `user_id`'s own AniList session and
    /// playback state, so every existing `_impl` command function keeps
    /// reading `state.anilist_client`/`state.cache`/`state.current_playback`
    /// exactly as written — only the caller (mobile-api) needs to know about
    /// users at all.
    ///
    /// `user_id == 0` is the desktop/single-user sentinel: it returns a
    /// clone of `self` unchanged, sharing the real global AniList
    /// client/cache/playback state (and thus staying in sync with the
    /// desktop app's own session) rather than fabricating an isolated "user
    /// 0" — there's no second identity to isolate from in single-user mode.
    /// Every other `user_id` gets its own lazily-created, fully isolated
    /// `UserAniList`/`UserPlaybackState`, refreshing the cached AniList
    /// token/username if the caller passed a newer one (handles "just
    /// connected/reconnected AniList" without a restart) and — since a
    /// second identity now genuinely exists — a fresh, never-`.connect()`ed
    /// `DiscordClient`, which is a correct, code-free way to disable rich
    /// presence for multi-user viewers (there's no sensible single "now
    /// playing" presence with N concurrent people, and no Discord IPC socket
    /// to reach on a headless Pi regardless).
    pub async fn scoped_for_user(
        &self,
        user_id: i64,
        anilist_token: Option<String>,
        anilist_username: Option<String>,
    ) -> AppState {
        if user_id == 0 {
            return self.clone();
        }

        let user_anilist = {
            let mut map = self.inner.user_anilist.lock().await;
            let entry = map.entry(user_id).or_insert_with(|| {
                let client = crate::anilist::AniListClient::new(self.inner.http_client.clone(), anilist_token.clone());
                if let Some(ref name) = anilist_username {
                    client.set_username(Some(name.clone()));
                }
                Arc::new(UserAniList { client, cache: crate::cache::AniListCache::new() })
            });
            if anilist_token.is_some() && anilist_token != entry.client.get_token() {
                entry.client.set_token(anilist_token.clone());
                entry.client.set_username(anilist_username.clone());
            }
            entry.clone()
        };

        let user_playback = {
            let mut map = self.inner.user_playback.lock().await;
            map.entry(user_id).or_insert_with(|| Arc::new(UserPlaybackState::new())).clone()
        };

        AppState {
            inner: Arc::new(AppStateInner {
                anilist_client: user_anilist.client.clone(),
                cache: user_anilist.cache.clone(),
                current_playback: user_playback.current_playback.clone(),
                preloaded_stream: user_playback.preloaded_stream.clone(),
                preloading: user_playback.preloading.clone(),
                playback_generation: user_playback.playback_generation.clone(),
                last_progress_record: user_playback.last_progress_record.clone(),
                discord: crate::discord::DiscordClient::new(),
                ..(*self.inner).clone()
            }),
        }
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

#[cfg(test)]
mod tests {
    use super::*;

    /// Builds a bare-bones `AppState` with no filesystem/network side
    /// effects — deliberately not `AppState::new()`, which reads/writes the
    /// real user's config.toml and probes for a scraper interpreter on disk;
    /// none of that is relevant to testing `scoped_for_user`'s isolation.
    fn bare_app_state() -> AppState {
        let http_client = reqwest::Client::new();
        AppState {
            inner: Arc::new(AppStateInner {
                config: Arc::new(RwLock::new(AppConfig::default())),
                config_path: String::new(),
                db_path: ":memory:".to_string(),
                anilist_client: crate::anilist::AniListClient::new(http_client.clone(), None),
                http_client,
                scraper_manager: Arc::new(crate::scraper::ScraperManager::new(reqwest::Client::new(), String::new(), String::new())),
                cache: crate::cache::AniListCache::new(),
                current_playback: Arc::new(tokio::sync::Mutex::new(None)),
                discord: crate::discord::DiscordClient::new(),
                proxy_port: Arc::new(std::sync::Mutex::new(0)),
                user_list_lock: Arc::new(tokio::sync::Mutex::new(())),
                last_progress_record: Arc::new(tokio::sync::Mutex::new(None)),
                preloaded_stream: Arc::new(tokio::sync::Mutex::new(None)),
                preloading: Arc::new(std::sync::Mutex::new(std::collections::HashSet::new())),
                playback_generation: Arc::new(std::sync::atomic::AtomicU64::new(0)),
                torrent: Arc::new(crate::torrent::TorrentManager::new()),
                user_anilist: Arc::new(tokio::sync::Mutex::new(std::collections::HashMap::new())),
                user_playback: Arc::new(tokio::sync::Mutex::new(std::collections::HashMap::new())),
            }),
        }
    }

    #[tokio::test]
    async fn user_id_zero_returns_the_same_global_state() {
        let global = bare_app_state();
        let scoped = global.scoped_for_user(0, None, None).await;
        // Same underlying playback mutex, not just equal values — proves 0
        // shares identity with the real global state rather than getting an
        // isolated (if empty) copy of its own.
        assert!(Arc::ptr_eq(&global.inner.current_playback, &scoped.inner.current_playback));
    }

    #[tokio::test]
    async fn distinct_users_get_isolated_playback_state() {
        let global = bare_app_state();
        let alice = global.scoped_for_user(1, None, None).await;
        let bob = global.scoped_for_user(2, None, None).await;

        assert!(!Arc::ptr_eq(&alice.inner.current_playback, &bob.inner.current_playback));
        assert!(!Arc::ptr_eq(&alice.inner.current_playback, &global.inner.current_playback));

        *alice.inner.current_playback.lock().await = Some(CurrentPlayback {
            media_id: 111, episode_number: 1, provider: "anineko".into(), title: "Alice's show".into(),
            episode_title: String::new(), cover_image: String::new(), total_episodes: 12,
            last_position: 42, last_duration: 1200, paused: false,
        });
        // Bob's slot, and the real global slot, must both still be empty —
        // this is the exact bug class (two friends' "now playing" colliding
        // on one shared field) the whole per-user scoping design exists to
        // prevent.
        assert!(bob.inner.current_playback.lock().await.is_none());
        assert!(global.inner.current_playback.lock().await.is_none());
    }

    #[tokio::test]
    async fn calling_scoped_for_user_twice_reuses_the_same_entry() {
        let global = bare_app_state();
        let first = global.scoped_for_user(7, None, None).await;
        *first.inner.current_playback.lock().await = Some(CurrentPlayback {
            media_id: 5, episode_number: 3, provider: "anineko".into(), title: "x".into(),
            episode_title: String::new(), cover_image: String::new(), total_episodes: 0,
            last_position: 99, last_duration: 100, paused: false,
        });
        let second = global.scoped_for_user(7, None, None).await;
        // Second call for the same user_id must land on the same session —
        // not a fresh empty one — so progress reported by an earlier
        // request in the same login is still there for a later one.
        let pb = second.inner.current_playback.lock().await;
        assert_eq!(pb.as_ref().map(|p| p.last_position), Some(99));
    }

    #[test]
    fn a_second_claim_on_the_same_target_is_refused_until_the_first_is_dropped() {
        let state = bare_app_state();
        let first = state.claim_preload(42, 7, "anineko");
        assert!(first.is_some());
        // This is the case the whole mechanism exists for: the detail page and
        // the player's near-end /player/preload both firing for one episode.
        // preloaded_stream can't catch it, because it stays empty until the
        // first resolve *finishes*.
        assert!(state.claim_preload(42, 7, "anineko").is_none());

        drop(first);
        assert!(
            state.claim_preload(42, 7, "anineko").is_some(),
            "dropping the guard must release the claim, or one failed resolve blocks the target forever"
        );
    }

    #[test]
    fn claims_are_scoped_to_episode_and_provider() {
        let state = bare_app_state();
        let _held = state.claim_preload(42, 7, "anineko");
        // Same show, next episode: a different stream to resolve.
        assert!(state.claim_preload(42, 8, "anineko").is_some());
        // Same episode via another provider: also a different stream, and
        // start_playback only consumes a preload whose provider matches.
        assert!(state.claim_preload(42, 7, "nyaa").is_some());
    }

    #[tokio::test]
    async fn distinct_users_get_isolated_preload_claims() {
        let global = bare_app_state();
        let alice = global.scoped_for_user(1, None, None).await;
        let bob = global.scoped_for_user(2, None, None).await;

        let _alice_claim = alice.claim_preload(42, 7, "anineko");
        // Two friends starting the same episode are resolving into two
        // separate preloaded_stream slots, so one must not suppress the
        // other's resolve and leave their slot empty.
        assert!(bob.claim_preload(42, 7, "anineko").is_some());
        assert!(alice.claim_preload(42, 7, "anineko").is_none());
    }

    #[tokio::test]
    async fn distinct_users_get_isolated_anilist_clients() {
        let global = bare_app_state();
        let alice = global.scoped_for_user(1, Some("alice-token".to_string()), Some("alice".to_string())).await;
        let bob = global.scoped_for_user(2, Some("bob-token".to_string()), Some("bob".to_string())).await;

        assert_eq!(alice.inner.anilist_client.get_username(), Some("alice".to_string()));
        assert_eq!(bob.inner.anilist_client.get_username(), Some("bob".to_string()));
        assert_eq!(global.inner.anilist_client.get_username(), None);
    }
}
