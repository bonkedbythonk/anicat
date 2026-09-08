use std::collections::HashMap;
use std::sync::{Arc, Mutex};
use std::time::{Duration, Instant};

use serde_json::Value;

const MAX_ENTRIES: usize = 500;
const PRUNE_EVERY_N_INSERTS: usize = 100;

/// How long an expired entry stays around as a stale fallback. When AniList
/// is down or rate-limiting, serving yesterday's home rows beats a blank
/// screen — `get` still never returns expired data on the happy path.
const STALE_GRACE: Duration = Duration::from_secs(24 * 3600);

#[derive(Clone)]
pub struct AniListCache {
    entries: Arc<Mutex<HashMap<String, (Value, Instant)>>>,
    insert_count: Arc<std::sync::atomic::AtomicUsize>,
    /// Write-through copy of `entries`, so a cold launch starts from the
    /// previous run's rows instead of refetching them. `None` for the
    /// in-memory cache tests and the fallback when the file cannot be
    /// opened. The memory map stays the only thing reads consult; the disk
    /// is loaded once in `persistent` and written on every mutation.
    disk: Arc<Mutex<Option<rusqlite::Connection>>>,
}

impl Default for AniListCache {
    fn default() -> Self {
        Self::new()
    }
}

impl AniListCache {
    pub fn new() -> Self {
        Self {
            entries: Arc::new(Mutex::new(HashMap::new())),
            insert_count: Arc::new(std::sync::atomic::AtomicUsize::new(0)),
            disk: Arc::new(Mutex::new(None)),
        }
    }

    /// A cache backed by a SQLite file. Every cold launch used to refetch
    /// every home row (user list per status, trending, discover, profile,
    /// schedule: a dozen requests in the first second against AniList's
    /// 90/min cap, 30/min in its degraded mode) because the previous
    /// process's cache died with it; the Swift home snapshot hid the
    /// latency but saved none of the requests. Rows are reloaded with
    /// their TTL recomputed from when they were stored, so a row that was
    /// fresh for another hour when the app quit is still fresh for that
    /// hour, and one older than TTL plus `STALE_GRACE` is dropped.
    pub fn persistent(path: &std::path::Path) -> Self {
        let cache = Self::new();
        let conn = match rusqlite::Connection::open(path) {
            Ok(c) => c,
            Err(e) => {
                log::warn!("catalog cache: could not open {}: {e}; running in memory only", path.display());
                return cache;
            }
        };
        let setup = conn.execute_batch(
            "PRAGMA journal_mode = WAL;
             CREATE TABLE IF NOT EXISTS entries (
                 key TEXT PRIMARY KEY,
                 cmd TEXT NOT NULL,
                 value TEXT NOT NULL,
                 stored_at INTEGER NOT NULL
             );",
        );
        if let Err(e) = setup {
            log::warn!("catalog cache: schema setup failed: {e}; running in memory only");
            return cache;
        }
        let now_unix = unix_now();
        let now = Instant::now();
        let mut loaded = 0usize;
        let mut dropped = Vec::new();
        {
            let mut stmt = match conn.prepare("SELECT key, cmd, value, stored_at FROM entries") {
                Ok(s) => s,
                Err(e) => {
                    log::warn!("catalog cache: read failed: {e}; running in memory only");
                    return cache;
                }
            };
            let rows = stmt.query_map([], |r| {
                Ok((r.get::<_, String>(0)?, r.get::<_, String>(1)?, r.get::<_, String>(2)?, r.get::<_, i64>(3)?))
            });
            let Ok(rows) = rows else { return cache };
            let mut entries = cache.entries.lock().unwrap();
            for row in rows.flatten() {
                let (key, cmd, value, stored_at) = row;
                let age = Duration::from_secs(now_unix.saturating_sub(stored_at).max(0) as u64);
                let ttl = Self::ttl(&cmd);
                if age >= ttl + STALE_GRACE {
                    dropped.push(key);
                    continue;
                }
                let Ok(value) = serde_json::from_str::<Value>(&value) else {
                    dropped.push(key);
                    continue;
                };
                // Instant has no past: an already-expired row (still inside
                // the stale grace) gets an expiry of "now", which `get`
                // treats as expired and `get_stale` still serves.
                let expires = if age < ttl { now + (ttl - age) } else { now };
                entries.insert(key, (value, expires));
                loaded += 1;
            }
        }
        for key in &dropped {
            let _ = conn.execute("DELETE FROM entries WHERE key = ?1", rusqlite::params![key]);
        }
        log::info!(
            "catalog cache: loaded {loaded} rows from {} ({} expired rows dropped)",
            path.display(),
            dropped.len()
        );
        *cache.disk.lock().unwrap() = Some(conn);
        cache
    }

