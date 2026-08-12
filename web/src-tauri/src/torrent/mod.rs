//! Torrent streaming provider ("nyaa"): searches SubsPlease/Nyaa for an HD
//! release of the requested episode (1080p preferred, 720p as a fallback tier
//! — see `search::SD_PENALTY`), downloads it with an embedded librqbit
//! session, and serves it to mpv over the local proxy with HTTP ranges. No
//! external client, no scraping of player pages — torrents don't rot the way
//! streaming-site extractors do.

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
}

/// What to find a torrent stream for. Grouped (rather than passed as five
/// separate `resolve()` params) since they're all "what episode, searched
/// how" — one cohesive unit distinct from the infra params (`client`,
/// `proxy_port`) alongside it.
pub struct ResolveTarget<'a> {
    pub media_id: i64,
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
}

/// One selectable torrent release, surfaced to the stream-server picker.
pub struct TorrentChoice {
    pub name: String,
    pub seeders: u64,
    pub prefer_dub: bool,
}

pub struct TorrentManager {
    session: tokio::sync::OnceCell<Arc<Session>>,
    cache_dir: PathBuf,
    resolved: tokio::sync::Mutex<HashMap<(i64, i64), Resolved>>,
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

    fn with_cache_dir(cache_dir: PathBuf) -> Self {
        let dir = cache_dir.clone();
        std::thread::spawn(move || cleanup_cache(&dir));
        Self {
            session: tokio::sync::OnceCell::new(),
            cache_dir,
            resolved: tokio::sync::Mutex::new(HashMap::new()),
        }
    }

