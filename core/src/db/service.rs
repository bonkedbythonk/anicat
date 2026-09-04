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

/// One watch, as the History view's activity chart reads them.
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct ActivityEntry {
    pub catalog: String,
    pub catalog_id: i64,
    pub episode_number: i64,
    /// SQLite `datetime('now')`, i.e. `YYYY-MM-DD HH:MM:SS` in UTC.
    pub watched_at: String,
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

    /// Every watch across every title, newest first.
    ///
    /// The per-title `history_for` cannot answer this: the History view's
    /// activity chart counts watches per *day* across the whole library, so it
    /// needs the rows ordered by when they happened rather than by which show
    /// they belong to. `idx_watch_history_watched` is the index for it.
    pub fn recent_activity(&self, limit: i64) -> Result<Vec<ActivityEntry>, String> {
        let conn = self.lock()?;
        let mut stmt = conn
            .prepare(
                "SELECT catalog, catalog_id, episode_number, watched_at FROM watch_history
                 ORDER BY watched_at DESC LIMIT ?1",
            )
            .map_err(|e| e.to_string())?;
        let rows = stmt
            .query_map(params![limit], |r| {
                Ok(ActivityEntry {
                    catalog: r.get::<_, String>(0)?,
                    catalog_id: r.get(1)?,
                    episode_number: r.get(2)?,
                    watched_at: r.get(3)?,
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

    /// Wipes every table: resume positions, provider-slug overrides, the
    /// offline list mirror, and per-show prefs. Schema/migrations are left
    /// alone — only rows go, not structure — so the next write just refills
    /// an empty database rather than re-running `migrate`.
    pub fn clear_all(&self) -> Result<(), String> {
        let conn = self.lock()?;
        conn.execute_batch(
            "BEGIN TRANSACTION;
            DELETE FROM watch_history;
            DELETE FROM provider_slugs;
            DELETE FROM local_library;
            DELETE FROM media_prefs;
            COMMIT;",
        )
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
    fn activity_comes_back_newest_first_across_every_title() {
        let db = Registry::open_in_memory().unwrap();
        // Written in the order they happened; `watched_at` defaults to now for
        // all three, so seed it explicitly to pin the ordering.
        for (id, ep, at) in [(1, 1, "2026-09-01 10:00:00"), (2, 4, "2026-09-03 09:00:00"), (1, 2, "2026-09-02 08:00:00")] {
            db.record_progress(Catalog::Anilist, id, ep, 10, 100).unwrap();
            let conn = db.conn.lock().unwrap();
            conn.execute(
                "UPDATE watch_history SET watched_at = ?1 WHERE catalog_id = ?2 AND episode_number = ?3",
                params![at, id, ep],
            )
            .unwrap();
        }
        let out = db.recent_activity(10).unwrap();
        assert_eq!(
            out.iter().map(|e| (e.catalog_id, e.episode_number)).collect::<Vec<_>>(),
            [(2, 4), (1, 2), (1, 1)]
        );
        assert_eq!(db.recent_activity(2).unwrap().len(), 2);
    }

    #[test]
    fn clear_all_empties_every_table_and_stays_usable() {
        let db = Registry::open_in_memory().unwrap();
        db.record_progress(Catalog::Anilist, 21, 1, 100, 1400).unwrap();
        db.set_provider_slug(Catalog::Anilist, 21, "nyaa", "One Piece").unwrap();

        db.clear_all().unwrap();

        assert_eq!(db.get_progress(Catalog::Anilist, 21, 1).unwrap(), None);
        assert_eq!(db.get_provider_slug(Catalog::Anilist, 21, "nyaa").unwrap(), None);
        assert_eq!(db.recent_activity(10).unwrap().len(), 0);

        // A write after clearing must not hit a dropped table — clear_all
        // deletes rows, it must never touch schema.
        db.record_progress(Catalog::Anilist, 21, 1, 50, 1400).unwrap();
        assert_eq!(db.get_progress(Catalog::Anilist, 21, 1).unwrap().unwrap().stop_time, 50);
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
