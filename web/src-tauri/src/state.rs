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
    #[serde(default = "default_novel_provider")]
    pub novel_provider: String,
    #[serde(default = "default_ereader_profile")]
    pub ereader_profile: String,
    #[serde(default = "default_ereader_width")]
    pub ereader_width: u32,
    #[serde(default = "default_ereader_height")]
    pub ereader_height: u32,
    #[serde(default = "default_true")]
    pub ereader_grayscale: bool,
    #[serde(default = "default_ereader_quality")]
    pub ereader_quality: u32,
    #[serde(default = "default_true")]
    pub ereader_split_spreads: bool,
}

#[derive(Debug, Clone, Serialize, Deserialize, Default)]
pub struct StreamConfig {
    #[serde(default = "default_false")]
    pub data_saver: bool,
    #[serde(default = "default_shader_profile")]
    pub shader_profile: String,
    #[serde(default = "default_translation_type")]
    pub translation_type: String,
    /// Ceiling on how fast a torrent may download, in megabytes per second.
    /// Zero means no ceiling, which is what this always did.
    ///
    /// Exists because a swarm pulling at 50 MB/s with sixty half-open peer
    /// connections is a very different load on a laptop's radio than the
    /// steady single stream every other provider produces, and Bluetooth
    /// headphones share that radio. 1080p needs about 1 MB/s sustained, so
    /// even a low ceiling here leaves several times the headroom playback
    /// actually uses — it costs only how quickly the rest of the episode
    /// arrives behind you.
    ///
    /// Read once, when the torrent session is created, so a change takes
    /// effect on the next launch.
    #[serde(default = "default_torrent_download_limit")]
    pub torrent_download_limit_mbps: u32,
}

/// Unlimited, matching the behaviour before the setting existed.
fn default_torrent_download_limit() -> u32 {
    0
}