    pub async fn session(&self) -> Result<Arc<Session>, String> {
        self.session
            .get_or_try_init(|| async {
                std::fs::create_dir_all(&self.cache_dir).map_err(|e| e.to_string())?;
                let opts = SessionOptions {
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
                Session::new_with_opts(self.cache_dir.clone(), opts)
                    .await
                    .map_err(|e| format!("torrent session init failed: {}", e))
            })
            .await
            .cloned()
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
        let ResolveTarget { media_id, episode, titles, allow_episodeless, episode_count, prefer_dub, browser_client, chosen_name } = target;
        let criteria = search::ReleaseCriteria { episode, allow_episodeless, prefer_dub, browser_client };
        let session = self.session().await?;

        // Reuse a previous resolution if the torrent is still in the session.
        // It may have been paused when the last playback stopped, so unpause
        // before handing back the URL.
        {
            let resolved = self.resolved.lock().await;
            if let Some(r) = resolved.get(&(media_id, episode)).filter(|r| r.browser_playable || !browser_client) {
                if let Some(handle) = session.get(r.torrent_id.into()) {
                    let _ = session.unpause(&handle).await;
                    return Ok(stream_url(proxy_port, r.torrent_id, r.file_id));
                }
            }
        }

        if titles.is_empty() {
            return Err("No title to search torrents for".into());
        }
        let mut candidates =
            search::find_candidates(client, titles, criteria).await;
        // Honor an explicit release pick: float the matching candidate to the
        // front (stable partition keeps the rest as ordered fallbacks).
        if let Some(ref chosen) = chosen_name {
            candidates.sort_by_key(|c| c.name != *chosen);
        }
        log::info!(
            "torrent: {} candidates for '{}' ep {} (best: {})",
            candidates.len(),
            titles[0],
            episode,
            candidates.first().map(|c| c.name.as_str()).unwrap_or("-")
        );
        if candidates.is_empty() {
            return Err(format!(
                "No HD torrent found for '{}' episode {}",
                titles[0], episode
            ));
        }

        let mut last_err = String::new();
        for cand in candidates.iter().take(4) {
            match self
                .try_candidate(client, &session, cand, episode, episode_count)
                .await
            {
                Ok(r) => {
                    self.resolved.lock().await.insert((media_id, episode), r);
                    let dir = self.cache_dir.clone();
                    tokio::task::spawn_blocking(move || cleanup_cache(&dir));
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
        let ResolveTarget { episode, titles, allow_episodeless, prefer_dub, browser_client, .. } = target;
        if titles.is_empty() {
            return vec![];
        }
        search::find_candidates(
            client,
            titles,
            search::ReleaseCriteria { episode, allow_episodeless, prefer_dub, browser_client },
        )
            .await
            .into_iter()
            .map(|c| TorrentChoice {
                name: c.name,
                seeders: c.seeders,
                prefer_dub,
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
        let dir = self.cache_dir.clone();
        tokio::task::spawn_blocking(move || cleanup_cache(&dir));
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

    /// Read the first bit of the chosen file so playback starts on warm data
    /// and dead torrents fail fast. Bounded by time, not just bytes, so a
    /// slow-but-alive swarm still passes.
    async fn prebuffer(
        &self,
        handle: &Arc<librqbit::ManagedTorrent>,
        file_id: usize,
    ) -> Result<(), String> {
        use tokio::io::AsyncReadExt;
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
        const PEER_POLL: std::time::Duration = std::time::Duration::from_millis(1000);
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
                return Err("no seeders (no peers connected)".to_string());
            }
            tokio::time::sleep(PEER_POLL).await;
        }

        let mut stream = handle
            .clone()
            .stream(file_id)
            .map_err(|e| format!("prebuffer stream open failed: {}", e))?;
        let want = PREBUFFER_BYTES.min(stream.len() as usize);
        let mut got = 0usize;
        let mut buf = vec![0u8; 256 * 1024];
        let started = std::time::Instant::now();
        while got < want {
            let remaining = PREBUFFER_TIMEOUT
                .checked_sub(started.elapsed())
                .ok_or_else(|| "no seeders (pre-buffer timed out)".to_string())?;
            match tokio::time::timeout(remaining, stream.read(&mut buf)).await {
                Ok(Ok(0)) => break, // reached EOF (tiny file)
                Ok(Ok(n)) => got += n,
                Ok(Err(e)) => return Err(format!("pre-buffer read failed: {}", e)),
                Err(_) => return Err("no seeders (pre-buffer timed out)".to_string()),
            }
        }
        log::info!(
            "torrent: pre-buffered {} KB in {:?}",
            got / 1024,
            started.elapsed()
        );
        Ok(())
    }

    async fn try_candidate(
        &self,
        client: &reqwest::Client,
        session: &Arc<Session>,
        cand: &search::Candidate,
        episode: i64,
        episode_count: Option<i64>,
    ) -> Result<Resolved, String> {
        // Prefer the .torrent file (instant metadata) over the magnet.
        let add = if let Some(ref url) = cand.torrent_url {
            let bytes = client
                .get(url)
                .send()
                .await
                .and_then(|r| r.error_for_status())
                .map_err(|e| format!("torrent file fetch failed: {}", e))?
                .bytes()
                .await
                .map_err(|e| e.to_string())?;
            AddTorrent::from_bytes(bytes.to_vec())
        } else if let Some(ref magnet) = cand.magnet {
            AddTorrent::from_url(magnet)
        } else {
            return Err("candidate has neither torrent url nor magnet".into());
        };

        let opts = AddTorrentOptions {
            overwrite: true,
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

        if tokio::time::timeout(INIT_TIMEOUT, handle.wait_until_initialized())
            .await
            .map_err(|_| "timed out fetching torrent metadata".to_string())?
            .is_err()
        {
            let _ = session.delete(torrent_id.into(), false).await;
            return Err("torrent failed to initialize".into());
        }

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

        let videos: Vec<&(usize, String, u64)> = files
            .iter()
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
        // through to the filename check, which rejects it and moves on to the
        // next candidate rather than playing episode 1 when episode 13 was
        // asked for.
        let file_id = if videos.len() == 1 && !cand.assume_batch {
            Some(videos[0].0)
        } else {
            // Which episode number the *files* use for the one being asked
            // for. Decided before any literal match, not after it: when a
            // release numbers a split cour absolutely (files 12-23 for an
            // AniList entry of 1-12), a file literally named "12" exists and is
            // the wrong episode — it is that entry's episode 1. Taking the
            // literal match first would quietly play the wrong thing, which is
            // worse than the "episode not found" this started as.
            let numbered: Vec<i64> = videos
                .iter()
                .filter_map(|(_, name, _)| search::filename_episode(name))
                .collect();
            let wanted = match search::absolute_episode(&numbered, episode, episode_count) {
                Some(absolute) => {
                    log::info!(
                        "torrent: '{}' numbers episodes absolutely; episode {} is file {}",
                        cand.name, episode, absolute
                    );
                    absolute
                }
                None => episode,
            };

            let mut best: Option<(usize, u64)> = None;
            for (i, name, len) in &videos {
                if search::filename_matches_episode(name, wanted)
                    && best.map(|(_, l)| *len > l).unwrap_or(true)
                {
                    best = Some((*i, *len));
                }
            }
            best.map(|(i, _)| i)
        };
        let Some(file_id) = file_id else {
            let _ = session.delete(torrent_id.into(), false).await;
            return Err(format!("episode {} not found inside torrent", episode));
        };

        // Select the wanted file — as a union with whatever is already
        // selected, not a replacement. Preloading the next episode reuses the
        // same batch torrent, and replacing the selection would deselect the
        // episode currently streaming to mpv: librqbit cancels its queued
        // pieces, capping it to the 32MB rolling stream-lookahead window while
        // the preloaded file downloads full-speed in natural piece order.
        // That bandwidth theft + tiny runway is exactly what showed up as
        // "cache 0.0MB, chunk, freeze" mid-playback.
        let mut wanted: std::collections::HashSet<usize> = std::iter::once(file_id).collect();
        if already_managed {
            if let Some(prev) = handle.only_files() {
                wanted.extend(prev);
            }
        }
        session
            .update_only_files(&handle, &wanted)
            .await
            .map_err(|e| format!("file selection failed: {}", e))?;
        // Errors if the torrent isn't paused — that's the normal case.
        let _ = session.unpause(&handle).await;

        // Pre-buffer the file header before handing mpv the URL. This does two
        // things: it proves the torrent actually has reachable seeders (a dead
        // one is rejected here, so the caller falls through to the next
        // candidate instead of opening mpv onto a stream that never flows), and
        // it means mpv starts reading into already-downloaded data instead of
        // spinning on byte 0. Reading the start also forces the first pieces,
        // which for these releases is where the container header lives.
        if let Err(e) = self.prebuffer(&handle, file_id).await {
            let _ = session.delete(torrent_id.into(), false).await;
            return Err(e);
        }

        Ok(Resolved {
            torrent_id,
            file_id,
            // Judged from the release name, the same text the scorer used, so
            // the cache agrees with the ranking that picked this candidate.
            browser_playable: !search::browser_incompatible_codec(&search::normalize(&cand.name)),
        })
    }
}

/// Search titles for a media (best first) plus what we know about its total
/// episode count. Titles: the user's manual override (saved as the "nyaa"
/// provider slug via the re-match UI) first, then AniList romaji/english/
/// synonyms, then whatever the frontend sent. Count: AniList `episodes`, or
/// aired-so-far for currently-airing shows.
pub(crate) async fn gather_media_info(
    state: &crate::state::AppState,
    media_id: i64,
    frontend_title: Option<String>,
) -> (Vec<String>, Option<i64>) {
    let mut titles: Vec<String> = vec![];
    {
        if let Ok(db) = state.open_db() {
            if let Some(over) = crate::registry::service::get_provider_slug(&db, media_id, "nyaa") {
                titles.push(over);
            }
        }
    }

    let mut episode_count = None;
    let detail_res = crate::commands::media::fetch_media_detail_cached(state, media_id, false).await;
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
        }
    }

    if let Some(t) = frontend_title.filter(|t| !t.is_empty()) {
        if !titles.contains(&t) {
            titles.push(t);
        }
    }
    (titles, episode_count)
}

fn stream_url(proxy_port: u16, torrent_id: usize, file_id: usize) -> String {
    format!(
        "http://127.0.0.1:{}/torrent-stream?t={}&f={}",
        proxy_port, torrent_id, file_id
    )
}

/// Evict least-recently-touched entries until the cache is under the cap.
/// Anything written to in the last hour is considered in use and skipped.
fn cleanup_cache(dir: &std::path::Path) {
    let Ok(entries) = std::fs::read_dir(dir) else { return };
    let mut items: Vec<(PathBuf, std::time::SystemTime, u64)> = vec![];
    for e in entries.flatten() {
        let path = e.path();
        let (size, mtime) = dir_size_and_mtime(&path);
        items.push((path, mtime, size));
    }
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
    for (path, mtime, size) in items {
        if total <= CACHE_CAP_BYTES {
            break;
        }
        if mtime > grace_cutoff {
            continue;
        }
        let ok = if path.is_dir() {
            std::fs::remove_dir_all(&path).is_ok()
        } else {
            std::fs::remove_file(&path).is_ok()
        };
        if ok {
            log::info!("torrent: evicted {} ({} MB)", path.display(), size / (1024 * 1024));
            total = total.saturating_sub(size);
        }
    }
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
        size = md.len();
        mtime = md.modified().unwrap_or(mtime);
    }
    (size, mtime)
}

#[cfg(test)]
mod tests {
    use super::*;
    use tokio::io::{AsyncReadExt, AsyncSeekExt};

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
        let titles = vec!["Sousou no Frieren".to_string()];
        let cands = search::find_candidates(&client(), &titles, search::ReleaseCriteria { episode: 1, allow_episodeless: false, prefer_dub: false, browser_client: false }).await;
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
        let cands = search::find_candidates(&client(), &titles, search::ReleaseCriteria { episode: 3, allow_episodeless: false, prefer_dub: false, browser_client: false }).await;
        for c in &cands {
            let n = search::normalize(&c.name);
            assert!(!n.contains("pocket"), "false positive: {}", c.name);
        }
    }

    // Live network + torrent test: resolve an episode and stream real bytes.
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
                    media_id: 154587,
                    episode: 1,
                    titles: &titles,
                    allow_episodeless: false,
                    episode_count: Some(28),
                    browser_client: false,
                    prefer_dub: false,
                    chosen_name: None,
                },
                13370,
            )
            .await
            .expect("resolve failed");
        println!("stream url: {}", url);

        // Pull the first 2 MB through the same librqbit stream the HTTP
        // handler uses, including a seek.
        let session = mgr.session().await.unwrap();
        let resolved = *mgr.resolved.lock().await.get(&(154587, 1)).unwrap();
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
