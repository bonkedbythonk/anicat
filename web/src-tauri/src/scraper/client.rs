use serde::{Deserialize, Serialize};
use std::path::Path;
use std::process::{Child, Command};
use std::sync::Arc;
use tokio::sync::Mutex;
use tokio::time::{sleep, Duration, Instant};

#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct AnimeRef {
    pub id: String,
    pub title: String,
    pub year: Option<i32>,
}

#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct Episode {
    pub number: i32,
    pub title: Option<String>,
    pub image: Option<String>,
    #[serde(default)]
    pub download_status: Option<String>,
}

#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct StreamServer {
    pub name: String,
    pub url: String,
    pub quality: Option<String>,
    #[serde(rename = "isM3U8", alias = "is_m3u8")]
    pub is_m3u8: Option<bool>,
    pub headers: Option<std::collections::HashMap<String, String>>,
    pub group: Option<String>,
    /// External VTT sidecar (anineko's soft_sub/dub servers attach one via
    /// a query param instead of baking captions into the video).
    #[serde(default)]
    pub subtitle_url: Option<String>,
}

#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct AnimeInfo {
    pub title: String,
    pub episodes: Vec<Episode>,
}

/// How long the sidecar may sit idle before the watchdog kills it.
///
/// This has to stay **above** the provider's Cloudflare clearance TTL
/// (`_CF_COOKIE_TTL = 1500` in `scraper/anineko.py`). The `cf_clearance`
/// cookie, the solver holding it, and the `curl_cffi` session carrying it all
/// live inside this process, so killing the process throws the clearance away
/// no matter how much of its 25 minutes is left. At the old 120s, browsing for
/// three minutes and then pressing play meant the first anineko request 403'd
/// and had to launch headless Chrome to re-solve the challenge — several
/// seconds of dead time on the play path, repeatedly, mid-session.
///
/// Cost of the larger window is an idle Python process (tens of MB) sticking
/// around longer. Persisting the clearance to disk would let this drop back
/// down, but needs the solving Chrome version and a wall-clock timestamp
/// persisted alongside it or the rehydrated session fingerprint won't match.
const IDLE_TIMEOUT_SECS: u64 = 1800;
const READY_RETRY_MS: u64 = 100;
const MAX_READY_ATTEMPTS: u32 = 50;

struct ScraperProcess {
    child: Child,
    port: u16,
    last_used: Instant,
}

impl Drop for ScraperProcess {
    fn drop(&mut self) {
        // Kill the whole process tree when dropped — covers the idle watchdog
        // path and any normal teardown. The PyInstaller onefile bootloader
        // spawns a child, so a plain kill would orphan it (see kill_child_tree).
        crate::util::kill_child_tree(&mut self.child);
    }
}

type FailureNotifier = Box<dyn Fn(&str) + Send + Sync>;

/// Consecutive transport failures before a provider is benched.
const BREAKER_TRIP_AFTER: u32 = 3;
/// How long a benched provider is skipped before one request is let through to
/// see whether it recovered.
const BREAKER_COLD_FOR: Duration = Duration::from_secs(5 * 60);

/// Per-provider circuit breaker for the scraper request path.
///
/// A provider that is down costs the *full* timeout budget on every attempt —
/// 90s for a search, 30s for a stream fetch, and the play path issues several
/// of each before giving up and running the whole chain again for the fallback
/// provider. Benching it after a few consecutive failures turns that into an
/// instant error, so the fallback provider gets tried immediately.
///
/// Deliberately counts **only transport failures** (the sidecar unreachable,
/// the request erroring or timing out). A request that completes and returns
/// zero results is not evidence the provider is down: an episode that genuinely
/// isn't on the site would otherwise bench a perfectly healthy provider for
/// five minutes.
#[derive(Clone, Default)]
struct ProviderBreaker {
    inner: Arc<std::sync::Mutex<std::collections::HashMap<String, BreakerEntry>>>,
}

#[derive(Default)]
struct BreakerEntry {
    consecutive_failures: u32,
    tripped_at: Option<Instant>,
}

