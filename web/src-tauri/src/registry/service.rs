use rusqlite::{params, OptionalExtension};
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

        let _ = conn.execute(
            "UPDATE media_records SET provider_mapping = REPLACE(provider_mapping, ?1, ?2)
             WHERE provider_mapping LIKE ?3",
            params!["\"gogoanime\"", "\"anineko\"", "%\"gogoanime\"%"],
        );

        conn.pragma_update(None, "user_version", 2)
            .map_err(|e| e.to_string())?;
    } else if version < 2 {
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

    // Migration (v4): multi-user support. Adds a `users` table plus a
    // `user_id` column to the two tables mobile-api's per-user reads/writes
    // actually touch (watch_history, local_library) — download_queue also
    // gets the column for schema consistency, but nothing threads it through
    // there since downloads are desktop-only and never reach a multi-user
    // context. SQLite can't ALTER a UNIQUE constraint or a PRIMARY KEY in
    // place, hence the create-new/copy/drop/rename dance instead of a plain
    // ADD COLUMN for those two tables. `user_id = 0` is a reserved sentinel
    // for "the original single-user desktop owner" — every existing row
    // migrates forward under it with no data loss and no forced re-entry.
    if version < 4 {
        conn.execute_batch(
            "BEGIN TRANSACTION;

            CREATE TABLE IF NOT EXISTS users (
                id INTEGER PRIMARY KEY AUTOINCREMENT,
                display_name TEXT NOT NULL UNIQUE,
                pin TEXT NOT NULL,
                anilist_token TEXT,
                anilist_username TEXT,
                created_at TEXT NOT NULL DEFAULT (datetime('now'))
            );

            CREATE TABLE watch_history_new (
                id INTEGER PRIMARY KEY AUTOINCREMENT,
                user_id INTEGER NOT NULL DEFAULT 0,
                media_id INTEGER NOT NULL,
                episode_number INTEGER NOT NULL,
                stop_time INTEGER NOT NULL DEFAULT 0,
                duration INTEGER NOT NULL DEFAULT 0,
                watched_at TEXT NOT NULL DEFAULT (datetime('now')),
                UNIQUE(user_id, media_id, episode_number)
            );
            INSERT INTO watch_history_new (id, user_id, media_id, episode_number, stop_time, duration, watched_at)
                SELECT id, 0, media_id, episode_number, stop_time, duration, watched_at FROM watch_history;
            DROP TABLE watch_history;
            ALTER TABLE watch_history_new RENAME TO watch_history;
            CREATE INDEX IF NOT EXISTS idx_watch_history_media ON watch_history(media_id);
            CREATE INDEX IF NOT EXISTS idx_watch_history_watched ON watch_history(watched_at);
            CREATE INDEX IF NOT EXISTS idx_watch_history_user ON watch_history(user_id);

            CREATE TABLE local_library_new (
                user_id INTEGER NOT NULL DEFAULT 0,
                media_id INTEGER NOT NULL,
                media_type TEXT NOT NULL DEFAULT 'ANIME',
                status TEXT,
                score REAL,
                progress INTEGER DEFAULT 0,
                notes TEXT,
                updated_at TEXT NOT NULL DEFAULT (datetime('now')),
                PRIMARY KEY (user_id, media_id)
            );
            INSERT INTO local_library_new (user_id, media_id, media_type, status, score, progress, notes, updated_at)
                SELECT 0, media_id, media_type, status, score, progress, notes, updated_at FROM local_library;
            DROP TABLE local_library;
            ALTER TABLE local_library_new RENAME TO local_library;

            ALTER TABLE download_queue ADD COLUMN user_id INTEGER NOT NULL DEFAULT 0;

            COMMIT;",
        )
        .map_err(|e| e.to_string())?;

        conn.pragma_update(None, "user_version", 4)
            .map_err(|e| e.to_string())?;
    }

    // Migration (v5): per-show preference overrides. A NULL column means
    // "inherit the global config value"; a row exists only while at least one
    // override is set (set_media_prefs deletes all-NULL rows).
    if version < 5 {
        conn.execute_batch(
            "CREATE TABLE IF NOT EXISTS media_prefs (
                user_id INTEGER NOT NULL DEFAULT 0,
                media_id INTEGER NOT NULL,
                provider TEXT,
                translation_type TEXT,
                PRIMARY KEY (user_id, media_id)
            );",
        )
        .map_err(|e| e.to_string())?;
        conn.pragma_update(None, "user_version", 5)
            .map_err(|e| e.to_string())?;
    }

    // Opportunistic, not required for correctness: SQLite's default
    // rollback-journal mode serializes all writers, which is fine for one
    // desktop user but starts to matter once several people's progress
    // writes can land concurrently. Outside the transaction above — SQLite
    // silently ignores a journal_mode change requested inside one.
    let _ = conn.pragma_update(None, "journal_mode", "WAL");

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