#[derive(Debug, Clone, Serialize, Deserialize, Default)]
pub struct ApiConfig {
    #[serde(default)]
    pub anilist_token: Option<String>,
    #[serde(default)]
    pub anilist_username: Option<String>,
    /// TMDB read access token, for cinema mode's catalog. Absent until the
    /// user pastes one in; cinema mode has no metadata without it.
    #[serde(default)]
    pub tmdb_token: Option<String>,
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
fn default_novel_provider() -> String {
    "ranobedb".into()
}
fn default_ereader_profile() -> String {
    "xteink_x3".into()
}
fn default_ereader_width() -> u32 {
    528
}
fn default_ereader_height() -> u32 {
    792
}
fn default_ereader_quality() -> u32 {
    85
}
fn default_shader_profile() -> String {
    "on".into()
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
    /// Cinema mode's catalog. The TMDB token identifies the app, not a person.
    pub tmdb_client: crate::tmdb::TmdbClient,
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
    /// One stream resolved ahead of time so the play that wants it is instant
    /// instead of waiting on a resolve. Three callers fill it — the player's
    /// near-end warm-up of episode+1, the detail page's Continue episode, and
    /// the episode list's hover/focus guess — and it holds exactly one of them,
    /// because a second held preload is a second file selected inside the same
    /// torrent on top of the one playing, which is one more than
    /// `SELECTED_FILES_KEPT` allows (see `torrent::retain_recent`).
    ///
    /// Every write therefore goes through [`preload_write_decision`], which
    /// keeps a hover from displacing an episode the user is about to play and
    /// names whatever does leave the slot so the caller can correct the
    /// webview's own per-episode map.
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
    /// `(media_id, episode)` mpv has actually opened, reported by the Lua
    /// script's own `file-loaded` handler.
    ///
    /// `current_playback` is written optimistically the moment the `loadfile`
    /// IPC batch is *sent*, which is the only way the callbacks for the new
    /// episode can find the right episode to report against. But a successful
    /// send only means the bytes reached the socket: if mpv then fails to open
    /// the stream, nothing walked that back, so the next press advanced from an
    /// episode that never played and skipped it silently. This is the other
    /// half — the confirmation that the file really opened — and its *absence*
    /// is what a failed transition looks like.
    pub confirmed_playing: Arc<tokio::sync::Mutex<Option<(i64, i64)>>>,
    /// Embedded torrent engine for the "nyaa" provider. Lazy: no torrent
    /// session (DHT, listeners) exists until the first torrent playback.
    pub torrent: Arc<crate::torrent::TorrentManager>,
    /// Remuxes a torrent release into HLS for the desktop builtin `<video>`
    /// player, which (like every WebKit-based browser) cannot open Matroska.
    /// Idle until that player picks a torrent release; see `crate::proxy::remux`.
    pub remux: Arc<crate::proxy::remux::RemuxManager>,
    /// Slug resolves currently in flight, keyed by (media_id, provider).
    /// Exists because two independent callers -- e.g. the detail page's
    /// episode-list query and a
    /// playback resolve landing at the same time -- can both find no cached
    /// slug and both kick off the same scraper search: observed live as two
    /// identical "searching '<title>' on 'anineko'" log lines a millisecond
    /// apart. `std::sync` mutex for the same reason as `preloading`: tiny,
    /// never held across an await.
    pub slug_resolving: Arc<std::sync::Mutex<std::collections::HashSet<SlugResolveKey>>>,
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

/// What identifies one slug resolve: the media and the provider being
/// searched. Not episode-scoped -- unlike a preload, the slug this resolves is
/// the same regardless of which episode asked for it.
pub type SlugResolveKey = (i64, String);

/// Releases a slug-resolve claim taken by [`AppState::claim_slug_resolve`]
/// when the resolve finishes, however it finishes.
pub struct SlugResolveGuard {
    set: Arc<std::sync::Mutex<std::collections::HashSet<SlugResolveKey>>>,
    key: SlugResolveKey,
}

impl Drop for SlugResolveGuard {
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

/// How much a preload is worth keeping when two of them want the one slot.
///
/// `Primary` is a preload the user's next action is *expected* to consume: the
/// detail page warming the Continue episode, and the player's near-end warming
/// of episode+1. `Speculative` is a guess made from a hover or a keyboard
/// focus resting on a row.
///
/// Ordered, because that ordering is the whole rule: hovering episode 7 for
/// 400ms used to overwrite an already-resolved Continue preload, so pressing
/// Continue right after went cold — the exact case the Continue preload
/// exists to prevent.
#[derive(Debug, Clone, Copy, PartialEq, Eq, PartialOrd, Ord)]
pub enum PreloadPriority {
    Speculative,
    Primary,
}

/// Who a preload is being resolved for: which player will consume it, and how
/// much it is worth keeping. One struct rather than two parameters because
/// `preload_episode_impl` is already at the `too_many_arguments` limit.
#[derive(Debug, Clone, Copy)]
pub struct PreloadOrigin {
    pub client: StreamClient,
    pub priority: PreloadPriority,
}

/// How long a `Primary` entry is protected from being evicted by a
/// `Speculative` one.
///
/// Matches the mpv read path's own `PRELOAD_MAX_AGE` (3 minutes, in
/// `commands/playback.rs`) on purpose but deliberately does not share the
/// constant: past that age `start_playback` discards the entry anyway, so
/// protecting it any longer would trade a usable speculative stream for one
/// nothing can consume. The browser read path allows an entry ten times older
/// (30 minutes), so this window is the stricter of the two — every preload
/// written today is `StreamClient::Mpv`, and a `Browser` entry between the two
/// windows would lose the slot to a hover, reported rather than dropped
/// silently.
pub const PRIMARY_PRELOAD_PROTECTION: std::time::Duration = std::time::Duration::from_secs(3 * 60);

/// What a writer should do with the one preload slot, and what the frontend
/// has to be told as a result.
///
/// The slot is a single `Option`, so every write is either a refusal or an
/// eviction — and both used to be silent. The webview keeps its own
/// per-episode `preloadStatus` map fed by `stream_preload_status` events, so a
/// silent overwrite left it reporting "ready" for an episode the backend no
/// longer held, and its own guard then refused to re-preload an episode that
/// was actually cold. Returning the evicted key forces the caller to emit the
/// correction.
#[derive(Debug, PartialEq, Eq)]
pub enum PreloadWrite {
    /// Store the new entry. `evicted` is the `(media_id, episode_number)` that
    /// leaves the slot, if any.
    Store { evicted: Option<(i64, i64)> },
    /// Leave the slot alone: what is in it is worth more than the incoming
    /// entry. The caller still has to report its own target as no longer held.
    Refused,
}

/// Decides a write against the current occupant of the preload slot.
///
/// Pure so the rule can be tested without a resolve, an `AppHandle` or a
/// runtime: what broke was not the resolving, it was what the slot did with
/// two results.
pub fn preload_write_decision(
    occupant: Option<&PreloadedStream>,
    incoming: PreloadPriority,
) -> PreloadWrite {
    match occupant {
        Some(held)
            if incoming < held.priority && held.at.elapsed() < PRIMARY_PRELOAD_PROTECTION =>
        {
            PreloadWrite::Refused
        }
        Some(held) => PreloadWrite::Store {
            evicted: Some((held.media_id, held.episode_number)),
        },
        None => PreloadWrite::Store { evicted: None },
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
    /// "sub" or "dub" at resolve time. A preload started before a mid-playback
    /// sub/dub toggle is keyed the same as one started after — same media,
    /// episode, provider, client — so without this a toggle's restart could
    /// silently reuse the stale-translation stream instead of re-resolving.
    pub translation_type: String,
    /// Whether losing the slot to a competing preload is acceptable; see
    /// [`preload_write_decision`].
    pub priority: PreloadPriority,
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

        let tmdb_client =
            crate::tmdb::TmdbClient::new(http_client.clone(), config.api.tmdb_token.clone());

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

        let torrent = Arc::new(crate::torrent::TorrentManager::new());
        // Before anything can create the session, which reads it once.
        torrent.set_download_limit_mbps(config.stream.torrent_download_limit_mbps);

        let app_state = Self {
            inner: Arc::new(AppStateInner {
                config: Arc::new(RwLock::new(config)),
                config_path: config_path.to_string_lossy().to_string(),
                db_path,
                anilist_client,
                tmdb_client,
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
                confirmed_playing: Arc::new(tokio::sync::Mutex::new(None)),
                torrent: torrent.clone(),
                remux: Arc::new(crate::proxy::remux::RemuxManager::new()),
                slug_resolving: Arc::new(std::sync::Mutex::new(std::collections::HashSet::new())),
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
        // nyaa. Every name that was ever selectable has to stay in this
        // list even once its code is gone -- mkissa's was deleted outright and
        // it is still here, because the list's job is to recognise what an old
        // `config.toml` might say, not what the binary can still do. Dropping a
        // name strands whoever still has it stored.
        const RETIRED_PROVIDERS: &[&str] =
            &["gogoanime", "anizone", "animepahe", "allanime", "mkissa", "anineko"];
        if RETIRED_PROVIDERS.contains(&config.general.provider.as_str()) {
            config.general.provider = "nyaa".into();
        }
        // `shader_profile` is "on" | "off". Everything that decides whether to
        // actually load the shaders asks `!= "off"`, so the older "balanced"
        // spelling this used to default to still upscales correctly -- but the
        // handful of readers that compare for equality (onboarding's GPU
        // toggle) match neither value and show the wrong state until something
        // rewrites the setting. Normalize on load rather than teaching every
        // reader a third spelling.
        if config.stream.shader_profile != "off" && config.stream.shader_profile != "on" {
            config.stream.shader_profile = "on".into();
        }
        config
    }

    pub async fn save_config(&self) -> Result<(), Box<dyn std::error::Error>> {
        let config = self.inner.config.read().await;
        // Takes effect for a session not yet created; an already-running one
        // keeps the ceiling it was built with until the next launch.
        self.inner
            .torrent
            .set_download_limit_mbps(config.stream.torrent_download_limit_mbps);
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

    /// Claims `(media_id, provider)` as a slug resolve in progress, returning a
    /// guard that releases the claim on drop. `None` means another resolve for
    /// the exact same media+provider is already running and this caller should
    /// wait on [`AppState::slug_resolve_in_flight`] instead of searching again.
    pub fn claim_slug_resolve(&self, media_id: i64, provider: &str) -> Option<SlugResolveGuard> {
        let key: SlugResolveKey = (media_id, provider.to_string());
        let mut set = self
            .inner
            .slug_resolving
            .lock()
            .unwrap_or_else(|e| e.into_inner());
        if !set.insert(key.clone()) {
            return None;
        }
        Some(SlugResolveGuard {
            set: self.inner.slug_resolving.clone(),
            key,
        })
    }

    /// Is a slug resolve for this exact media+provider still running?
    pub fn slug_resolve_in_flight(&self, media_id: i64, provider: &str) -> bool {
        self.inner
            .slug_resolving
            .lock()
            .unwrap_or_else(|e| e.into_inner())
            .contains(&(media_id, provider.to_string()))
    }

    pub fn open_db(&self) -> Result<rusqlite::Connection, String> {
        rusqlite::Connection::open(&self.inner.db_path).map_err(|e| {
            log::error!("Failed to open registry DB at {:?}: {}", self.inner.db_path, e);
            e.to_string()
        })
    }

}

/// Which providers are worth warming in the scraper sidecar at startup: the
/// configured anime provider and the manga provider.
/// `ScraperManager::prewarm` drops the ones the sidecar doesn't implement
/// (`nyaa`, `none`) and de-duplicates, so the anime entry costs nothing while
/// nyaa is the only anime source.
pub async fn scraper_providers_to_warm(state: &AppState) -> Vec<String> {
    let config = state.config.read().await;
    vec![config.general.provider.clone(), config.general.manga_provider.clone()]
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
    /// none of that is relevant to the preload-claim tests below.
    fn bare_app_state() -> AppState {
        let http_client = reqwest::Client::new();
        AppState {
            inner: Arc::new(AppStateInner {
                config: Arc::new(RwLock::new(AppConfig::default())),
                config_path: String::new(),
                db_path: ":memory:".to_string(),
                anilist_client: crate::anilist::AniListClient::new(http_client.clone(), None),
                tmdb_client: crate::tmdb::TmdbClient::new(http_client.clone(), None),
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
                confirmed_playing: Arc::new(tokio::sync::Mutex::new(None)),
                torrent: Arc::new(crate::torrent::TorrentManager::new()),
                remux: Arc::new(crate::proxy::remux::RemuxManager::new()),
                slug_resolving: Arc::new(std::sync::Mutex::new(std::collections::HashSet::new())),
            }),
        }
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

    /// `start_playback` now takes the same claim a preload does, for as long
    /// as it owns the target. That is what makes a second press for the same
    /// episode wait on the first resolve instead of starting a competing
    /// `add_torrent` round against the torrent the player is already reading.
    #[test]
    fn a_start_holding_the_claim_is_visible_to_the_wait_that_looks_for_it() {
        let state = AppState::new();
        let held = state.claim_preload(42, 7, "nyaa");
        assert!(held.is_some(), "the first start claims the target");
        assert!(
            state.preload_in_flight(42, 7, "nyaa"),
            "a second start must see it and wait rather than race it"
        );
        // A preload for the very episode a start already owns is redundant by
        // definition, and is refused for the same reason.
        assert!(state.claim_preload(42, 7, "nyaa").is_none());
        drop(held);
        assert!(!state.preload_in_flight(42, 7, "nyaa"));
        assert!(state.claim_preload(42, 7, "nyaa").is_some());
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

    /// One entry in the slot, aged `age` and worth `priority`.
    fn held(
        episode_number: i64,
        priority: PreloadPriority,
        age: std::time::Duration,
    ) -> PreloadedStream {
        PreloadedStream {
            media_id: 42,
            episode_number,
            provider: "nyaa".into(),
            client: StreamClient::Mpv,
            translation_type: "sub".into(),
            priority,
            raw_url: "http://127.0.0.1:13370/torrent-stream?t=1&f=0".into(),
            headers: None,
            subtitle_url: None,
            at: std::time::Instant::now()
                .checked_sub(age)
                .expect("an Instant that far back exists on every supported platform"),
        }
    }

    const FRESH: std::time::Duration = std::time::Duration::from_secs(1);

    #[test]
    fn a_hover_guess_does_not_displace_the_episode_the_user_is_about_to_play() {
        // The regression this exists for: the detail page warms the Continue
        // episode on open, then a 400ms hover on episode 7 resolved and wrote
        // straight over it, so pressing Continue immediately afterwards ran a
        // full cold resolve -- the exact thing the Continue preload prevents.
        let occupant = held(3, PreloadPriority::Primary, FRESH);
        assert_eq!(
            preload_write_decision(Some(&occupant), PreloadPriority::Speculative),
            PreloadWrite::Refused
        );
    }

    #[test]
    fn every_displacement_names_what_left_the_slot() {
        // The webview's per-episode preloadStatus map is fed only by
        // stream_preload_status events. A displacement that reported nothing
        // left it calling episode 7 "ready" after episode 3 had taken the slot,
        // and its own guard then refused to re-preload 7 -- a stuck wrong
        // state, not just a missed preload. Every write that displaces has to
        // hand the caller the key to correct.
        let speculative = held(7, PreloadPriority::Speculative, FRESH);
        assert_eq!(
            preload_write_decision(Some(&speculative), PreloadPriority::Primary),
            PreloadWrite::Store { evicted: Some((42, 7)) }
        );
        // Two preloads of equal worth: the newer one wins, and the older is
        // still reported.
        let primary = held(3, PreloadPriority::Primary, FRESH);
        assert_eq!(
            preload_write_decision(Some(&primary), PreloadPriority::Primary),
            PreloadWrite::Store { evicted: Some((42, 3)) }
        );
        // As does a speculative write over a speculative occupant: walking down
        // the episode list must not leave the row it started on marked ready.
        assert_eq!(
            preload_write_decision(Some(&speculative), PreloadPriority::Speculative),
            PreloadWrite::Store { evicted: Some((42, 7)) }
        );
    }

    #[test]
    fn an_empty_slot_takes_the_write_and_evicts_nothing() {
        assert_eq!(
            preload_write_decision(None, PreloadPriority::Speculative),
            PreloadWrite::Store { evicted: None }
        );
    }

    #[test]
    fn a_primary_past_its_consume_window_no_longer_holds_the_slot() {
        // start_playback discards an entry older than its own three-minute
        // PRELOAD_MAX_AGE, so protecting one past that would keep an
        // unusable stream and refuse a usable one.
        let stale = held(3, PreloadPriority::Primary, PRIMARY_PRELOAD_PROTECTION + FRESH);
        assert_eq!(
            preload_write_decision(Some(&stale), PreloadPriority::Speculative),
            PreloadWrite::Store { evicted: Some((42, 3)) }
        );
    }

    /// A config.toml written before the anime fallback chain was deleted still
    /// carries `fallback_provider` / `secondary_fallback_provider`. There is no
    /// `deny_unknown_fields` on these structs, so those keys are ignored rather
    /// than failing the whole parse -- if that ever changed, every existing
    /// install would silently reset to defaults on the next launch, losing the
    /// AniList and TMDB tokens stored alongside them.
    #[test]
    fn a_config_naming_the_removed_fallback_keys_still_parses() {
        let stored = r#"
[general]
provider = "nyaa"
fallback_provider = "none"
secondary_fallback_provider = "none"
manga_provider = "mangakatana"

[api]
anilist_token = "token"
"#;
        let config: AppConfig = toml::from_str(stored).expect("an old config.toml must still load");
        assert_eq!(config.general.provider, "nyaa");
        assert_eq!(config.general.manga_provider, "mangakatana");
        assert_eq!(config.api.anilist_token.as_deref(), Some("token"));
    }
}