impl ProviderBreaker {
    /// `Err` with a human-readable reason when the provider is currently
    /// benched. Clears an expired bench on the way through, so the next request
    /// probes the provider for real.
    fn check(&self, provider: &str) -> Result<(), String> {
        let mut map = self.inner.lock().unwrap_or_else(|e| e.into_inner());
        let Some(entry) = map.get_mut(provider) else { return Ok(()) };
        let Some(tripped_at) = entry.tripped_at else { return Ok(()) };
        let elapsed = tripped_at.elapsed();
        if elapsed >= BREAKER_COLD_FOR {
            // Half-open: let this one through and judge the provider on it.
            entry.tripped_at = None;
            entry.consecutive_failures = 0;
            log::info!("[breaker] '{}' cooled off, trying it again", provider);
            return Ok(());
        }
        Err(format!(
            "{} is temporarily unavailable ({} consecutive failures; retrying in {}s)",
            provider,
            entry.consecutive_failures,
            (BREAKER_COLD_FOR - elapsed).as_secs()
        ))
    }

    fn record_success(&self, provider: &str) {
        let mut map = self.inner.lock().unwrap_or_else(|e| e.into_inner());
        map.remove(provider);
    }

    fn record_failure(&self, provider: &str) {
        let mut map = self.inner.lock().unwrap_or_else(|e| e.into_inner());
        let entry = map.entry(provider.to_string()).or_default();
        entry.consecutive_failures += 1;
        if entry.consecutive_failures >= BREAKER_TRIP_AFTER && entry.tripped_at.is_none() {
            entry.tripped_at = Some(Instant::now());
            log::warn!(
                "[breaker] benching '{}' for {}s after {} consecutive transport failures",
                provider,
                BREAKER_COLD_FOR.as_secs(),
                entry.consecutive_failures
            );
        }
    }
}

pub struct ScraperManager {
    process: Arc<Mutex<Option<ScraperProcess>>>,
    spawn_lock: tokio::sync::Mutex<()>,
    http_client: reqwest::Client,
    python_path: String,
    scraper_script: String,
    // Surfaces "the sidecar itself is broken" (spawn/health failure — not a
    // provider returning zero results) to the user. Fired once per breakage,
    // re-armed by a successful start so a later relapse notifies again.
    failure_notifier: Arc<std::sync::Mutex<Option<FailureNotifier>>>,
    failure_notified: Arc<std::sync::atomic::AtomicBool>,
    /// Skips requests to a provider that has been failing at transport level,
    /// so a dead site doesn't cost the full timeout budget on every play.
    breaker: ProviderBreaker,
}

impl Clone for ScraperManager {
    fn clone(&self) -> Self {
        Self {
            process: self.process.clone(),
            spawn_lock: tokio::sync::Mutex::new(()),
            http_client: self.http_client.clone(),
            python_path: self.python_path.clone(),
            scraper_script: self.scraper_script.clone(),
            failure_notifier: self.failure_notifier.clone(),
            failure_notified: self.failure_notified.clone(),
            breaker: self.breaker.clone(),
        }
    }
}

impl ScraperManager {
    pub fn new(
        http_client: reqwest::Client,
        python_path: String,
        scraper_script: String,
    ) -> Self {
        Self {
            process: Arc::new(Mutex::new(None)),
            spawn_lock: tokio::sync::Mutex::new(()),
            http_client,
            python_path,
            scraper_script,
            failure_notifier: Arc::new(std::sync::Mutex::new(None)),
            failure_notified: Arc::new(std::sync::atomic::AtomicBool::new(false)),
            breaker: ProviderBreaker::default(),
        }
    }

    pub fn set_failure_notifier(&self, f: impl Fn(&str) + Send + Sync + 'static) {
        if let Ok(mut guard) = self.failure_notifier.lock() {
            *guard = Some(Box::new(f));
        }
    }

    fn notify_fatal(&self, detail: &str) {
        use std::sync::atomic::Ordering;
        if self.failure_notified.swap(true, Ordering::SeqCst) {
            return; // already notified for this breakage
        }
        log::error!("[scraper] Sidecar is broken: {}", detail);
        if let Ok(guard) = self.failure_notifier.lock() {
            if let Some(ref notify) = *guard {
                notify(
                    "Scraper failed to start — streaming providers are unavailable. \
                     Torrents still work. Please report this issue.",
                );
            }
        }
    }

