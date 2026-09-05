//! Torrent streaming provider ("nyaa"): searches SubsPlease/Nyaa for an HD
//! release of the requested episode (1080p preferred, 720p as a fallback tier
//! — see `search::SD_PENALTY`), downloads it with an embedded librqbit
//! session, and serves it to mpv over the local proxy with HTTP ranges. No
//! external client, no scraping of player pages — torrents don't rot the way
//! streaming-site extractors do.

pub mod cinema;
pub mod layout;
pub mod seadex;
pub mod series;
pub mod search;
pub mod stream;

use std::collections::HashMap;
use std::path::PathBuf;
use std::sync::Arc;

use librqbit::{AddTorrent, AddTorrentOptions, AddTorrentResponse, PeerConnectionOptions, Session, SessionOptions};

const VIDEO_EXTS: &[&str] = &["mkv", "mp4", "avi", "ts", "webm", "m4v"];
/// Metadata fetch (magnet -> torrent info via trackers/DHT) timeout.
const INIT_TIMEOUT: std::time::Duration = std::time::Duration::from_secs(45);
/// Keep the stream cache under this many bytes; least-recently-touched
/// torrents are evicted first.
const CACHE_CAP_BYTES: u64 = 3 * 1024 * 1024 * 1024;

#[derive(Clone, Copy)]
struct Resolved {
    torrent_id: usize,
    file_id: usize,
    /// Whether the release this came from is playable in a `<video>` element.
    /// The cache is keyed by episode alone, so a resolution made for mpv can
    /// be handed to the phone — fine when the release is browser-compatible
    /// (no second download of the same episode), wrong when it is an AV1 or
    /// Hi10P batch mpv was happy with. A browser caller re-resolves in that
    /// case instead of reusing it.
    browser_playable: bool,
    /// The dub preference this resolution was made under. The cache is keyed
    /// by `(media, episode)` alone, so flipping Sub/Dub and replaying an
    /// episode already resolved this session used to hand back the release
    /// picked under the *old* preference — the setting looked dead. Stored
    /// as the preference rather than the release's own dub-ness: a show with
    /// no dub at all resolves to a sub release under `prefer_dub`, and
    /// comparing dub-ness there would miss the cache on every single play.
    prefer_dub: bool,
}

/// What to find a torrent stream for. Grouped (rather than passed as five
/// separate `resolve()` params) since they're all "what episode, searched
/// how" — one cohesive unit distinct from the infra params (`client`,
/// `proxy_port`) alongside it.
pub struct ResolveTarget<'a> {
    pub media: crate::media::MediaKey,
    pub episode: i64,
    /// Search candidates, best first (AniList romaji, english, synonyms — or
    /// the user's manual override).
    pub titles: &'a [String],
    /// Movies/OVAs legitimately have no episode number in their release
    /// names; allow an episodeless match for those.
    pub allow_episodeless: bool,
    /// How many episodes this AniList entry has, when known. Used to recognise
    /// a release that numbers a split cour absolutely — see
    /// `search::absolute_episode`.
    pub episode_count: Option<i64>,
    pub prefer_dub: bool,
    /// The stream is bound for a browser `<video>` element rather than mpv,
    /// which narrows what codecs are acceptable. See
    /// `search::ReleaseCriteria::browser_client`.
    pub browser_client: bool,
    /// When the user picked a specific release from the server list, its
    /// name. That candidate is tried first; the rest stay as fallbacks so a
    /// pick that turns out to be dead still plays something.
    pub chosen_name: Option<String>,
    /// Set for a film, which is searched by title and year rather than by
    /// episode. Everything past candidate generation — the session, the
    /// candidate loop, the range stream — is identical either way, so this
    /// only swaps which search runs.
    pub movie: Option<cinema::MovieCriteria>,
    /// Set for an episode of a series, which is searched by season and
    /// episode. Mutually exclusive with `movie`.
    pub series: Option<series::EpisodeCriteria>,
    /// The titles of the franchise's other AniList entries, when known.
    /// Only read for an OVA or specials entry, where every sibling shares
    /// this entry's title and a release of one matches all of them — see
    /// `search::names_a_sibling`.
    pub sibling_titles: &'a [String],
    /// Where this AniList entry sits in its franchise — which season it is,
    /// and whether it is a TV run, an OVA/specials collection or a film. Used
    /// only once a torrent's file list is in hand, to find this entry's own
    /// episodes inside a pack that holds several seasons' worth. See
    /// `layout::select`.
    pub entry: layout::EntryHint,
    /// How far into the file playback will start, as a fraction of its
    /// length (0.0-1.0). `None`/`Some(0.0)` means a fresh play from byte 0,
    /// which `prebuffer` already probes. Set for a resume: the player opens
    /// with mpv's `--start=<seconds>`, so its first real read lands deep into
    /// the file rather than at byte 0, and the pre-buffer gate has to probe
    /// the same region it hands off — otherwise it proves the swarm is
    /// delivering unrelated bytes near the start, waves mpv through, and mpv
    /// then blocks forever on `--cache-pause-initial` waiting for a piece
    /// nothing prioritized. An estimate from the client's own
    /// stopTime/duration is close enough: this only needs to warm roughly the
    /// right region, not land on the exact byte.
    pub resume_fraction: Option<f64>,
}

/// What every candidate in one resolve is judged against. Constant across the
/// candidate loop, so it is built once and lent to each `try_candidate` rather
/// than passed as six repeated arguments.
struct CandidateContext<'a> {
    titles: &'a [String],
    alts: &'a [String],
    hint: layout::EntryHint,
    /// The episode as the *files* number it: within-season for Western TV,
    /// entry-relative for anime. Distinct from the absolute number the app
    /// keys everything else by.
    episode: i64,
    episode_count: Option<i64>,
    allow_episodeless: bool,
    /// See `ResolveTarget::resume_fraction`.
    resume_fraction: Option<f64>,
    /// Stamped onto the `Resolved` this attempt produces, so the reuse
    /// early-return can tell which preference picked it.
    prefer_dub: bool,
}

/// Elapsed time of each stage of one candidate's attempt, logged as a single
/// line when the attempt ends either way.
///
/// The torrent path is where "pressing play took ages" now lives, and until
/// this existed the log said only which candidate won and how long the whole
/// resolve took. The stages behave nothing alike: fetching a `.torrent` and
/// adding it are HTTP-fast, metadata is a DHT round trip, `peers` is bounded
/// by `PEER_GRACE`, and `throughput` spends a flat 3s (6s if the first sample
/// is low) *by design*. Which of those a slow play was made of decides which
/// constant is worth touching -- and two of them are already tuned against
/// numbers nothing has re-measured since.
struct CandidateStages {
    last: std::time::Instant,
    /// Downloading the `.torrent` file (skipped for a magnet).
    fetch_ms: u128,
    /// `session.add_torrent`.
    add_ms: u128,
    /// Waiting for torrent metadata -- the magnet/DHT round trip.
    metadata_ms: u128,
    /// Picking the file inside the torrent and selecting it.
    select_ms: u128,
    /// Waiting for the first live peer (bounded by `PEER_GRACE`).
    peers_ms: u128,
    /// Reading the first `PREBUFFER_BYTES` off the swarm.
    prebuffer_ms: u128,
    /// The fixed-length throughput sample that follows it.
    throughput_ms: u128,
}

impl CandidateStages {
    fn new() -> Self {
        Self {
            last: std::time::Instant::now(),
            fetch_ms: 0,
            add_ms: 0,
            metadata_ms: 0,
            select_ms: 0,
            peers_ms: 0,
            prebuffer_ms: 0,
            throughput_ms: 0,
        }
    }

    /// Milliseconds since the previous stage ended, and start the next one.
    fn take(&mut self) -> u128 {
        let elapsed = self.last.elapsed().as_millis();
        self.last = std::time::Instant::now();
        elapsed
    }

    fn log(&self, name: &str, outcome: &str, total_ms: u128) {
        log::info!(
            "[resolve] torrent candidate outcome={} total={}ms fetch={}ms add={}ms \
             metadata={}ms select={}ms peers={}ms prebuffer={}ms throughput={}ms '{}'",
            outcome, total_ms, self.fetch_ms, self.add_ms, self.metadata_ms,
            self.select_ms, self.peers_ms, self.prebuffer_ms, self.throughput_ms, name
        );
    }
}

/// Everything the indexer search reads, so a hit can never be a pool scored
/// for a different request. `media` covers anything derived from it, but
/// `titles` and `sibling_titles` are here because they are handed to
/// `search::find_candidates` directly: a manual search-title override changes
/// the titles without changing `media`, and for an extras entry the
/// sibling list is what *rejects* releases of the franchise's other entries,
/// so a pool built while relations were still unknown holds candidates a
/// later call must not be given.
///
/// `chosen_name` is deliberately absent: it only reorders an existing pool
/// after the fact, so keying on it would split the cache for no gain.
#[derive(PartialEq, Eq, Hash)]
struct CandidateKey {
    media: crate::media::MediaKey,
    titles: Vec<String>,
    sibling_titles: Vec<String>,
    /// Holds `episode` too, so nothing about the wanted episode is spelled
    /// out twice here.
    criteria: search::ReleaseCriteria,
}

/// How long a cached candidate pool stays usable. Long enough to cover the
/// burst this exists for — a retry, a fallback, a preload overlapping a manual
/// play — and short enough that a release published (or a swarm that died)
/// mid-session is picked up on the next play rather than sat on.
const CANDIDATE_CACHE_TTL: std::time::Duration = std::time::Duration::from_secs(60);

/// One selectable torrent release, surfaced to the stream-server picker.
pub struct TorrentChoice {
    pub name: String,
    pub seeders: u64,
    pub is_dub: bool,
}

pub struct TorrentManager {
    session: tokio::sync::OnceCell<Arc<Session>>,
    cache_dir: PathBuf,
    resolved: tokio::sync::Mutex<HashMap<(crate::media::MediaKey, i64), Resolved>>,
    /// Torrent ids with a `spawn_stall_logger` task currently running —
    /// dedupes against the burst of range requests mpv fires per seek.
    stall_logging: std::sync::Mutex<std::collections::HashSet<usize>>,
    /// SeaDex's parsed release list per AniList id — see
    /// `seadex::find_candidates`'s doc comment for why this is cached at all.
    seadex_cache: tokio::sync::Mutex<HashMap<i64, Vec<seadex::SeadexRelease>>>,
    /// The merged, sorted indexer pool of a recent search, with the instant it
    /// was produced. Nyaa answers four concurrent queries and starts returning
    /// 429s at eight, and a throttled query doesn't fail — it just yields a
    /// smaller pool. A retry, a fallback attempt and a preload racing a manual
    /// play all re-ran the whole wave against that host within seconds of each
    /// other, so the second search was the one likely to come back thin.
    ///
    /// Only ever written from `resolve`, which searches at `Breadth::Fast`.
    /// `list_candidates` asks for `Breadth::Full` under what would be the same
    /// key, so sharing this map with the picker would show the user a pool
    /// truncated to what the play path stops at.
    candidate_cache: tokio::sync::Mutex<HashMap<CandidateKey, (std::time::Instant, Vec<search::Candidate>)>>,
    /// Ceiling on download speed in bytes per second, or zero for none. Set
    /// from config before the session is created; see
    /// `StreamConfig::torrent_download_limit_mbps`.
    download_limit_bps: std::sync::atomic::AtomicU32,
    /// Which files are currently selected inside each live torrent, oldest
    /// first. librqbit's own `only_files()` is an unordered set, so the
    /// recency this needs to bound the selection is tracked here instead.
    selected_files: tokio::sync::Mutex<HashMap<usize, Vec<usize>>>,
    /// The `(torrent, file)` a player is currently reading, exempt from
    /// `retain_recent`'s eviction. Recency alone picked the wrong victim: with
    /// the playing episode selected and the next one preloaded behind it, the
    /// selection is already at `SELECTED_FILES_KEPT`, so any *third* resolve
    /// into the same pack — the episode-list hover guess is one, and it
    /// resolves for real the first time it fires — dropped the oldest entry,
    /// which is the file mpv is reading. librqbit then cancels its pieces and
    /// playback stalls as soon as the reader passes what it had buffered.
    ///
    /// One slot, not a map keyed by torrent: the tuple carries the torrent id,
    /// so a pin on one pack can never protect the same file *index* in
    /// another, and moving to a different torrent invalidates it by
    /// overwriting. A map would instead accumulate a stale pin per torrent
    /// across a binge, each one a permanent extra selected file — the exact
    /// bandwidth leak `SELECTED_FILES_KEPT` exists to stop.
    playing_file: std::sync::Mutex<Option<(usize, usize)>>,
    /// One in-flight or finished "Download Episode" per (torrent, file).
    /// Session-only — nothing here survives a relaunch, on purpose: there is
    /// no queue to resume, only a status the episode row polls while it's
    /// open.
    downloads: tokio::sync::Mutex<HashMap<(usize, usize), EpisodeDownloadStatus>>,
}

/// Status of one "Download Episode" — see `TorrentManager::spawn_episode_download`.
#[derive(Debug, Clone)]
pub enum EpisodeDownloadStatus {
    NotStarted,
    Downloading { percent: f64 },
    Done { path: String },
    Failed { message: String },
}

/// How many files stay selected inside one torrent: the one playing, and the
/// one preloaded behind it.
const SELECTED_FILES_KEPT: usize = 2;

/// Record `file_id` as the most recently wanted file of a torrent, dropping
/// whatever fell out of the window. Most recent last.
///
/// `pinned` is the file a player is reading right now, if it lives in this
/// torrent. It is skipped when choosing what to drop — never kept *extra*, so
/// the window stays `SELECTED_FILES_KEPT` wide whether or not one is set.
fn retain_recent(recent: &mut Vec<usize>, file_id: usize, pinned: Option<usize>) {
    recent.retain(|f| *f != file_id);
    recent.push(file_id);
    while recent.len() > SELECTED_FILES_KEPT {
        // Oldest first, as before, but stepping over the pin. Only one file is
        // ever pinned, so with more than one entry to choose from this always
        // finds a victim; the `break` is for the impossible case rather than a
        // silent overshoot of the window.
        match recent.iter().position(|f| Some(*f) != pinned) {
            Some(i) => {
                recent.remove(i);
            }
            None => break,
        }
    }
}

/// Strips characters a filesystem path component can't hold. Episode/series
/// titles come from AniList free text and routinely carry `/` (a season
/// subtitle written "Show / Subtitle") and other separators that would
/// otherwise be read as directory boundaries or fail outright on APFS.
fn sanitize_path_component(name: &str) -> String {
    let cleaned: String = name
        .chars()
        .map(|c| if matches!(c, '/' | '\\' | ':') { '-' } else { c })
        .collect();
    let trimmed = cleaned.trim();
    if trimmed.is_empty() { "Untitled".to_string() } else { trimmed.to_string() }
}

impl Default for TorrentManager {
    fn default() -> Self {
        Self::new()
    }
}

impl TorrentManager {
    pub fn new() -> Self {
        let cache_dir = dirs::cache_dir()
            .unwrap_or_else(std::env::temp_dir)
            .join("anicat")
            .join("torrent-streams");
        Self::with_cache_dir(cache_dir)
    }

    pub fn with_cache_dir(cache_dir: PathBuf) -> Self {
        let dir = cache_dir.clone();
        // No session exists yet at construction time, so there's nothing to
        // reconcile against -- these are leftovers from a previous process,
        // not anything a live Session is tracking.
        std::thread::spawn(move || {
            tokio::runtime::Builder::new_current_thread()
                .build()
                .expect("tokio runtime for startup cache cleanup")
                .block_on(cleanup_cache(&dir, None));
        });
        Self {
            session: tokio::sync::OnceCell::new(),
            cache_dir,
            resolved: tokio::sync::Mutex::new(HashMap::new()),
            stall_logging: std::sync::Mutex::new(std::collections::HashSet::new()),
            seadex_cache: tokio::sync::Mutex::new(HashMap::new()),
            candidate_cache: tokio::sync::Mutex::new(HashMap::new()),
            selected_files: tokio::sync::Mutex::new(HashMap::new()),
            playing_file: std::sync::Mutex::new(None),
            download_limit_bps: std::sync::atomic::AtomicU32::new(0),
            downloads: tokio::sync::Mutex::new(HashMap::new()),
        }
    }

    /// Set the download ceiling, in megabytes per second (0 = unlimited).
    /// Only read when the session is first created, so this has to happen
    /// before the first torrent play — which is where `AppState` calls it,
    /// at startup and whenever config is saved.
    pub fn set_download_limit_mbps(&self, mbps: u32) {
        self.download_limit_bps.store(
            mbps.saturating_mul(1024 * 1024),
            std::sync::atomic::Ordering::Relaxed,
        );
    }

