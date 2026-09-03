use rusqlite::Connection;

/// Which upstream catalog a `catalog_id` belongs to. Stored as the string in
/// `as_str`, not as an ordinal: a reordered enum must not silently repoint
/// existing rows at a different catalog.
#[derive(Debug, Clone, Copy, PartialEq, Eq, Hash)]
pub enum Catalog {
    Anilist,
    TmdbMovie,
    TmdbTv,
    MangaDex,
}

impl Catalog {
    pub fn as_str(self) -> &'static str {
        match self {
            Catalog::Anilist => "anilist",
            Catalog::TmdbMovie => "tmdb_movie",
            Catalog::TmdbTv => "tmdb_tv",
            Catalog::MangaDex => "mangadex",
        }
    }

    pub fn parse(s: &str) -> Option<Self> {
        match s {
            "anilist" => Some(Catalog::Anilist),
            "tmdb_movie" => Some(Catalog::TmdbMovie),
            "tmdb_tv" => Some(Catalog::TmdbTv),
            "mangadex" => Some(Catalog::MangaDex),
            _ => None,
        }
    }
}

/// Numbered and idempotent, the same discipline the Tauri registry used: a
/// shipped migration is never deleted or edited, because it still has to run
/// against a database created before it.
pub fn migrate(conn: &Connection) -> Result<(), String> {
    let version: i64 = conn
        .pragma_query_value(None, "user_version", |row| row.get(0))
        .unwrap_or(0);

    if version < 1 {
        conn.execute_batch(
            "BEGIN TRANSACTION;

            -- Per-episode resume position. `episode_number` is 0 for a film,
            -- which has no episodes but still needs a resume position.
            CREATE TABLE IF NOT EXISTS watch_history (
                catalog TEXT NOT NULL,
                catalog_id INTEGER NOT NULL,
                episode_number INTEGER NOT NULL,
                stop_time INTEGER NOT NULL DEFAULT 0,
                duration INTEGER NOT NULL DEFAULT 0,
                watched_at TEXT NOT NULL DEFAULT (datetime('now')),
                PRIMARY KEY (catalog, catalog_id, episode_number)
            );
            CREATE INDEX IF NOT EXISTS idx_watch_history_watched
                ON watch_history(watched_at);

            -- Provider-side identity for a catalog entry: the MangaDex uuid
            -- for a manga, or the manual search-title override for `nyaa`,
            -- which has no ids of its own.
            CREATE TABLE IF NOT EXISTS provider_slugs (
                catalog TEXT NOT NULL,
                catalog_id INTEGER NOT NULL,
                provider TEXT NOT NULL,
                slug TEXT NOT NULL,
                PRIMARY KEY (catalog, catalog_id, provider)
            );

            -- Offline mirror of list state, so the app is usable with no
            -- AniList token and so a progress write survives a failed sync.
            CREATE TABLE IF NOT EXISTS local_library (
                catalog TEXT NOT NULL,
                catalog_id INTEGER NOT NULL,
                status TEXT,
                score REAL,
                progress INTEGER NOT NULL DEFAULT 0,
                notes TEXT,
                updated_at TEXT NOT NULL DEFAULT (datetime('now')),
                PRIMARY KEY (catalog, catalog_id)
            );

            -- Per-show overrides. A NULL column means 'inherit the global
            -- setting'; a row exists only while at least one override is set.
            CREATE TABLE IF NOT EXISTS media_prefs (
                catalog TEXT NOT NULL,
                catalog_id INTEGER NOT NULL,
                prefer_dub INTEGER,
                release_name TEXT,
                PRIMARY KEY (catalog, catalog_id)
            );

            COMMIT;",
        )
        .map_err(|e| e.to_string())?;
        conn.pragma_update(None, "user_version", 1)
            .map_err(|e| e.to_string())?;
    }

    // Opportunistic, not required for correctness: WAL lets a read (the
    // library view repainting) proceed while a write (a progress tick) is in
    // flight, instead of the two serializing on the rollback journal.
    let _ = conn.pragma_update(None, "journal_mode", "WAL");

    Ok(())
}
