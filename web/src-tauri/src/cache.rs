use std::collections::HashMap;
use std::sync::{Arc, Mutex};
use std::time::{Duration, Instant};

use serde_json::Value;

/// In-memory TTL cache for AniList API responses.
/// Keyed by "command_name:serialized_args", values expire after per-command TTLs.
#[derive(Clone)]
pub struct AniListCache {
    entries: Arc<Mutex<HashMap<String, (Value, Instant)>>>,
}

impl AniListCache {
    pub fn new() -> Self {
        Self {
            entries: Arc::new(Mutex::new(HashMap::new())),
        }
    }

    /// Build a cache key from a command identifier and its args.
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

    /// TTL durations per command.
    fn ttl(cmd: &str) -> Duration {
        match cmd {
            "get_trending" | "get_seasonal" | "get_upcoming" | "get_smart_playlist" => {
                Duration::from_secs(6 * 3600) // 6 hours
            }
            "get_user_list" => Duration::from_secs(15 * 60), // 15 minutes
            "get_airing_schedule" => Duration::from_secs(15 * 60), // 15 minutes
            "get_user_profile" => Duration::from_secs(3600), // 1 hour
            "get_notifications" => Duration::from_secs(5 * 60), // 5 minutes
            _ => Duration::from_secs(60),
        }
    }

    /// Get a cached value if it exists and is within TTL.
    pub fn get(&self, key: &str) -> Option<Value> {
        let entries = self.entries.lock().unwrap();
        if let Some((value, expires)) = entries.get(key) {
            if Instant::now() < *expires {
                return Some(value.clone());
            }
        }
        None
    }

    /// Store a value in the cache with TTL based on the command.
    pub fn set(&self, key: String, value: Value, cmd: &str) {
        let ttl = Self::ttl(cmd);
        let expires = Instant::now() + ttl;
        let mut entries = self.entries.lock().unwrap();
        entries.insert(key, (value, expires));
    }

    /// Invalidate all entries matching a command prefix.
    pub fn invalidate(&self, cmd_prefix: &str) {
        let mut entries = self.entries.lock().unwrap();
        entries.retain(|k, _| !k.starts_with(cmd_prefix));
    }

    /// Remove all expired entries (can be called periodically).
    #[allow(dead_code)]
    pub fn prune(&self) {
        let mut entries = self.entries.lock().unwrap();
        let now = Instant::now();
        entries.retain(|_, (_, expires)| now < *expires);
    }
}