    pub fn python_path(&self) -> &str {
        &self.python_path
    }

    /// Spawns the scraper sidecar ahead of the first search, so the process's
    /// startup cost (cold-start extraction, first-run OS binary scan, etc.)
    /// lands during app launch instead of stalling the user's first search.
    /// Best-effort: a failure here just means the first real request pays the
    /// startup cost (and reports it) as before.
    pub async fn prewarm(&self) {
        if let Err(e) = self.ensure_running().await {
            log::warn!("[scraper] Prewarm failed, will retry on first request: {}", e);
        }
    }

    /// Synchronously kill the running scraper (and its process tree). Called
    /// from the Tauri exit handler, where Tauri tears the app down via
    /// `process::exit` and would otherwise skip the async Drop path, leaving
    /// the scraper orphaned after the window closes.
    pub fn shutdown_blocking(&self) {
        // best-effort: if the watchdog momentarily holds the lock, the OS will
        // still reap the child when our process group ends on Unix; on Windows
        // the explicit kill below is what matters and the lock is virtually
        // never held at exit.
        if let Ok(mut guard) = self.process.try_lock() {
            // Dropping the ScraperProcess runs kill_child_tree via Drop.
            let _ = guard.take();
        }
    }

    pub async fn search(&self, query: &str, provider: &str) -> Result<Vec<AnimeRef>, String> {
        log::info!("Searching scraper: query='{}', provider={}", query, provider);
        self.breaker.check(provider)?;
        let port = self.ensure_running().await.inspect_err(|_| self.breaker.record_failure(provider))?;
        let url = format!(
            "http://127.0.0.1:{}/search?query={}&provider={}",
            port,
            crate::util::percent_encode(query),
            provider
        );
        let resp = self
            .http_client
            .get(&url)
            .timeout(Duration::from_secs(90))
            .send()
            .await
            .map_err(|e| {
                log::error!("Scraper search request failed (query={}, provider={}): {}", query, provider, e);
                self.breaker.record_failure(provider);
                format!("Scraper search failed: {}", e)
            })?;
        // The request completed. Whether it found anything is the provider's
        // business, not the breaker's — see ProviderBreaker.
        self.breaker.record_success(provider);
        let body = resp.text().await.map_err(|e| e.to_string())?;
        match serde_json::from_str::<Vec<AnimeRef>>(&body) {
            Ok(results) => {
                log::info!("Scraper search returned {} results", results.len());
                Ok(results)
            }
            Err(e) => {
                log::error!("Failed to parse scraper search response: {}, error: {}", body, e);
                Err(format!("Parse search: {}", e))
            }
        }
    }

    pub async fn get_anime(&self, slug: &str, provider: &str) -> Result<AnimeInfo, String> {
        let port = self.ensure_running().await?;
        let url = format!("http://127.0.0.1:{}/get?slug={}&provider={}", port, slug, provider);
        let resp = self
            .http_client
            .get(&url)
            .timeout(Duration::from_secs(30))
            .send()
            .await
            .map_err(|e| {
                log::error!("Scraper get_anime request failed (slug={}, provider={}): {}", slug, provider, e);
                format!("Scraper get_anime failed: {}", e)
            })?;
        let body = resp.text().await.map_err(|e| e.to_string())?;
        serde_json::from_str(&body).map_err(|e| {
            log::error!("Failed to parse scraper get_anime response: {}, error: {}", body, e);
            format!("Parse anime: {}", e)
        })
    }