    pub async fn session(&self) -> Result<Arc<Session>, String> {
        self.session
            .get_or_try_init(|| async {
                std::fs::create_dir_all(&self.cache_dir).map_err(|e| e.to_string())?;
                // Built twice: once normally, once without DHT persistence if
                // the stored state turns out to be unusable. See below.
                let limit_bps = self.download_limit_bps.load(std::sync::atomic::Ordering::Relaxed);
                if limit_bps > 0 {
                    log::info!(
                        "torrent: download limited to {} MB/s",
                        limit_bps / (1024 * 1024)
                    );
                }
                let opts = move |disable_dht_persistence: bool| SessionOptions {
                    disable_dht_persistence,
                    ratelimits: librqbit::limits::LimitsConfig {
                        upload_bps: None,
                        download_bps: std::num::NonZeroU32::new(limit_bps),
                    },
                    // Never seed — see the Cargo.toml note on the feature.
                    disable_upload: true,
                    // A dead/unreachable peer under the library's 10s default
                    // holds its connection slot for that whole time before
                    // it's abandoned. Anime torrent swarms are often mostly
                    // stale peer-list entries (long-offline seeders trackers
                    // never pruned), so with the default this spends most of
                    // its time waiting on peers that were never coming — at
                    // the cost of not trying the ones that would actually
                    // answer. Failing faster cycles through candidates
                    // quicker, which is what actually helps buffering when we
                    // can't make ourselves more attractive to the swarm
                    // (never uploading is a deliberate, separate choice).
                    peer_opts: Some(PeerConnectionOptions {
                        connect_timeout: Some(std::time::Duration::from_secs(4)),
                        ..Default::default()
                    }),
                    ..Default::default()
                };
                match Session::new_with_opts(self.cache_dir.clone(), opts(false)).await {
                    Ok(session) => Ok(session),
                    Err(persistent_err) => {
                        // librqbit persists the DHT routing table *and the UDP
                        // port it was listening on* to a file of its own
                        // (~/Library/Caches/com.rqbit.dht/dht.json on macOS).
                        // If that file is corrupt, or the port it names is
                        // taken by something else, `PersistentDht::create`
                        // fails and takes the whole session with it — so every
                        // torrent play died with "error initializing
                        // persistent DHT" until someone found and deleted a
                        // cache file they had no reason to know about.
                        //
                        // The stored table is a startup optimisation, not a
                        // requirement: without it the DHT just bootstraps from
                        // the well-known nodes again. So fall back rather than
                        // fail. Deliberately not deleting the file — this is a
                        // play path, and a stale cache file is not ours to
                        // remove behind the user's back; the fallback costs one
                        // bootstrap per launch and nothing else.
                        log::warn!(
                            "torrent: stored DHT state is unusable ({}); starting without DHT persistence",
                            persistent_err
                        );
                        Session::new_with_opts(self.cache_dir.clone(), opts(true))
                            .await
                            .map_err(|e| {
                                format!(
                                    "torrent session init failed: {} (also failed with stored DHT state: {})",
                                    e, persistent_err
                                )
                            })
                    }
                }
            })
            .await
            .cloned()
    }

    /// A candidate pool from the last `CANDIDATE_CACHE_TTL`, if one was
    /// searched for exactly this request.
    async fn cached_candidates(&self, key: &CandidateKey) -> Option<Vec<search::Candidate>> {
        let cache = self.candidate_cache.lock().await;
        cache
            .get(key)
            .filter(|(at, _)| at.elapsed() < CANDIDATE_CACHE_TTL)
            .map(|(_, candidates)| candidates.clone())
    }

    /// Remember a candidate pool for `CANDIDATE_CACHE_TTL`.
    ///
    /// An empty pool is not stored: that is the one result a retry exists to
    /// re-ask, and it is also what a rate-limited Nyaa returns, so caching it
    /// would pin the failure for a minute.
    async fn store_candidates(&self, key: CandidateKey, candidates: &[search::Candidate]) {
        if candidates.is_empty() {
            return;
        }
        let mut cache = self.candidate_cache.lock().await;
        // Swept here rather than on a timer: nothing else ever removes an
        // entry, and a long binge inserts one per episode per criteria, so the
        // map would grow for the life of the process.
        cache.retain(|_, (at, _)| at.elapsed() < CANDIDATE_CACHE_TTL);
        cache.insert(key, (std::time::Instant::now(), candidates.to_vec()));
    }

    /// The file pinned inside `torrent_id`, or `None` when the player is
    /// reading somewhere else entirely.
    fn pinned_file_in(&self, torrent_id: usize) -> Option<usize> {
        self.playing_file
            .lock()
            .unwrap_or_else(|e| e.into_inner())
            .filter(|(t, _)| *t == torrent_id)
            .map(|(_, f)| f)
    }

    /// Record the file behind `(media, episode)` as the one a player is now
    /// reading, and make sure it is still selected inside its torrent.
    ///
    /// Called by the playback layer at the point a stream is committed to a
    /// player, which is the only place that can tell a real play from a
    /// speculative preload — `resolve` cannot, since it serves both.
    ///
    /// The re-selection is not belt-and-braces. A play served out of
    /// `preloaded_stream` hands mpv the cached URL without going through
    /// `resolve` at all, so the reuse path's own re-assert never runs for it —
    /// and that file may well have been deselected in the meantime by a
    /// hover-preload resolve that landed between the preload and the click.
    /// Pin first, then re-select, so the re-select's own `retain_recent` can
    /// see the pin and drop something else.
    ///
    /// Cleared by `clear_playing`, and overwritten by the next play.
    /// The `(torrent, file)` a previous `resolve` landed on, if it is still
    /// cached. The url `resolve` returns names these two ids, so this exists
    /// for callers that need them without re-parsing that url.
    pub async fn resolved_ids(
        &self,
        media: crate::media::MediaKey,
        episode: i64,
    ) -> Option<(usize, usize)> {
        self.resolved
            .lock()
            .await
            .get(&(media, episode))
            .map(|r| (r.torrent_id, r.file_id))
    }

    pub async fn set_playing(&self, media: crate::media::MediaKey, episode: i64) {
        let resolved = self.resolved.lock().await.get(&(media, episode)).copied();
        let Some(r) = resolved else {
            // Nothing in the session backs this episode (a scraper provider,
            // a direct URL): whatever was pinned before is not being read any
            // more, and keeping it would hold a file selected for nobody.
            self.clear_playing();
            return;
        };
        *self.playing_file.lock().unwrap_or_else(|e| e.into_inner()) =
            Some((r.torrent_id, r.file_id));
        let Some(session) = self.session.get().cloned() else { return };
        self.ensure_selected(&session, r.torrent_id, r.file_id).await;
    }

    /// Release the pin. Playback has ended, so the file it protected is just
    /// another recently-watched one — left pinned it would be a permanent
    /// third selected file for the rest of the binge.
    pub fn clear_playing(&self) {
        *self.playing_file.lock().unwrap_or_else(|e| e.into_inner()) = None;
    }

    /// Select `file_id` inside `torrent_id` if this process hasn't already,
    /// recording it as the most recently wanted file.
    ///
    /// The check reads `selected_files`, our own record of what librqbit was
    /// last asked for, so the ordinary case — the file is still selected —
    /// costs one mutex and no round trip. That is what lets this sit on the
    /// instant-play path: `update_only_files` is reached only when the
    /// selection genuinely has to change.
    async fn ensure_selected(&self, session: &Arc<Session>, torrent_id: usize, file_id: usize) {
        let Some(handle) = session.get(torrent_id.into()) else { return };
        let wanted: std::collections::HashSet<usize> = {
            let mut selected = self.selected_files.lock().await;
            let recent = selected.entry(torrent_id).or_default();
            if recent.contains(&file_id) {
                return;
            }
            retain_recent(recent, file_id, self.pinned_file_in(torrent_id));
            recent.iter().copied().collect()
        };
        log::info!(
            "torrent: re-selecting file {} of torrent {} (it had been deselected)",
            file_id, torrent_id
        );
        if let Err(e) = session.update_only_files(&handle, &wanted).await {
            log::warn!(
                "torrent: could not re-select file {} of torrent {}: {}",
                file_id, torrent_id, e
            );
        }
    }

    /// Resolve (search + start downloading) a stream URL for an episode.
    /// `titles` are search candidates, best first (AniList romaji, english,
    /// synonyms — or the user's manual override).
    pub async fn resolve(
        &self,
        client: &reqwest::Client,
        target: ResolveTarget<'_>,
        proxy_port: u16,
    ) -> Result<String, String> {
        let ResolveTarget { media, episode, titles, allow_episodeless, episode_count, prefer_dub, browser_client, chosen_name, movie, series: series_criteria, entry, sibling_titles, resume_fraction } = target;
        let criteria = search::ReleaseCriteria {
            episode,
            allow_episodeless,
            prefer_dub,
            browser_client,
            extras: entry.kind == layout::EntryKind::Extra,
            episode_count,
        };
        let mut stage = std::time::Instant::now();
        let session = self.session().await?;
        // Normally ~0 because startup warms the session, but a cold one
        // bootstraps DHT before anything else can happen — worth telling
        // apart from a slow search.
        let session_ms = stage.elapsed().as_millis();
        stage = std::time::Instant::now();

        // Reuse a previous resolution if the torrent is still in the session.
        // It may have been paused when the last playback stopped, so unpause
        // before handing back the URL.
        let reusable = {
            let resolved = self.resolved.lock().await;
            resolved
                .get(&(media, episode))
                .filter(|r| r.browser_playable || !browser_client)
                .filter(|r| r.prefer_dub == prefer_dub)
                .copied()
        };
        if let Some(r) = reusable {
            if let Some(handle) = session.get(r.torrent_id.into()) {
                let _ = session.unpause(&handle).await;
                // Being in the session is not the same as still being
                // selected: another episode of the same pack resolving in the
                // meantime narrows `only_files` down to its own window, and
                // this early return used to hand back the URL of a file
                // librqbit had stopped fetching, which reads as a stream that
                // opens and then never advances. Costs nothing when the file
                // is selected, which is the usual case.
                self.ensure_selected(&session, r.torrent_id, r.file_id).await;
                // Says why a play was instant, so a fast one isn't
                // mistaken for evidence about the cold path.
                log::info!(
                    "[resolve] torrent reused torrent {} file {} for media={} ep={} (session={}ms)",
                    r.torrent_id, r.file_id, media, episode, session_ms
                );
                return Ok(stream_url(proxy_port, r.torrent_id, r.file_id));
            }
        }

        if titles.is_empty() {
            return Err("No title to search torrents for".into());
        }
        // Which number the *files* inside a torrent use. For a series that is
        // the within-season episode, since a season pack names its files
        // SxxEyy — while `episode` stays absolute, because it is the identity
        // the resolved-stream cache and the whole app are keyed by, and
        // within-season numbers collide across seasons.
        let file_episode = series_criteria.map(|c| c.episode as i64).unwrap_or(episode);

        // SeaDex is a different host answering a different question (which
        // release did a human pick for this AniList entry), so it has no
        // reason to wait for the indexer search to finish first — which is
        // what it used to do, adding its whole round-trip to every single
        // play. Started here and joined below.
        let seadex_query = seadex::find_candidates(
            client,
            &self.seadex_cache,
            media.anilist_id(),
            titles,
            file_episode,
            allow_episodeless,
            episode_count,
        );
        let indexer_query = async {
            match (movie, series_criteria) {
                (Some(movie_criteria), _) => {
                    cinema::find_movie_candidates(client, titles, movie_criteria).await
                }
                (_, Some(episode_criteria)) => {
                    series::find_episode_candidates(client, titles, episode_criteria).await
                }
                // Cached for the plain-anime path only. A film and a series
                // episode take an entirely different search whose inputs
                // (`MovieCriteria`, `EpisodeCriteria`) are not in the key, so
                // a cinema pool would have to either widen the key or be
                // handed back for the wrong request.
                _ => {
                    let key = CandidateKey {
                        media,
                        titles: titles.to_vec(),
                        sibling_titles: sibling_titles.to_vec(),
                        criteria,
                    };
                    match self.cached_candidates(&key).await {
                        Some(cached) => {
                            // Says why a play was fast, so it isn't mistaken
                            // for evidence about what the indexers are
                            // answering with right now.
                            log::info!(
                                "[resolve] torrent reused candidate pool ({} candidates) for media={} ep={}",
                                cached.len(), media, episode
                            );
                            cached
                        }
                        None => {
                            let found = search::find_candidates(
                                client,
                                titles,
                                sibling_titles,
                                criteria,
                                search::Breadth::Fast,
                            )
                            .await;
                            self.store_candidates(key, &found).await;
                            found
                        }
                    }
                }
            }
        };
        let (mut candidates, mut seadex_candidates) =
            tokio::join!(indexer_query, seadex_query);
        // One wall-clock number covers both now that they overlap; splitting
        // them would only report which of the two happened to finish last.
        let search_ms = stage.elapsed().as_millis();
        // Where this entry sits in its franchise, as `try_candidate` needs it
        // to find the right season's files inside a combined pack. Western TV
        // states its season outright in `EpisodeCriteria`; for anime it comes
        // from AniList via `gather_media_info`, and is left unknown rather
        // than guessed when nothing establishes it.
        let hint = match series_criteria {
            Some(c) => layout::EntryHint {
                kind: layout::EntryKind::Tv,
                season: Some(c.season),
                season_at_least: None,
            },
            None => entry,
        };
        // Titles normalized once, so an alias inside a torrent's own paths is
        // told apart from a title continuation — same rule the search uses.
        let alts: Vec<String> = titles.iter().map(|t| search::normalize(t)).collect();
        // A human already picked the release for this exact AniList entry, so
        // when SeaDex has one it goes in ahead of every regex-matched result —
        // and, unlike the regex search, it can be the *only* candidate for the
        // scattered OVA/special/"Lite" entries a franchise splits into, so this
        // is merged before the "no candidates" check below, not after it.
        if !seadex_candidates.is_empty() {
            candidates.append(&mut seadex_candidates);
            candidates.sort_by(|a, b| b.score.cmp(&a.score).then(b.seeders.cmp(&a.seeders)));
        }
        // Honor an explicit release pick: float the matching candidate to the
        // front (stable partition keeps the rest as ordered fallbacks).
        if let Some(ref chosen) = chosen_name {
            candidates.sort_by_key(|c| c.name != *chosen);
        }
        // The other half of the picture is per-candidate (see
        // `CandidateStages`); this half is everything that happens before the
        // first candidate is touched, which on a rate-limited Nyaa is where a
        // surprising amount of a slow play actually goes.
        log::info!(
            "[resolve] torrent lookup media={} ep={} candidates={} session={}ms search+seadex={}ms (best: {})",
            media,
            episode,
            candidates.len(),
            session_ms,
            search_ms,
            candidates.first().map(|c| c.name.as_str()).unwrap_or("-")
        );
        if candidates.is_empty() {
            return Err(if movie.is_some() || series_criteria.is_some() {
                format!("No torrent found for '{}'", titles[0])
            } else {
                format!("No HD torrent found for '{}' episode {}", titles[0], episode)
            });
        }

        let mut last_err = String::new();
        // Collected rather than iterated. Peeling two candidates off an
        // iterator to test for a pair consumes both even when there is only
        // one — so a media with a single candidate (every scattered
        // OVA/specials entry, whose one release is often the only one that
        // exists) raced nothing, then walked an already-empty iterator, and
        // failed with "All torrent candidates failed (last error: )" without
        // ever having tried it.
        let shortlist: Vec<&search::Candidate> = candidates.iter().take(search::SHORTLIST_SIZE).collect();
        let raced = shortlist.len() >= 2;

        // Race the top two candidates instead of trying them one at a time.
        // A dead-but-not-quite candidate (peers connect, then nothing —
        // "no seeders (pre-buffer timed out)") burns most of PREBUFFER_TIMEOUT
        // before the sequential loop even starts the next one; observed live,
        // that alone was 35-40s of a 65s resolve. Racing means the wait is
        // bounded by whichever candidate actually works, not by however long
        // the first pick takes to fail.
        if let [cand_a, cand_b, ..] = shortlist[..] {
            let ctx = CandidateContext { titles, alts: &alts, hint, episode: file_episode, episode_count, allow_episodeless, resume_fraction, prefer_dub };
            let added_a = std::sync::Mutex::new(None);
            let added_b = std::sync::Mutex::new(None);
            let fut_a = self.try_candidate(client, &session, cand_a, &ctx, &added_a);
            let fut_b = self.try_candidate(client, &session, cand_b, &ctx, &added_b);
            tokio::pin!(fut_a);
            tokio::pin!(fut_b);

            let (result, winner, loser_fut, loser, loser_added) = tokio::select! {
                r = &mut fut_a => (r, cand_a, fut_b, cand_b, &added_b),
                r = &mut fut_b => (r, cand_b, fut_a, cand_a, &added_a),
            };

            let result = match result {
                Ok(r) => Ok((r, winner)),
                Err(e) => {
                    log::warn!("torrent: candidate '{}' failed: {}", winner.name, e);
                    last_err = e;
                    // The loser was still mid-flight, not dead — worth
                    // waiting on rather than falling all the way through to
                    // the sequential candidates below.
                    match loser_fut.await {
                        Ok(r) => Ok((r, loser)),
                        Err(e) => {
                            log::warn!("torrent: candidate '{}' failed: {}", loser.name, e);
                            last_err = e;
                            Err(())
                        }
                    }
                }
            };

            if let Ok((r, cand)) = result {
                // Stop the losing racer before anything else. Winning the
                // select only stops the loser's *future* being polled -- the
                // torrent it already added stays in the session and keeps
                // pulling its selected file at full speed, competing for
                // bandwidth with the stream mpv is about to read. Nothing tore
                // it down, because a cancelled future never reaches its own
                // error-path cleanup: observed as a release that lost the race
                // still writing chunks to disk at session teardown.
                //
                // The id comparison is the safety net for the case where the
                // winner *is* the erstwhile loser (the raced pick failed and
                // the loser was awaited into the winner's place), and for two
                // candidates that resolved to the same torrent.
                let loser_id = *loser_added.lock().unwrap_or_else(|e| e.into_inner());
                if let Some(id) = loser_id.filter(|id| *id != r.torrent_id) {
                    log::info!(
                        "torrent: dropping losing candidate '{}' (torrent {})",
                        loser.name, id
                    );
                    // librqbit logs any chunk that lands after this as
                    // "FATAL: error writing chunk to disk ... file is None".
                    // Benign -- writes already queued for a torrent that is
                    // going away -- and not worth avoiding: pausing first was
                    // measured and produced exactly the same lines.
                    let _ = session.delete(id.into(), true).await;
                    self.selected_files.lock().await.remove(&id);
                }

                self.resolved.lock().await.insert((media, episode), r);
                let dir = self.cache_dir.clone();
                let session_for_cleanup = session.clone();
                tokio::spawn(async move { cleanup_cache(&dir, Some(&session_for_cleanup)).await });
                log::info!(
                    "torrent: streaming '{}' (torrent {}, file {})",
                    cand.name, r.torrent_id, r.file_id
                );
                return Ok(stream_url(proxy_port, r.torrent_id, r.file_id));
            }
        }

        for cand in shortlist.iter().skip(if raced { 2 } else { 0 }).copied() {
            match self
                .try_candidate(
                    client,
                    &session,
                    cand,
                    &CandidateContext { titles, alts: &alts, hint, episode: file_episode, episode_count, allow_episodeless, resume_fraction, prefer_dub },
                    // Sequential: each attempt is awaited to completion, so its
                    // own error path cleans up after it and nothing is left for
                    // the caller to tear down.
                    &std::sync::Mutex::new(None),
                )
                .await
            {
                Ok(r) => {
                    self.resolved.lock().await.insert((media, episode), r);
                    let dir = self.cache_dir.clone();
                    let session_for_cleanup = session.clone();
                    tokio::spawn(async move { cleanup_cache(&dir, Some(&session_for_cleanup)).await });
                    log::info!(
                        "torrent: streaming '{}' (torrent {}, file {})",
                        cand.name, r.torrent_id, r.file_id
                    );
                    return Ok(stream_url(proxy_port, r.torrent_id, r.file_id));
                }
                Err(e) => {
                    log::warn!("torrent: candidate '{}' failed: {}", cand.name, e);
                    last_err = e;
                }
            }
        }

        // The whole shortlist can fail for reasons search never sees: a
        // release's swarm goes cold between being indexed and being tried, or
        // never had real seeders to begin with. Measured live on one episode:
        // 17 candidates found, all four shortlisted ones genuinely dead (0-21
        // KB/s against a 789 KB/s bar, one hitting the full prebuffer timeout
        // with zero bytes) -- and the other 13 were never touched. Extending
        // into the rest of the pool costs no extra search (already fetched),
        // only the per-candidate liveness check the shortlist already pays,
        // and a dead-with-no-peers candidate fails that in ~PEER_GRACE, not
        // the full PREBUFFER_TIMEOUT. Capped, not exhaustive: a pool of
        // hundreds must not turn one failed play into a multi-minute wait.
        const EXTENDED_FALLBACK_SIZE: usize = 6;
        for cand in candidates.iter().skip(search::SHORTLIST_SIZE).take(EXTENDED_FALLBACK_SIZE) {
            match self
                .try_candidate(
                    client,
                    &session,
                    cand,
                    &CandidateContext { titles, alts: &alts, hint, episode: file_episode, episode_count, allow_episodeless, resume_fraction, prefer_dub },
                    &std::sync::Mutex::new(None),
                )
                .await
            {
                Ok(r) => {
                    self.resolved.lock().await.insert((media, episode), r);
                    let dir = self.cache_dir.clone();
                    let session_for_cleanup = session.clone();
                    tokio::spawn(async move { cleanup_cache(&dir, Some(&session_for_cleanup)).await });
                    log::info!(
                        "torrent: streaming '{}' (torrent {}, file {}) from the extended fallback pool",
                        cand.name, r.torrent_id, r.file_id
                    );
                    return Ok(stream_url(proxy_port, r.torrent_id, r.file_id));
                }
                Err(e) => {
                    log::warn!("torrent: candidate '{}' failed: {}", cand.name, e);
                    last_err = e;
                }
            }
        }
        Err(format!("All torrent candidates failed (last error: {})", last_err))
    }