    fn disk_put(&self, key: &str, cmd: &str, value: &Value) {
        let guard = self.disk.lock().unwrap();
        let Some(conn) = guard.as_ref() else { return };
        let Ok(text) = serde_json::to_string(value) else { return };
        if let Err(e) = conn.execute(
            "INSERT INTO entries (key, cmd, value, stored_at) VALUES (?1, ?2, ?3, ?4)
             ON CONFLICT(key) DO UPDATE SET cmd = excluded.cmd, value = excluded.value, stored_at = excluded.stored_at",
            rusqlite::params![key, cmd, text, unix_now()],
        ) {
            log::warn!("catalog cache: write failed for {key}: {e}");
        }
    }

    /// Rewrites a row's value in place after an in-memory patch
    /// (`update_user_list_progress`, `remove_from_user_list_by_entry_id`)
    /// without touching `stored_at`, so the patch does not extend the row's
    /// life.
    fn disk_patch(&self, key: &str, value: &Value) {
        let guard = self.disk.lock().unwrap();
        let Some(conn) = guard.as_ref() else { return };
        let Ok(text) = serde_json::to_string(value) else { return };
        let _ = conn.execute(
            "UPDATE entries SET value = ?2 WHERE key = ?1",
            rusqlite::params![key, text],
        );
    }

    fn disk_delete_prefix(&self, prefix: &str) {
        let guard = self.disk.lock().unwrap();
        let Some(conn) = guard.as_ref() else { return };
        let _ = conn.execute(
            "DELETE FROM entries WHERE key = ?1 OR key LIKE ?2",
            rusqlite::params![prefix, format!("{prefix}|%")],
        );
    }

    fn disk_delete_keys(&self, keys: &[String]) {
        let guard = self.disk.lock().unwrap();
        let Some(conn) = guard.as_ref() else { return };
        for key in keys {
            let _ = conn.execute("DELETE FROM entries WHERE key = ?1", rusqlite::params![key]);
        }
    }

    pub fn key(cmd: &str, args: &[(&str, &str)]) -> String {
        let mut s = String::from(cmd);
        for (k, v) in args {
            s.push('|');
            s.push_str(k);
            s.push('=');
            s.push_str(v);
        }
        s
    }