    pub async fn get_streams(
        &self,
        slug: &str,
        episode: i32,
        provider: &str,
    ) -> Result<Vec<StreamServer>, String> {
        log::info!("Requesting streams from scraper: provider={}, slug={}, episode={}", provider, slug, episode);
        self.breaker.check(provider)?;
        let port = self.ensure_running().await.inspect_err(|_| self.breaker.record_failure(provider))?;
        let url = format!(
            "http://127.0.0.1:{}/streams?slug={}&episode={}&provider={}",
            port, slug, episode, provider
        );
        let resp = self
            .http_client
            .get(&url)
            .timeout(Duration::from_secs(30))
            .send()
            .await
            .map_err(|e| {
                log::error!("Scraper streams request failed (slug={}, episode={}, provider={}): {}", slug, episode, provider, e);
                self.breaker.record_failure(provider);
                format!("Scraper streams failed: {}", e)
            })?;
        // Completed request: a provider that answers "no streams for this
        // episode" is up, not down.
        self.breaker.record_success(provider);
        let body = resp.text().await.map_err(|e| e.to_string())?;
        match serde_json::from_str::<Vec<StreamServer>>(&body) {
            Ok(servers) => {
                log::info!("Scraper found {} stream servers for episode {}", servers.len(), episode);
                Ok(servers)
            }
            Err(e) => {
                log::error!("Failed to parse scraper streams response: {}, error: {}", body, e);
                Err(format!("Parse streams: {}", e))
            }
        }
    }

    pub async fn search_manga(&self, query: &str) -> Result<Vec<AnimeRef>, String> {
        let port = self.ensure_running().await?;
        let url = format!(
            "http://127.0.0.1:{}/manga/search?query={}",
            port,
            crate::util::percent_encode(query)
        );
        let resp = self
            .http_client
            .get(&url)
            .timeout(Duration::from_secs(90))
            .send()
            .await
            .map_err(|e| {
                log::error!("Scraper manga search request failed (query={}): {}", query, e);
                format!("Scraper search failed: {}", e)
            })?;
        let body = resp.text().await.map_err(|e| e.to_string())?;
        serde_json::from_str(&body).map_err(|e| {
            log::error!("Failed to parse scraper manga search response: {}, error: {}", body, e);
            format!("Parse search: {}", e)
        })
    }

    pub async fn get_manga(&self, slug: &str) -> Result<AnimeInfo, String> {
        let port = self.ensure_running().await?;
        let url = format!(
            "http://127.0.0.1:{}/manga/get?slug={}",
            port,
            crate::util::percent_encode(slug)
        );
        let resp = self
            .http_client
            .get(&url)
            .timeout(Duration::from_secs(30))
            .send()
            .await
            .map_err(|e| {
                log::error!("Scraper get_manga request failed (slug={}): {}", slug, e);
                format!("Scraper get_manga failed: {}", e)
            })?;
        let body = resp.text().await.map_err(|e| e.to_string())?;
        serde_json::from_str(&body).map_err(|e| {
            log::error!("Failed to parse scraper get_manga response: {}, error: {}", body, e);
            format!("Parse manga: {}", e)
        })
    }

    pub async fn get_chapter_pages(
        &self,
        slug: &str,
        chapter: &str,
    ) -> Result<serde_json::Value, String> {
        let port = self.ensure_running().await?;
        let url = format!(
            "http://127.0.0.1:{}/manga/chapter?slug={}&chapter={}",
            port,
            crate::util::percent_encode(slug),
            crate::util::percent_encode(chapter)
        );
        let resp = self
            .http_client
            .get(&url)
            .timeout(Duration::from_secs(45))
            .send()
            .await
            .map_err(|e| {
                log::error!("Scraper get_chapter_pages request failed (slug={}, chapter={}): {}", slug, chapter, e);
                format!("Scraper get_chapter_pages failed: {}", e)
            })?;
        let body = resp.text().await.map_err(|e| e.to_string())?;
        serde_json::from_str(&body).map_err(|e| {
            log::error!("Failed to parse scraper chapter pages response: {}, error: {}", body, e);
            format!("Parse chapter pages: {}", e)
        })
    }

    pub async fn debug_streams(
        &self,
        slug: &str,
        episode: i32,
        provider: &str,
    ) -> Result<serde_json::Value, String> {
        let port = self.ensure_running().await?;
        let url = format!(
            "http://127.0.0.1:{}/debug/streams?slug={}&episode={}&provider={}",
            port, slug, episode, provider
        );
        let resp = self
            .http_client
            .get(&url)
            .timeout(Duration::from_secs(60))
            .send()
            .await
            .map_err(|e| {
                log::error!("Scraper debug_streams request failed (slug={}, episode={}, provider={}): {}", slug, episode, provider, e);
                format!("Debug streams request failed: {}", e)
            })?;
        let body = resp.text().await.map_err(|e| e.to_string())?;
        serde_json::from_str(&body).map_err(|e| {
            log::error!("Failed to parse scraper debug_streams response: {}, error: {}", body, e);
            format!("Parse debug response: {}", e)
        })
    }

