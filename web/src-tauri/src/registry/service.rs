use rusqlite::params;
use serde::{Deserialize, Serialize};

// ── Schema initialization ─────────────────────────────────

pub fn initialize(conn: &rusqlite::Connection) -> Result<(), String> {
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

        CREATE INDEX IF NOT EXISTS idx_watch_history_media
            ON watch_history(media_id);
        CREATE INDEX IF NOT EXISTS idx_watch_history_watched
            ON watch_history(watched_at);",
    )
    .map_err(|e| e.to_string())
}

// ── Provider mapping ──────────────────────────────────────

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

// ── Watch history ─────────────────────────────────────────

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

// ── Local library ─────────────────────────────────────────

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