    fn ttl(cmd: &str) -> Duration {
        match cmd {
            "get_trending"
            | "get_seasonal"
            | "get_upcoming"
            | "get_smart_playlist"
            | "get_discover" => Duration::from_secs(6 * 3600),
            "get_user_list" => Duration::from_secs(15 * 60),
            // A week's calendar is up to ten requests, and what it says only
            // changes when a broadcaster moves a slot.
            "get_airing_schedule" => Duration::from_secs(30 * 60),
            // Held far longer than the list it is derived from: the row set
            // is keyed by the seed ids, so a list change that does not move
            // the viewer's top six leaves this entry correct anyway.
            "viewer_recommendations" => Duration::from_secs(6 * 3600),
            "get_user_profile" => Duration::from_secs(3600),
            "get_notifications" => Duration::from_secs(5 * 60),
            // Media metadata (title, synonyms, episode count, MAL id) is
            // effectively static; characters never change. Both are fetched
            // repeatedly for the same id across a single open+watch flow.
            "media_detail" => Duration::from_secs(60 * 60),
            // Same lifetime as media_detail: it's fetched alongside it and
            // changes on the same cadence (a new episode airing).
            "anizip_meta" => Duration::from_secs(60 * 60),
            // An AniList id's MAL id never changes once it is known, so a
            // hit is held far longer than the detail record it rides along
            // with — the point is that a title is looked up once, not once
            // an hour.
            "jikan_mal_id" => Duration::from_secs(7 * 24 * 3600),
            // A miss needs its own cmd, not just its own value: `ttl` is a
            // pure function of the cmd, and `persistent` recomputes every
            // reloaded row's expiry from it. Sharing "jikan_mal_id" would
            // pin a miss for a week — which is wrong for the exact case
            // this fallback exists for, a show whose MAL entry is being
            // created right now. Short enough to catch up the same day,
            // long enough that reopening a detail page costs nothing.
            "jikan_mal_id_miss" => Duration::from_secs(6 * 3600),
            "get_media_characters" => Duration::from_secs(6 * 3600),
            "get_media_discussions" => Duration::from_secs(30 * 60),
            // A bio and a filmography change about as often as a season
            // announcement, and both pages are re-entered constantly:
            // tapping through a cast list is a walk between them.
            "character_detail" => Duration::from_secs(6 * 3600),
            "staff_detail" => Duration::from_secs(6 * 3600),
            "studio_detail" => Duration::from_secs(6 * 3600),
            // Forum content is the one live thing here. A thread on an airing
            // show gains replies while its page is open, and someone who
            // posts a comment and reopens the thread must not be handed the
            // copy from before they posted.
            "thread_detail" => Duration::from_secs(10 * 60),
            "thread_comments" => Duration::from_secs(5 * 60),
            // Search results are stable within a session; the real churn is
            // unique queries while typing, which no cache helps (debounce
            // does). This mainly spares repeats/back-navigation.
            "search_media" => Duration::from_secs(10 * 60),
            // TMDB's own lists turn over slowly (trending is weekly, popular
            // barely moves day to day), and a detail record is near-static.
            "tmdb_row" => Duration::from_secs(6 * 3600),
            "tmdb_search" => Duration::from_secs(10 * 60),
            "tmdb_detail" => Duration::from_secs(24 * 3600),
            // An episode list changes when a season airs, not day to day, but
            // it costs one request per season so it is worth holding longer
            // than a detail record.
            "tmdb_episodes" => Duration::from_secs(24 * 3600),
            _ => Duration::from_secs(60),
        }
    }

    pub fn get(&self, key: &str) -> Option<Value> {
        let entries = self.entries.lock().unwrap();
        if let Some((value, expires)) = entries.get(key) {
            if Instant::now() < *expires {
                return Some(value.clone());
            }
        }
        None
    }

    /// Like `get`, but also returns entries past their TTL (within
    /// STALE_GRACE, enforced by `prune`). Only for the degraded path where
    /// the live AniList fetch already failed.
    pub fn get_stale(&self, key: &str) -> Option<Value> {
        let entries = self.entries.lock().unwrap();
        entries.get(key).map(|(value, _)| value.clone())
    }

    /// Degraded-mode fallback: when a live fetch failed, serve the stale
    /// cache entry if one survives, otherwise propagate the error.
    pub fn stale_or_err(&self, key: &str, err: String) -> Result<Value, String> {
        match self.get_stale(key) {
            Some(v) => {
                log::warn!("AniList fetch failed ({}); serving stale cache for {}", err, key);
                Ok(v)
            }
            None => Err(err),
        }
    }

    pub fn set(&self, key: String, value: Value, cmd: &str) {
        let ttl = Self::ttl(cmd);
        let expires = Instant::now() + ttl;
        self.disk_put(&key, cmd, &value);
        let mut entries = self.entries.lock().unwrap();
        entries.insert(key, (value, expires));
        drop(entries);

        let count = self.insert_count.fetch_add(1, std::sync::atomic::Ordering::Relaxed);
        if count.is_multiple_of(PRUNE_EVERY_N_INSERTS) {
            self.prune();
        }
    }

    pub fn invalidate(&self, cmd_prefix: &str) {
        let mut entries = self.entries.lock().unwrap();
        entries.retain(|k, _| !k.starts_with(cmd_prefix));
        drop(entries);
        self.disk_delete_prefix(cmd_prefix);
    }