    async fn ensure_running(&self) -> Result<u16, String> {
        {
            let mut proc = self.process.lock().await;
            if let Some(ref mut sp) = *proc {
                let exited = sp.child.try_wait().map(|r| r.is_some()).unwrap_or(true);
                if !exited {
                    sp.last_used = Instant::now();
                    return Ok(sp.port);
                }
                *proc = None;
            }
        }

        let _lock = self.spawn_lock.lock().await;

        {
            let mut proc = self.process.lock().await;
            if let Some(ref mut sp) = *proc {
                let exited = sp.child.try_wait().map(|r| r.is_some()).unwrap_or(true);
                if !exited {
                    sp.last_used = Instant::now();
                    return Ok(sp.port);
                }
                *proc = None;
            }
        }

        match self.start_process().await {
            Ok(port) => {
                // A healthy start re-arms the one-shot failure notification.
                self.failure_notified
                    .store(false, std::sync::atomic::Ordering::SeqCst);
                Ok(port)
            }
            Err(e) => {
                self.notify_fatal(&e);
                Err(e)
            }
        }
    }

    async fn start_process(&self) -> Result<u16, String> {
        let port = find_free_port()?;
        let script_dir = Path::new(&self.scraper_script).parent().unwrap_or(Path::new("."));

        // Bundled standalone binary — run directly, no Python wrapper
        let mut cmd = if self.python_path.is_empty() {
            #[cfg(unix)]
            {
                use std::os::unix::fs::PermissionsExt;
                if let Ok(metadata) = std::fs::metadata(&self.scraper_script) {
                    let mut perms = metadata.permissions();
                    if perms.mode() & 0o111 == 0 {
                        perms.set_mode(0o755);
                        let _ = std::fs::set_permissions(&self.scraper_script, perms);
                        log::info!("[scraper] Set executable permissions for standalone binary");
                    }
                }
            }
            let mut c = Command::new(&self.scraper_script);
            c.arg("--port").arg(port.to_string());
            c
        } else {
            let mut c = Command::new(&self.python_path);
            if self.python_path.contains("uv") {
                c.arg("run").arg("python");
            }
            c.arg(&self.scraper_script).arg("--port").arg(port.to_string());
            c
        };
        crate::util::suppress_console(&mut cmd);
        cmd.current_dir(script_dir);

        log::info!(
            "[scraper] Spawning process: python_path='{}', script='{}', port={}, current_dir={:?}",
            self.python_path,
            self.scraper_script,
            port,
            script_dir
        );

        start_and_wait(cmd, port, &self.process, &self.http_client).await
    }
}

async fn idle_watchdog(
    process: Arc<Mutex<Option<ScraperProcess>>>,
    _client: reqwest::Client,
) {
    loop {
        sleep(Duration::from_secs(5)).await;

        let mut proc = process.lock().await;
        let should_kill = if let Some(ref mut sp) = *proc {
            if let Ok(Some(_status)) = sp.child.try_wait() {
                true
            } else {
                sp.last_used.elapsed().as_secs() >= IDLE_TIMEOUT_SECS
            }
        } else {
            return;
        };

        if should_kill {
            log::info!("Stopping idle scraper (pid={})", if let Some(ref sp) = *proc { sp.child.id() } else { 0 });
            // Dropping the taken ScraperProcess runs kill_child_tree via Drop,
            // tearing down the bootloader and its extracted child together.
            let _ = proc.take();
            return;
        }
    }
}

fn find_free_port() -> Result<u16, String> {
    let listener = std::net::TcpListener::bind("127.0.0.1:0")
        .map_err(|e| format!("No free port: {}", e))?;
    listener.local_addr().map(|a| a.port()).map_err(|e| e.to_string())
}

