use rusqlite::params;
use serde::{Deserialize, Serialize};

pub fn initialize(conn: &rusqlite::Connection) -> Result<(), String> {
    let version: i64 = conn
        .pragma_query_value(None, "user_version", |row| row.get(0))
        .unwrap_or(0);

    if version < 1 {
        conn.execute_batch(
            "CREATE TABLE IF NOT EXISTS media_records (
                media_id INTEGER PRIMARY KEY,
                provider_mapping TEXT NOT NULL DEFAULT '{}',
                updated_at TEXT NOT NULL DEFAULT (datetime('now'))
            );

            CREATE TABLE IF NOT EXISTS watch_history (
                id INTEGER PRIMARY KEY AUTOINCREMENT,
                media_id INTEGER NOT NULL,
                episode_number INTEGER NOT NULL,
                stop_time INTEGER NOT NULL DEFAULT 0,
                duration INTEGER NOT NULL DEFAULT 0,
                watched_at TEXT NOT NULL DEFAULT (datetime('now')),
                UNIQUE(media_id, episode_number)
            );

            CREATE TABLE IF NOT EXISTS local_library (
                media_id INTEGER PRIMARY KEY,
                media_type TEXT NOT NULL DEFAULT 'ANIME',
                status TEXT,
                score REAL,
                progress INTEGER DEFAULT 0,
                notes TEXT,
                updated_at TEXT NOT NULL DEFAULT (datetime('now'))
            );

            CREATE TABLE IF NOT EXISTS download_queue (
                id INTEGER PRIMARY KEY AUTOINCREMENT,
                media_id INTEGER NOT NULL,
                episode_number INTEGER NOT NULL,
                status TEXT NOT NULL DEFAULT 'queued',
                queued_at TEXT NOT NULL DEFAULT (datetime('now')),
                media_title TEXT NOT NULL DEFAULT '',
                cover_image TEXT NOT NULL DEFAULT '',
                error_message TEXT,
                progress REAL NOT NULL DEFAULT 0.0,
                UNIQUE(media_id, episode_number)
            );

            CREATE INDEX IF NOT EXISTS idx_watch_history_media
                ON watch_history(media_id);
            CREATE INDEX IF NOT EXISTS idx_watch_history_watched
                ON watch_history(watched_at);",
        )
        .map_err(|e| e.to_string())?;

        // Migration: rename provider key gogoanime → anineko
        let _ = conn.execute(
            "UPDATE media_records SET provider_mapping = REPLACE(provider_mapping, ?1, ?2)
             WHERE provider_mapping LIKE ?3",
            params!["\"gogoanime\"", "\"anineko\"", "%\"gogoanime\"%"],
        );

        conn.pragma_update(None, "user_version", 2)
            .map_err(|e| e.to_string())?;
    } else if version < 2 {
        // Migrations for download_queue columns
        let _ = conn.execute("ALTER TABLE download_queue ADD COLUMN media_title TEXT NOT NULL DEFAULT ''", []);
        let _ = conn.execute("ALTER TABLE download_queue ADD COLUMN cover_image TEXT NOT NULL DEFAULT ''", []);
        let _ = conn.execute("ALTER TABLE download_queue ADD COLUMN error_message TEXT", []);
        let _ = conn.execute("ALTER TABLE download_queue ADD COLUMN progress REAL NOT NULL DEFAULT 0.0", []);

        conn.pragma_update(None, "user_version", 2)
            .map_err(|e| e.to_string())?;
    }

    // Migration (v3): rename provider key allanime → mkissa. Mkissa hits the
    // same allanime.day GraphQL backend, so a show's cached _id slug is
    // identical — reuse it instead of forcing every existing user to re-match.
    // Runs for both fresh installs (no-op) and existing v2 databases, which
    // the if/else-if above leaves untouched. Idempotent: once the "allanime"
    // key is gone the LIKE filter matches nothing.
    if version < 3 {
        let _ = conn.execute(
            "UPDATE media_records SET provider_mapping = REPLACE(provider_mapping, ?1, ?2)
             WHERE provider_mapping LIKE ?3",
            params!["\"allanime\"", "\"mkissa\"", "%\"allanime\"%"],
        );
        conn.pragma_update(None, "user_version", 3)
            .map_err(|e| e.to_string())?;
    }

    Ok(())
}