    /// Rewrites one title's own list entry (progress, status, score) in every
    /// cached shape that carries it, in memory and on disk.
    ///
    /// `media_detail` is in the list because dropping it instead was one of
    /// the six AniList requests a single mark-watched click used to cost: the
    /// detail page is always the page the click came from, so it was refetched
    /// every time. See `Catalogs::save_media_list_entry`.
    pub fn update_user_list_progress(&self, media_id: i64, new_progress: Option<i64>, new_status: Option<&str>, new_score: Option<f64>) {
        let mut entries = self.entries.lock().unwrap();
        let relevant_prefixes = [
            "get_user_list",
            "media_detail",
            "get_trending",
            "get_seasonal",
            "get_upcoming",
            "get_smart_playlist",
            "search_media",
        ];
        let mut touched = Vec::new();
        for (key, (value, _)) in entries.iter_mut() {
            if relevant_prefixes.iter().any(|p| key.starts_with(p)) {
                update_media_in_value(value, media_id, new_progress, new_status, new_score);
                touched.push((key.clone(), value.clone()));
            }
        }
        drop(entries);
        for (key, value) in &touched {
            self.disk_patch(key, value);
        }
    }

    /// Rewrites `isFavourite` on every cached `media_detail` row for one
    /// title, in memory and on disk. See `Catalogs::toggle_favourite` for
    /// why this is a patch and not an invalidation.
    pub fn set_media_detail_favourite(&self, media_id: i64, is_favourite: bool) {
        let prefix = format!("media_detail|id={media_id}|");
        let mut entries = self.entries.lock().unwrap();
        let mut touched = Vec::new();
        for (key, (value, _)) in entries.iter_mut() {
            if key.starts_with(&prefix) {
                if let Some(media) = value.get_mut("Media") {
                    media["isFavourite"] = Value::Bool(is_favourite);
                    touched.push((key.clone(), value.clone()));
                }
            }
        }
        drop(entries);
        for (key, value) in &touched {
            self.disk_patch(key, value);
        }
    }

    /// Best-effort lookup of the media's current progress from cached list
    /// data. Used to guard AniList writes so progress only ever moves forward —
    /// returns None when no cached entry is known (cold cache), in which case
    /// callers should proceed with the write.
    pub fn get_user_list_progress(&self, media_id: i64) -> Option<i64> {
        let entries = self.entries.lock().unwrap();
        for (key, (value, _)) in entries.iter() {
            if key.starts_with("get_user_list") {
                if let Some(p) = find_media_progress(value, media_id) {
                    return Some(p);
                }
            }
        }
        None
    }

    /// Best-effort lookup of the media's current list status (e.g. "CURRENT")
    /// from cached list data. Used to skip the redundant status write fired on
    /// every episode start when the entry is already in that status.
    pub fn get_user_list_status(&self, media_id: i64) -> Option<String> {
        let entries = self.entries.lock().unwrap();
        for (key, (value, _)) in entries.iter() {
            if key.starts_with("get_user_list") {
                if let Some(s) = find_media_status(value, media_id) {
                    return Some(s);
                }
            }
        }
        None
    }

    pub fn remove_from_user_list_by_entry_id(&self, entry_id: i64) {
        let mut entries = self.entries.lock().unwrap();
        let relevant_prefixes = [
            "get_user_list",
            "get_trending",
            "get_seasonal",
            "get_upcoming",
            "get_smart_playlist",
            "search_media",
        ];
        let mut touched = Vec::new();
        for (key, (value, _)) in entries.iter_mut() {
            if relevant_prefixes.iter().any(|p| key.starts_with(p)) {
                remove_media_in_value(value, entry_id);
                touched.push((key.clone(), value.clone()));
            }
        }
        drop(entries);
        for (key, value) in &touched {
            self.disk_patch(key, value);
        }
    }

    pub fn prune(&self) {
        let mut entries = self.entries.lock().unwrap();
        let now = Instant::now();
        let mut removed = Vec::new();
        // Expired entries live on for STALE_GRACE as degraded-mode fallbacks
        // (see get_stale); only truly ancient ones get dropped here.
        entries.retain(|k, (_, expires)| {
            let keep = now < *expires + STALE_GRACE;
            if !keep {
                removed.push(k.clone());
            }
            keep
        });
        while entries.len() > MAX_ENTRIES {
            let oldest_key = entries
                .iter()
                .min_by_key(|(_, (_, expires))| *expires)
                .map(|(k, _)| k.clone());
            if let Some(key) = oldest_key {
                entries.remove(&key);
                removed.push(key);
            } else {
                break;
            }
        }
        drop(entries);
        self.disk_delete_keys(&removed);
    }
}

