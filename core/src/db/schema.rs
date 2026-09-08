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

    if version < 2 {
        conn.execute_batch(
            "BEGIN TRANSACTION;

            -- The release that last played for an episode, with enough of
            -- the candidate to add it to the session again without a search.
            -- A play that starts here skips the indexer wave entirely; one
            -- whose release has since died falls through to the ordinary
            -- search after a bounded attempt. prefer_dub is the preference
            -- it was picked under, since a flip must re-search.
            CREATE TABLE IF NOT EXISTS resolved_releases (
                catalog TEXT NOT NULL,
                catalog_id INTEGER NOT NULL,
                episode_number INTEGER NOT NULL,
                name TEXT NOT NULL,
                magnet TEXT,
                torrent_url TEXT,
                assume_batch INTEGER NOT NULL DEFAULT 0,
                prefer_dub INTEGER NOT NULL DEFAULT 0,
                resolved_at TEXT NOT NULL DEFAULT (datetime('now')),
                PRIMARY KEY (catalog, catalog_id, episode_number)
            );

            COMMIT;",
        )
        .map_err(|e| e.to_string())?;
        conn.pragma_update(None, "user_version", 2)
            .map_err(|e| e.to_string())?;
    }

    if version < 3 {
        conn.execute_batch(
            "BEGIN TRANSACTION;

            -- The audio and subtitle tracks the viewer last chose for a
            -- title, so episode 2 opens the way they left episode 1. Stored
            -- by language rather than by track index: a track order is a
            -- property of one release's mux, and the next episode is
            -- routinely a different one. `subtitle_title` is the tie-break
            -- for the packs that ship several tracks of the same language
            -- (\"Signs & Songs\" beside \"Full Subtitles\").
            --
            -- A NULL column means 'no preference recorded', which is not the
            -- same as 'no subtitles' — the player falls back to its global
            -- default there.
            CREATE TABLE IF NOT EXISTS title_track_prefs (
                catalog TEXT NOT NULL,
                catalog_id INTEGER NOT NULL,
                audio_lang TEXT,
                subtitle_lang TEXT,
                subtitle_title TEXT,
                updated_at TEXT NOT NULL DEFAULT (datetime('now')),
                PRIMARY KEY (catalog, catalog_id)
            );

            COMMIT;",
        )
        .map_err(|e| e.to_string())?;
        conn.pragma_update(None, "user_version", 3)
            .map_err(|e| e.to_string())?;
    }

    if version < 4 {
        conn.execute_batch(
            "BEGIN TRANSACTION;

            -- Where a chapter was left, and that a chapter was read at all.
            --
            -- Not rows in `watch_history`: that table is keyed by
            -- `episode_number`, and a manga entry shares its AniList id with
            -- nothing but itself -- chapter 3 and episode 3 of the same id
            -- would be one row overwriting the other. Chapters also number
            -- fractionally (10.5 is a real chapter) and are identified by a
            -- provider id, neither of which an integer episode column can
            -- carry.
            --
            -- `page` is a zero-based index into the chapter and `page_count`
            -- what it was out of, so a resume can tell 'page 4 of 20' from a
            -- chapter whose page count has since changed.
            CREATE TABLE IF NOT EXISTS reading_history (
                catalog TEXT NOT NULL,
                catalog_id INTEGER NOT NULL,
                chapter_id TEXT NOT NULL,
                chapter_number TEXT NOT NULL,
                page INTEGER NOT NULL DEFAULT 0,
                page_count INTEGER NOT NULL DEFAULT 0,
                read_at TEXT NOT NULL DEFAULT (datetime('now')),
                PRIMARY KEY (catalog, catalog_id, chapter_id)
            );

            COMMIT;",
        )
        .map_err(|e| e.to_string())?;
        conn.pragma_update(None, "user_version", 4)
            .map_err(|e| e.to_string())?;
    }

    if version < 5 {
        conn.execute_batch(
            "BEGIN TRANSACTION;

            -- Chapters kept on disk for reading with no network.
            --
            -- The files are the truth and this is the index: what was
            -- downloaded, how big it is and when, so a list of downloads does
            -- not mean walking the directory tree and re-deriving titles.
            -- `reader::offline` reads the directory itself when asked for
            -- pages, so a row whose files have been deleted underneath us
            -- reads as not downloaded rather than as a chapter with holes.
            CREATE TABLE IF NOT EXISTS offline_chapters (
                catalog TEXT NOT NULL,
                catalog_id INTEGER NOT NULL,
                chapter_id TEXT NOT NULL,
                chapter_number TEXT NOT NULL,
                title TEXT,
                page_count INTEGER NOT NULL DEFAULT 0,
                bytes INTEGER NOT NULL DEFAULT 0,
                downloaded_at TEXT NOT NULL DEFAULT (datetime('now')),
                PRIMARY KEY (catalog, catalog_id, chapter_id)
            );

            COMMIT;",
        )
        .map_err(|e| e.to_string())?;
        conn.pragma_update(None, "user_version", 5)
            .map_err(|e| e.to_string())?;
    }

    if version < 6 {
        conn.execute_batch(
            "BEGIN TRANSACTION;

            -- When a downloaded chapter was last opened, which is what the
            -- size cap evicts by. Downloading is not using: a chapter grabbed
            -- for a trip and never read should go before one read yesterday,
            -- and `downloaded_at` alone cannot tell them apart. Backfilled to
            -- the download time, which is the only thing known about rows
            -- that existed before this column did.
            ALTER TABLE offline_chapters ADD COLUMN last_used_at TEXT;
            UPDATE offline_chapters SET last_used_at = downloaded_at WHERE last_used_at IS NULL;

            COMMIT;",
        )
        .map_err(|e| e.to_string())?;
        conn.pragma_update(None, "user_version", 6)
            .map_err(|e| e.to_string())?;
    }

    if version < 7 {
        conn.execute_batch(
            "BEGIN TRANSACTION;

            -- Episodes downloaded to the Downloads folder.
            --
            -- The engine's own download map is session-only, and the file it
            -- copies out lives in ~/Downloads/Anicat and outlives every
            -- process: without this the app forgot, on every relaunch, that
            -- it had the episode -- the Downloads page came back empty and
            -- pressing Play re-fetched a file already on the disk.
            --
            -- `path` is where the copy landed. It is checked before use: a
            -- file the viewer has since moved or deleted has to read as not
            -- downloaded, which is why this table is an index and not the
            -- truth.
            CREATE TABLE IF NOT EXISTS downloaded_episodes (
                catalog TEXT NOT NULL,
                catalog_id INTEGER NOT NULL,
                episode_number INTEGER NOT NULL,
                title TEXT,
                path TEXT NOT NULL,
                bytes INTEGER NOT NULL DEFAULT 0,
                downloaded_at TEXT NOT NULL DEFAULT (datetime('now')),
                PRIMARY KEY (catalog, catalog_id, episode_number)
            );

            COMMIT;",
        )
        .map_err(|e| e.to_string())?;
        conn.pragma_update(None, "user_version", 7)
            .map_err(|e| e.to_string())?;
    }

    if version < 8 {
        // That an episode was finished, kept apart from where the player last
        // was.
        //
        // 'Watched' used to be derived from `stop_time / duration >= 0.85`
        // alone, and `stop_time` is a resume position that a rewatch is
        // entitled to reset: opening a finished episode and stopping 50
        // seconds in took a row from 1407/1420 to 50/1420, which dropped it
        // out of the statistics and made it read as unwatched. On
        // AniList-tracked anime the list progress masked it; a local-only
        // title, a signed-out device or a film had no such backstop.
        //
        // Set once and never cleared by a later position, so a rewatch moves
        // the resume point without disowning the watch. An explicit un-check
        // still deletes the row outright (`clear_progress_from`).
        //
        // Guarded on the column rather than on the version alone: this
        // migration was first written as a second `if version < 5` block
        // beside the one that creates `offline_chapters`, so a database
        // already stamped 5 or later skipped it entirely and every query
        // naming `completed` failed on that machine, while a database at 4
        // got the column and would now see this ALTER a second time.
        if !has_column(conn, "watch_history", "completed")? {
            conn.execute_batch(
                "BEGIN TRANSACTION;

                ALTER TABLE watch_history ADD COLUMN completed INTEGER NOT NULL DEFAULT 0;

                -- Existing rows already past the bar keep their standing.
                UPDATE watch_history
                   SET completed = 1
                 WHERE duration > 0 AND CAST(stop_time AS REAL) / duration >= 0.85;

                COMMIT;",
            )
            .map_err(|e| e.to_string())?;
        }
        conn.pragma_update(None, "user_version", 8)
            .map_err(|e| e.to_string())?;
    }

    if version < 9 {
        conn.execute_batch(
            "BEGIN TRANSACTION;

            -- What kind of thing was downloaded. Everything before this was a
            -- manga chapter -- a directory of page images -- and
            -- `offline_chapter_pages` answers with file paths the reader hands
            -- straight to an image view. A downloaded novel volume is prose in
            -- one JSON file, so without a discriminator here the first novel
            -- download would come back through that same call and the manga
            -- reader would try to decode a text file as a page.
            ALTER TABLE offline_chapters ADD COLUMN kind TEXT NOT NULL DEFAULT 'manga';

            COMMIT;",
        )
        .map_err(|e| e.to_string())?;
        conn.pragma_update(None, "user_version", 9)
            .map_err(|e| e.to_string())?;
    }

    // Opportunistic, not required for correctness: WAL lets a read (the
    // library view repainting) proceed while a write (a progress tick) is in
    // flight, instead of the two serializing on the rollback journal.
    let _ = conn.pragma_update(None, "journal_mode", "WAL");

    Ok(())
}

/// Whether a table already has a column, for a migration that has to be safe
/// to meet a database it has already run against under a different number.
fn has_column(conn: &rusqlite::Connection, table: &str, column: &str) -> Result<bool, String> {
    let mut stmt = conn
        .prepare(&format!("PRAGMA table_info({table})"))
        .map_err(|e| e.to_string())?;
    let mut rows = stmt.query([]).map_err(|e| e.to_string())?;
    while let Some(row) = rows.next().map_err(|e| e.to_string())? {
        let name: String = row.get(1).map_err(|e| e.to_string())?;
        if name == column {
            return Ok(true);
        }
    }
    Ok(false)
}