use std::collections::HashMap;

pub fn get_provider_slug(
    conn: &rusqlite::Connection,
    media_id: i64,
    provider: &str,
) -> Option<String> {
    let mut stmt = conn
        .prepare("SELECT provider_mapping FROM media_records WHERE media_id = ?1")
        .ok()?;
    let mapping_json: String = stmt.query_row([media_id], |row| row.get(0)).ok()?;
    let mapping: HashMap<String, String> = serde_json::from_str(&mapping_json).ok()?;
    mapping.get(provider).cloned()
}

pub fn set_provider_slug(
    conn: &rusqlite::Connection,
    media_id: i64,
    provider: &str,
    slug: &str,
) -> Result<(), String> {
    let mut mapping = get_full_mapping(conn, media_id).unwrap_or_default();
    mapping.insert(provider.to_string(), slug.to_string());
    let mapping_json = serde_json::to_string(&mapping).map_err(|e| e.to_string())?;

    conn.execute(
        "INSERT INTO media_records (media_id, provider_mapping, updated_at)
         VALUES (?1, ?2, datetime('now'))
         ON CONFLICT(media_id) DO UPDATE SET
           provider_mapping = excluded.provider_mapping,
           updated_at = excluded.updated_at",
        params![media_id, mapping_json],
    )
    .map_err(|e| e.to_string())?;

    Ok(())
}

pub fn clear_provider_cache(conn: &rusqlite::Connection, media_id: i64) -> Result<(), String> {
    conn.execute(
        "UPDATE media_records SET provider_mapping = '{}' WHERE media_id = ?1",
        [media_id],
    )
    .map_err(|e| e.to_string())?;
    Ok(())
}

fn get_full_mapping(
    conn: &rusqlite::Connection,
    media_id: i64,
) -> Option<HashMap<String, String>> {
    let mut stmt = conn
        .prepare("SELECT provider_mapping FROM media_records WHERE media_id = ?1")
        .ok()?;
    let mapping_json: String = stmt.query_row([media_id], |row| row.get(0)).ok()?;
    serde_json::from_str(&mapping_json).ok()
}

pub fn record_watched_episode(
    conn: &rusqlite::Connection,
    media_id: i64,
    episode_number: i64,
    stop_time: i64,
    duration: i64,
) -> Result<(), String> {
    conn.execute(
        "INSERT INTO watch_history (media_id, episode_number, stop_time, duration, watched_at)
         VALUES (?1, ?2, ?3, ?4, datetime('now'))
         ON CONFLICT(media_id, episode_number) DO UPDATE SET
           stop_time = excluded.stop_time,
           duration = excluded.duration,
           watched_at = excluded.watched_at",
        params![media_id, episode_number, stop_time, duration],
    )
    .map_err(|e| e.to_string())?;
    Ok(())
}

#[derive(Debug, Serialize, Deserialize)]
pub struct WatchEntry {
    pub episode_number: i64,
    pub stop_time: i64,
    pub duration: i64,
    pub watched_at: String,
}

pub fn get_watched_episodes(
    conn: &rusqlite::Connection,
    media_id: i64,
) -> Result<Vec<WatchEntry>, String> {
    let mut stmt = conn
        .prepare(
            "SELECT episode_number, stop_time, duration, watched_at
             FROM watch_history WHERE media_id = ?1
             ORDER BY episode_number",
        )
        .map_err(|e| e.to_string())?;

    let rows = stmt
        .query_map([media_id], |row| {
            Ok(WatchEntry {
                episode_number: row.get(0)?,
                stop_time: row.get(1)?,
                duration: row.get(2)?,
                watched_at: row.get(3)?,
            })
        })
        .map_err(|e| e.to_string())?;

    let mut entries = Vec::new();
    for row in rows {
        entries.push(row.map_err(|e| e.to_string())?);
    }
    Ok(entries)
}

