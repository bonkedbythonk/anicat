//! Where the server keeps its files, and the AniList token.

use std::path::{Path, PathBuf};

/// The data directory: `ANICAT_DATA_DIR` when set, otherwise the platform
/// default below.
pub fn data_dir() -> PathBuf {
    if let Some(dir) = std::env::var_os("ANICAT_DATA_DIR").filter(|v| !v.is_empty()) {
        return PathBuf::from(dir);
    }
    default_data_dir()
}

/// `%APPDATA%\Anicat`, the same file names the Mac app uses under
/// Application Support, so a registry can be carried between the two.
#[cfg(windows)]
fn default_data_dir() -> PathBuf {
    dirs::data_dir()
        .unwrap_or_else(std::env::temp_dir)
        .join("Anicat")
}

/// Never `Application Support/Anicat`: that is the Mac app's own registry
/// and download cache, and the owner runs that app on the same machine a
/// server is developed on. Two engines on one SQLite file and one librqbit
/// cache would each evict and pin files under the other.
#[cfg(not(windows))]
fn default_data_dir() -> PathBuf {
    dirs::data_dir()
        .unwrap_or_else(std::env::temp_dir)
        .join("Anicat-Server")
}

/// The TMDB proxy base URL. Compiled in from `ANICAT_TMDB_PROXY` as the Mac
/// package script does; the same variable at runtime wins, so a local build
/// made without it can still reach Films and TV. Without either, cinema
/// rows fail with no key and the Films and TV half of the page is empty.
pub fn tmdb_proxy() -> Option<String> {
    std::env::var("ANICAT_TMDB_PROXY")
        .ok()
        .or_else(|| option_env!("ANICAT_TMDB_PROXY").map(str::to_string))
        .map(|s| s.trim().to_string())
        .filter(|s| !s.is_empty())
}

pub fn config_path(data_dir: &Path) -> PathBuf {
    data_dir.join("config.json")
}

/// Reads the token the way the Mac app's `loadTokenFromConfigFile` does:
/// top-level `anilist_token`, then `api.anilist_token`, `api.token`,
/// `anilist.token`. The older shapes are what 5.x wrote, and a copied
/// config from one of those must still sign in.
pub fn load_token(data_dir: &Path) -> Option<String> {
    let text = std::fs::read_to_string(config_path(data_dir)).ok()?;
    let json: serde_json::Value = serde_json::from_str(&text).ok()?;
    let candidates = [
        json.get("anilist_token"),
        json.get("api").and_then(|a| a.get("anilist_token")),
        json.get("api").and_then(|a| a.get("token")),
        json.get("anilist").and_then(|a| a.get("token")),
    ];
    let token = candidates
        .into_iter()
        .flatten()
        .filter_map(|v| v.as_str())
        .map(str::trim)
        .find(|t| !t.is_empty())
        .map(str::to_string);
    token
}

/// Writes or clears the token, keeping every other key in the file. Writes
/// both `anilist_token` and `api.anilist_token` like `saveTokenToConfigFile`,
/// because the Tauri-era readers only looked under `api`.
pub fn save_token(data_dir: &Path, token: Option<&str>) -> std::io::Result<()> {
    let path = config_path(data_dir);
    let mut json = std::fs::read_to_string(&path)
        .ok()
        .and_then(|t| serde_json::from_str::<serde_json::Value>(&t).ok())
        .filter(|v| v.is_object())
        .unwrap_or_else(|| serde_json::json!({}));
    let obj = json.as_object_mut().expect("checked is_object above");
    let mut api = obj
        .get("api")
        .filter(|v| v.is_object())
        .cloned()
        .unwrap_or_else(|| serde_json::json!({}));
    let api_obj = api.as_object_mut().expect("checked is_object above");
    match token {
        Some(t) => {
            obj.insert("anilist_token".into(), t.into());
            api_obj.insert("anilist_token".into(), t.into());
        }
        None => {
            obj.remove("anilist_token");
            api_obj.remove("anilist_token");
            api_obj.remove("token");
        }
    }
    obj.insert("api".into(), api);
    std::fs::create_dir_all(data_dir)?;
    // Write-then-rename: a crash mid-write otherwise leaves a truncated file
    // that parses as nothing, and the viewer is silently signed out.
    let tmp = path.with_extension("json.tmp");
    write_private(&tmp, &serde_json::to_vec_pretty(&json).unwrap_or_default())?;
    std::fs::rename(tmp, path)
}

/// Creates the file readable by its owner only. The token is a bearer
/// credential for the viewer's AniList account, and `fs::write` leaves a new
/// file at the umask default (0644 on a Unix host). Windows needs nothing:
/// a file under `%APPDATA%` inherits that user's ACL.
fn write_private(path: &Path, bytes: &[u8]) -> std::io::Result<()> {
    use std::io::Write;
    // Removed first: the mode applies only when the file is created, and a
    // leftover temp file from a crashed save would keep its old one.
    let _ = std::fs::remove_file(path);
    let mut options = std::fs::OpenOptions::new();
    options.write(true).create_new(true);
    #[cfg(unix)]
    {
        use std::os::unix::fs::OpenOptionsExt;
        options.mode(0o600);
    }
    options.open(path)?.write_all(bytes)
}

#[cfg(all(test, unix))]
mod tests {
    use super::*;
    use std::os::unix::fs::PermissionsExt;

    #[test]
    fn the_token_file_is_never_readable_by_others() {
        let dir = std::env::temp_dir().join(format!("anicat-config-test-{}", std::process::id()));
        let _ = std::fs::remove_dir_all(&dir);
        // A temp file left at 0644 by an older build must not set the mode.
        std::fs::create_dir_all(&dir).unwrap();
        let stale = config_path(&dir).with_extension("json.tmp");
        std::fs::write(&stale, b"{}").unwrap();
        std::fs::set_permissions(&stale, std::fs::Permissions::from_mode(0o644)).unwrap();

        save_token(&dir, Some("secret")).unwrap();

        let mode = std::fs::metadata(config_path(&dir)).unwrap().permissions().mode();
        assert_eq!(mode & 0o777, 0o600);
        assert_eq!(load_token(&dir).as_deref(), Some("secret"));
        let _ = std::fs::remove_dir_all(&dir);
    }
}