    /// Search-only: list the release candidates for an episode without adding
    /// any torrent to the session. Powers the stream-server picker so the user
    /// can choose a specific release (fansub group, batch, seeder count)
    /// instead of always taking the auto-picked best. Returns descriptors,
    /// best first.
    pub async fn list_candidates(
        &self,
        client: &reqwest::Client,
        target: ResolveTarget<'_>,
    ) -> Vec<TorrentChoice> {
        let ResolveTarget {
            media, episode, titles, allow_episodeless, episode_count, prefer_dub, browser_client,
            movie, series: series_criteria, entry, sibling_titles, ..
        } = target;
        if titles.is_empty() {
            return vec![];
        }
        // Which catalog this belongs to has to be honoured here exactly as it
        // is in `resolve`. Destructuring these away and always running the
        // anime search meant the picker offered nothing at all for a film or
        // an episode: it searched nyaa for a title nyaa has never carried.
        let mut candidates = match (movie, series_criteria) {
            (Some(movie_criteria), _) => cinema::find_movie_candidates(client, titles, movie_criteria).await,
            (_, Some(episode_criteria)) => {
                series::find_episode_candidates(client, titles, episode_criteria).await
            }
            _ => {
                search::find_candidates(
                    client,
                    titles,
                    sibling_titles,
                    search::ReleaseCriteria {
                        episode,
                        allow_episodeless,
                        prefer_dub,
                        browser_client,
                        extras: entry.kind == layout::EntryKind::Extra,
                        episode_count,
                    },
                    // The picker exists to show what the auto-pick didn't
                    // take, so it asks every title variant even though the
                    // play path no longer does.
                    search::Breadth::Full,
                )
                .await
            }
        };
        let file_episode = series_criteria.map(|c| c.episode as i64).unwrap_or(episode);
        let mut seadex_candidates =
            seadex::find_candidates(client, &self.seadex_cache, media.anilist_id(), titles, file_episode, allow_episodeless, episode_count).await;
        if !seadex_candidates.is_empty() {
            candidates.append(&mut seadex_candidates);
            candidates.sort_by(|a, b| b.score.cmp(&a.score).then(b.seeders.cmp(&a.seeders)));
        }
        candidates
            .into_iter()
            .map(|c| {
                let is_dub = search::is_dub_release(&search::normalize(&c.name));
                TorrentChoice {
                    name: c.name,
                    seeders: c.seeders,
                    is_dub,
                }
            })
            .collect()
    }

    /// Pause every active torrent. Called when playback stops so the download
    /// (and its DHT/peer traffic) goes quiet the moment mpv closes, instead of
    /// finishing the episode in the background. Files stay on disk, so pressing
    /// play again resumes instantly. No-op if the session was never started.
    ///
    /// Also kicks off a cache sweep: this is the natural point where an
    /// episode just went from "actively playing" to "sitting idle", so it's
    /// the best moment to trim anything over the cap instead of waiting for
    /// the next resolve() (which only happens once the user picks something
    /// new — during a long binge that could be many episodes away).
    pub async fn pause_all(&self) {
        // Every caller of this is a real teardown (mpv stopped, mpv exited),
        // so nothing is reading a file here any more.
        self.clear_playing();
        let Some(session) = self.session.get().cloned() else { return };
        let handles = std::sync::Mutex::new(Vec::new());
        session.with_torrents(|it| {
            let mut hs = handles.lock().unwrap();
            for (_, h) in it {
                hs.push(h.clone());
            }
        });
        let handles = handles.into_inner().unwrap();
        for h in handles {
            let _ = session.pause(&h).await;
        }
        cleanup_cache(&self.cache_dir, Some(&session)).await;
    }

    /// True while any torrent in the session is still downloading (live and
    /// not yet finished). Low Data Mode uses this to defer the near-end
    /// next-episode preload until the current episode's download is done, so
    /// the two never compete for bandwidth on a slow connection.
    pub async fn any_download_active(&self) -> bool {
        let Some(session) = self.session.get().cloned() else { return false };
        let active = std::sync::Mutex::new(false);
        session.with_torrents(|it| {
            let mut a = active.lock().unwrap();
            for (_, h) in it {
                let stats = h.stats();
                if stats.live.is_some() && !stats.finished {
                    *a = true;
                }
            }
        });
        active.into_inner().unwrap()
    }

    /// Whether a torrent id is still tracked by the session — i.e. whether
    /// `/torrent-stream?t=<id>` would actually serve something rather than
    /// 404. Cheap, local, no network round trip: the right liveness check
    /// for a torrent-backed preload, where `probe_stream`'s HTTP range probe
    /// (built for CDN URLs that can 403/expire) just adds latency without
    /// checking anything more meaningful than this does.
    pub async fn is_live(&self, torrent_id: usize) -> bool {
        match self.session().await {
            Ok(session) => session.get(torrent_id.into()).is_some(),
            Err(_) => false,
        }
    }

    /// Samples peer counts and download speed every 5s into the app log for
    /// as long as the torrent is downloading, so "why isn't this buffering"
    /// can be answered from Anicat.log after the fact instead of needing
    /// tracing turned on to reproduce it live.
    ///
    /// Deduped per torrent id: mpv fires a burst of range requests per seek,
    /// and `torrent_stream_handler` calls this on every one of them — only
    /// the first actually starts a logger. Stops once the torrent finishes,
    /// disappears from the session (evicted, deleted), or after a generous
    /// cap so a paused/idle torrent doesn't log forever.
    pub fn spawn_stall_logger(self: &Arc<Self>, session: &Arc<Session>, torrent_id: usize) {
        {
            let mut active = self.stall_logging.lock().unwrap_or_else(|e| e.into_inner());
            if !active.insert(torrent_id) {
                return;
            }
        }
        let mgr = self.clone();
        let session = session.clone();
        tokio::spawn(async move {
            const INTERVAL: std::time::Duration = std::time::Duration::from_secs(5);
            const MAX_SAMPLES: u32 = 240; // 20 minutes
            for _ in 0..MAX_SAMPLES {
                tokio::time::sleep(INTERVAL).await;
                let Some(handle) = session.get(torrent_id.into()) else { break };
                let stats = handle.stats();
                let finished = stats.finished;
                let peers = stats.live.as_ref().map(|l| &l.snapshot.peer_stats);
                log::info!(
                    "torrent: stall-check id {} — {} [peers live={} connecting={} seen={} dead={}]",
                    torrent_id,
                    stats,
                    peers.map(|p| p.live).unwrap_or(0),
                    peers.map(|p| p.connecting).unwrap_or(0),
                    peers.map(|p| p.seen).unwrap_or(0),
                    peers.map(|p| p.dead).unwrap_or(0),
                );
                if finished {
                    break;
                }
            }
            mgr.stall_logging
                .lock()
                .unwrap_or_else(|e| e.into_inner())
                .remove(&torrent_id);
        });
    }

    pub async fn download_status(&self, torrent_id: usize, file_id: usize) -> EpisodeDownloadStatus {
        self.downloads
            .lock()
            .await
            .get(&(torrent_id, file_id))
            .cloned()
            .unwrap_or(EpisodeDownloadStatus::NotStarted)
    }

    /// Downloads one already-resolved episode to completion and copies it out
    /// of the stream cache into the user's Downloads folder. A no-op if this
    /// (torrent, file) already has a status recorded — the episode row calls
    /// this on every tap of the download button, and a second tap while the
    /// first download is still running must not start a second copy racing
    /// the first.
    ///
    /// Deliberately outside the eviction system `playing_file` protects: that
    /// pin is one slot, already spoken for by whatever is actually playing.
    /// Instead this re-asserts the file's selection on every poll tick via
    /// `ensure_selected` — the same call `resolve`'s reuse path makes — so a
    /// download surviving a different episode of the same pack being watched
    /// costs one extra `update_only_files` call a second rather than a
    /// dedicated second pin.
    pub fn spawn_episode_download(self: &Arc<Self>, session: &Arc<Session>, torrent_id: usize, file_id: usize, display_title: String) {
        let mgr = self.clone();
        let session = session.clone();
        tokio::spawn(async move {
            {
                let mut downloads = mgr.downloads.lock().await;
                if downloads.contains_key(&(torrent_id, file_id)) {
                    return;
                }
                downloads.insert((torrent_id, file_id), EpisodeDownloadStatus::Downloading { percent: 0.0 });
            }

            async fn fail(mgr: &TorrentManager, torrent_id: usize, file_id: usize, msg: String) {
                mgr.downloads.lock().await.insert(
                    (torrent_id, file_id),
                    EpisodeDownloadStatus::Failed { message: msg },
                );
            }

            let Some(handle) = session.get(torrent_id.into()) else {
                fail(&mgr, torrent_id, file_id, "torrent is no longer in the session".into()).await;
                return;
            };
            let Ok((relative_filename, expected_len)) = handle.with_metadata(|m| {
                let info = &m.file_infos[file_id];
                (info.relative_filename.clone(), info.len)
            }) else {
                fail(&mgr, torrent_id, file_id, "could not read file metadata".into()).await;
                return;
            };
            // `ManagedTorrentShared.options` (which holds the resolved
            // per-torrent output folder) is `pub(crate)` inside librqbit —
            // invisible from here. `Api::api_torrent_details` is librqbit's
            // own public wrapper around that same field, built fresh and
            // cheaply since `Api` is just a session handle plus two `None`s.
            let output_folder = match librqbit::Api::new(session.clone(), None)
                .api_torrent_details(librqbit::api::TorrentIdOrHash::Id(torrent_id))
            {
                Ok(details) => PathBuf::from(details.output_folder),
                Err(e) => {
                    fail(&mgr, torrent_id, file_id, format!("could not read output folder: {e}")).await;
                    return;
                }
            };
            let source_path = output_folder.join(&relative_filename);

            const POLL: std::time::Duration = std::time::Duration::from_secs(1);
            // Bounded the same way spawn_stall_logger is: a dead swarm must
            // eventually report failure rather than leave the row spinning
            // forever. 40 minutes is generous for a 1080p episode even on a
            // slow swarm — the pre-buffer gate elsewhere is seconds-scale
            // because it only proves the swarm is *delivering*, but this has
            // to prove the whole file landed.
            const MAX_SAMPLES: u32 = 2400;
            let mut finished = false;
            for _ in 0..MAX_SAMPLES {
                mgr.ensure_selected(&session, torrent_id, file_id).await;
                let on_disk = tokio::fs::metadata(&source_path).await.map(|m| m.len()).unwrap_or(0);
                if expected_len > 0 {
                    let percent = (on_disk as f64 / expected_len as f64 * 100.0).min(100.0);
                    mgr.downloads.lock().await.insert(
                        (torrent_id, file_id),
                        EpisodeDownloadStatus::Downloading { percent },
                    );
                }
                if on_disk >= expected_len && expected_len > 0 {
                    finished = true;
                    break;
                }
                if session.get(torrent_id.into()).is_none() {
                    break;
                }
                tokio::time::sleep(POLL).await;
            }

            if !finished {
                fail(&mgr, torrent_id, file_id, "download did not complete (swarm stalled or torrent was removed)".into()).await;
                return;
            }

            let dest_dir = dirs::download_dir()
                .unwrap_or_else(std::env::temp_dir)
                .join("Anicat")
                .join(sanitize_path_component(&display_title));
            let file_name = relative_filename
                .file_name()
                .map(|n| n.to_string_lossy().to_string())
                .unwrap_or_else(|| format!("{display_title}.mkv"));
            let dest_path = dest_dir.join(sanitize_path_component(&file_name));

            let copy_result = tokio::task::spawn_blocking({
                let source_path = source_path.clone();
                let dest_dir = dest_dir.clone();
                let dest_path = dest_path.clone();
                move || -> std::io::Result<()> {
                    std::fs::create_dir_all(&dest_dir)?;
                    std::fs::copy(&source_path, &dest_path)?;
                    Ok(())
                }
            })
            .await;

            match copy_result {
                Ok(Ok(())) => {
                    mgr.downloads.lock().await.insert(
                        (torrent_id, file_id),
                        EpisodeDownloadStatus::Done { path: dest_path.to_string_lossy().to_string() },
                    );
                }
                Ok(Err(e)) => fail(&mgr, torrent_id, file_id, format!("could not copy file to Downloads: {e}")).await,
                Err(e) => fail(&mgr, torrent_id, file_id, format!("copy task panicked: {e}")).await,
            }
        });
    }