fn unix_now() -> i64 {
    std::time::SystemTime::now()
        .duration_since(std::time::UNIX_EPOCH)
        .map(|d| d.as_secs() as i64)
        .unwrap_or(0)
}

fn update_media_in_value(
    value: &mut Value,
    media_id: i64,
    new_progress: Option<i64>,
    new_status: Option<&str>,
    new_score: Option<f64>,
) {
    match value {
        Value::Object(map) => {
            let is_list_entry = map.get("media")
                .and_then(|m| m.get("id"))
                .and_then(|id| id.as_i64())
                .map(|id| id == media_id)
                .unwrap_or(false);

            if is_list_entry {
                if let Some(p_val) = new_progress {
                    map.insert("progress".to_string(), serde_json::json!(p_val));
                }
                if let Some(status_str) = new_status {
                    map.insert("status".to_string(), serde_json::json!(status_str.to_uppercase()));
                }
                if let Some(s_val) = new_score {
                    map.insert("score".to_string(), serde_json::json!(s_val));
                }
            }

            let is_media_item = map.get("id")
                .and_then(|id| id.as_i64())
                .map(|id| id == media_id)
                .unwrap_or(false);

            if is_media_item {
                if let Some(entry) = map.get_mut("mediaListEntry") {
                    if entry.is_null() {
                        if let Some(status_str) = new_status {
                            *entry = serde_json::json!({
                                "status": status_str.to_uppercase(),
                                "progress": new_progress.unwrap_or(0),
                                "score": 0.0
                            });
                        }
                    } else if let Some(entry_map) = entry.as_object_mut() {
                        if let Some(p_val) = new_progress {
                            entry_map.insert("progress".to_string(), serde_json::json!(p_val));
                        }
                        if let Some(status_str) = new_status {
                            entry_map.insert("status".to_string(), serde_json::json!(status_str.to_uppercase()));
                        }
                        if let Some(s_val) = new_score {
                            entry_map.insert("score".to_string(), serde_json::json!(s_val));
                        }
                    }
                }
                if let Some(user_status) = map.get_mut("user_status") {
                    if user_status.is_null() {
                        if let Some(status_str) = new_status {
                            *user_status = serde_json::json!({
                                "status": status_str.to_lowercase(),
                                "progress": new_progress.unwrap_or(0),
                                "score": 0.0
                            });
                        }
                    } else if let Some(us_map) = user_status.as_object_mut() {
                        if let Some(p_val) = new_progress {
                            us_map.insert("progress".to_string(), serde_json::json!(p_val));
                        }
                        if let Some(status_str) = new_status {
                            us_map.insert("status".to_string(), serde_json::json!(status_str.to_lowercase()));
                        }
                        if let Some(s_val) = new_score {
                            us_map.insert("score".to_string(), serde_json::json!(s_val));
                        }
                    }
                }
            }

            for (_, val) in map.iter_mut() {
                update_media_in_value(val, media_id, new_progress, new_status, new_score);
            }
        }
        Value::Array(arr) => {
            for val in arr.iter_mut() {
                update_media_in_value(val, media_id, new_progress, new_status, new_score);
            }
        }
        _ => {}
    }
}

/// Recursively find the `progress` of the list entry whose `media.id` matches.
fn find_media_progress(value: &Value, media_id: i64) -> Option<i64> {
    match value {
        Value::Object(map) => {
            let is_list_entry = map.get("media")
                .and_then(|m| m.get("id"))
                .and_then(|id| id.as_i64())
                .map(|id| id == media_id)
                .unwrap_or(false);
            if is_list_entry {
                if let Some(p) = map.get("progress").and_then(|p| p.as_i64()) {
                    return Some(p);
                }
            }
            for (_, val) in map.iter() {
                if let Some(p) = find_media_progress(val, media_id) {
                    return Some(p);
                }
            }
            None
        }
        Value::Array(arr) => {
            for val in arr.iter() {
                if let Some(p) = find_media_progress(val, media_id) {
                    return Some(p);
                }
            }
            None
        }
        _ => None,
    }
}

