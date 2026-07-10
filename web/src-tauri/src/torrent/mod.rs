//! Torrent streaming provider ("nyaa"): searches SubsPlease/Nyaa for a 1080p
//! release of the requested episode, downloads it with an embedded librqbit
//! session, and serves it to mpv over the local proxy with HTTP ranges. No
//! external client, no scraping of player pages — torrents don't rot the way
//! streaming-site extractors do.

pub mod search;
pub mod stream;

use std::collections::HashMap;
use std::path::PathBuf;
use std::sync::Arc;

use librqbit::{AddTorrent, AddTorrentOptions, AddTorrentResponse, Session, SessionOptions};

const VIDEO_EXTS: &[&str] = &["mkv", "mp4", "avi", "ts", "webm", "m4v"];
/// Metadata fetch (magnet -> torrent info via trackers/DHT) timeout.
const INIT_TIMEOUT: std::time::Duration = std::time::Duration::from_secs(45);
/// Keep the stream cache under this many bytes; least-recently-touched
/// torrents are evicted first.
const CACHE_CAP_BYTES: u64 = 15 * 1024 * 1024 * 1024;

#[derive(Clone, Copy)]
struct Resolved {
    torrent_id: usize,
    file_id: usize,
}

pub struct TorrentManager {
    session: tokio::sync::OnceCell<Arc<Session>>,
    cache_dir: PathBuf,
    resolved: tokio::sync::Mutex<HashMap<(i64, i64), Resolved>>,
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
        media_id: i64,
        episode: i64,
        titles: &[String],
        allow_episodeless: bool,
        prefer_dub: bool,
        proxy_port: u16,
    ) -> Result<String, String> {
        let session = self.session().await?;

        // Reuse a previous resolution if the torrent is still in the session.
        // It may have been paused when the last playback stopped, so unpause
        // before handing back the URL.
        {
            let resolved = self.resolved.lock().await;
            if let Some(r) = resolved.get(&(media_id, episode)) {
                if let Some(handle) = session.get(r.torrent_id.into()) {
                    let _ = session.unpause(&handle).await;
                    return Ok(stream_url(proxy_port, r.torrent_id, r.file_id));
                }
            }
        }

        if titles.is_empty() {
            return Err("No title to search torrents for".into());
        }
        let candidates =
            search::find_candidates(client, titles, episode, allow_episodeless, prefer_dub).await;
        log::info!(
            "torrent: {} candidates for '{}' ep {} (best: {})",
            candidates.len(),
            titles[0],
            episode,
            candidates.first().map(|c| c.name.as_str()).unwrap_or("-")
        );
        if candidates.is_empty() {
            return Err(format!(
                "No 1080p torrent found for '{}' episode {}",
                titles[0], episode
            ));
        }

        let mut last_err = String::new();
        for cand in candidates.iter().take(4) {
            match self
                .try_candidate(client, &session, cand, episode)
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

    /// Pause every active torrent. Called when playback stops so the download
    /// (and its DHT/peer traffic) goes quiet the moment mpv closes, instead of
    /// finishing the episode in the background. Files stay on disk, so pressing
    /// play again resumes instantly. No-op if the session was never started.
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
    }

    /// Read the first few MB of the chosen file so playback starts on warm
    /// data and dead torrents fail fast. Bounded by time, not just bytes, so a
    /// slow-but-alive swarm still passes.
    async fn prebuffer(
        &self,
        handle: &Arc<librqbit::ManagedTorrent>,
        file_id: usize,
    ) -> Result<(), String> {
        use tokio::io::AsyncReadExt;
        const PREBUFFER_BYTES: usize = 6 * 1024 * 1024;
        const PREBUFFER_TIMEOUT: std::time::Duration = std::time::Duration::from_secs(40);

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
        let handle = match resp {
            AddTorrentResponse::Added(_, h) => h,
            AddTorrentResponse::AlreadyManaged(_, h) => h,
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

        let file_id = if videos.len() == 1 {
            Some(videos[0].0)
        } else {
            let mut best: Option<(usize, u64)> = None;
            for (i, name, len) in &videos {
                if search::filename_matches_episode(name, episode) {
                    if best.map(|(_, l)| *len > l).unwrap_or(true) {
                        best = Some((*i, *len));
                    }
                }
            }
            best.map(|(i, _)| i)
        };
        let Some(file_id) = file_id else {
            let _ = session.delete(torrent_id.into(), false).await;
            return Err(format!("episode {} not found inside torrent", episode));
        };

        session
            .update_only_files(&handle, &std::iter::once(file_id).collect())
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

        Ok(Resolved { torrent_id, file_id })
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
    let mut vars = std::collections::HashMap::new();
    vars.insert("id".to_string(), serde_json::json!(media_id));
    vars.insert("type".to_string(), serde_json::json!("ANIME"));
    let detail_res: Result<crate::anilist::responses::MediaResponse, String> = state
        .anilist_client
        .execute(crate::anilist::queries::MEDIA_DETAIL_QUERY, vars)
        .await;
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
    let hour_ago = std::time::SystemTime::now() - std::time::Duration::from_secs(3600);
    for (path, mtime, size) in items {
        if total <= CACHE_CAP_BYTES {
            break;
        }
        if mtime > hour_ago {
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
        let cands = search::find_candidates(&client(), &titles, 1, false, false).await;
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
        let cands = search::find_candidates(&client(), &titles, 3, false, false).await;
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
            .resolve(&client(), 154587, 1, &titles, false, false, 13370)
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