    /// Read the first bit of the chosen file so playback starts on warm data
    /// and dead torrents fail fast. Bounded by time, not just bytes, so a
    /// slow-but-alive swarm still passes.
    async fn prebuffer(
        &self,
        handle: &Arc<librqbit::ManagedTorrent>,
        file_id: usize,
        stages: &mut CandidateStages,
        resume_fraction: Option<f64>,
    ) -> Result<(), String> {
        use tokio::io::{AsyncReadExt, AsyncSeekExt};
        // Was 6MB: on a slow-but-alive swarm this alone was the wait (a
        // ~180KB/s peer took 33s just to deliver 6MB before mpv even
        // started). This only needs to (a) prove the swarm is actually
        // delivering bytes and (b) hand mpv a header it can parse — a
        // container header is comfortably under 1MB. mpv's own
        // --cache-pause/--demuxer-readahead-secs (see the is_torrent_stream
        // args) already handle gracefully pausing/rebuffering mid-playback
        // if it catches up to the download edge, so there's no need to front-
        // load minutes of runway here — that tradeoff belongs to mpv's cache,
        // not this one-time startup gate.
        const PREBUFFER_BYTES: usize = 1024 * 1024;
        const PREBUFFER_TIMEOUT: std::time::Duration = std::time::Duration::from_secs(40);
        // A candidate that never connects a single peer is dead — don't make
        // the user sit through the full PREBUFFER_TIMEOUT to learn that. A
        // swarm that DOES have peers still gets the full timeout below, even
        // if those peers are slow to actually send data.
        const PEER_GRACE: std::time::Duration = std::time::Duration::from_millis(3500);
        // Short, because this poll is a flat tax on *every* play, not just the
        // dead ones: a fresh add never has a live peer on the first check, so
        // at the old 1000ms every resolve slept a full second here regardless
        // of when peers actually connected — measured at peers=1000ms on three
        // consecutive healthy resolves, to the millisecond. Checking a stats
        // snapshot is cheap; the grace budget above is unchanged.
        const PEER_POLL: std::time::Duration = std::time::Duration::from_millis(150);
        let grace_start = std::time::Instant::now();
        loop {
            let live = handle
                .stats()
                .live
                .map(|l| l.snapshot.peer_stats.live)
                .unwrap_or(0);
            if live > 0 {
                break;
            }
            if grace_start.elapsed() >= PEER_GRACE {
                stages.peers_ms = stages.take();
                return Err("no seeders (no peers connected)".to_string());
            }
            tokio::time::sleep(PEER_POLL).await;
        }

        stages.peers_ms = stages.take();

        let mut stream = handle
            .clone()
            .stream(file_id)
            .map_err(|e| format!("prebuffer stream open failed: {}", e))?;
        let file_len = stream.len();
        // Resume opens mpv at `--start=<seconds>`, not byte 0 — its first real
        // read lands wherever that maps to in the file. Probing byte 0 in that
        // case proves nothing about the region mpv is about to block on, so
        // seek here to (roughly) the same offset before reading. The fraction
        // is an estimate (client-side stopTime/duration against a constant
        // bitrate assumption), which is fine: this only has to warm the right
        // neighborhood of pieces, not land on an exact byte.
        let resume_offset = resume_fraction
            .filter(|f| *f > 0.0)
            .map(|f| (file_len as f64 * f.clamp(0.0, 1.0)) as u64)
            .unwrap_or(0);
        if resume_offset > 0 {
            stream
                .seek(std::io::SeekFrom::Start(resume_offset))
                .await
                .map_err(|e| format!("prebuffer seek failed: {}", e))?;
        }
        let want = PREBUFFER_BYTES.min((file_len - resume_offset) as usize);
        let mut got = 0usize;
        let mut buf = vec![0u8; 256 * 1024];
        let fetched_at_prebuffer_start = handle
            .stats()
            .live
            .as_ref()
            .map(|l| l.snapshot.fetched_bytes)
            .unwrap_or(0);
        // What this read is actually waiting for, and why finishing it is not
        // worth much.
        //
        // The read blocks until the *first piece* of the file lands, and a
        // piece is the unit the swarm delivers however few bytes are asked for
        // -- lowering PREBUFFER_BYTES cannot speed it up. Measured on the
        // Chivalry BD remux (1MB pieces): ~3s to satisfy a 1MB read, while the
        // swarm moved ~32MB torrent-wide in the same window at 9.6MB/s. The
        // head piece simply isn't raced -- one slow peer holding it stalls the
        // read while fast peers race ahead through librqbit's 32MB stream
        // lookahead.
        //
        // Both jobs of this gate are already done by then. "The swarm is alive"
        // is proven by those bytes moving, which is the same evidence the
        // throughput check below uses. And handing mpv the URL earlier costs
        // nothing: mpv opens it with --cache-pause-initial and waits for that
        // identical piece, except the viewer is looking at the player instead
        // of a loading toast. So once the swarm has demonstrably cleared the
        // bar, stop waiting for one particular piece and let mpv wait for it.
        //
        // Deliberately *not* an unconditional early exit: a candidate whose
        // swarm never delivers has to keep failing here, or nothing falls
        // through to the next release and mpv is handed a stream that never
        // flows.
        //
        // Known limit, shared with the throughput check below: `fetched_bytes`
        // is torrent-wide, so on a season pack where the previous episode is
        // still selected (`SELECTED_FILES_KEPT` is 2) its bytes count towards
        // this bar. That can only happen mid-binge, where the swarm has already
        // proven itself on the file just watched, so the reading is optimistic
        // rather than wrong -- but it is not per-file evidence and shouldn't be
        // read as such.
        //
        // Measured on the Chivalry BD remux, same candidate, n=3 each:
        // pre-buffer median 3160ms before, 1129ms after; total candidate time
        // 3865ms before, 1819ms after. Nothing is dismissed early on the UI
        // side either -- the loading modal is gated on mpv's own file-loaded,
        // not on this returning.
        const HEAD_PIECE_GRACE: std::time::Duration = std::time::Duration::from_millis(1200);
        // The same bar the throughput check below applies: fast enough to
        // finish the file inside half an hour.
        let required_bps = file_len as f64 / NEEDS_TO_FINISH_WITHIN_SECS;

        let started = std::time::Instant::now();
        while got < want {
            let Some(remaining) = PREBUFFER_TIMEOUT.checked_sub(started.elapsed()) else {
                stages.prebuffer_ms = stages.take();
                return Err("no seeders (pre-buffer timed out)".to_string());
            };
            let waited = started.elapsed();
            if waited >= HEAD_PIECE_GRACE {
                let fetched = handle
                    .stats()
                    .live
                    .as_ref()
                    .map(|l| l.snapshot.fetched_bytes)
                    .unwrap_or(0)
                    .saturating_sub(fetched_at_prebuffer_start);
                let bps = fetched as f64 / waited.as_secs_f64();
                if bps >= required_bps {
                    stages.prebuffer_ms = stages.take();
                    log::info!(
                        "torrent: swarm proven at {:.0} KB/s (needs {:.0} KB/s) after {:?}; \
                         handing off with {} of {} KB read -- mpv waits out the head piece",
                        bps / 1024.0,
                        required_bps / 1024.0,
                        waited,
                        got / 1024,
                        want / 1024
                    );
                    return Ok(());
                }
            }
            let remaining = remaining.min(std::time::Duration::from_millis(200));
            match tokio::time::timeout(remaining, stream.read(&mut buf)).await {
                Ok(Ok(0)) => break, // reached EOF (tiny file)
                Ok(Ok(n)) => got += n,
                Ok(Err(e)) => {
                    stages.prebuffer_ms = stages.take();
                    return Err(format!("pre-buffer read failed: {}", e));
                }
                // A poll tick expiring, not the gate expiring: the loop goes
                // back to re-check the swarm's rate. `PREBUFFER_TIMEOUT` above
                // is still the only thing that fails a candidate.
                Err(_) => {}
            }
        }
        stages.prebuffer_ms = stages.take();
        log::info!(
            // Piece length is the number that explains a slow pre-buffer, and
            // nothing used to report it: reading byte 0 needs the whole first
            // piece, so a pack with 16MB pieces cannot pre-buffer faster than
            // the swarm delivers 16MB however few bytes are asked for.
            "torrent: pre-buffered {} KB in {:?} (piece length {} KB)",
            got / 1024,
            started.elapsed(),
            handle
                .with_metadata(|m| m.lengths.default_piece_length())
                .unwrap_or(0)
                / 1024
        );

        // The read above proves nothing on its own: `cache_dir` (see `new()`)
        // survives across app launches, so a file already partly downloaded
        // from an earlier attempt satisfies it entirely from disk — in
        // 516 microseconds, observed live — with zero bytes actually coming
        // from today's swarm. That let a candidate whose live peers can't
        // sustain real-time playback right now sail through this check
        // instead of falling through to one of the other candidates that
        // might be healthier: SubsPlease Horimiya ep3 measured 21 peers seen,
        // never more than 4 live, 0.3-0.5MiB/s sustained against a 1.2GiB
        // file (needs ~0.7MiB/s to even plausibly finish in 30 minutes) —
        // "pre-buffered instantly" and "buffers too slowly to actually play"
        // at once.
        //
        // `fetched_bytes` only increments on bytes actually received from a
        // peer this session (librqbit's `on_received_piece`), never on
        // pieces the disk cache already had, so sampling its delta over a
        // few seconds measures the swarm, not the disk. The threshold is
        // deliberately generous — "would finish within 30 minutes", not
        // "keeps up in real time" — since the real episode duration isn't
        // known this early; a swarm that fails even that bar is failing hard
        // enough that another candidate is worth trying.
        const NEEDS_TO_FINISH_WITHIN_SECS: f64 = 30.0 * 60.0;
        let required_bps = file_len as f64 / NEEDS_TO_FINISH_WITHIN_SECS;

        // Two samples, not one: right after a network hiccup (the machine
        // waking from sleep, Wi-Fi reassociating, a VPN reconnect) a swarm's
        // *actual* peers are still reconnecting, and the first few seconds
        // read exactly like a genuinely dead swarm — observed live, 507 KB/s
        // then 0 KB/s on two candidates moments after wake, before a third
        // candidate came back at 13 MB/s once connectivity had caught up.
        // One retry window gives a recovering swarm a second chance without
        // meaningfully softening the check for one that's actually just slow
        // (still two strikes, not an escalating grace period).
        // ...but when the pre-buffer above did real network work, it already
        // *is* that measurement, and sampling again just to re-learn it costs
        // a flat THROUGHPUT_SAMPLE on every healthy play. Three consecutive
        // resolves of the same episode measured prebuffer=12021/5055/1439ms
        // followed by throughput=3001/3001/3000ms, then reported 4.8-8.9 MB/s
        // against a 291 KB/s requirement -- three seconds spent confirming
        // what the previous twelve had just shown.
        //
        // Only when the window is long enough to mean something and the bytes
        // came off the swarm: `fetched_bytes` ignores anything the disk cache
        // served, so the case this whole check exists for -- an instant
        // pre-buffer out of a previous session's partial download, proving
        // nothing about today's peers -- reads as zero here and falls through
        // to the explicit sample below exactly as before.
        const MIN_IMPLICIT_SAMPLE: std::time::Duration = std::time::Duration::from_secs(1);
        let prebuffer_window = started.elapsed();
        let fetched_during_prebuffer = handle
            .stats()
            .live
            .as_ref()
            .map(|l| l.snapshot.fetched_bytes)
            .unwrap_or(0)
            .saturating_sub(fetched_at_prebuffer_start);
        if fetched_during_prebuffer > 0 {
            let prebuffer_secs = prebuffer_window.as_secs_f64().max(0.001);
            let prebuffer_bps = fetched_during_prebuffer as f64 / prebuffer_secs;
            if (prebuffer_window >= MIN_IMPLICIT_SAMPLE || fetched_during_prebuffer >= want as u64)
                && prebuffer_bps >= required_bps
            {
                stages.throughput_ms = stages.take();
                log::info!(
                    "torrent: throughput check passed at {:.0} KB/s (needs {:.0} KB/s) from the pre-buffer window itself ({:?})",
                    prebuffer_bps / 1024.0,
                    required_bps / 1024.0,
                    prebuffer_window
                );
                return Ok(());
            }
        }

        const THROUGHPUT_SAMPLE: std::time::Duration = std::time::Duration::from_millis(1500);

        let mut last_bps = 0.0f64;
        for attempt in 0..2 {
            let fetched_before = handle
                .stats()
                .live
                .as_ref()
                .map(|l| l.snapshot.fetched_bytes)
                .unwrap_or(0);
            tokio::time::sleep(THROUGHPUT_SAMPLE).await;
            let fetched_after = handle
                .stats()
                .live
                .as_ref()
                .map(|l| l.snapshot.fetched_bytes)
                .unwrap_or(0);
            let diff = fetched_after.saturating_sub(fetched_before);
            last_bps = diff as f64 / THROUGHPUT_SAMPLE.as_secs_f64();
            if last_bps >= required_bps {
                stages.throughput_ms = stages.take();
                log::info!(
                    "torrent: throughput check passed at {:.0} KB/s (needs {:.0} KB/s){}",
                    last_bps / 1024.0,
                    required_bps / 1024.0,
                    if attempt > 0 { " on retry" } else { "" }
                );
                return Ok(());
            }
            let live_peers = handle
                .stats()
                .live
                .as_ref()
                .map(|l| l.snapshot.peer_stats.live)
                .unwrap_or(0);
            if diff == 0 && live_peers == 0 {
                // Completely dead swarm with zero connected peers and zero bytes transferred — fail immediately.
                break;
            }
            if attempt == 0 {
                log::info!(
                    "torrent: throughput low on first sample ({:.0} KB/s, needs {:.0} KB/s, {} live peers); resampling once before giving up",
                    last_bps / 1024.0,
                    required_bps / 1024.0,
                    live_peers
                );
            }
        }
        stages.throughput_ms = stages.take();
        Err(format!(
            "swarm too slow: {:.0} KB/s, needs {:.0} KB/s to plausibly keep up",
            last_bps / 1024.0,
            required_bps / 1024.0
        ))
    }

    /// Times every stage of the attempt and logs one line for it, win or
    /// lose -- a candidate that *fails* slowly is exactly as interesting as
    /// one that succeeds slowly, since the play path waits on both.
    /// `added` records the torrent this attempt put into the session, and only
    /// when the session did not already have it. The caller uses it to clean up
    /// after a *cancelled* attempt: a losing racer's future stops being polled
    /// the moment the other one wins, so its own error-path cleanup never runs,
    /// while the torrent it added keeps downloading. `AlreadyManaged` is
    /// deliberately not recorded -- that torrent belongs to whatever put it
    /// there, very possibly the episode mpv is reading right now.
    async fn try_candidate(
        &self,
        client: &reqwest::Client,
        session: &Arc<Session>,
        cand: &search::Candidate,
        ctx: &CandidateContext<'_>,
        added: &std::sync::Mutex<Option<usize>>,
    ) -> Result<Resolved, String> {
        let started = std::time::Instant::now();
        let mut stages = CandidateStages::new();
        let out = self
            .try_candidate_inner(client, session, cand, ctx, &mut stages, added)
            .await;
        stages.log(
            &cand.name,
            if out.is_ok() { "ok" } else { "failed" },
            started.elapsed().as_millis(),
        );
        out
    }

    #[allow(clippy::too_many_arguments)] // resolve context, passed field-by-field
    async fn try_candidate_inner(
        &self,
        client: &reqwest::Client,
        session: &Arc<Session>,
        cand: &search::Candidate,
        ctx: &CandidateContext<'_>,
        stages: &mut CandidateStages,
        added: &std::sync::Mutex<Option<usize>>,
    ) -> Result<Resolved, String> {
        // Prefer the .torrent file (instant metadata) over the magnet.
        let torrent_bytes: Option<bytes::Bytes> = if let Some(ref url) = cand.torrent_url {
            let b = client
                .get(url)
                .send()
                .await
                .and_then(|r| r.error_for_status())
                .map_err(|e| format!("torrent file fetch failed: {}", e))?
                .bytes()
                .await
                .map_err(|e| e.to_string())?;
            Some(b)
        } else {
            None
        };

        let make_add = |tb: &Option<bytes::Bytes>| -> Result<AddTorrent<'_>, String> {
            if let Some(ref b) = tb {
                Ok(AddTorrent::from_bytes(b.to_vec()))
            } else if let Some(ref magnet) = cand.magnet {
                Ok(AddTorrent::from_url(magnet))
            } else {
                Err("candidate has neither torrent url nor magnet".into())
            }
        };

        stages.fetch_ms = stages.take();

        // Read the file list before adding the torrent for real, so the wanted
        // episode can be named in `only_files` from the start. Without it
        // librqbit briefly adopts *every* file in a complete-series pack --
        // allocating and checking all of them on disk -- before
        // `update_only_files` narrows it back down, which on a 12-file BD pack
        // is the single largest chunk of a cold play.
        //
        // Only ever for a candidate that came with a `.torrent`: parsing those
        // bytes is local and instant, while a magnet has to fetch its metadata
        // over DHT. Doing that here would pay that fetch twice, serially, on
        // the play path -- and this probe has no timeout of its own, so a
        // magnet whose metadata never arrives would hang the whole resolve
        // past the player's own ceiling. A magnet keeps the original path:
        // add, wait out INIT_TIMEOUT, then narrow.
        let mut pre_selected_file_id = None;
        if torrent_bytes.is_some() {
            let list_opts = AddTorrentOptions {
                list_only: true,
                ..Default::default()
            };
            let add_lo = make_add(&torrent_bytes)?;
            if let Ok(AddTorrentResponse::ListOnly(lo)) = session.add_torrent(add_lo, Some(list_opts)).await {
                if let Ok(iter) = lo.info.iter_file_details() {
                    let files: Vec<(usize, String, u64)> = iter
                        .enumerate()
                        .map(|(i, f)| {
                            let fname = f
                                .filename
                                .to_pathbuf()
                                .map(|p| p.to_string_lossy().to_string())
                                .unwrap_or_else(|_| f.filename.to_string().unwrap_or_default());
                            (i, fname, f.len)
                        })
                        .collect();
                    let videos: Vec<(usize, String, u64)> = files
                        .into_iter()
                        .filter(|(_, name, _)| {
                            let lower = name.to_lowercase();
                            VIDEO_EXTS.iter().any(|e| lower.ends_with(&format!(".{}", e)))
                        })
                        .collect();
                    if videos.len() == 1 && !cand.assume_batch {
                        pre_selected_file_id = Some(videos[0].0);
                    } else {
                        let req = layout::SelectRequest {
                            titles: ctx.titles,
                            alts: ctx.alts,
                            hint: ctx.hint,
                            episode: ctx.episode,
                            episode_count: ctx.episode_count,
                            release_name: &cand.name,
                            allow_episodeless: ctx.allow_episodeless,
                        };
                        match layout::select(&videos, &req) {
                            Ok(index) => pre_selected_file_id = Some(index),
                            // The post-add check below runs the identical
                            // `layout::select` over the identical file list, so
                            // this rejection is the one it would reach anyway --
                            // just without first adding the torrent, waiting out
                            // its initialization and deleting it again. Falling
                            // through would spend that on a pack already known
                            // not to contain the episode, delaying the next
                            // candidate by the whole of it.
                            Err(e) => {
                                log::info!("torrent: '{}' rejected before add: {}", cand.name, e);
                                return Err(format!(
                                    "episode {} not found inside torrent",
                                    ctx.episode
                                ));
                            }
                        }
                    }
                }
            }
        }