/// Recursively find the list `status` of the entry whose `media.id` matches.
fn find_media_status(value: &Value, media_id: i64) -> Option<String> {
    match value {
        Value::Object(map) => {
            let is_list_entry = map.get("media")
                .and_then(|m| m.get("id"))
                .and_then(|id| id.as_i64())
                .map(|id| id == media_id)
                .unwrap_or(false);
            if is_list_entry {
                if let Some(s) = map.get("status").and_then(|s| s.as_str()) {
                    return Some(s.to_string());
                }
            }
            for (_, val) in map.iter() {
                if let Some(s) = find_media_status(val, media_id) {
                    return Some(s);
                }
            }
            None
        }
        Value::Array(arr) => {
            for val in arr.iter() {
                if let Some(s) = find_media_status(val, media_id) {
                    return Some(s);
                }
            }
            None
        }
        _ => None,
    }
}

fn remove_media_in_value(value: &mut Value, entry_id: i64) {
    match value {
        Value::Object(map) => {
            if let Some(entry) = map.get_mut("mediaListEntry") {
                let is_matching_entry = entry.get("id")
                    .and_then(|id| id.as_i64())
                    .map(|id| id == entry_id)
                    .unwrap_or(false);
                if is_matching_entry {
                    *entry = Value::Null;
                }
            }
            if let Some(user_status) = map.get_mut("user_status") {
                let is_matching_entry = user_status.get("id")
                    .and_then(|id| id.as_i64())
                    .map(|id| id == entry_id)
                    .unwrap_or(false);
                if is_matching_entry {
                    *user_status = Value::Null;
                }
            }

            for (_, val) in map.iter_mut() {
                remove_media_in_value(val, entry_id);
            }
        }
        Value::Array(arr) => {
            arr.retain(|val| {
                let is_matching_entry = val.get("id")
                    .and_then(|id| id.as_i64())
                    .map(|id| id == entry_id)
                    .unwrap_or(false);
                !is_matching_entry
            });

            for val in arr.iter_mut() {
                remove_media_in_value(val, entry_id);
            }
        }
        _ => {}
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn newly_cached_commands_have_long_ttls() {
        // A typo'd match arm would silently fall through to the 60s default,
        // making these caches nearly useless. Assert they got real TTLs.
        assert!(AniListCache::ttl("media_detail") >= Duration::from_secs(30 * 60));
        assert!(AniListCache::ttl("get_media_characters") >= Duration::from_secs(3600));
        assert!(AniListCache::ttl("get_media_discussions") >= Duration::from_secs(15 * 60));
        assert!(AniListCache::ttl("get_discover") >= Duration::from_secs(3600));
        assert!(AniListCache::ttl("get_user_list") >= Duration::from_secs(10 * 60));
        assert!(AniListCache::ttl("search_media") >= Duration::from_secs(5 * 60));
        assert!(AniListCache::ttl("character_detail") >= Duration::from_secs(3600));
        assert!(AniListCache::ttl("staff_detail") >= Duration::from_secs(3600));
        assert!(AniListCache::ttl("thread_detail") >= Duration::from_secs(5 * 60));
        assert!(AniListCache::ttl("thread_comments") >= Duration::from_secs(5 * 60));
        // Unknown commands still fall back to the short default.
        assert_eq!(AniListCache::ttl("something_else"), Duration::from_secs(60));
    }

    /// The whole point of patching instead of invalidating: after a
    /// progress write, the detail page and the shelves must both read back
    /// the new number without a refetch. `media_detail` was missing from the
    /// patched prefixes, so the detail page — the page every mark-watched
    /// click is made from — refetched every time.
    #[test]
    fn progress_patch_reaches_media_detail_and_user_list() {
        let cache = AniListCache::new();
        let detail = AniListCache::key("media_detail", &[("id", "1535"), ("type", "ANIME")]);
        cache.set(
            detail.clone(),
            serde_json::json!({"Media": {"id": 1535, "mediaListEntry": {"progress": 3, "status": "CURRENT"}}}),
            "media_detail",
        );
        let list = AniListCache::key("get_user_list", &[("user", "me"), ("type", "ANIME"), ("status", "CURRENT")]);
        cache.set(
            list.clone(),
            serde_json::json!([{"id": 1535, "mediaListEntry": {"progress": 3, "status": "CURRENT"}}]),
            "get_user_list",
        );

        cache.update_user_list_progress(1535, Some(4), None, None);

        assert_eq!(cache.get(&detail).unwrap()["Media"]["mediaListEntry"]["progress"], 4);
        assert_eq!(cache.get(&list).unwrap()[0]["mediaListEntry"]["progress"], 4);
    }

    #[test]
    fn get_returns_value_within_ttl_and_key_is_param_sensitive() {
        let cache = AniListCache::new();
        let k1 = AniListCache::key("search_media", &[("q", "naruto"), ("page", "1")]);
        let k2 = AniListCache::key("search_media", &[("q", "naruto"), ("page", "2")]);
        cache.set(k1.clone(), serde_json::json!({"hit": 1}), "search_media");
        assert_eq!(cache.get(&k1), Some(serde_json::json!({"hit": 1})));
        // Different page => different key => cache miss (no cross-contamination).
        assert_eq!(cache.get(&k2), None);
    }

    #[test]
    fn expired_entry_is_not_returned() {
        let cache = AniListCache::new();
        let key = "x".to_string();
        // Insert a manually-expired entry.
        cache.entries.lock().unwrap().insert(
            key.clone(),
            (serde_json::json!(1), Instant::now() - Duration::from_secs(1)),
        );
        assert_eq!(cache.get(&key), None);
    }

    #[test]
    fn persistent_cache_survives_a_restart_and_mirrors_invalidation() {
        let dir = std::env::temp_dir().join(format!("anicat-catalog-cache-{}", std::process::id()));
        let _ = std::fs::remove_dir_all(&dir);
        std::fs::create_dir_all(&dir).unwrap();
        let path = dir.join("catalog-cache.sqlite");

        let first = AniListCache::persistent(&path);
        let trending = AniListCache::key("get_trending", &[("type", "ANIME")]);
        let list = AniListCache::key("get_user_list", &[("user", "thomas"), ("status", "CURRENT")]);
        first.set(trending.clone(), serde_json::json!([{"id": 1}]), "get_trending");
        first.set(list.clone(), serde_json::json!([{"id": 2}]), "get_user_list");
        drop(first);

        // A second process: rows come back fresh, since their TTLs (6h and
        // 15min) are nowhere near up.
        let second = AniListCache::persistent(&path);
        assert_eq!(second.get(&trending), Some(serde_json::json!([{"id": 1}])));
        assert_eq!(second.get(&list), Some(serde_json::json!([{"id": 2}])));

        // Invalidation reaches the file, or the next launch would resurrect
        // a list the user just changed.
        second.invalidate("get_user_list");
        drop(second);
        let third = AniListCache::persistent(&path);
        assert_eq!(third.get(&list), None);
        assert_eq!(third.get(&trending), Some(serde_json::json!([{"id": 1}])));

        // A row stored longer ago than TTL + STALE_GRACE is dropped on load;
        // one past TTL but inside the grace is served only as stale.
        {
            let guard = third.disk.lock().unwrap();
            let conn = guard.as_ref().unwrap();
            let ancient = unix_now() - (6 * 3600 + 24 * 3600 + 60);
            let expired = unix_now() - (6 * 3600 + 60);
            conn.execute(
                "UPDATE entries SET stored_at = ?1 WHERE key = ?2",
                rusqlite::params![expired, trending],
            )
            .unwrap();
            conn.execute(
                "INSERT INTO entries (key, cmd, value, stored_at) VALUES ('get_seasonal|x', 'get_seasonal', '[]', ?1)",
                rusqlite::params![ancient],
            )
            .unwrap();
        }
        drop(third);
        let fourth = AniListCache::persistent(&path);
        assert_eq!(fourth.get(&trending), None);
        assert_eq!(fourth.get_stale(&trending), Some(serde_json::json!([{"id": 1}])));
        assert_eq!(fourth.get_stale("get_seasonal|x"), None);
        let _ = std::fs::remove_dir_all(&dir);
    }
}
