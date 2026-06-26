use serde::{Deserialize, Serialize};
use std::path::Path;
use std::process::{Child, Command};
use std::sync::Arc;
use tokio::sync::Mutex;
use tokio::time::{sleep, Duration, Instant};

// ── Public types ──────────────────────────────────────────

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
}

#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct AnimeInfo {
    pub title: String,
    pub episodes: Vec<Episode>,
}

// ── Manager ───────────────────────────────────────────────

const IDLE_TIMEOUT_SECS: u64 = 120;
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

pub struct ScraperManager {
    process: Arc<Mutex<Option<ScraperProcess>>>,
    spawn_lock: tokio::sync::Mutex<()>,
    http_client: reqwest::Client,
    python_path: String,
    scraper_script: String,
}

impl Clone for ScraperManager {
    fn clone(&self) -> Self {
        Self {
            process: self.process.clone(),
            spawn_lock: tokio::sync::Mutex::new(()),
            http_client: self.http_client.clone(),
            python_path: self.python_path.clone(),
            scraper_script: self.scraper_script.clone(),
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
        }
    }

    pub fn python_path(&self) -> &str {
        &self.python_path
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
        let port = self.ensure_running().await?;
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
            .map_err(|e| format!("Scraper search failed: {}", e))?;
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
            .map_err(|e| format!("Scraper get_anime failed: {}", e))?;
        let body = resp.text().await.map_err(|e| e.to_string())?;
        serde_json::from_str(&body).map_err(|e| format!("Parse anime: {}", e))
    }

    pub async fn get_streams(
        &self,
        slug: &str,
        episode: i32,
        provider: &str,
    ) -> Result<Vec<StreamServer>, String> {
        log::info!("Requesting streams from scraper: provider={}, slug={}, episode={}", provider, slug, episode);
        let port = self.ensure_running().await?;
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
            .map_err(|e| format!("Scraper streams failed: {}", e))?;
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
            .map_err(|e| format!("Scraper search failed: {}", e))?;
        let body = resp.text().await.map_err(|e| e.to_string())?;
        serde_json::from_str(&body).map_err(|e| format!("Parse search: {}", e))
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
            .map_err(|e| format!("Scraper get_manga failed: {}", e))?;
        let body = resp.text().await.map_err(|e| e.to_string())?;
        serde_json::from_str(&body).map_err(|e| format!("Parse manga: {}", e))
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
            .map_err(|e| format!("Scraper get_chapter_pages failed: {}", e))?;
        let body = resp.text().await.map_err(|e| e.to_string())?;
        serde_json::from_str(&body).map_err(|e| format!("Parse chapter pages: {}", e))
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
            .map_err(|e| format!("Debug streams request failed: {}", e))?;
        let body = resp.text().await.map_err(|e| e.to_string())?;
        serde_json::from_str(&body).map_err(|e| format!("Parse debug response: {}", e))
    }

    // ── Lifecycle ──────────────────────────────────────

    async fn ensure_running(&self) -> Result<u16, String> {
        // Check if existing process is alive
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

        // Serialize spawns: only one thread starts a new process
        let _lock = self.spawn_lock.lock().await;

        // Double-check after acquiring lock (another thread may have started it)
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

        self.start_process().await
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

// ── Idle watchdog ─────────────────────────────────────────

async fn idle_watchdog(
    process: Arc<Mutex<Option<ScraperProcess>>>,
    _client: reqwest::Client,
) {
    loop {
        sleep(Duration::from_secs(5)).await;

        let mut proc = process.lock().await;
        let should_kill = if let Some(ref mut sp) = *proc {
            // Check if child exited on its own
            if let Ok(Some(_status)) = sp.child.try_wait() {
                true
            } else {
                // Check idle time
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

// ── Helpers ───────────────────────────────────────────────

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
                log::info!("Scraper ready on port {} (attempt {})", port, attempt + 1);
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

    #[tokio::test]
    #[ignore = "integration test: needs the scraper binary and network; run with --ignored"]
    async fn test_search() {
        let _ = env_logger::builder().is_test(true).try_init();
        let http_client = reqwest::Client::new();
        let python_path = "uv".to_string();
        let scraper_script = "/Users/thomas/Documents/randomcode/personal/anicat/scraper/main.py".to_string();

        let manager = ScraperManager::new(http_client, python_path, scraper_script);
        let results = manager.search("The Ramparts of Ice", "allanime").await.unwrap();
        println!("TEST_SEARCH_RESULTS: {:?}", results);
        assert!(!results.is_empty());
    }
}
