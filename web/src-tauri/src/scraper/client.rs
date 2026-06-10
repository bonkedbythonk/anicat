use serde::{Deserialize, Serialize};
use std::process::{Child, Command};
use std::sync::Arc;
use tokio::sync::RwLock;
use tokio::time::{sleep, Duration};

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
    pub is_m3u8: Option<bool>,
    pub headers: Option<std::collections::HashMap<String, String>>,
}

#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct AnimeInfo {
    pub title: String,
    pub episodes: Vec<Episode>,
}

#[derive(Clone)]
pub struct ScraperManager {
    process: Arc<RwLock<Option<Child>>>,
    port: Arc<RwLock<Option<u16>>>,
    http_client: reqwest::Client,
    python_path: String,
    scraper_script: String,
}

impl ScraperManager {
    pub fn new(http_client: reqwest::Client, python_path: String, scraper_script: String) -> Self {
        Self {
            process: Arc::new(RwLock::new(None)),
            port: Arc::new(RwLock::new(None)),
            http_client,
            python_path,
            scraper_script,
        }
    }

    pub async fn ensure_running(&self) -> Result<u16, String> {
        if let Some(port) = *self.port.read().await {
            return Ok(port);
        }

        let port = find_free_port()?;

        let child = Command::new(&self.python_path)
            .arg(&self.scraper_script)
            .arg("--port")
            .arg(port.to_string())
            .spawn()
            .map_err(|e| format!("Failed to start scraper: {}", e))?;

        *self.process.write().await = Some(child);
        *self.port.write().await = Some(port);

        // Wait for the service to be ready
        for _ in 0..20 {
            let url = format!("http://127.0.0.1:{}/health", port);
            if let Ok(resp) = self.http_client.get(&url).send().await {
                if resp.status().is_success() {
                    // Start idle monitor
                    let http_client = self.http_client.clone();
                    let process = self.process.clone();
                    let port_arc = self.port.clone();
                    tokio::spawn(async move {
                        idle_monitor(http_client, process, port_arc, port).await;
                    });
                    return Ok(port);
                }
            }
            sleep(Duration::from_millis(100)).await;
        }

        Err("Scraper failed to start within timeout".into())
    }

    pub async fn search(&self, query: &str) -> Result<Vec<AnimeRef>, String> {
        let port = self.ensure_running().await?;
        let url = format!("http://127.0.0.1:{}/search?query={}", port, urlencoding::encode(query));
        let resp = self
            .http_client
            .get(&url)
            .send()
            .await
            .map_err(|e| format!("Search request failed: {}", e))?;
        resp.json()
            .await
            .map_err(|e| format!("Failed to parse search results: {}", e))
    }

    pub async fn get_anime(&self, slug: &str) -> Result<AnimeInfo, String> {
        let port = self.ensure_running().await?;
        let url = format!("http://127.0.0.1:{}/get?slug={}", port, slug);
        let resp = self
            .http_client
            .get(&url)
            .send()
            .await
            .map_err(|e| format!("Get request failed: {}", e))?;
        resp.json()
            .await
            .map_err(|e| format!("Failed to parse anime info: {}", e))
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
            .send()
            .await
            .map_err(|e| format!("Streams request failed: {}", e))?;
        resp.json()
            .await
            .map_err(|e| format!("Failed to parse stream servers: {}", e))
    }
}

async fn idle_monitor(
    client: reqwest::Client,
    process: Arc<RwLock<Option<Child>>>,
    port_arc: Arc<RwLock<Option<u16>>>,
    port: u16,
) {
    let mut idle_seconds = 0u32;

    loop {
        sleep(Duration::from_secs(5)).await;

        // Check if process is still alive
        {
            let mut proc_guard = process.write().await;
            if let Some(ref mut child) = *proc_guard {
                match child.try_wait() {
                    Ok(Some(_)) => {
                        // Process exited
                        *proc_guard = None;
                        *port_arc.write().await = None;
                        return;
                    }
                    Ok(None) => {}
                    Err(_) => {
                        *proc_guard = None;
                        *port_arc.write().await = None;
                        return;
                    }
                }
            } else {
                *port_arc.write().await = None;
                return;
            }
        }

        // Check if service was recently used
        let health_url = format!("http://127.0.0.1:{}/last_used", port);
        let was_active = if let Ok(resp) = client.get(&health_url).send().await {
            if resp.status().is_success() {
                if let Ok(data) = resp.json::<serde_json::Value>().await {
                    data.get("seconds_since_last_use")
                        .and_then(|v| v.as_u64())
                        .unwrap_or(0)
                        < 10
                } else {
                    false
                }
            } else {
                false
            }
        } else {
            false
        };

        if !was_active {
            idle_seconds += 5;
            if idle_seconds >= 60 {
                log::info!("Scraper idle for 60s, terminating");
                let mut proc_guard = process.write().await;
                if let Some(ref mut child) = *proc_guard {
                    let _ = child.kill();
                    let _ = child.wait();
                }
                *proc_guard = None;
                *port_arc.write().await = None;
                return;
            }
        } else {
            idle_seconds = 0;
        }
    }
}

fn find_free_port() -> Result<u16, String> {
    use std::net::TcpListener;
    let listener =
        TcpListener::bind("127.0.0.1:0").map_err(|e| format!("Failed to find free port: {}", e))?;
    let port = listener
        .local_addr()
        .map_err(|e| format!("Failed to get port: {}", e))?
        .port();
    drop(listener);
    Ok(port)
}

// urlencoding is a simple encoding; for production use a proper crate
mod urlencoding {
    pub fn encode(s: &str) -> String {
        let mut result = String::with_capacity(s.len());
        for byte in s.bytes() {
            match byte {
                b'A'..=b'Z' | b'a'..=b'z' | b'0'..=b'9' | b'-' | b'_' | b'.' | b'~' => {
                    result.push(byte as char)
                }
                b' ' => result.push('+'),
                _ => {
                    result.push('%');
                    result.push_str(&format!("{:02X}", byte));
                }
            }
        }
        result
    }
}
