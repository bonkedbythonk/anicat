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
