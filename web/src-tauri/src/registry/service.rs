use serde::{Deserialize, Serialize};
use std::collections::HashMap;

#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct MediaRecord {
    pub media_id: i64,
    pub provider_mapping: HashMap<String, String>,
    pub updated_at: String,
}

pub fn get_provider_slug(db: &rusqlite::Connection, media_id: i64, provider: &str) -> Option<String> {
    let mut stmt = db
        .prepare("SELECT provider_mapping FROM media_records WHERE media_id = ?1")
        .ok()?;
    let mapping_json: String = stmt
        .query_row([media_id], |row| row.get(0))
        .ok()?;
    let mapping: HashMap<String, String> = serde_json::from_str(&mapping_json).ok()?;
    mapping.get(provider).cloned()
}

pub fn set_provider_slug(
    db: &rusqlite::Connection,
    media_id: i64,
    provider: &str,
    slug: &str,
) -> Result<(), String> {
    let mut mapping = get_full_mapping(db, media_id).unwrap_or_default();

    mapping.insert(provider.to_string(), slug.to_string());
    let mapping_json = serde_json::to_string(&mapping).map_err(|e| e.to_string())?;

    db.execute(
        "INSERT INTO media_records (media_id, provider_mapping, updated_at)
         VALUES (?1, ?2, datetime('now'))
         ON CONFLICT(media_id) DO UPDATE SET
           provider_mapping = excluded.provider_mapping,
           updated_at = excluded.updated_at",
        rusqlite::params![media_id, mapping_json],
    )
    .map_err(|e| e.to_string())?;

    Ok(())
}

pub fn clear_provider_cache(db: &rusqlite::Connection, media_id: i64) -> Result<(), String> {
    db.execute(
        "UPDATE media_records SET provider_mapping = '{}' WHERE media_id = ?1",
        [media_id],
    )
    .map_err(|e| e.to_string())?;
    Ok(())
}

fn get_full_mapping(
    db: &rusqlite::Connection,
    media_id: i64,
) -> Option<HashMap<String, String>> {
    let mut stmt = db
        .prepare("SELECT provider_mapping FROM media_records WHERE media_id = ?1")
        .ok()?;
    let mapping_json: String = stmt
        .query_row([media_id], |row| row.get(0))
        .ok()?;
    serde_json::from_str(&mapping_json).ok()
}

pub fn record_watched_episode(
    db: &rusqlite::Connection,
    media_id: i64,
    episode_number: i64,
    stop_time: i64,
    duration: i64,
) -> Result<(), String> {
    db.execute(
        "INSERT INTO watched_episodes (media_id, episode_number, stop_time, duration, watched_at)
         VALUES (?1, ?2, ?3, ?4, datetime('now'))
         ON CONFLICT(media_id, episode_number) DO UPDATE SET
           stop_time = excluded.stop_time,
           duration = excluded.duration,
           watched_at = excluded.watched_at",
        rusqlite::params![media_id, episode_number, stop_time, duration],
    )
    .map_err(|e| e.to_string())?;

    Ok(())
}

pub fn get_watched_episodes(
    db: &rusqlite::Connection,
    media_id: i64,
) -> Result<Vec<(i64, i64, i64)>, String> {
    let mut stmt = db
        .prepare(
            "SELECT episode_number, stop_time, duration FROM watched_episodes WHERE media_id = ?1",
        )
        .map_err(|e| e.to_string())?;

    let rows = stmt
        .query_map([media_id], |row| {
            Ok((row.get(0)?, row.get(1)?, row.get(2)?))
        })
        .map_err(|e| e.to_string())?;

    let mut episodes = Vec::new();
    for row in rows {
        if let Ok(ep) = row {
            episodes.push(ep);
        }
    }
    Ok(episodes)
}