#[derive(Debug, Clone, Default, Serialize, Deserialize)]
pub struct MediaPrefs {
    pub provider: Option<String>,
    pub translation_type: Option<String>,
}

pub fn get_media_prefs(
    conn: &rusqlite::Connection,
    user_id: i64,
    media_id: i64,
) -> Option<MediaPrefs> {
    conn.query_row(
        "SELECT provider, translation_type FROM media_prefs
         WHERE user_id = ?1 AND media_id = ?2",
        params![user_id, media_id],
        |row| {
            Ok(MediaPrefs {
                provider: row.get(0)?,
                translation_type: row.get(1)?,
            })
        },
    )
    .optional()
    .ok()
    .flatten()
}

pub fn set_media_prefs(
    conn: &rusqlite::Connection,
    user_id: i64,
    media_id: i64,
    prefs: &MediaPrefs,
) -> Result<(), String> {
    if prefs.provider.is_none() && prefs.translation_type.is_none() {
        conn.execute(
            "DELETE FROM media_prefs WHERE user_id = ?1 AND media_id = ?2",
            params![user_id, media_id],
        )
        .map_err(|e| e.to_string())?;
        return Ok(());
    }
    conn.execute(
        "INSERT INTO media_prefs (user_id, media_id, provider, translation_type)
         VALUES (?1, ?2, ?3, ?4)
         ON CONFLICT(user_id, media_id) DO UPDATE SET
           provider = excluded.provider,
           translation_type = excluded.translation_type",
        params![user_id, media_id, prefs.provider, prefs.translation_type],
    )
    .map_err(|e| e.to_string())?;
    Ok(())
}

