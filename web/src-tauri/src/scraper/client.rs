use serde::{Deserialize, Serialize};
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
}

#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct StreamServer {
    pub name: String,
    pub url: String,
    pub quality: Option<String>,
    #[serde(rename = "isM3U8", alias = "is_m3u8")]
    pub is_m3u8: Option<bool>,
    pub headers: Option<std::collections::HashMap<String, String>>,
}

#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct AnimeInfo {
    pub title: String,
    pub episodes: Vec<Episode>,
}

// ── Manager ───────────────────────────────────────────────

const IDLE_TIMEOUT_SECS: u64 = 60;
const READY_RETRY_MS: u64 = 100;
const MAX_READY_ATTEMPTS: u32 = 50;

struct ScraperProcess {
    child: Child,
    port: u16,
    last_used: Instant,
}

pub struct ScraperManager {
    process: Arc<Mutex<Option<ScraperProcess>>>,
    http_client: reqwest::Client,
    python_path: String,
    scraper_script: String,
}

impl Clone for ScraperManager {
    fn clone(&self) -> Self {
        Self {
            process: self.process.clone(),
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
            http_client,
            python_path,
            scraper_script,
        }
    }

    pub async fn search(&self, query: &str) -> Result<Vec<AnimeRef>, String> {
        let port = self.ensure_running().await?;
        let url = format!(
            "http://127.0.0.1:{}/search?query={}",
            port,
            percent_encode(query)
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

    pub async fn get_anime(&self, slug: &str) -> Result<AnimeInfo, String> {
        let port = self.ensure_running().await?;
        let url = format!("http://127.0.0.1:{}/get?slug={}", port, slug);
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
    ) -> Result<Vec<StreamServer>, String> {
        let port = self.ensure_running().await?;
        let url = format!(
            "http://127.0.0.1:{}/streams?slug={}&episode={}",
            port, slug, episode
        );
        let resp = self
            .http_client
            .get(&url)
            .timeout(Duration::from_secs(30))
            .send()
            .await
            .map_err(|e| format!("Scraper streams failed: {}", e))?;
        let body = resp.text().await.map_err(|e| e.to_string())?;
        serde_json::from_str(&body).map_err(|e| format!("Parse streams: {}", e))
    }

    pub async fn debug_streams(
        &self,
        slug: &str,
        episode: i32,
    ) -> Result<serde_json::Value, String> {
        let port = self.ensure_running().await?;
        let url = format!(
            "http://127.0.0.1:{}/debug/streams?slug={}&episode={}",
            port, slug, episode
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
                // Check if child is still alive
                let exited = sp.child.try_wait().map(|r| r.is_some()).unwrap_or(true);
                if !exited {
                    sp.last_used = Instant::now();
                    return Ok(sp.port);
                }
                // Process died — clean up
                *proc = None;
            }
        }

        // Start new process
        self.start_process().await
    }

    async fn start_process(&self) -> Result<u16, String> {
        let port = find_free_port()?;

        let mut cmd = Command::new(&self.python_path);
        if self.python_path.contains("uv") {
            cmd.arg("run").arg("python");
        }
        let mut child = cmd.arg(&self.scraper_script)
            .arg("--port")
            .arg(port.to_string())
            .stdout(std::process::Stdio::null())
            .stderr(std::process::Stdio::null())
            .spawn()
            .map_err(|e| format!("Failed to start scraper: {}", e))?;

        // Wait for readiness with backoff
        let mut delay_ms = READY_RETRY_MS;
        for attempt in 0..MAX_READY_ATTEMPTS {
            sleep(Duration::from_millis(delay_ms)).await;

            let health_url = format!("http://127.0.0.1:{}/health", port);
            match self.http_client.get(&health_url).timeout(Duration::from_secs(2)).send().await {
                Ok(resp) if resp.status().is_success() => {
                    let sp = ScraperProcess {
                        child,
                        port,
                        last_used: Instant::now(),
                    };
                    *self.process.lock().await = Some(sp);

                    // Spawn idle watchdog
                    let process = self.process.clone();
                    let http_client = self.http_client.clone();
                    tokio::spawn(async move {
                        idle_watchdog(process, http_client).await;
                    });

                    log::info!("Scraper ready on port {} (attempt {})", port, attempt + 1);
                    return Ok(port);
                }
                _ => {
                    // Increase delay on each attempt
                    delay_ms = (delay_ms * 2).min(2000);
                }
            }
        }

        // Kill the process if it didn't become ready
        let _ = child.kill();
        Err(format!(
            "Scraper failed to become ready within {} attempts",
            MAX_READY_ATTEMPTS
        ))
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
            if let Some(mut sp) = proc.take() {
                let _ = sp.child.kill();
                let _ = sp.child.wait();
            }
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

fn percent_encode(s: &str) -> String {
    let mut result = String::with_capacity(s.len());
    for byte in s.bytes() {
        match byte {
            b'A'..=b'Z' | b'a'..=b'z' | b'0'..=b'9' | b'-' | b'_' | b'.' | b'~' => {
                result.push(byte as char);
            }
            b' ' => result.push('+'),
            _ => result.push_str(&format!("%{:02X}", byte)),
        }
    }
    result
}
