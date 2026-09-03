use std::path::Path;
use std::sync::Mutex;

use rusqlite::{params, Connection, OptionalExtension};

use super::schema::{migrate, Catalog};

/// An episode's playback position, as stored.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub struct WatchEntry {
    pub episode_number: i64,
    pub stop_time: i64,
    pub duration: i64,
}

/// The registry, owning its one connection.
///
/// A `Mutex<Connection>` rather than a pool: every caller is in-process on one
/// device, the writes are single-row, and WAL already keeps a read from
/// blocking behind a write. A pool here would buy contention we do not have.
pub struct Registry {
    conn: Mutex<Connection>,
}

impl Registry {
    pub fn open(path: &Path) -> Result<Self, String> {
        if let Some(dir) = path.parent() {
            std::fs::create_dir_all(dir).map_err(|e| e.to_string())?;
        }
        let conn = Connection::open(path).map_err(|e| e.to_string())?;
        migrate(&conn)?;
        Ok(Self { conn: Mutex::new(conn) })
    }

    pub fn open_in_memory() -> Result<Self, String> {
        let conn = Connection::open_in_memory().map_err(|e| e.to_string())?;
        migrate(&conn)?;
        Ok(Self { conn: Mutex::new(conn) })
    }

    fn lock(&self) -> Result<std::sync::MutexGuard<'_, Connection>, String> {
        self.conn.lock().map_err(|e| e.to_string())
    }

    pub fn record_progress(
        &self,
        catalog: Catalog,
        catalog_id: i64,
        episode_number: i64,
        stop_time: i64,
        duration: i64,
    ) -> Result<(), String> {
        let conn = self.lock()?;
        conn.execute(
            "INSERT INTO watch_history
                 (catalog, catalog_id, episode_number, stop_time, duration, watched_at)
             VALUES (?1, ?2, ?3, ?4, ?5, datetime('now'))
             ON CONFLICT(catalog, catalog_id, episode_number) DO UPDATE SET
                 stop_time = excluded.stop_time,
                 -- A zero duration means the player had not reported one yet.
                 -- Keeping the known value stops a late tick from erasing the
                 -- denominator the watched-percentage is computed against.
                 duration = CASE WHEN excluded.duration > 0
                                 THEN excluded.duration ELSE duration END,
                 watched_at = excluded.watched_at",
            params![catalog.as_str(), catalog_id, episode_number, stop_time, duration],
        )
        .map_err(|e| e.to_string())?;
        Ok(())
    }

    pub fn get_progress(
        &self,
        catalog: Catalog,
        catalog_id: i64,
        episode_number: i64,
    ) -> Result<Option<WatchEntry>, String> {
        let conn = self.lock()?;
        conn.query_row(
            "SELECT episode_number, stop_time, duration FROM watch_history
             WHERE catalog = ?1 AND catalog_id = ?2 AND episode_number = ?3",
            params![catalog.as_str(), catalog_id, episode_number],
            |r| {
                Ok(WatchEntry {
                    episode_number: r.get(0)?,
                    stop_time: r.get(1)?,
                    duration: r.get(2)?,
                })
            },
        )
        .optional()
        .map_err(|e| e.to_string())
    }

    pub fn history_for(&self, catalog: Catalog, catalog_id: i64) -> Result<Vec<WatchEntry>, String> {
        let conn = self.lock()?;
        let mut stmt = conn
            .prepare(
                "SELECT episode_number, stop_time, duration FROM watch_history
                 WHERE catalog = ?1 AND catalog_id = ?2 ORDER BY episode_number",
            )
            .map_err(|e| e.to_string())?;
        let rows = stmt
            .query_map(params![catalog.as_str(), catalog_id], |r| {
                Ok(WatchEntry {
                    episode_number: r.get(0)?,
                    stop_time: r.get(1)?,
                    duration: r.get(2)?,
                })
            })
            .map_err(|e| e.to_string())?;
        rows.collect::<Result<Vec<_>, _>>().map_err(|e| e.to_string())
    }

    pub fn set_provider_slug(
        &self,
        catalog: Catalog,
        catalog_id: i64,
        provider: &str,
        slug: &str,
    ) -> Result<(), String> {
        let conn = self.lock()?;
        conn.execute(
            "INSERT INTO provider_slugs (catalog, catalog_id, provider, slug)
             VALUES (?1, ?2, ?3, ?4)
             ON CONFLICT(catalog, catalog_id, provider) DO UPDATE SET slug = excluded.slug",
            params![catalog.as_str(), catalog_id, provider, slug],
        )
        .map_err(|e| e.to_string())?;
        Ok(())
    }

    pub fn get_provider_slug(
        &self,
        catalog: Catalog,
        catalog_id: i64,
        provider: &str,
    ) -> Result<Option<String>, String> {
        let conn = self.lock()?;
        conn.query_row(
            "SELECT slug FROM provider_slugs
             WHERE catalog = ?1 AND catalog_id = ?2 AND provider = ?3",
            params![catalog.as_str(), catalog_id, provider],
            |r| r.get(0),
        )
        .optional()
        .map_err(|e| e.to_string())
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn anilist_and_tmdb_ids_do_not_collide() {
        // The whole point of the composite key: the same integer under two
        // catalogs is two different shows. Under the old banding scheme this
        // was only true because the TMDB id had been shifted on the way in.
        let db = Registry::open_in_memory().unwrap();
        db.record_progress(Catalog::Anilist, 21, 1, 100, 1400).unwrap();
        db.record_progress(Catalog::TmdbTv, 21, 1, 700, 1400).unwrap();

        assert_eq!(db.get_progress(Catalog::Anilist, 21, 1).unwrap().unwrap().stop_time, 100);
        assert_eq!(db.get_progress(Catalog::TmdbTv, 21, 1).unwrap().unwrap().stop_time, 700);
        assert_eq!(db.get_progress(Catalog::TmdbMovie, 21, 1).unwrap(), None);
    }

    #[test]
    fn a_late_zero_duration_tick_does_not_erase_the_known_duration() {
        let db = Registry::open_in_memory().unwrap();
        db.record_progress(Catalog::Anilist, 5, 3, 60, 1440).unwrap();
        db.record_progress(Catalog::Anilist, 5, 3, 90, 0).unwrap();
        let e = db.get_progress(Catalog::Anilist, 5, 3).unwrap().unwrap();
        assert_eq!((e.stop_time, e.duration), (90, 1440));
    }

    #[test]
    fn migrate_is_idempotent() {
        let conn = Connection::open_in_memory().unwrap();
        migrate(&conn).unwrap();
        migrate(&conn).unwrap();
        let v: i64 = conn.pragma_query_value(None, "user_version", |r| r.get(0)).unwrap();
        assert_eq!(v, 1);
    }
}