/// Remove a single provider's slug for a media, leaving other providers'
/// mappings (including manual nyaa search-title overrides) intact.
pub fn clear_provider_slug(
    conn: &rusqlite::Connection,
    media_id: i64,
    provider: &str,
) -> Result<(), String> {
    let Some(mut mapping) = get_full_mapping(conn, media_id) else {
        return Ok(());
    };
    if mapping.remove(provider).is_none() {
        return Ok(());
    }
    let mapping_json = serde_json::to_string(&mapping).map_err(|e| e.to_string())?;
    conn.execute(
        "UPDATE media_records SET provider_mapping = ?2, updated_at = datetime('now') WHERE media_id = ?1",
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
    user_id: i64,
    media_id: i64,
    episode_number: i64,
    stop_time: i64,
    duration: i64,
) -> Result<(), String> {
    conn.execute(
        "INSERT INTO watch_history (user_id, media_id, episode_number, stop_time, duration, watched_at)
         VALUES (?1, ?2, ?3, ?4, ?5, datetime('now'))
         ON CONFLICT(user_id, media_id, episode_number) DO UPDATE SET
           stop_time = excluded.stop_time,
           duration = excluded.duration,
           watched_at = excluded.watched_at",
        params![user_id, media_id, episode_number, stop_time, duration],
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
    user_id: i64,
    media_id: i64,
) -> Result<Vec<WatchEntry>, String> {
    let mut stmt = conn
        .prepare(
            "SELECT episode_number, stop_time, duration, watched_at
             FROM watch_history WHERE user_id = ?1 AND media_id = ?2
             ORDER BY episode_number",
        )
        .map_err(|e| e.to_string())?;

    let rows = stmt
        .query_map(params![user_id, media_id], |row| {
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

#[derive(Debug, Serialize, Deserialize)]
pub struct HistoryEntry {
    pub media_id: i64,
    pub episode_number: i64,
    pub watched_at: String,
}

/// Full per-episode watch log, newest first. Note the watch_history table
/// upserts on (media_id, episode_number), so a rewatch moves the entry
/// forward in time rather than adding a second row.
pub fn get_watch_history(
    conn: &rusqlite::Connection,
    user_id: i64,
    limit: i64,
) -> Result<Vec<HistoryEntry>, String> {
    let mut stmt = conn
        .prepare(
            "SELECT media_id, episode_number, watched_at FROM watch_history
             WHERE user_id = ?1 ORDER BY watched_at DESC LIMIT ?2",
        )
        .map_err(|e| e.to_string())?;
    let rows = stmt
        .query_map(params![user_id, limit], |row| {
            Ok(HistoryEntry {
                media_id: row.get(0)?,
                episode_number: row.get(1)?,
                watched_at: row.get(2)?,
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
    user_id: i64,
) -> Result<HashMap<i64, String>, String> {
    let mut stmt = conn
        .prepare("SELECT media_id, MAX(watched_at) FROM watch_history WHERE user_id = ?1 GROUP BY media_id")
        .map_err(|e| e.to_string())?;
    let rows = stmt
        .query_map([user_id], |row| {
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

#[allow(clippy::too_many_arguments)]
pub fn upsert_library_entry(
    conn: &rusqlite::Connection,
    user_id: i64,
    media_id: i64,
    media_type: &str,
    status: Option<&str>,
    score: Option<f64>,
    progress: Option<i32>,
    notes: Option<&str>,
) -> Result<(), String> {
    conn.execute(
        "INSERT INTO local_library (user_id, media_id, media_type, status, score, progress, notes, updated_at)
         VALUES (?1, ?2, ?3, ?4, ?5, ?6, ?7, datetime('now'))
         ON CONFLICT(user_id, media_id) DO UPDATE SET
           status = COALESCE(excluded.status, status),
           score = COALESCE(excluded.score, score),
           progress = COALESCE(excluded.progress, progress),
           notes = COALESCE(excluded.notes, notes),
           updated_at = excluded.updated_at",
        params![user_id, media_id, media_type, status, score, progress, notes],
    )
    .map_err(|e| e.to_string())?;
    Ok(())
}

pub fn get_all_library(
    conn: &rusqlite::Connection,
    user_id: i64,
) -> Result<Vec<LibraryEntry>, String> {
    let mut stmt = conn
        .prepare(
            "SELECT media_id, media_type, status, score, progress, notes, updated_at
             FROM local_library WHERE user_id = ?1 ORDER BY updated_at DESC",
        )
        .map_err(|e| e.to_string())?;

    let rows = stmt
        .query_map([user_id], |row| {
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
    user_id: i64,
    media_id: i64,
) -> Result<(), String> {
    conn.execute("DELETE FROM local_library WHERE user_id = ?1 AND media_id = ?2", params![user_id, media_id])
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

// ── multi-user (Stage 2: headless server, Tailscale-invited friends) ──────

#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct User {
    pub id: i64,
    pub display_name: String,
    #[serde(skip_serializing)]
    pub pin: String,
    pub anilist_token: Option<String>,
    pub anilist_username: Option<String>,
    pub created_at: String,
}

/// `pin` is stored and compared in plaintext — same trust model as the
/// existing single-user `MobileConfig.pin`: Tailscale is the actual
/// security boundary here (only devices on the host's tailnet can reach
/// this server at all), not this PIN, so hashing a short PIN wouldn't
/// meaningfully raise the bar.
pub fn create_user(conn: &rusqlite::Connection, display_name: &str, pin: &str) -> Result<i64, String> {
    conn.execute(
        "INSERT INTO users (display_name, pin) VALUES (?1, ?2)",
        params![display_name, pin],
    )
    .map_err(|e| e.to_string())?;
    Ok(conn.last_insert_rowid())
}

fn row_to_user(row: &rusqlite::Row) -> rusqlite::Result<User> {
    Ok(User {
        id: row.get(0)?,
        display_name: row.get(1)?,
        pin: row.get(2)?,
        anilist_token: row.get(3)?,
        anilist_username: row.get(4)?,
        created_at: row.get(5)?,
    })
}

const USER_COLUMNS: &str = "id, display_name, pin, anilist_token, anilist_username, created_at";

pub fn get_user_by_id(conn: &rusqlite::Connection, user_id: i64) -> Result<Option<User>, String> {
    conn.query_row(
        &format!("SELECT {USER_COLUMNS} FROM users WHERE id = ?1"),
        [user_id],
        row_to_user,
    )
    .optional()
    .map_err(|e| e.to_string())
}

pub fn get_user_by_name(conn: &rusqlite::Connection, display_name: &str) -> Result<Option<User>, String> {
    conn.query_row(
        &format!("SELECT {USER_COLUMNS} FROM users WHERE display_name = ?1"),
        [display_name],
        row_to_user,
    )
    .optional()
    .map_err(|e| e.to_string())
}

/// Every registered user, most-recently-created first. Fine to load in full
/// at friend-group scale — there is no pagination need here.
pub fn list_users(conn: &rusqlite::Connection) -> Result<Vec<User>, String> {
    let mut stmt = conn
        .prepare(&format!("SELECT {USER_COLUMNS} FROM users ORDER BY id DESC"))
        .map_err(|e| e.to_string())?;
    let rows = stmt.query_map([], row_to_user).map_err(|e| e.to_string())?;
    let mut users = Vec::new();
    for row in rows {
        users.push(row.map_err(|e| e.to_string())?);
    }
    Ok(users)
}

pub fn set_user_anilist_token(
    conn: &rusqlite::Connection,
    user_id: i64,
    token: Option<&str>,
    username: Option<&str>,
) -> Result<(), String> {
    conn.execute(
        "UPDATE users SET anilist_token = ?2, anilist_username = ?3 WHERE id = ?1",
        params![user_id, token, username],
    )
    .map_err(|e| e.to_string())?;
    Ok(())
}

#[cfg(test)]
mod tests {
    use super::*;

    fn migrated_conn() -> rusqlite::Connection {
        let conn = rusqlite::Connection::open_in_memory().unwrap();
        initialize(&conn).unwrap();
        conn
    }

    #[test]
    fn migration_lands_on_v5() {
        let conn = migrated_conn();
        let version: i64 = conn.pragma_query_value(None, "user_version", |r| r.get(0)).unwrap();
        assert_eq!(version, 5);
    }

    #[test]
    fn media_prefs_roundtrip_and_all_null_delete() {
        let conn = migrated_conn();
        assert!(get_media_prefs(&conn, 0, 42).is_none());

        let prefs = MediaPrefs {
            provider: Some("nyaa".into()),
            translation_type: Some("dub".into()),
        };
        set_media_prefs(&conn, 0, 42, &prefs).unwrap();
        let got = get_media_prefs(&conn, 0, 42).unwrap();
        assert_eq!(got.provider.as_deref(), Some("nyaa"));
        assert_eq!(got.translation_type.as_deref(), Some("dub"));

        // Another user's prefs stay isolated.
        assert!(get_media_prefs(&conn, 1, 42).is_none());

        // Clearing both overrides removes the row entirely.
        set_media_prefs(&conn, 0, 42, &MediaPrefs::default()).unwrap();
        assert!(get_media_prefs(&conn, 0, 42).is_none());
    }

    #[test]
    fn migration_enables_wal_on_a_real_file() {
        // SQLite ignores journal_mode=WAL for :memory: databases (always
        // reports "memory" regardless) — this needs a real file to actually
        // exercise the pragma.
        let path = std::env::temp_dir().join(format!("anicat-test-{}.db", std::process::id()));
        let _ = std::fs::remove_file(&path);
        let conn = rusqlite::Connection::open(&path).unwrap();
        initialize(&conn).unwrap();
        let journal_mode: String = conn.pragma_query_value(None, "journal_mode", |r| r.get(0)).unwrap();
        assert_eq!(journal_mode.to_lowercase(), "wal");
        drop(conn);
        let _ = std::fs::remove_file(&path);
        let _ = std::fs::remove_file(path.with_extension("db-wal"));
        let _ = std::fs::remove_file(path.with_extension("db-shm"));
    }

    #[test]
    fn create_and_fetch_user_roundtrips() {
        let conn = migrated_conn();
        let id = create_user(&conn, "Sam", "4821").unwrap();
        let by_id = get_user_by_id(&conn, id).unwrap().unwrap();
        assert_eq!(by_id.display_name, "Sam");
        assert_eq!(by_id.pin, "4821");
        let by_name = get_user_by_name(&conn, "Sam").unwrap().unwrap();
        assert_eq!(by_name.id, id);
        assert!(get_user_by_name(&conn, "Nobody").unwrap().is_none());
    }

    #[test]
    fn duplicate_display_name_is_rejected() {
        let conn = migrated_conn();
        create_user(&conn, "Sam", "1111").unwrap();
        assert!(create_user(&conn, "Sam", "2222").is_err());
    }

    /// The whole point of the user_id column: two people's progress on the
    /// same episode must not collide, and the desktop sentinel (0) must not
    /// collide with a real registered user either.
    #[test]
    fn watch_history_is_isolated_per_user() {
        let conn = migrated_conn();
        let friend_id = create_user(&conn, "Alex", "0000").unwrap();

        record_watched_episode(&conn, 0, 999, 1, 50, 200).unwrap();
        record_watched_episode(&conn, friend_id, 999, 1, 150, 200).unwrap();

        let desktop_entries = get_watched_episodes(&conn, 0, 999).unwrap();
        let friend_entries = get_watched_episodes(&conn, friend_id, 999).unwrap();
        assert_eq!(desktop_entries.len(), 1);
        assert_eq!(friend_entries.len(), 1);
        assert_eq!(desktop_entries[0].stop_time, 50);
        assert_eq!(friend_entries[0].stop_time, 150);

        // Re-recording the desktop owner's progress must not touch the friend's row.
        record_watched_episode(&conn, 0, 999, 1, 80, 200).unwrap();
        assert_eq!(get_watched_episodes(&conn, 0, 999).unwrap()[0].stop_time, 80);
        assert_eq!(get_watched_episodes(&conn, friend_id, 999).unwrap()[0].stop_time, 150);
    }

    #[test]
    fn library_entries_are_isolated_per_user() {
        let conn = migrated_conn();
        let friend_id = create_user(&conn, "Jo", "0000").unwrap();

        upsert_library_entry(&conn, 0, 555, "ANIME", Some("WATCHING"), None, Some(3), None).unwrap();
        upsert_library_entry(&conn, friend_id, 555, "ANIME", Some("COMPLETED"), None, Some(12), None).unwrap();

        let desktop_lib = get_all_library(&conn, 0).unwrap();
        let friend_lib = get_all_library(&conn, friend_id).unwrap();
        assert_eq!(desktop_lib.len(), 1);
        assert_eq!(friend_lib.len(), 1);
        assert_eq!(desktop_lib[0].status.as_deref(), Some("WATCHING"));
        assert_eq!(friend_lib[0].status.as_deref(), Some("COMPLETED"));

        delete_library_entry(&conn, friend_id, 555).unwrap();
        assert_eq!(get_all_library(&conn, friend_id).unwrap().len(), 0);
        assert_eq!(get_all_library(&conn, 0).unwrap().len(), 1, "deleting the friend's entry must not touch the desktop owner's");
    }
}