        let add = make_add(&torrent_bytes)?;

        let opts = AddTorrentOptions {
            overwrite: true,
            only_files: pre_selected_file_id.map(|id| vec![id]),
            ..Default::default()
        };
        let resp = session
            .add_torrent(add, Some(opts))
            .await
            .map_err(|e| format!("add_torrent failed: {}", e))?;
        let (handle, already_managed) = match resp {
            AddTorrentResponse::Added(_, h) => (h, false),
            AddTorrentResponse::AlreadyManaged(_, h) => (h, true),
            AddTorrentResponse::ListOnly(_) => return Err("unexpected list-only response".into()),
        };
        let torrent_id = handle.id();
        if !already_managed {
            *added.lock().unwrap_or_else(|e| e.into_inner()) = Some(torrent_id);
        }
        stages.add_ms = stages.take();

        if tokio::time::timeout(INIT_TIMEOUT, handle.wait_until_initialized())
            .await
            .map_err(|_| {
                stages.metadata_ms = stages.take();
                "timed out fetching torrent metadata".to_string()
            })?
            .is_err()
        {
            stages.metadata_ms = stages.take();
            let _ = session.delete(torrent_id.into(), false).await;
            self.selected_files.lock().await.remove(&torrent_id);
            return Err("torrent failed to initialize".into());
        }
        stages.metadata_ms = stages.take();

        // Pick the file: single video file, or the one whose name carries the
        // requested episode number.
        let files: Vec<(usize, String, u64)> = handle
            .with_metadata(|m| {
                m.file_infos
                    .iter()
                    .enumerate()
                    .map(|(i, f)| {
                        (i, f.relative_filename.to_string_lossy().to_string(), f.len)
                    })
                    .collect()
            })
            .map_err(|e| format!("no metadata: {}", e))?;

        let videos: Vec<(usize, String, u64)> = files
            .into_iter()
            .filter(|(_, name, _)| {
                let lower = name.to_lowercase();
                VIDEO_EXTS.iter().any(|e| lower.ends_with(&format!(".{}", e)))
            })
            .collect();

        // A lone video file is normally the episode by definition — the search
        // already matched the release name to this episode, so there is nothing
        // to disambiguate.
        //
        // Not so for a candidate accepted on the *assumption* that it is a
        // complete-series batch (see `Candidate::assume_batch`): its name said
        // nothing about episodes, so "one video file" is evidence the
        // assumption was wrong — a real 25-episode batch has 25 files. Fall
        // through to the layout check, which rejects it and moves on to the
        // next candidate rather than playing episode 1 when episode 13 was
        // asked for.
        let file_id = if let Some(fid) = pre_selected_file_id {
            Some(fid)
        } else if videos.len() == 1 && !cand.assume_batch {
            Some(videos[0].0)
        } else {
            // Everything else — which season's folder this entry is, whether
            // the pack numbers its files absolutely, where the specials live —
            // is `layout`'s problem, decided from the paths themselves.
            let req = layout::SelectRequest {
                titles: ctx.titles,
                alts: ctx.alts,
                hint: ctx.hint,
                episode: ctx.episode,
                episode_count: ctx.episode_count,
                release_name: &cand.name,
                allow_episodeless: ctx.allow_episodeless,
            };
            match layout::select(&videos, &req) {
                Ok(index) => Some(index),
                Err(e) => {
                    log::info!("torrent: '{}' rejected: {}", cand.name, e);
                    None
                }
            }
        };

        let Some(file_id) = file_id else {
            let _ = session.delete(torrent_id.into(), false).await;
            self.selected_files.lock().await.remove(&torrent_id);
            return Err(format!("episode {} not found inside torrent", ctx.episode));
        };

        // Select the wanted file alongside the one selected just before it,
        // and nothing older.
        //
        // Not a plain replacement: preloading the next episode reuses the same
        // batch torrent, and deselecting the episode currently streaming to
        // mpv makes librqbit cancel its queued pieces, capping it to the 32MB
        // rolling stream-lookahead window while the preloaded file downloads
        // full-speed in natural piece order. That bandwidth theft plus a tiny
        // runway is what showed up as "cache 0.0MB, chunk, freeze" mid-play.
        //
        // But it was a union with everything ever selected, which never shrank
        // — so an evening on one season pack ended up selecting every episode
        // watched and fetching all of them at full speed, long after playback
        // had moved on. Measured on a real session: six episodes of a 12-file
        // pack, 10.1 GiB, downloaded to completion while the viewer was
        // watching something else entirely.
        //
        // Two is the whole requirement: whatever is playing, and whatever was
        // preloaded next. A resolve only ever happens for one or the other —
        // except that a *speculative* one (the episode list's hover guess) can
        // arrive while both slots are full, which is why the playing file is
        // pinned out of the eviction rather than left to lose on age.
        let wanted: std::collections::HashSet<usize> = {
            // A freshly added torrent shares nothing with whatever held this
            // id before it — a pin included, since librqbit hands ids out
            // again and a stale one would protect an unrelated file index in
            // the new torrent.
            if !already_managed && self.pinned_file_in(torrent_id).is_some() {
                self.clear_playing();
            }
            let pinned = self.pinned_file_in(torrent_id);
            let mut selected = self.selected_files.lock().await;
            let recent = selected.entry(torrent_id).or_default();
            if !already_managed {
                recent.clear();
            }
            retain_recent(recent, file_id, pinned);
            recent.iter().copied().collect()
        };
        session
            .update_only_files(&handle, &wanted)
            .await
            .map_err(|e| format!("file selection failed: {}", e))?;

        // Errors if the torrent isn't paused — that's the normal case.
        let _ = session.unpause(&handle).await;
        stages.select_ms = stages.take();

        // Pre-buffer the file header before handing mpv the URL. This does two
        // things: it proves the torrent actually has reachable seeders (a dead
        // one is rejected here, so the caller falls through to the next
        // candidate instead of opening mpv onto a stream that never flows), and
        // it means mpv starts reading into already-downloaded data instead of
        // spinning on byte 0. Reading the start also forces the first pieces,
        // which for these releases is where the container header lives.
        if let Err(e) = self.prebuffer(&handle, file_id, stages, ctx.resume_fraction).await {
            let _ = session.delete(torrent_id.into(), false).await;
            self.selected_files.lock().await.remove(&torrent_id);
            return Err(e);
        }

        Ok(Resolved {
            torrent_id,
            file_id,
            // Judged from the release name, the same text the scorer used, so
            // the cache agrees with the ranking that picked this candidate.
            browser_playable: !search::browser_incompatible_codec(&search::normalize(&cand.name)),
            prefer_dub: ctx.prefer_dub,
        })
    }
}

/// What a media is, as far as searching torrents for it is concerned.
pub struct MediaInfo {
    /// Search titles, best first: the user's manual override (saved as the
    /// "nyaa" provider slug via the re-match UI) first, then AniList
    /// romaji/english/synonyms, then whatever the frontend sent.
    pub titles: Vec<String>,
    /// AniList `episodes`, or aired-so-far for currently-airing shows.
    pub episode_count: Option<i64>,
    /// Where this entry sits in its franchise — see `layout::EntryHint`.
    pub hint: layout::EntryHint,
    /// The franchise's other AniList entries, by title. See
    /// `ResolveTarget::sibling_titles`.
    pub siblings: Vec<String>,
}

/// Gather everything about a media that a torrent search needs.
///
/// Takes the two things it actually reads — the registry, for a manual
/// search-title override, and the catalog client — rather than an app-wide
/// state handle. That is what lets this file compile with no UI framework
/// underneath it.
pub async fn gather_media_info(
    registry: &crate::db::Registry,
    catalog: &crate::catalog::Catalogs,
    media: crate::media::MediaKey,
    frontend_title: Option<String>,
) -> MediaInfo {
    let mut titles: Vec<String> = vec![];
    if let Ok(Some(over)) = registry.get_provider_slug(media.catalog, media.id, "nyaa") {
        titles.push(over);
    }

    let mut episode_count = None;
    let mut kind = layout::EntryKind::Tv;
    // Whether AniList knows of an earlier TV entry this one continues. Not a
    // season number — a franchise can be three entries deep — but enough to
    // rule out a pack's season-1 files for an entry that cannot be season 1.
    let mut has_tv_prequel = false;
    let mut sibling_titles: Vec<String> = vec![];
    // Only AniList describes a franchise's shape (relations, format,
    // synonyms). A TMDB key gets the frontend title alone, which is all the
    // cinema search paths read anyway — they match on title and year.
    let detail_res = match media.anilist_id() {
        Some(id) => catalog.media_detail(id, false).await,
        None => Err("not an anilist entry".to_string()),
    };
    if let Ok(detail) = detail_res {
        if let Some(m) = detail.media {
            if let Some(t) = m.title {
                for cand in [t.romaji, t.english] {
                    if let Some(c) = cand.filter(|c| !c.is_empty()) {
                        if !titles.contains(&c) {
                            titles.push(c);
                        }
                    }
                }
            }
            for s in m.synonyms.unwrap_or_default() {
                // Synonyms include native-language titles; torrent release
                // names are searched with latin titles, so skip non-ascii.
                if !s.is_empty() && s.is_ascii() && !titles.contains(&s) {
                    titles.push(s);
                }
            }
            episode_count = m
                .episodes
                .map(|e| e as i64)
                .or_else(|| {
                    m.next_airing_episode
                        .and_then(|n| n.episode)
                        .map(|e| (e as i64 - 1).max(0))
                });
            // An OVA or a specials collection is not a season of anything:
            // release groups file both under `Extras/`, `Specials/` or `S00`,
            // and number them in their own `SP01..` sequence.
            kind = match m.format.as_deref() {
                Some("MOVIE") => layout::EntryKind::Movie,
                Some("OVA") | Some("SPECIAL") | Some("MUSIC") => layout::EntryKind::Extra,
                _ => layout::EntryKind::Tv,
            };
            let is_tv = |f: Option<&str>| matches!(f, Some("TV") | Some("TV_SHORT") | Some("ONA"));
            let edges = m.relations.and_then(|r| r.edges).unwrap_or_default();
            has_tv_prequel = edges.iter().any(|e| {
                e.relation_type.as_deref() == Some("PREQUEL")
                    && e.node.as_ref().is_some_and(|n| is_tv(n.format.as_deref()))
            });
            // Every directly related entry's titles. Which relation it is
            // doesn't matter — an OVA can be a SIDE_STORY of the series, a
            // SEQUEL of another OVA, or a SPECIAL of either, and all three
            // are equally capable of being mistaken for this one.
            // Adaptations of and by other media are the exception: the
            // manga's title is this entry's own title, so keeping it would
            // make the entry disown its own releases.
            for edge in &edges {
                if matches!(edge.relation_type.as_deref(), Some("ADAPTATION") | Some("SOURCE")) {
                    continue;
                }
                let Some(node) = edge.node.as_ref() else { continue };
                let Some(t) = node.title.as_ref() else { continue };
                for cand in [t.romaji.as_ref(), t.english.as_ref()] {
                    if let Some(c) = cand.filter(|c| !c.is_empty() && c.is_ascii()) {
                        if !sibling_titles.contains(c) {
                            sibling_titles.push(c.clone());
                        }
                    }
                }
            }
        }
    }

    if let Some(t) = frontend_title.filter(|t| !t.is_empty()) {
        if !titles.contains(&t) {
            titles.push(t);
        }
    }

    // The season number, only when something actually establishes it: the
    // title spelling it out ("Mob Psycho 100 II"), or the entry having no TV
    // prequel at all, which makes it the franchise's first season by
    // definition. A named sequel ("... Burst") states nothing and gets
    // `None` — treating that as season 1 is precisely what selects the
    // previous season's files out of a combined pack.
    //
    // Only for a TV entry. An OVA or specials entry has no season of its own —
    // it belongs to one — and its titles are full of numbers that are not
    // season markers ("Shinmai Maou no Testament Burst Episode 11" is a real
    // AniList synonym for a one-episode OVA).
    let season = if kind == layout::EntryKind::Tv {
        search::stated_season(&titles).or(if has_tv_prequel { None } else { Some(1) })
    } else {
        None
    };
    let hint = layout::EntryHint {
        kind,
        season,
        season_at_least: if kind == layout::EntryKind::Tv && has_tv_prequel && season.is_none() {
            Some(2)
        } else {
            None
        },
    };
    MediaInfo { titles, episode_count, hint, siblings: sibling_titles }
}

fn stream_url(proxy_port: u16, torrent_id: usize, file_id: usize) -> String {
    format!(
        "http://127.0.0.1:{}/torrent-stream?t={}&f={}",
        proxy_port, torrent_id, file_id
    )
}

/// Evict least-recently-touched entries until the cache is under the cap.
/// Anything written to in the last hour is considered in use and skipped.
/// Evicts old cached torrent-stream files once the cache exceeds its cap.
///
/// When `session` is given, this also tells librqbit to drop any live
/// torrent whose output folder is being evicted, via `session.delete`.
/// Without that, deleting the files out from under the Session doesn't tell
/// it the torrent is gone -- it keeps the `ManagedTorrent` (peer
/// connections, piece bitfield, stats) resident for the rest of the
/// process's life. This function used to always go straight to
/// `std::fs::remove_*`, so *every* torrent ever streamed in a session's
/// lifetime stayed fully live in memory even after its file was deleted —
/// across a long session watching many episodes, that's how memory grew
/// large enough to trigger the OS's own out-of-memory prompt.
async fn cleanup_cache(dir: &std::path::Path, session: Option<&Arc<Session>>) {
    // The scan walks every torrent directory in the cache and stats every file
    // in it, which on a multi-GB cache is real, uninterruptible disk work.
    // This function became async so it could tell the Session about what it
    // evicts, and that moved the scan onto a runtime worker thread — where a
    // slow disk stalls whatever else that worker was driving, including the
    // resolve this cleanup was spawned from. Keep the blocking half blocking.
    let scan_dir = dir.to_path_buf();
    let Ok(mut items) = tokio::task::spawn_blocking(move || {
        let mut items: Vec<(PathBuf, std::time::SystemTime, u64)> = vec![];
        let Ok(entries) = std::fs::read_dir(&scan_dir) else { return items };
        for e in entries.flatten() {
            let path = e.path();
            let (size, mtime) = dir_size_and_mtime(&path);
            items.push((path, mtime, size));
        }
        items
    })
    .await
    else {
        return;
    };
    let mut total: u64 = items.iter().map(|(_, _, s)| s).sum();
    if total <= CACHE_CAP_BYTES {
        return;
    }
    items.sort_by_key(|(_, mtime, _)| *mtime);
    // Only protect what was touched very recently (still buffering/playing).
    // This used to be a 1-hour grace window, which let an hour of binge-
    // watching (many episodes, each several GB) sit fully protected from
    // eviction regardless of the cap — that's how the cache grew unbounded
    // in practice. 10 minutes is enough to cover the current episode without
    // giving a whole session immunity.
    let grace_cutoff = std::time::SystemTime::now() - std::time::Duration::from_secs(600);

    // librqbit's default per-torrent output folder (or, for a single-file
    // torrent, the file itself) is named after `handle.name()` directly —
    // confirmed against what's actually on disk here, since the private
    // field that holds the real output path isn't part of librqbit's public
    // API. `name()` is.
    let id_by_name: HashMap<String, usize> = match session {
        Some(session) => session.with_torrents(|it| {
            it.filter_map(|(id, h)| h.name().map(|name| (name, id))).collect()
        }),
        None => HashMap::new(),
    };

    for (path, mtime, size) in items {
        if total <= CACHE_CAP_BYTES {
            break;
        }
        if mtime > grace_cutoff {
            continue;
        }
        let matched_id = path
            .file_name()
            .and_then(|n| n.to_str())
            .and_then(|name| id_by_name.get(name));
        if let (Some(session), Some(&id)) = (session, matched_id) {
            if session.delete(id.into(), true).await.is_ok() {
                log::info!("torrent: evicted {} (session id {}, {} MB)", path.display(), id, size / (1024 * 1024));
                total = total.saturating_sub(size);
                continue;
            }
        }
        let ok = if path.is_dir() {
            tokio::fs::remove_dir_all(&path).await.is_ok()
        } else {
            tokio::fs::remove_file(&path).await.is_ok()
        };
        if ok {
            log::info!("torrent: evicted {} ({} MB)", path.display(), size / (1024 * 1024));
            total = total.saturating_sub(size);
        }
    }
}

/// What a file actually costs on disk, rather than how long it claims to be.
///
/// librqbit lays down every file in a torrent up front, whether or not it is
/// selected, so a 20GB season pack occupies 20GB of *apparent* length from the
/// moment it is added while holding only the few episodes actually fetched.
/// Summing `len()` therefore told the cache it was 7x over its cap when it was
/// under it, and evicted a whole session's worth of episodes — the two just
/// watched included — the moment the grace window let it.
#[cfg(unix)]
fn allocated_size(md: &std::fs::Metadata) -> u64 {
    use std::os::unix::fs::MetadataExt;
    // st_blocks is always in 512-byte units, whatever the filesystem's own
    // block size is.
    md.blocks() * 512
}