async fn start_and_wait(
    mut cmd: Command,
    port: u16,
    process: &Arc<Mutex<Option<ScraperProcess>>>,
    http_client: &reqwest::Client,
) -> Result<u16, String> {
    let mut child = cmd
        .stdout(std::process::Stdio::null())
        .stderr(std::process::Stdio::piped())
        .spawn()
        .map_err(|e| format!("Failed to start scraper: {}", e))?;

    let stderr = child.stderr.take();
    if let Some(stderr) = stderr {
        std::thread::spawn(move || {
            use std::io::{BufRead, BufReader};
            let reader = BufReader::new(stderr);
            for line in reader.lines().map_while(Result::ok) {
                if !line.trim().is_empty() {
                    log::warn!("[scraper-py] {}", line);
                }
            }
        });
    }

    let spawn_start = Instant::now();
    let mut delay_ms = READY_RETRY_MS;
    for attempt in 0..MAX_READY_ATTEMPTS {
        sleep(Duration::from_millis(delay_ms)).await;
        let health_url = format!("http://127.0.0.1:{}/health", port);
        match http_client.get(&health_url).timeout(Duration::from_secs(2)).send().await {
            Ok(resp) if resp.status().is_success() => {
                let mut proc_guard = process.lock().await;
                if proc_guard.is_some() {
                    let _ = child.kill();
                    return Ok(proc_guard.as_ref().map(|s| s.port).unwrap_or(port));
                }
                let sp = ScraperProcess { child, port, last_used: Instant::now() };
                *proc_guard = Some(sp);
                drop(proc_guard);
                let p = process.clone();
                let c = http_client.clone();
                tokio::spawn(async move { idle_watchdog(p, c).await; });
                // Elapsed, not just the attempt count: a cold sidecar spawn is
                // one of the stages that shows up as "pressing play was slow",
                // and the resolve summary line can't see inside this call.
                log::info!(
                    "[resolve] sidecar cold-start ready on port {} in {}ms (attempt {})",
                    port,
                    spawn_start.elapsed().as_millis(),
                    attempt + 1
                );
                return Ok(port);
            }
            _ => { delay_ms = (delay_ms * 2).min(2000); }
        }
    }
    let _ = child.kill();
    Err(format!(
        "Scraper failed to become ready within {} attempts. Check logs above for details.",
        MAX_READY_ATTEMPTS
    ))
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn breaker_trips_only_after_consecutive_failures() {
        let breaker = ProviderBreaker::default();
        assert!(breaker.check("anineko").is_ok());
        for _ in 0..BREAKER_TRIP_AFTER - 1 {
            breaker.record_failure("anineko");
            assert!(breaker.check("anineko").is_ok(), "should not bench before the threshold");
        }
        breaker.record_failure("anineko");
        assert!(breaker.check("anineko").is_err(), "should be benched at the threshold");
    }

    #[test]
    fn a_success_resets_the_failure_streak() {
        let breaker = ProviderBreaker::default();
        // Two failures then a success must not leave the provider one failure
        // from being benched — the streak has to be *consecutive*, or an
        // intermittently flaky site eventually benches itself.
        breaker.record_failure("anineko");
        breaker.record_failure("anineko");
        breaker.record_success("anineko");
        breaker.record_failure("anineko");
        assert!(breaker.check("anineko").is_ok());
    }

    #[test]
    fn benching_one_provider_leaves_the_others_alone() {
        let breaker = ProviderBreaker::default();
        for _ in 0..BREAKER_TRIP_AFTER {
            breaker.record_failure("anineko");
        }
        assert!(breaker.check("anineko").is_err());
        // The whole point of benching a provider is to reach the fallback
        // faster, so the fallback must not be benched along with it.
        assert!(breaker.check("nyaa").is_ok());
    }

    #[tokio::test]
    #[ignore = "integration test: needs the scraper binary and network; run with --ignored"]
    async fn test_search() {
        let _ = env_logger::builder().is_test(true).try_init();
        let http_client = reqwest::Client::new();
        let python_path = "uv".to_string();
        let scraper_script = std::path::Path::new(env!("CARGO_MANIFEST_DIR"))
            .join("../../scraper/main.py")
            .to_string_lossy()
            .to_string();

        let manager = ScraperManager::new(http_client, python_path, scraper_script);
        let results = manager.search("The Ramparts of Ice", "mkissa").await.unwrap();
        println!("TEST_SEARCH_RESULTS: {:?}", results);
        assert!(!results.is_empty());
    }
}
