use std::collections::HashMap;
use std::sync::{Arc, Mutex};
use std::time::{Duration, Instant};

use serde_json::Value;

const MAX_ENTRIES: usize = 500;
const PRUNE_EVERY_N_INSERTS: usize = 100;

#[derive(Clone)]
pub struct AniListCache {
    entries: Arc<Mutex<HashMap<String, (Value, Instant)>>>,
    insert_count: Arc<std::sync::atomic::AtomicUsize>,
}

impl AniListCache {
    pub fn new() -> Self {
        Self {
            entries: Arc::new(Mutex::new(HashMap::new())),
            insert_count: Arc::new(std::sync::atomic::AtomicUsize::new(0)),
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
            "get_trending" | "get_seasonal" | "get_upcoming" | "get_smart_playlist" => {
                Duration::from_secs(6 * 3600)
            }
            "get_user_list" => Duration::from_secs(15 * 60),
            "get_airing_schedule" => Duration::from_secs(15 * 60),
            "get_user_profile" => Duration::from_secs(3600),
            "get_notifications" => Duration::from_secs(5 * 60),
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

    pub fn set(&self, key: String, value: Value, cmd: &str) {
        let ttl = Self::ttl(cmd);
        let expires = Instant::now() + ttl;
        let mut entries = self.entries.lock().unwrap();
        entries.insert(key, (value, expires));
        drop(entries);

        let count = self.insert_count.fetch_add(1, std::sync::atomic::Ordering::Relaxed);
        if count % PRUNE_EVERY_N_INSERTS == 0 {
            self.prune();
        }
    }

    pub fn invalidate(&self, cmd_prefix: &str) {
        let mut entries = self.entries.lock().unwrap();
        entries.retain(|k, _| !k.starts_with(cmd_prefix));
    }

    pub fn update_user_list_progress(&self, media_id: i64, new_progress: Option<i64>, new_status: Option<&str>, new_score: Option<f64>) {
        let mut entries = self.entries.lock().unwrap();
        let relevant_prefixes = [
            "get_user_list",
            "get_trending",
            "get_seasonal",
            "get_upcoming",
            "get_smart_playlist",
            "search_media",
        ];
        for (key, (value, _)) in entries.iter_mut() {
            if relevant_prefixes.iter().any(|p| key.starts_with(p)) {
                update_media_in_value(value, media_id, new_progress, new_status, new_score);
            }
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
        for (key, (value, _)) in entries.iter_mut() {
            if relevant_prefixes.iter().any(|p| key.starts_with(p)) {
                remove_media_in_value(value, entry_id);
            }
        }
    }

    pub fn prune(&self) {
        let mut entries = self.entries.lock().unwrap();
        let now = Instant::now();
        entries.retain(|_, (_, expires)| now < *expires);
        while entries.len() > MAX_ENTRIES {
            let oldest_key = entries
                .iter()
                .min_by_key(|(_, (_, expires))| *expires)
                .map(|(k, _)| k.clone());
            if let Some(key) = oldest_key {
                entries.remove(&key);
            } else {
                break;
            }
        }
    }
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
                if let Some(ref status_str) = new_status {
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
                        if let Some(ref status_str) = new_status {
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
                        if let Some(ref status_str) = new_status {
                            entry_map.insert("status".to_string(), serde_json::json!(status_str.to_uppercase()));
                        }
                        if let Some(s_val) = new_score {
                            entry_map.insert("score".to_string(), serde_json::json!(s_val));
                        }
                    }
                }
                if let Some(user_status) = map.get_mut("user_status") {
                    if user_status.is_null() {
                        if let Some(ref status_str) = new_status {
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
                        if let Some(ref status_str) = new_status {
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
