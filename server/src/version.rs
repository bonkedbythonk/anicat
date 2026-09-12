//! The running version and whether a newer release is out. Same endpoint
//! and cadence as the Mac's `UpdateChecker`.

use std::path::Path;
use std::time::{SystemTime, UNIX_EPOCH};

use serde::{Deserialize, Serialize};

/// From version.txt, which `bump-version.sh` rewrites. Trimmed: the file
/// ends in a newline, and "6.0.1\n" never equals a tag's "6.0.1", so every
/// launch would have announced an update to the version already running.
pub fn current() -> &'static str {
    include_str!("../../version.txt").trim()
}

const ENDPOINT: &str = "https://api.github.com/repos/bonkedbythonk/anicat/releases/latest";

/// Once a day. GitHub rate-limits unauthenticated callers by IP, which on
/// a shared network is everyone behind it at once, and a page reload is not
/// a reason to spend a request.
const CHECK_INTERVAL_SECS: u64 = 24 * 60 * 60;

const CACHE_FILE: &str = "update-check.json";

#[derive(Debug, Clone, Default, Serialize, Deserialize)]
pub struct CachedCheck {
    pub checked_at: u64,
    pub latest_version: Option<String>,
    pub page_url: Option<String>,
}

#[derive(Debug, Serialize)]
pub struct VersionInfo {
    pub current: String,
    pub latest: Option<String>,
    pub page_url: Option<String>,
    pub update_available: bool,
    pub checked_at: u64,
}

#[derive(Deserialize)]
struct GithubRelease {
    tag_name: String,
    html_url: String,
}

fn now() -> u64 {
    SystemTime::now()
        .duration_since(UNIX_EPOCH)
        .map(|d| d.as_secs())
        .unwrap_or(0)
}

pub async fn check(http: &reqwest::Client, data_dir: &Path) -> VersionInfo {
    let path = data_dir.join(CACHE_FILE);
    let mut cached: CachedCheck = std::fs::read(&path)
        .ok()
        .and_then(|b| serde_json::from_slice(&b).ok())
        .unwrap_or_default();

    if now().saturating_sub(cached.checked_at) >= CHECK_INTERVAL_SECS {
        match fetch(http).await {
            Ok(release) => {
                cached.latest_version = Some(release.tag_name.trim_start_matches('v').to_string());
                cached.page_url = Some(release.html_url);
            }
            // The previous answer is kept. The attempt time is still
            // recorded, so an offline machine asks once a day and not on
            // every page load.
            Err(e) => log::warn!("update check failed: {e}"),
        }
        cached.checked_at = now();
        if let Ok(bytes) = serde_json::to_vec(&cached) {
            let _ = std::fs::write(&path, bytes);
        }
    }

    let current = current().to_string();
    let update_available = cached
        .latest_version
        .as_deref()
        .map(|latest| is_newer(latest, &current))
        .unwrap_or(false);
    VersionInfo {
        current,
        latest: cached.latest_version,
        page_url: cached.page_url,
        update_available,
        checked_at: cached.checked_at,
    }
}

async fn fetch(http: &reqwest::Client) -> Result<GithubRelease, String> {
    http.get(ENDPOINT)
        .header("Accept", "application/vnd.github+json")
        .send()
        .await
        .map_err(|e| e.to_string())?
        .error_for_status()
        .map_err(|e| e.to_string())?
        .json::<GithubRelease>()
        .await
        .map_err(|e| e.to_string())
}

/// Dotted numeric compare, as `UpdateChecker.isNewer`. A string compare
/// sorts "6.10.0" before "6.9.0" and a tenth minor release would read as
/// older than the ninth.
pub fn is_newer(candidate: &str, current: &str) -> bool {
    fn parts(s: &str) -> Vec<u64> {
        let core = s.split(['-', '+']).next().unwrap_or(s);
        core.split('.')
            .map(|p| p.chars().filter(char::is_ascii_digit).collect::<String>().parse().unwrap_or(0))
            .collect()
    }
    let (a, b) = (parts(candidate), parts(current));
    for i in 0..a.len().max(b.len()) {
        let (x, y) = (a.get(i).copied().unwrap_or(0), b.get(i).copied().unwrap_or(0));
        if x != y {
            return x > y;
        }
    }
    false
}

#[cfg(test)]
mod tests {
    use super::is_newer;

    #[test]
    fn compares_numerically() {
        assert!(is_newer("6.10.0", "6.9.0"));
        assert!(!is_newer("6.1", "6.1.0"));
        assert!(!is_newer("6.0.1", "6.0.1"));
        assert!(is_newer("7.0.0-beta", "6.9.9"));
    }
}