pub fn get_all_last_watched(
    conn: &rusqlite::Connection,
) -> Result<HashMap<i64, String>, String> {
    let mut stmt = conn
        .prepare("SELECT media_id, MAX(watched_at) FROM watch_history GROUP BY media_id")
        .map_err(|e| e.to_string())?;
    let rows = stmt
        .query_map([], |row| {
            Ok((row.get::<_, i64>(0)?, row.get::<_, String>(1)?))
        })
        .map_err(|e| e.to_string())?;
    
    let mut map = HashMap::new();
    for (id, time) in rows.flatten() {
        map.insert(id, time);
    }
    Ok(map)
}

#[derive(Debug, Serialize, Deserialize)]
pub struct LibraryEntry {
    pub media_id: i64,
    pub media_type: String,
    pub status: Option<String>,
    pub score: Option<f64>,
    pub progress: Option<i32>,
    pub notes: Option<String>,
    pub updated_at: String,
}

pub fn upsert_library_entry(
    conn: &rusqlite::Connection,
    media_id: i64,
    media_type: &str,
    status: Option<&str>,
    score: Option<f64>,
    progress: Option<i32>,
    notes: Option<&str>,
) -> Result<(), String> {
    conn.execute(
        "INSERT INTO local_library (media_id, media_type, status, score, progress, notes, updated_at)
         VALUES (?1, ?2, ?3, ?4, ?5, ?6, datetime('now'))
         ON CONFLICT(media_id) DO UPDATE SET
           status = COALESCE(excluded.status, status),
           score = COALESCE(excluded.score, score),
           progress = COALESCE(excluded.progress, progress),
           notes = COALESCE(excluded.notes, notes),
           updated_at = excluded.updated_at",
        params![media_id, media_type, status, score, progress, notes],
    )
    .map_err(|e| e.to_string())?;
    Ok(())
}

#[allow(dead_code)]
pub fn get_library_entry(
    conn: &rusqlite::Connection,
    media_id: i64,
) -> Result<Option<LibraryEntry>, String> {
    let mut stmt = conn
        .prepare(
            "SELECT media_id, media_type, status, score, progress, notes, updated_at
             FROM local_library WHERE media_id = ?1",
        )
        .map_err(|e| e.to_string())?;

    let mut rows = stmt
        .query_map([media_id], |row| {
            Ok(LibraryEntry {
                media_id: row.get(0)?,
                media_type: row.get(1)?,
                status: row.get(2)?,
                score: row.get(3)?,
                progress: row.get(4)?,
                notes: row.get(5)?,
                updated_at: row.get(6)?,
            })
        })
        .map_err(|e| e.to_string())?;

    match rows.next() {
        Some(Ok(entry)) => Ok(Some(entry)),
        Some(Err(e)) => Err(e.to_string()),
        None => Ok(None),
    }
}

pub fn get_all_library(
    conn: &rusqlite::Connection,
) -> Result<Vec<LibraryEntry>, String> {
    let mut stmt = conn
        .prepare(
            "SELECT media_id, media_type, status, score, progress, notes, updated_at
             FROM local_library ORDER BY updated_at DESC",
        )
        .map_err(|e| e.to_string())?;

    let rows = stmt
        .query_map([], |row| {
            Ok(LibraryEntry {
                media_id: row.get(0)?,
                media_type: row.get(1)?,
                status: row.get(2)?,
                score: row.get(3)?,
                progress: row.get(4)?,
                notes: row.get(5)?,
                updated_at: row.get(6)?,
            })
        })
        .map_err(|e| e.to_string())?;

    let mut entries = Vec::new();
    for row in rows {
        entries.push(row.map_err(|e| e.to_string())?);
    }
    Ok(entries)
}

pub fn delete_library_entry(
    conn: &rusqlite::Connection,
    media_id: i64,
) -> Result<(), String> {
    conn.execute("DELETE FROM local_library WHERE media_id = ?1", [media_id])
        .map_err(|_| ())
        .map_err(|_| "Delete failed".to_string())?;
    Ok(())
}

#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct QueueItem {
    pub media_id: i64,
    pub episode_number: i64,
    pub status: String,
    pub media_title: String,
    pub cover_image: String,
    pub error_message: Option<String>,
    pub progress: f64,
}