/// Windows has no sparse-aware size in `std`, and the alternative is a raw
/// `GetCompressedFileSize` call for a cache heuristic. Overcounting a sparse
/// file there costs an early eviction, never a wrong file.
#[cfg(not(unix))]
fn allocated_size(md: &std::fs::Metadata) -> u64 {
    md.len()
}

fn dir_size_and_mtime(path: &std::path::Path) -> (u64, std::time::SystemTime) {
    let mut size = 0u64;
    let mut mtime = std::time::SystemTime::UNIX_EPOCH;
    let meta_of = |p: &std::path::Path| p.metadata().ok();
    if path.is_dir() {
        if let Ok(rd) = std::fs::read_dir(path) {
            for e in rd.flatten() {
                let (s, m) = dir_size_and_mtime(&e.path());
                size += s;
                if m > mtime {
                    mtime = m;
                }
            }
        }
    } else if let Some(md) = meta_of(path) {
        size = allocated_size(&md);
        mtime = md.modified().unwrap_or(mtime);
    }
    (size, mtime)
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::media::MediaKey;
    use tokio::io::{AsyncReadExt, AsyncSeekExt};

    #[test]
    fn a_zero_download_limit_means_unlimited() {
        // librqbit takes the ceiling as NonZeroU32, where None is "no limit".
        // Zero has to land there rather than as a literal zero bytes per
        // second, which would stall every torrent outright.
        let manager = TorrentManager::with_cache_dir(std::env::temp_dir().join("anicat-limit-test"));
        manager.set_download_limit_mbps(0);
        let bps = manager.download_limit_bps.load(std::sync::atomic::Ordering::Relaxed);
        assert_eq!(bps, 0);
        assert!(std::num::NonZeroU32::new(bps).is_none(), "zero must mean unlimited");

        manager.set_download_limit_mbps(5);
        let bps = manager.download_limit_bps.load(std::sync::atomic::Ordering::Relaxed);
        assert_eq!(bps, 5 * 1024 * 1024);
        assert!(std::num::NonZeroU32::new(bps).is_some());

        // A ceiling large enough to overflow the byte conversion would wrap to
        // something tiny and throttle playback to nothing.
        manager.set_download_limit_mbps(u32::MAX);
        assert_eq!(
            manager.download_limit_bps.load(std::sync::atomic::Ordering::Relaxed),
            u32::MAX
        );
    }

    #[tokio::test]
    async fn a_cached_candidate_pool_answers_only_the_request_it_was_searched_for() {
        let manager =
            TorrentManager::with_cache_dir(std::env::temp_dir().join("anicat-candidate-cache-test"));
        let key = |prefer_dub| CandidateKey {
            media: MediaKey::anilist(1),
            titles: vec!["Some Show".to_string()],
            sibling_titles: vec![],
            criteria: search::ReleaseCriteria {
                episode: 3,
                allow_episodeless: false,
                prefer_dub,
                browser_client: false,
                extras: false,
                episode_count: Some(12),
            },
        };
        let pool = vec![search::Candidate {
            name: "[Group] Some Show - 03 [1080p]".to_string(),
            magnet: None,
            torrent_url: None,
            seeders: 40,
            score: 1000,
            assume_batch: false,
        }];

        manager.store_candidates(key(false), &pool).await;
        assert_eq!(
            manager.cached_candidates(&key(false)).await.map(|c| c.len()),
            Some(1)
        );
        // A dub preference penalizes every non-dub release, so it reorders the
        // pool rather than filtering it -- handing this one back for a dub
        // request would play a sub with no sign anything was wrong.
        assert!(manager.cached_candidates(&key(true)).await.is_none());

        // An empty pool is what a throttled Nyaa answers with; caching it
        // would hold the failure for the whole TTL.
        manager.store_candidates(key(true), &[]).await;
        assert!(manager.cached_candidates(&key(true)).await.is_none());

        {
            let mut cache = manager.candidate_cache.lock().await;
            let stale = std::time::Instant::now()
                .checked_sub(CANDIDATE_CACHE_TTL + std::time::Duration::from_secs(1))
                .expect("machine booted long enough ago to age an entry past the TTL");
            cache.get_mut(&key(false)).expect("pool stored above").0 = stale;
        }
        assert!(manager.cached_candidates(&key(false)).await.is_none());
        manager.store_candidates(key(true), &pool).await;
        assert_eq!(
            manager.candidate_cache.lock().await.len(),
            1,
            "an expired entry must be dropped on insert, or the map grows for the whole session"
        );
    }

    /// The two safety rails on tearing down a losing racer. Both exist because
    /// deleting the wrong torrent kills the stream mpv is reading.
    #[test]
    fn a_losing_racer_is_only_torn_down_when_it_is_safe_to() {
        // What `try_candidate` records: a torrent it actually added, never one
        // the session already had (that one belongs to whoever put it there --
        // very possibly the episode currently playing).
        let record = |already_managed: bool, id: usize| -> Option<usize> {
            let slot = std::sync::Mutex::new(None);
            if !already_managed {
                *slot.lock().unwrap() = Some(id);
            }
            let held = *slot.lock().unwrap();
            held
        };
        assert_eq!(record(false, 7), Some(7), "a freshly added torrent is ours to drop");
        assert_eq!(record(true, 7), None, "an already-managed torrent is not");

        // What `resolve` does with it: never delete the torrent that won,
        // which is what the id comparison guards. That case is real -- the
        // raced pick can fail and the loser gets awaited into the winner's
        // place, so the "loser" slot then holds the winner's id.
        let should_delete = |loser: Option<usize>, winner_id: usize| -> Option<usize> {
            loser.filter(|id| *id != winner_id)
        };
        assert_eq!(should_delete(Some(3), 9), Some(3));
        assert_eq!(should_delete(Some(9), 9), None, "the loser became the winner");
        assert_eq!(should_delete(None, 9), None, "it never got as far as adding one");
    }

    #[test]
    fn the_selection_keeps_what_plays_and_what_was_preloaded() {
        // Watching straight through a season pack: each episode is resolved,
        // then the next is preloaded behind it. Only ever two files stay
        // selected, and in this order age alone is enough to drop the right
        // one -- what plays is always newer than what it replaced.
        let mut recent = vec![];
        retain_recent(&mut recent, 0, None); // play episode 1
        assert_eq!(recent, vec![0]);
        retain_recent(&mut recent, 1, None); // preload episode 2
        assert_eq!(recent, vec![0, 1]);
        retain_recent(&mut recent, 2, None); // episode 2 plays, preload episode 3
        assert_eq!(recent, vec![1, 2], "episode 1 dropped, episode 2 still playing");
        retain_recent(&mut recent, 3, None);
        assert_eq!(recent, vec![2, 3]);
        // Re-resolving a file already selected re-dates it rather than
        // selecting it twice -- jumping back to the previous episode must not
        // evict the one it is jumping from.
        retain_recent(&mut recent, 2, None);
        assert_eq!(recent, vec![3, 2]);
    }

    /// Regression: a hover-preload deselected the file mpv was reading, and
    /// the stream froze the moment playback passed the buffered bytes.
    #[test]
    fn a_speculative_resolve_evicts_the_preload_not_what_is_playing() {
        // Episode 5 playing, episode 6 preloaded behind it at the ceiling.
        let playing = 5;
        let mut recent = vec![];
        retain_recent(&mut recent, playing, Some(playing));
        retain_recent(&mut recent, 6, Some(playing));
        assert_eq!(recent, vec![5, 6]);

        // The user hovers episode 7 in the list. Its first-time resolve lands
        // in the same pack and needs a slot; by age that slot is episode 5's,
        // which is the one being read.
        retain_recent(&mut recent, 7, Some(playing));
        assert_eq!(recent, vec![5, 7], "the preload goes, never the playing file");
        assert!(recent.contains(&playing));
        assert_eq!(recent.len(), SELECTED_FILES_KEPT);

        // Hovering along the whole list never widens the selection either --
        // the pin changes which entry is dropped, not how many are kept.
        for file in 8..20 {
            retain_recent(&mut recent, file, Some(playing));
            assert!(recent.contains(&playing), "file {} evicted the playing one", file);
            assert_eq!(recent.len(), SELECTED_FILES_KEPT);
        }

        // Playback moves on: the pin follows it, and the file that was pinned
        // is now ordinary and evictable.
        retain_recent(&mut recent, 6, Some(6));
        retain_recent(&mut recent, 7, Some(6));
        assert_eq!(recent, vec![6, 7]);
        retain_recent(&mut recent, 8, Some(6));
        assert_eq!(recent, vec![6, 8], "episode 5 is no longer protected");
    }

    /// Regression: a 20GB pack whose files are laid down up front, holding
    /// almost nothing, counted as 20GB against a 3GB cap.
    #[cfg(unix)]
    #[test]
    fn cache_accounting_counts_disk_used_not_length_claimed() {
        let dir = std::env::temp_dir().join(format!("anicat-sparse-test-{}", std::process::id()));
        let _ = std::fs::remove_dir_all(&dir);
        std::fs::create_dir_all(&dir).unwrap();
        let file = dir.join("episode.mkv");
        // Two gigabytes of nothing, exactly as librqbit leaves an unselected
        // file in a season pack.
        std::fs::File::create(&file).unwrap().set_len(2 * 1024 * 1024 * 1024).unwrap();
        assert_eq!(std::fs::metadata(&file).unwrap().len(), 2 * 1024 * 1024 * 1024);

        let (size, _) = dir_size_and_mtime(&dir);
        assert!(
            size < 16 * 1024 * 1024,
            "sparse file counted as {} bytes; the cap can't hold against that",
            size
        );
        let _ = std::fs::remove_dir_all(&dir);
    }


    fn client() -> reqwest::Client {
        reqwest::Client::builder()
            .user_agent("Anicat/5.0")
            .build()
            .unwrap()
    }

    // Live network test: search candidates for a well-seeded show.
    #[tokio::test]
    #[ignore]
    async fn live_find_candidates() {
        // These tests are the only way to see the `[resolve]` stage timings
        // without running the whole app; nothing else here initializes a
        // logger, so `--nocapture` would otherwise print none of them.
        let _ = env_logger::Builder::from_env(env_logger::Env::default().default_filter_or("info"))
            .try_init();
        let titles = vec!["Sousou no Frieren".to_string()];
        let cands = search::find_candidates(&client(), &titles, &[], search::ReleaseCriteria { episode: 1, allow_episodeless: false, prefer_dub: false, browser_client: false, extras: false, episode_count: None }, search::Breadth::Full).await;
        assert!(!cands.is_empty(), "no candidates found");
        let best = &cands[0];
        println!("best: {} (score {}, seeders {})", best.name, best.score, best.seeders);
        assert!(best.score >= 600, "best candidate score too low: {}", best.score);
        // Season 1 was requested; S2 releases must not win.
        assert!(
            !search::normalize(&best.name).contains(" s2"),
            "wrong season matched: {}",
            best.name
        );
        // A short/ambiguous title must not match unrelated shows.
        let titles = vec!["Monster".to_string()];
        let cands = search::find_candidates(&client(), &titles, &[], search::ReleaseCriteria { episode: 3, allow_episodeless: false, prefer_dub: false, browser_client: false, extras: false, episode_count: None }, search::Breadth::Full).await;
        for c in &cands {
            let n = search::normalize(&c.name);
            assert!(!n.contains("pocket"), "false positive: {}", c.name);
        }
    }

    /// Live. `cargo test --lib torrent -- --ignored --nocapture`
    ///
    /// The play path stops querying title variants once it has enough healthy
    /// releases (`Breadth::Fast`). That is only safe if it still finds the
    /// same release the exhaustive search would have picked — a faster search
    /// that picks a worse torrent is not faster, it just fails later, in
    /// prebuffer, having spent the peer grace to get there.
    #[tokio::test]
    #[ignore]
    async fn live_fast_breadth_finds_the_same_best_candidate() {
        // These tests are the only way to see the `[resolve]` stage timings
        // without running the whole app; nothing else here initializes a
        // logger, so `--nocapture` would otherwise print none of them.
        let _ = env_logger::Builder::from_env(env_logger::Env::default().default_filter_or("info"))
            .try_init();
        // The worst case on purpose: a title long enough to expand to the
        // full four variants, i.e. twelve queries in three throttled waves
        // under `Full`. A one-variant show has nothing to skip.
        let titles = vec![
            "Saijo no Osewa: Takane no Hanadarake na Meimonkou de, Gakuin Ichi no Ojou-sama \
             (Seikatsu Nouryoku Kaimu) wo Kagenagara Osewa suru Koto ni Narimashita"
                .to_string(),
            "Rich Girl Caretaker: I'm Secretly the Caregiver of the Most Popular Girl in This \
             Rich Kid School"
                .to_string(),
        ];
        let criteria = search::ReleaseCriteria {
            episode: 6,
            allow_episodeless: false,
            prefer_dub: false,
            browser_client: false,
            extras: false,
            episode_count: None,
        };
        let full_started = std::time::Instant::now();
        let full =
            search::find_candidates(&client(), &titles, &[], criteria, search::Breadth::Full).await;
        let full_ms = full_started.elapsed().as_millis();
        let fast_started = std::time::Instant::now();
        let fast =
            search::find_candidates(&client(), &titles, &[], criteria, search::Breadth::Fast).await;
        let fast_ms = fast_started.elapsed().as_millis();
        println!(
            "full: {} candidates in {}ms (best: {})\nfast: {} candidates in {}ms (best: {})",
            full.len(), full_ms, full[0].name,
            fast.len(), fast_ms, fast[0].name,
        );
        assert!(!fast.is_empty(), "fast breadth found nothing");
        assert_eq!(
            fast[0].name, full[0].name,
            "fast breadth picked a different best candidate"
        );
    }

    // Live network test: a show whose AniList title is a 95-character mouthful
    // and whose release groups all use the glued `Title SxxEyy` convention.
    // Both of those independently produced "no streams found" on every episode
    // — the long title returns nothing from Nyaa's AND-search, and the glued
    // name failed title matching even when handed to it directly.
    #[tokio::test]
    #[ignore]
    async fn live_find_candidates_for_a_long_titled_sxxeyy_show() {
        let titles = vec![
            "Saijo no Osewa: Takane no Hanadarake na Meimonkou de, Gakuin Ichi no Ojou-sama \
             (Seikatsu Nouryoku Kaimu) wo Kagenagara Osewa suru Koto ni Narimashita"
                .to_string(),
            "Rich Girl Caretaker: I'm Secretly the Caregiver of the Most Popular Girl in This \
             Rich Kid School"
                .to_string(),
        ];
        let cands = search::find_candidates(
            &client(),
            &titles,
            &[],
            search::ReleaseCriteria { episode: 6, allow_episodeless: false, prefer_dub: false, browser_client: false, extras: false, episode_count: None },
            search::Breadth::Full,
        )
        .await;
        assert!(!cands.is_empty(), "no candidates found");
        let best = &cands[0];
        println!("best: {} (score {}, seeders {})", best.name, best.score, best.seeders);
        assert!(
            search::filename_matches_episode(&best.name, 6) || best.assume_batch,
            "best candidate is not episode 6: {}",
            best.name
        );
        // "has an episode 6" is not enough — a wrong show or a wrong season has
        // one too. Name the show.
        let norm = search::normalize(&best.name);
        assert!(
            norm.contains("saijo no osewa") || norm.contains("rich girl caretaker"),
            "best candidate is a different show: {}",
            best.name
        );
    }

    // Live network test: SeaDex has a Nyaa-tracked, single-file "best" pick
    // for a Chuunibyou OVA (AniList id 16934) — exactly the class of entry
    // (a franchise special split off into its own AniList id) the lookup
    // exists for, and the simple case: one file, nothing to disambiguate.
    #[tokio::test]
    #[ignore]
    async fn live_seadex_finds_a_single_file_ova() {
        let titles = vec!["Chuunibyou demo Koi ga Shitai!: Kirameki no... Slapstick Noel".to_string()];
        let cache = tokio::sync::Mutex::new(HashMap::new());
        let cands = seadex::find_candidates(&client(), &cache, Some(16934), &titles, 1, true, Some(1)).await;
        assert!(!cands.is_empty(), "no SeaDex candidates found for alID 16934");
        let best = &cands[0];
        println!("best: {} (score {})", best.name, best.score);
        assert!(best.name.starts_with("[SeaDex"), "not a SeaDex candidate: {}", best.name);
        assert!(best.magnet.as_ref().is_some_and(|m| m.starts_with("magnet:?xt=urn:btih:")));
        assert!(!best.assume_batch, "a single-file OVA is not a batch");
    }

    // Live network test, regression coverage for the bug this module's
    // box-set guard exists to prevent: SeaDex's record for Chuunibyou's "Ren
    // Lite" shorts (AniList id 20582) is a 22-file YURI release that also
    // contains all of season 2 ("S02E01".."S02E12") and a handful of other
    // specials — the *only* Nyaa-tracked entries for this alID are that box
    // set and a single combined-range file the title check can't place. Both
    // must be rejected rather than hand back a wrong-season file.
    #[tokio::test]
    #[ignore]
    async fn live_seadex_rejects_a_franchise_box_set() {
        let titles = vec![
            "Chuunibyou demo Koi ga Shitai! Ren Lite".to_string(),
            "Love, Chunibyo & Other Delusions Ren Lite".to_string(),
        ];
        let cache = tokio::sync::Mutex::new(HashMap::new());
        for episode in 1..=6 {
            let cands = seadex::find_candidates(&client(), &cache, Some(20582), &titles, episode, false, Some(6)).await;
            assert!(
                cands.is_empty(),
                "episode {}: expected no safe SeaDex candidate, got {:?}",
                episode,
                cands.iter().map(|c| &c.name).collect::<Vec<_>>()
            );
        }
    }

    // Live network test: a colon in an AniList title separates a sequel or arc
    // from its series as often as it separates a descriptive tail, and only the
    // latter may be dropped from the search query. Truncating the former queries
    // season 1, which has the same episode numbers, so nothing downstream
    // catches it — the failure is silently watching the wrong season.
    #[tokio::test]
    #[ignore]
    async fn live_sequels_are_not_collapsed_into_their_first_season() {
        for (title, required) in [
            ("Kaguya-sama wa Kokurasetai: Ultra Romantic", "ultra romantic"),
            ("Kimetsu no Yaiba: Yuukaku-hen", "yuukaku"),
            // A dash inside the title rather than a colon: the cour that
            // follows it is a separate AniList entry with its own episode 6.
            ("Sword Art Online: Alicization - War of Underworld", "war of underworld"),
        ] {
            let titles = vec![title.to_string()];
            let cands = search::find_candidates(
                &client(),
                &titles,
                &[],
                search::ReleaseCriteria { episode: 6, allow_episodeless: false, prefer_dub: false, browser_client: false, extras: false, episode_count: None },
                search::Breadth::Full,
            )
            .await;
            let best = cands.first().unwrap_or_else(|| panic!("no candidates for {}", title));
            println!("best for {}: {} (score {})", title, best.name, best.score);
            assert!(
                search::normalize(&best.name).contains(required),
                "{} resolved to a different season: {}",
                title,
                best.name
            );
        }
    }

    /// Live, one-off content check: resolve an episode, write the first
    /// megabytes to a file and leave it for `ffprobe`/`mpv` to inspect. Not
    /// an assertion — the path it prints is what a human plays to confirm the
    /// picture on screen is the episode that was asked for.
    #[tokio::test]
    #[ignore]
    async fn live_dump_a_resolved_episode_for_inspection() {
        let dir = std::env::temp_dir().join("anicat-torrent-dump");
        let mgr = TorrentManager::with_cache_dir(dir.clone());
        let titles = vec![
            "Shinmai Maou no Testament".to_string(),
            "The Testament of Sister New Devil".to_string(),
        ];
        mgr.resolve(
            &client(),
            ResolveTarget {
                media: MediaKey::anilist(20678),
                episode: 1,
                titles: &titles,
                allow_episodeless: false,
                episode_count: Some(12),
                prefer_dub: false,
                browser_client: false,
                chosen_name: None,
                movie: None,
                series: None,
                sibling_titles: &[],
                entry: layout::EntryHint {
                    kind: layout::EntryKind::Tv,
                    season: Some(1),
                    season_at_least: None,
                },
                resume_fraction: None,
            },
            13370,
        )
        .await
        .expect("resolve failed");
        let session = mgr.session().await.unwrap();
        let r = *mgr.resolved.lock().await.get(&(MediaKey::anilist(20678), 1)).unwrap();
        let handle = session.get(r.torrent_id.into()).unwrap();
        let mut stream = handle.stream(r.file_id).unwrap();
        let mut buf = vec![0u8; 8 * 1024 * 1024];
        tokio::time::timeout(std::time::Duration::from_secs(300), stream.read_exact(&mut buf))
            .await
            .expect("timed out")
            .expect("read failed");
        let out = std::env::temp_dir().join("anicat-episode-head.mkv");
        std::fs::write(&out, &buf).unwrap();
        println!("wrote {}", out.display());
        let _ = session.stop().await;
    }

    /// Live. `cargo test --lib torrent -- --ignored --nocapture`
    ///
    /// Selection against live search results, with no swarm involved: every
    /// candidate the real search returns for each entry of a split franchise
    /// has its .torrent fetched over HTTP and its file list run through
    /// `layout::select`. A candidate is allowed to decline (that is the
    /// designed answer for a pack it cannot place), but a candidate that
    /// answers must answer with a file belonging to the entry that asked.
    ///
    /// Separate from `live_resolves_every_entry_of_a_split_franchise` on
    /// purpose: that one proves bytes flow, and so depends on swarm health;
    /// this one proves the *choice* is right and depends on nothing but Nyaa
    /// being reachable.
    #[tokio::test]
    #[ignore]
    async fn live_selects_the_right_file_for_every_entry() {
        struct Case {
            titles: &'static [&'static str],
            episode: i64,
            episode_count: Option<i64>,
            hint: layout::EntryHint,
            allow_episodeless: bool,
            expect_any: &'static [&'static str],
            reject: &'static [&'static str],
            /// The franchise's other entries, as AniList relations give them.
            siblings: &'static [&'static str],
        }
        let tv = |season: Option<u32>, at_least: Option<u32>| layout::EntryHint {
            kind: layout::EntryKind::Tv,
            season,
            season_at_least: at_least,
        };
        let extra = layout::EntryHint {
            kind: layout::EntryKind::Extra,
            season: None,
            season_at_least: None,
        };
        // What AniList's `relations` actually return for each entry — one hop,
        // and thinner than the franchise. 20678 knows the specials and the
        // season 1 OVA; the season 1 OVA knows only the two TV seasons, which
        // is why Departures cannot be recognised as a relative of it at all.
        // Modelled exactly rather than idealised: a test fed the whole
        // franchise would prove a check that production never gets to run.
        const REL_SEASON_ONE: &[&str] = &[
            "Shinmai Maou no Testament Specials",
            "Shinmai Maou no Testament: Toujou Basara no Hard Sweet na Nichijou",
        ];
        const REL_BURST: &[&str] = &[
            "Shinmai Maou no Testament Burst Specials",
            "Shinmai Maou no Testament: Toujou Basara no Hard Sweet na Nichijou",
            "Shinmai Maou no Testament Burst: Toujou Basara no Shigoku Heiwa na Nichijou",
        ];
        const REL_SPECIALS: &[&str] = &["Shinmai Maou no Testament"];
        const REL_BURST_SPECIALS: &[&str] = &["Shinmai Maou no Testament Burst"];
        const REL_DEPARTURES: &[&str] = &[
            "Shinmai Maou no Testament Departures: Maria no Hizou Eizou",
            "Shinmai Maou no Testament Burst: Toujou Basara no Shigoku Heiwa na Nichijou",
        ];
        const REL_SEASON_ONE_OVA: &[&str] = &[
            "Shinmai Maou no Testament",
            "Shinmai Maou no Testament Burst",
        ];
        // The real AniList entries: 20678 (TV, 12), 21110 (TV, 10), 21209
        // (SPECIAL, 6), 102508 (SPECIAL, 5), 100451 (OVA, 1), 21247 (OVA, 1).
        let cases = [
            Case {
                titles: &["Shinmai Maou no Testament", "The Testament of Sister New Devil"],
                episode: 1,
                episode_count: Some(12),
                hint: tv(Some(1), None),
                allow_episodeless: false,
                expect_any: &["01", "e01", "- 1 "],
                siblings: REL_SEASON_ONE,
                reject: &["burst", "s02", "season 2", "departures", "ncop", "nced"],
            },
            Case {
                titles: &["Shinmai Maou no Testament", "The Testament of Sister New Devil"],
                episode: 12,
                episode_count: Some(12),
                hint: tv(Some(1), None),
                allow_episodeless: false,
                expect_any: &["12"],
                siblings: REL_SEASON_ONE,
                reject: &["burst", "s02", "season 2", "departures"],
            },
            Case {
                titles: &["Shinmai Maou no Testament Burst", "The Testament of Sister New Devil BURST"],
                episode: 1,
                episode_count: Some(10),
                hint: tv(None, Some(2)),
                allow_episodeless: false,
                expect_any: &["burst", "s02", "season 2"],
                siblings: REL_BURST,
                reject: &["departures", "ncop", "nced", "s01", "season 1"],
            },
            Case {
                titles: &["Shinmai Maou no Testament Burst", "The Testament of Sister New Devil BURST"],
                episode: 10,
                episode_count: Some(10),
                hint: tv(None, Some(2)),
                allow_episodeless: false,
                expect_any: &["10"],
                siblings: REL_BURST,
                reject: &["departures", "s01", "season 1"],
            },
            Case {
                titles: &["Shinmai Maou no Testament Specials", "The Testament of Sister New Devil Specials"],
                episode: 1,
                episode_count: Some(6),
                hint: extra,
                allow_episodeless: false,
                expect_any: &["sp1", "sp01", "special", "s00"],
                siblings: REL_SPECIALS,
                reject: &["burst"],
            },
            Case {
                titles: &[
                    "Shinmai Maou no Testament Burst Specials",
                    "The Testament of Sister New Devil BURST Specials",
                ],
                episode: 1,
                episode_count: Some(5),
                hint: extra,
                allow_episodeless: false,
                expect_any: &["sp1", "sp01", "special", "s00"],
                siblings: REL_BURST_SPECIALS,
                reject: &[],
            },
            Case {
                titles: &["Shinmai Maou no Testament Departures", "The Testament of Sister New Devil DEPARTURES"],
                episode: 1,
                episode_count: Some(1),
                hint: extra,
                allow_episodeless: true,
                expect_any: &["departures"],
                siblings: REL_DEPARTURES,
                reject: &["ncop", "nced"],
            },
            Case {
                titles: &[
                    "Shinmai Maou no Testament: Toujou Basara no Hard Sweet na Nichijou",
                    "Shinmai Maou no Testament OVA",
                ],
                episode: 1,
                episode_count: Some(1),
                hint: extra,
                allow_episodeless: true,
                expect_any: &["ova", "oad", "e13", "hard"],
                siblings: REL_SEASON_ONE_OVA,
                reject: &["burst", "departures", "ncop", "nced"],
            },
        ];

        let http = client();
        let mut failures: Vec<String> = vec![];
        for case in cases {
            tokio::time::sleep(std::time::Duration::from_secs(3)).await;
            let titles: Vec<String> = case.titles.iter().map(|t| t.to_string()).collect();
            let alts: Vec<String> = titles.iter().map(|t| search::normalize(t)).collect();
            let siblings: Vec<String> = case.siblings.iter().map(|t| t.to_string()).collect();
            let candidates = search::find_candidates(
                &http,
                &titles,
                &siblings,
                search::ReleaseCriteria {
                    episode: case.episode,
                    allow_episodeless: case.allow_episodeless,
                    prefer_dub: false,
                    browser_client: false,
                    extras: case.hint.kind == layout::EntryKind::Extra,
                    episode_count: case.episode_count,
                },
                search::Breadth::Full,
            )
            .await;
            println!("\n=== {} ep {} — {} candidates", titles[0], case.episode, candidates.len());
            if candidates.is_empty() {
                failures.push(format!("{} ep {}: no candidates at all", titles[0], case.episode));
                continue;
            }
            let mut answered = 0;
            for cand in candidates.iter().take(8) {
                let Some(ref url) = cand.torrent_url else { continue };
                let Ok(resp) = http.get(url).send().await else { continue };
                let Ok(bytes) = resp.bytes().await else { continue };
                let Ok(meta) = librqbit::torrent_from_bytes::<librqbit::ByteBuf>(&bytes) else {
                    continue;
                };
                let Ok(details) = meta.info.iter_file_details() else { continue };
                let files: Vec<(usize, String, u64)> = details
                    .enumerate()
                    .filter_map(|(i, d)| {
                        let path = d.filename.to_pathbuf().ok()?.to_string_lossy().to_string();
                        Some((i, path, d.len))
                    })
                    .filter(|(_, name, _)| {
                        let lower = name.to_lowercase();
                        VIDEO_EXTS.iter().any(|e| lower.ends_with(&format!(".{}", e)))
                    })
                    .collect();
                if files.is_empty() {
                    continue;
                }
                let req = layout::SelectRequest {
                    titles: &titles,
                    alts: &alts,
                    hint: case.hint,
                    episode: case.episode,
                    episode_count: case.episode_count,
                    release_name: &cand.name,
                    allow_episodeless: case.allow_episodeless,
                };
                // A single-file release is taken as-is by `try_candidate`
                // before `layout` is consulted; mirror that here.
                let chosen = if files.len() == 1 && !cand.assume_batch {
                    Ok(files[0].0)
                } else {
                    layout::select(&files, &req)
                };
                match chosen {
                    Ok(index) => {
                        let path = &files.iter().find(|(i, _, _)| *i == index).unwrap().1;
                        answered += 1;
                        println!("    {} -> {}", cand.name, path);
                        let lower = path.to_lowercase();
                        if !case.expect_any.is_empty()
                            && !case.expect_any.iter().any(|f| lower.contains(f))
                        {
                            failures.push(format!(
                                "{} ep {}: '{}' chose '{}', which carries none of {:?}",
                                titles[0], case.episode, cand.name, path, case.expect_any
                            ));
                        }
                        if let Some(bad) = case.reject.iter().find(|f| lower.contains(**f)) {
                            failures.push(format!(
                                "{} ep {}: '{}' chose '{}', which belongs to another entry ('{}')",
                                titles[0], case.episode, cand.name, path, bad
                            ));
                        }
                    }
                    Err(e) => println!("    {} -> declined ({})", cand.name, e),
                }
            }
            if answered == 0 {
                failures.push(format!(
                    "{} ep {}: every candidate declined; nothing would play",
                    titles[0], case.episode
                ));
            }
        }
        assert!(failures.is_empty(), "\n  {}", failures.join("\n  "));
    }

    /// Live. `cargo test --lib torrent -- --ignored --nocapture`
    ///
    /// The franchise-splitting case end to end, on the real network: five
    /// separate AniList entries of "The Testament of Sister New Devil" — two
    /// TV seasons, two specials collections and an OVA — each resolved
    /// through the real search and the real torrent session, asserting the
    /// file that comes back belongs to that entry and no other.
    ///
    /// Ids, titles and episode counts are the real ones. The hints are what
    /// `gather_media_info` derives for each: season 1 is known outright (no
    /// TV prequel), Burst is known only to be a sequel, and neither specials
    /// entry has a season of its own.
    #[tokio::test]
    #[ignore]
    async fn live_resolves_every_entry_of_a_split_franchise() {
        struct Case {
            media: MediaKey,
            titles: &'static [&'static str],
            episode: i64,
            episode_count: Option<i64>,
            hint: layout::EntryHint,
            allow_episodeless: bool,
            /// Lowercased fragments, one of which the chosen path must carry.
            expect_any: &'static [&'static str],
            /// Lowercased fragments the chosen path must not carry.
            reject: &'static [&'static str],
            siblings: &'static [&'static str],
        }
        /// The franchise's other entries, as AniList relations give them.
        const FRANCHISE: &[&str] = &[
            "Shinmai Maou no Testament",
            "Shinmai Maou no Testament Burst",
            "Shinmai Maou no Testament Specials",
            "Shinmai Maou no Testament Burst Specials",
            "Shinmai Maou no Testament Departures",
            "Shinmai Maou no Testament: Toujou Basara no Hard Sweet na Nichijou",
        ];
        let tv = |season: Option<u32>, at_least: Option<u32>| layout::EntryHint {
            kind: layout::EntryKind::Tv,
            season,
            season_at_least: at_least,
        };
        let extra = layout::EntryHint {
            kind: layout::EntryKind::Extra,
            season: None,
            season_at_least: None,
        };
        let cases = [
            Case {
                media: MediaKey::anilist(20678),
                titles: &["Shinmai Maou no Testament", "The Testament of Sister New Devil"],
                episode: 1,
                episode_count: Some(12),
                hint: tv(Some(1), None),
                allow_episodeless: false,
                expect_any: &["01", "e01", "- 1"],
                siblings: FRANCHISE,
                reject: &["burst", "s02", "season 2", "departures", "ncop", "nced"],
            },
            Case {
                media: MediaKey::anilist(20678),
                titles: &["Shinmai Maou no Testament", "The Testament of Sister New Devil"],
                episode: 12,
                episode_count: Some(12),
                hint: tv(Some(1), None),
                allow_episodeless: false,
                expect_any: &["12"],
                siblings: FRANCHISE,
                reject: &["burst", "s02", "season 2", "departures"],
            },
            Case {
                media: MediaKey::anilist(21110),
                titles: &["Shinmai Maou no Testament Burst", "The Testament of Sister New Devil BURST"],
                episode: 1,
                episode_count: Some(10),
                hint: tv(None, Some(2)),
                allow_episodeless: false,
                expect_any: &["burst", "s02", "season 2"],
                siblings: FRANCHISE,
                reject: &["departures", "ncop", "nced"],
            },
            Case {
                media: MediaKey::anilist(21209),
                titles: &["Shinmai Maou no Testament Specials", "The Testament of Sister New Devil Specials"],
                episode: 1,
                episode_count: Some(6),
                hint: extra,
                allow_episodeless: false,
                expect_any: &["sp1", "sp01", "special", "s00"],
                siblings: FRANCHISE,
                reject: &["burst"],
            },
            Case {
                media: MediaKey::anilist(100451),
                titles: &["Shinmai Maou no Testament Departures", "The Testament of Sister New Devil DEPARTURES"],
                episode: 1,
                episode_count: Some(1),
                hint: extra,
                allow_episodeless: true,
                expect_any: &["departures"],
                siblings: FRANCHISE,
                reject: &["ncop", "nced"],
            },
        ];

        let dir = std::env::temp_dir().join("anicat-torrent-franchise-test");
        let mgr = TorrentManager::with_cache_dir(dir.clone());
        let mut failures: Vec<String> = vec![];
        for case in cases {
            // Nyaa rate-limits, and one pass of this test fires six RSS
            // queries per case. Without a pause between them the later cases
            // come back empty and read as a matching failure that isn't one.
            tokio::time::sleep(std::time::Duration::from_secs(3)).await;
            let titles: Vec<String> = case.titles.iter().map(|t| t.to_string()).collect();
            let siblings: Vec<String> = case.siblings.iter().map(|t| t.to_string()).collect();
            let resolved = mgr
                .resolve(
                    &client(),
                    ResolveTarget {
                        media: case.media,
                        episode: case.episode,
                        titles: &titles,
                        allow_episodeless: case.allow_episodeless,
                        episode_count: case.episode_count,
                        prefer_dub: false,
                        browser_client: false,
                        chosen_name: None,
                        movie: None,
                        series: None,
                        entry: case.hint,
                        sibling_titles: &siblings,
                        resume_fraction: None,
                    },
                    13370,
                )
                .await;
            let url = match resolved {
                Ok(url) => url,
                Err(e) => {
                    failures.push(format!("{} ep {}: resolve failed: {}", case.media, case.episode, e));
                    continue;
                }
            };
            let session = mgr.session().await.unwrap();
            let r = *mgr.resolved.lock().await.get(&(case.media, case.episode)).unwrap();
            let handle = session.get(r.torrent_id.into()).unwrap();
            let path = handle
                .with_metadata(|m| {
                    m.file_infos[r.file_id]
                        .relative_filename
                        .to_string_lossy()
                        .to_string()
                })
                .unwrap();
            println!("{} ep {} -> {}\n    ({})", case.media, case.episode, path, url);
            let lower = path.to_lowercase();
            if !case.expect_any.iter().any(|f| lower.contains(f)) {
                failures.push(format!(
                    "{} ep {}: chose '{}', which carries none of {:?}",
                    case.media, case.episode, path, case.expect_any
                ));
            }
            if let Some(bad) = case.reject.iter().find(|f| lower.contains(**f)) {
                failures.push(format!(
                    "{} ep {}: chose '{}', which belongs to another entry ('{}')",
                    case.media, case.episode, path, bad
                ));
            }
        }

        // One real read, so this proves playable bytes and not just a name.
        let session = mgr.session().await.unwrap();
        if let Some(r) = mgr.resolved.lock().await.get(&(MediaKey::anilist(20678), 1)).copied() {
            let handle = session.get(r.torrent_id.into()).unwrap();
            let mut stream = handle.stream(r.file_id).unwrap();
            let mut buf = vec![0u8; 1024 * 1024];
            tokio::time::timeout(std::time::Duration::from_secs(240), stream.read_exact(&mut buf))
                .await
                .expect("timed out reading stream")
                .expect("read failed");
            let mkv = buf[..4] == [0x1A, 0x45, 0xDF, 0xA3];
            let mp4 = &buf[4..8] == b"ftyp";
            assert!(mkv || mp4, "not an mkv or mp4 header: {:02X?}", &buf[..12]);
        }
        let _ = session.stop().await;
        let _ = std::fs::remove_dir_all(&dir);
        assert!(failures.is_empty(), "wrong file chosen:\n  {}", failures.join("\n  "));
    }

    /// Live. `cargo test --lib torrent -- --ignored --nocapture`
    ///
    /// Walk three episodes of one batch and watch what stays selected. The
    /// selection used to be a union that never shrank, so this grew to three
    /// files here and to a whole season pack over an evening -- every one of
    /// them fetched at full speed, long after playback had moved on.
    ///
    /// Drives `try_candidate` rather than `resolve`, because `resolve` races
    /// its top candidates and a single-episode release always prebuffers
    /// faster than a 28-file batch. That race is right for playback and wrong
    /// for this test: it never lets the batch path run.
    #[tokio::test]
    #[ignore]
    async fn live_selection_stays_bounded_across_episodes() {
        let dir = std::env::temp_dir().join("anicat-torrent-selection-test");
        let mgr = TorrentManager::with_cache_dir(dir.clone());
        let titles = vec!["Sousou no Frieren".to_string()];
        let http = client();
        let candidates = search::find_candidates(
            &http,
            &titles,
            &[],
            search::ReleaseCriteria {
                episode: 1,
                allow_episodeless: false,
                prefer_dub: false,
                browser_client: false,
                extras: false,
                episode_count: Some(28),
            },
            search::Breadth::Full,
        )
        .await;
        let batch = candidates
            .iter()
            .find(|c| c.name.contains("01-28"))
            .expect("no whole-season batch among the candidates");
        println!("batch: {}", batch.name);

        let session = mgr.session().await.unwrap();
        let alts: Vec<String> = titles.iter().map(|t| search::normalize(t)).collect();
        let mut file_ids = vec![];
        let mut torrent_id = 0usize;
        for episode in 1..=3 {
            let ctx = CandidateContext {
                titles: &titles,
                alts: &alts,
                hint: layout::EntryHint {
                    kind: layout::EntryKind::Tv,
                    season: Some(1),
                    season_at_least: None,
                },
                episode,
                episode_count: Some(28),
                allow_episodeless: false,
                resume_fraction: None,
                prefer_dub: false,
            };
            let resolved = mgr
                .try_candidate(&http, &session, batch, &ctx, &std::sync::Mutex::new(None))
                .await
                .unwrap_or_else(|e| panic!("episode {} failed: {}", episode, e));
            torrent_id = resolved.torrent_id;
            let handle = session.get(resolved.torrent_id.into()).unwrap();
            let mut selected: Vec<usize> = handle.only_files().unwrap_or_default().into_iter().collect();
            selected.sort_unstable();
            println!("episode {} -> file {}, selected {:?}", episode, resolved.file_id, selected);
            assert!(
                selected.contains(&resolved.file_id),
                "episode {} is not among the files it selected: {:?}",
                episode, selected
            );
            assert!(
                selected.len() <= SELECTED_FILES_KEPT,
                "episode {} left {} files selected: {:?}",
                episode, selected.len(), selected
            );

            // The episode before this one stays selected -- that is what keeps
            // a preloaded next episode from stealing the pieces mpv is
            // currently reading.
            if let Some(previous) = file_ids.last() {
                assert!(
                    selected.contains(previous),
                    "the episode still playing was dropped: {:?}",
                    selected
                );
            }
            file_ids.push(resolved.file_id);
        }
        assert_ne!(file_ids[0], file_ids[2], "three episodes resolved to one file");

        let handle = session.get(torrent_id.into()).unwrap();
        let selected = handle.only_files().unwrap_or_default();
        assert!(
            !selected.contains(&file_ids[0]),
            "the first episode is still selected after two more: {:?}",
            selected
        );

        let _ = session.stop().await;
        let _ = std::fs::remove_dir_all(&dir);
    }

    // Live network + torrent test: resolve an episode and stream real bytes.
    //
    // If this fails instantly with "torrent session init failed: error
    // initializing persistent DHT", the stored DHT state is unusable rather
    // than anything here being wrong — `session()` now falls back to a
    // non-persistent DHT for exactly that case, so seeing it fail here means
    // the fallback regressed.
    #[tokio::test]
    #[ignore]
    async fn live_resolve_and_stream() {
        let dir = std::env::temp_dir().join("anicat-torrent-test");
        let mgr = TorrentManager::with_cache_dir(dir.clone());
        let titles = vec!["Sousou no Frieren".to_string()];
        let url = mgr
            .resolve(
                &client(),
                ResolveTarget {
                    media: MediaKey::anilist(154587),
                    episode: 1,
                    titles: &titles,
                    allow_episodeless: false,
                    episode_count: Some(28),
                    browser_client: false,
                    prefer_dub: false,
                    chosen_name: None,
                    movie: None,
                    series: None,
                    sibling_titles: &[],
                    entry: layout::EntryHint {
                        kind: layout::EntryKind::Tv,
                        season: Some(1),
                        season_at_least: None,
                    },
                resume_fraction: None,
                },
                13370,
            )
            .await
            .expect("resolve failed");
        println!("stream url: {}", url);

        // Pull the first 2 MB through the same librqbit stream the HTTP
        // handler uses, including a seek.
        let session = mgr.session().await.unwrap();
        let resolved = *mgr.resolved.lock().await.get(&(MediaKey::anilist(154587), 1)).unwrap();
        let handle = session.get(resolved.torrent_id.into()).unwrap();
        let mut stream = handle.stream(resolved.file_id).unwrap();
        let mut buf = vec![0u8; 2 * 1024 * 1024];
        tokio::time::timeout(std::time::Duration::from_secs(180), stream.read_exact(&mut buf))
            .await
            .expect("timed out reading stream")
            .expect("read failed");
        // Matroska magic: 1A 45 DF A3
        assert_eq!(&buf[..4], &[0x1A, 0x45, 0xDF, 0xA3], "not an mkv header");
        stream.seek(std::io::SeekFrom::Start(1024)).await.unwrap();

        let _ = session.stop().await;
        let _ = std::fs::remove_dir_all(&dir);
    }

    /// Live. `cargo test --lib torrent -- --ignored`
    ///
    /// The film counterpart of `live_resolve_and_stream`: proves the whole
    /// cinema path down to real bytes — apibay search, year matching, magnet,
    /// librqbit session, and the file the range endpoint would serve. mpv is
    /// not involved, so this is the strongest check available without a
    /// window on screen.
    #[tokio::test]
    #[ignore]
    async fn live_resolve_and_stream_a_film() {
        let dir = std::env::temp_dir().join("anicat-torrent-film-test");
        let mgr = TorrentManager::with_cache_dir(dir.clone());
        let titles = vec!["Dune".to_string()];
        // A cinema id, as the playback path would pass it.
        let media = MediaKey::tmdb_movie(438631);
        let url = mgr
            .resolve(
                &client(),
                ResolveTarget {
                    media,
                    episode: 1,
                    titles: &titles,
                    allow_episodeless: true,
                    episode_count: Some(1),
                    browser_client: false,
                    prefer_dub: false,
                    chosen_name: None,
                    movie: Some(cinema::MovieCriteria { year: Some(2021), browser_client: false }),
                    series: None,
                    sibling_titles: &[],
                    entry: layout::EntryHint { kind: layout::EntryKind::Movie, ..Default::default() },
                    resume_fraction: None,
                },
                13370,
            )
            .await
            .expect("resolve failed");
        println!("film stream url: {}", url);

        let session = mgr.session().await.unwrap();
        let resolved = *mgr.resolved.lock().await.get(&(media, 1)).unwrap();
        let handle = session.get(resolved.torrent_id.into()).unwrap();
        let mut stream = handle.stream(resolved.file_id).unwrap();
        let mut buf = vec![0u8; 1024 * 1024];
        tokio::time::timeout(std::time::Duration::from_secs(240), stream.read_exact(&mut buf))
            .await
            .expect("timed out reading stream")
            .expect("read failed");
        // Films ship as mkv or mp4; accept either container rather than
        // pinning the test to whichever release happens to win today.
        let mkv = buf[..4] == [0x1A, 0x45, 0xDF, 0xA3];
        let mp4 = &buf[4..8] == b"ftyp";
        assert!(mkv || mp4, "not an mkv or mp4 header: {:02X?}", &buf[..12]);

        let _ = session.stop().await;
        let _ = std::fs::remove_dir_all(&dir);
    }

    /// Live. `cargo test --lib torrent -- --ignored`
    ///
    /// The series counterpart: Knaben search, SxxEyy matching, magnet,
    /// session, and real bytes off the stream the range endpoint serves.
    #[tokio::test]
    #[ignore]
    async fn live_resolve_and_stream_an_episode() {
        // These tests are the only way to see the `[resolve]` stage timings
        // without running the whole app; nothing else here initializes a
        // logger, so `--nocapture` would otherwise print none of them.
        let _ = env_logger::Builder::from_env(env_logger::Env::default().default_filter_or("info"))
            .try_init();
        let dir = std::env::temp_dir().join("anicat-torrent-series-test");
        let mgr = TorrentManager::with_cache_dir(dir.clone());
        let titles = vec!["Silo".to_string()];
        let media = MediaKey::tmdb_tv(125988);
        let url = mgr
            .resolve(
                &client(),
                ResolveTarget {
                    media,
                    // Absolute numbering: episode 1 is S01E01 here.
                    episode: 1,
                    titles: &titles,
                    allow_episodeless: false,
                    episode_count: None,
                    browser_client: false,
                    prefer_dub: false,
                    chosen_name: None,
                    movie: None,
                    series: Some(series::EpisodeCriteria {
                        season: 1,
                        episode: 1,
                        browser_client: false,
                    }),
                    entry: Default::default(),
                    sibling_titles: &[],
                    resume_fraction: None,
                },
                13370,
            )
            .await
            .expect("resolve failed");
        println!("episode stream url: {}", url);

        let session = mgr.session().await.unwrap();
        let resolved = *mgr.resolved.lock().await.get(&(media, 1)).unwrap();
        let handle = session.get(resolved.torrent_id.into()).unwrap();
        let mut stream = handle.stream(resolved.file_id).unwrap();
        let mut buf = vec![0u8; 1024 * 1024];
        tokio::time::timeout(std::time::Duration::from_secs(240), stream.read_exact(&mut buf))
            .await
            .expect("timed out reading stream")
            .expect("read failed");
        let mkv = buf[..4] == [0x1A, 0x45, 0xDF, 0xA3];
        let mp4 = &buf[4..8] == b"ftyp";
        assert!(mkv || mp4, "not an mkv or mp4 header: {:02X?}", &buf[..12]);

        let _ = session.stop().await;
        let _ = std::fs::remove_dir_all(&dir);
    }

    /// Live. `cargo test --lib torrent::tests::live_chivalry -- --ignored --nocapture`
    ///
    /// A stopwatch on the whole nyaa path for one ordinary, finished,
    /// single-cour show — the common case, not the pathological one the other
    /// live tests are built from. `live_resolve_and_stream` proves Frieren
    /// *works*; this one asks how long an average play actually takes, from a
    /// cold cache, with the stage log printing what the time was spent on.
    /// The second `resolve` is the warm in-app path (the `resolved` map hit),
    /// which is what a rewatch or a next-episode press really costs.
    #[tokio::test]
    #[ignore]
    async fn live_chivalry_of_a_failed_knight_resolves_quickly() {
        // These tests are the only way to see the `[resolve]` stage timings
        // without running the whole app; nothing else here initializes a
        // logger, so `--nocapture` would otherwise print none of them.
        let _ = env_logger::Builder::from_env(env_logger::Env::default().default_filter_or("info"))
            .try_init();
        let dir = std::env::temp_dir().join("anicat-torrent-chivalry-test");
        // Wipe up front as well as at the end: a panic or timeout in an
        // earlier run skips the teardown, and pieces left on disk would make
        // the next "cold" measurement quietly warm.
        let _ = std::fs::remove_dir_all(&dir);
        let mgr = TorrentManager::with_cache_dir(dir.clone());
        let titles = vec![
            "Rakudai Kishi no Cavalry".to_string(),
            "Chivalry of a Failed Knight".to_string(),
        ];
        const EPISODE: i64 = 4;
        let target = || ResolveTarget {
            media: MediaKey::anilist(20977),
            episode: EPISODE,
            titles: &titles,
            allow_episodeless: false,
            episode_count: Some(12),
            browser_client: false,
            prefer_dub: false,
            chosen_name: None,
            movie: None,
            series: None,
            sibling_titles: &[],
            entry: layout::EntryHint {
                kind: layout::EntryKind::Tv,
                season: Some(1),
                season_at_least: None,
            },
                resume_fraction: None,
        };

        let cold_started = std::time::Instant::now();
        let url = tokio::time::timeout(
            std::time::Duration::from_secs(300),
            mgr.resolve(&client(), target(), 13370),
        )
        .await
        .expect("resolve timed out after 300s")
        .expect("resolve failed");
        let cold_ms = cold_started.elapsed().as_millis();

        // The warm path: same episode again, served out of `resolved`.
        let warm_started = std::time::Instant::now();
        let warm_url = mgr
            .resolve(&client(), target(), 13370)
            .await
            .expect("warm resolve failed");
        let warm_ms = warm_started.elapsed().as_millis();
        assert_eq!(url, warm_url, "the warm resolve returned a different stream");

        println!(
            "chivalry ep{}: cold resolve {}ms, warm resolve {}ms -> {}",
            EPISODE, cold_ms, warm_ms, url
        );

        // The file behind the url has to be this episode, not merely something
        // that played — a fast resolve onto the wrong file is not a win.
        let resolved = *mgr.resolved.lock().await.get(&(MediaKey::anilist(20977), EPISODE)).unwrap();
        let session = mgr.session().await.unwrap();
        let handle = session.get(resolved.torrent_id.into()).unwrap();
        let picked = handle
            .metadata
            .load()
            .as_ref()
            .and_then(|m| m.file_infos.get(resolved.file_id).map(|f| f.relative_filename.display().to_string()))
            .unwrap_or_default();
        println!("chivalry ep{}: picked file '{}'", EPISODE, picked);
        assert!(
            search::filename_matches_episode(&picked, EPISODE),
            "picked file is not episode {}: {}",
            EPISODE,
            picked
        );

        let _ = session.stop().await;
        let _ = std::fs::remove_dir_all(&dir);
    }

    #[test]
    fn episode_parsing() {
        use search::filename_matches_episode;
        assert!(filename_matches_episode("[SubsPlease] Sousou no Frieren - 05 (1080p) [ABCD1234].mkv", 5));
        assert!(filename_matches_episode("Show S01E12 1080p WEBRip.mkv", 12));
        assert!(!filename_matches_episode("[SubsPlease] Sousou no Frieren - 05 (1080p).mkv", 6));
        // resolution/codec noise must not read as an episode
        assert!(!filename_matches_episode("Show (BD 1080p HEVC x265 10bit).mkv", 1080));
    }
}