pub fn add_to_queue(
    conn: &rusqlite::Connection,
    media_id: i64,
    episode_number: i64,
    media_title: &str,
    cover_image: &str,
) -> Result<(), String> {
    conn.execute(
        "INSERT OR REPLACE INTO download_queue (media_id, episode_number, status, media_title, cover_image, error_message, progress) VALUES (?1, ?2, 'queued', ?3, ?4, NULL, 0.0)",
        params![media_id, episode_number, media_title, cover_image],
    )
    .map_err(|e| e.to_string())?;
    Ok(())
}

#[allow(dead_code)]
pub fn get_queue_status(
    conn: &rusqlite::Connection,
    media_id: i64,
    episode_number: i64,
) -> Result<Option<String>, String> {
    let result: Result<String, rusqlite::Error> = conn.query_row(
        "SELECT status FROM download_queue WHERE media_id = ?1 AND episode_number = ?2",
        params![media_id, episode_number],
        |row| row.get(0),
    );
    match result {
        Ok(status) => Ok(Some(status)),
        Err(rusqlite::Error::QueryReturnedNoRows) => Ok(None),
        Err(e) => Err(e.to_string()),
    }
}

pub fn update_queue_status(
    conn: &rusqlite::Connection,
    media_id: i64,
    episode_number: i64,
    status: &str,
    error_message: Option<&str>,
) -> Result<(), String> {
    conn.execute(
        "UPDATE download_queue SET status = ?3, error_message = ?4 WHERE media_id = ?1 AND episode_number = ?2",
        params![media_id, episode_number, status, error_message],
    )
    .map_err(|e| e.to_string())?;
    Ok(())
}

pub fn update_queue_progress(
    conn: &rusqlite::Connection,
    media_id: i64,
    episode_number: i64,
    progress: f64,
) -> Result<(), String> {
    conn.execute(
        "UPDATE download_queue SET progress = ?3 WHERE media_id = ?1 AND episode_number = ?2",
        params![media_id, episode_number, progress],
    )
    .map_err(|e| e.to_string())?;
    Ok(())
}

#[allow(dead_code)]
pub fn get_queue_pending(_conn: &rusqlite::Connection) -> Result<Vec<(i64, i64)>, String> {
    let mut stmt = _conn
        .prepare("SELECT media_id, episode_number FROM download_queue WHERE status = 'queued' ORDER BY id ASC")
        .map_err(|e| e.to_string())?;
    let rows = stmt
        .query_map([], |row| Ok((row.get::<_, i64>(0)?, row.get::<_, i64>(1)?)))
        .map_err(|e| e.to_string())?;
    let mut result = Vec::new();
    for row in rows {
        result.push(row.map_err(|e| e.to_string())?);
    }
    Ok(result)
}

pub fn get_all_queue(conn: &rusqlite::Connection) -> Result<Vec<QueueItem>, String> {
    let mut stmt = conn
        .prepare("SELECT media_id, episode_number, status, media_title, cover_image, error_message, progress FROM download_queue ORDER BY id DESC")
        .map_err(|e| e.to_string())?;
    let rows = stmt
        .query_map([], |row| {
            Ok(QueueItem {
                media_id: row.get(0)?,
                episode_number: row.get(1)?,
                status: row.get(2)?,
                media_title: row.get(3)?,
                cover_image: row.get(4)?,
                error_message: row.get(5)?,
                progress: row.get(6).unwrap_or(0.0),
            })
        })
        .map_err(|e| e.to_string())?;
    let mut result = Vec::new();
    for row in rows {
        result.push(row.map_err(|e| e.to_string())?);
    }
    Ok(result)
}

pub fn remove_from_queue(
    conn: &rusqlite::Connection,
    media_id: i64,
    episode_number: i64,
) -> Result<(), String> {
    conn.execute(
        "DELETE FROM download_queue WHERE media_id = ?1 AND episode_number = ?2",
        params![media_id, episode_number],
    )
    .map_err(|e| e.to_string())?;
    Ok(())
}

pub fn retry_queue(conn: &rusqlite::Connection) -> Result<(), String> {
    conn.execute(
        "UPDATE download_queue SET status = 'queued', error_message = NULL WHERE status = 'failed'",
        [],
    )
    .map_err(|e| e.to_string())?;
    Ok(())
}
