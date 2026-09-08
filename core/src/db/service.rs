use std::path::Path;
use std::sync::Mutex;

use rusqlite::{params, Connection, OptionalExtension};

use super::schema::{migrate, Catalog};
use super::stats::{ProgressRow, WATCHED_FRACTION};
use crate::torrent::RememberedRelease;

/// The audio and subtitle tracks chosen for one title, by language rather
/// than by track index — see the `title_track_prefs` migration.
#[derive(Debug, Clone, PartialEq, Eq, Default)]
pub struct TrackPreference {
    pub audio_lang: Option<String>,
    pub subtitle_lang: Option<String>,
    pub subtitle_title: Option<String>,
}

/// One `resolved_releases` row as it travels between devices.
///
/// `RememberedRelease` deliberately carries no key and no timestamp -- it is
/// the answer to "what played this episode" and nothing more. A row on the
/// wire needs both: the key to land on the other side, and `resolved_at` so
/// the merge can tell which device saw it last.
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct ExportedRelease {
    pub catalog: String,
    pub catalog_id: i64,
    pub episode_number: i64,
    pub name: String,
    pub magnet: Option<String>,
    pub torrent_url: Option<String>,
    pub assume_batch: bool,
    pub prefer_dub: bool,
    pub resolved_at: String,
}

/// `datetime('now')` writes `YYYY-MM-DD HH:MM:SS` with no zone marker, and it
/// is always UTC. Parsed here, at the one boundary that knows that, so the
/// aggregation upstream deals in real instants.
fn parse_watched_at(raw: &str) -> Option<chrono::DateTime<chrono::Utc>> {
    chrono::NaiveDateTime::parse_from_str(raw.trim(), "%Y-%m-%d %H:%M:%S")
        .ok()
        .map(|naive| naive.and_utc())
}

/// An episode's playback position, as stored.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub struct WatchEntry {
    pub episode_number: i64,
    pub stop_time: i64,
    pub duration: i64,
    /// Set once the episode passed the 85% bar and never cleared by a later
    /// position; see migration 5. Read alongside the percentage rather than
    /// instead of it, so a row written before the column existed still counts.
    pub completed: bool,
}

/// A chapter about to be recorded as downloaded. A record rather than eight
/// positional arguments, half of them strings that would sit next to each
/// other at the call site.
pub struct NewOfflineChapter<'a> {
    pub catalog: Catalog,
    pub catalog_id: i64,
    pub chapter_id: &'a str,
    pub chapter_number: &'a str,
    pub title: Option<&'a str>,
    pub page_count: i64,
    pub bytes: i64,
}

/// One episode copied into the Downloads folder.
#[derive(Debug, Clone)]
pub struct DownloadedEpisode {
    pub catalog: Catalog,
    pub catalog_id: i64,
    pub episode_number: i64,
    pub title: Option<String>,
    pub path: String,
    pub bytes: i64,
    pub downloaded_at: String,
}

/// One chapter kept on disk.
#[derive(Debug, Clone)]
pub struct OfflineChapter {
    pub catalog: Catalog,
    pub catalog_id: i64,
    pub chapter_id: String,
    pub chapter_number: String,
    pub title: Option<String>,
    pub page_count: i64,
    pub bytes: i64,
    pub downloaded_at: String,
    /// When it was last opened. Eviction order, and not the same as
    /// `downloaded_at`: a chapter grabbed for a trip and never read should go
    /// before one read yesterday.
    pub last_used_at: String,
}

/// One chapter, as far as it was read.
#[derive(Debug, Clone)]
pub struct ReadingEntry {
    pub catalog: Catalog,
    pub catalog_id: i64,
    pub chapter_id: String,
    pub chapter_number: String,
    pub page: i64,
    pub page_count: i64,
    /// `YYYY-MM-DD HH:MM:SS` in UTC, as SQLite writes it.
    pub read_at: String,
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
                 (catalog, catalog_id, episode_number, stop_time, duration, completed, watched_at)
             VALUES (?1, ?2, ?3, ?4, ?5, ?6, datetime('now'))
             ON CONFLICT(catalog, catalog_id, episode_number) DO UPDATE SET
                 stop_time = excluded.stop_time,
                 -- A zero duration means the player had not reported one yet.
                 -- Keeping the known value stops a late tick from erasing the
                 -- denominator the watched-percentage is computed against.
                 duration = CASE WHEN excluded.duration > 0
                                 THEN excluded.duration ELSE duration END,
                 -- Sticky: a rewatch resets the position, not the fact. See
                 -- migration 5 -- 50 seconds into a finished episode used to
                 -- take it back out of the watched set entirely.
                 completed = CASE WHEN excluded.completed = 1
                                  THEN 1 ELSE completed END,
                 watched_at = excluded.watched_at",
            params![
                catalog.as_str(),
                catalog_id,
                episode_number,
                stop_time,
                duration,
                i64::from(duration > 0 && (stop_time as f64 / duration as f64) >= WATCHED_FRACTION)
            ],
        )
        .map_err(|e| e.to_string())?;
        Ok(())
    }

    /// Forgets the local watch record for an episode and every episode after
    /// it, for an explicit un-check in the episode list.
    ///
    /// Without this an un-check could not stick. `episode_is_watched` is
    /// `local_percent >= 85.0 || number <= anilist_progress`, so a history
    /// row past 85% pins the box on whatever AniList says: un-checking
    /// episode 10 of AniList 156023 (stop_time 1319 of 1420, 92.9%) wrote
    /// `progress: 9`, AniList took it, and the row snapped straight back to
    /// checked. The viewer clicked it six times.
    ///
    /// Rows are deleted rather than zeroed because `recent_activity` and
    /// `progress_rows` select every row regardless of `stop_time` — a
    /// zeroed one would keep the episode in the activity feed and in the
    /// lifetime statistics as something that was watched.
    ///
    /// From `from_episode` rather than that one episode alone: AniList holds
    /// a single progress number, so un-checking episode 5 means "I have
    /// watched up to 4", and leaving 6 through 10 locally watched would show
    /// them checked while the list said 4.
    pub fn clear_progress_from(
        &self,
        catalog: Catalog,
        catalog_id: i64,
        from_episode: i64,
    ) -> Result<(), String> {
        let conn = self.lock()?;
        conn.execute(
            "DELETE FROM watch_history
             WHERE catalog = ?1 AND catalog_id = ?2 AND episode_number >= ?3",
            params![catalog.as_str(), catalog_id, from_episode],
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
            "SELECT episode_number, stop_time, duration, completed FROM watch_history
             WHERE catalog = ?1 AND catalog_id = ?2 AND episode_number = ?3",
            params![catalog.as_str(), catalog_id, episode_number],
            |r| {
                Ok(WatchEntry {
                    episode_number: r.get(0)?,
                    stop_time: r.get(1)?,
                    duration: r.get(2)?,
                    completed: r.get::<_, i64>(3)? == 1,
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
                "SELECT episode_number, stop_time, duration, completed FROM watch_history
                 WHERE catalog = ?1 AND catalog_id = ?2 ORDER BY episode_number",
            )
            .map_err(|e| e.to_string())?;
        let rows = stmt
            .query_map(params![catalog.as_str(), catalog_id], |r| {
                Ok(WatchEntry {
                    episode_number: r.get(0)?,
                    stop_time: r.get(1)?,
                    duration: r.get(2)?,
                    completed: r.get::<_, i64>(3)? == 1,
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

    /// Every watch ever recorded, for the statistics page.
    ///
    /// Unbounded and unfiltered on purpose: only `per_day` is windowed, and
    /// the lifetime totals, the longest streak and the busiest hour all read
    /// the whole table. Narrowing this by date in SQL would quietly leave six
    /// of the eight figures describing the window instead of the library.
    ///
    /// A row whose `watched_at` will not parse is skipped rather than
    /// failing the query — one unreadable timestamp must not cost the viewer
    /// their whole history.
    pub fn progress_rows(&self) -> Result<Vec<ProgressRow>, String> {
        let conn = self.lock()?;
        let mut stmt = conn
            .prepare(
                "SELECT catalog, catalog_id, episode_number, stop_time, duration, completed,
                        watched_at
                 FROM watch_history",
            )
            .map_err(|e| e.to_string())?;
        let rows = stmt
            .query_map([], |r| {
                Ok((
                    r.get::<_, String>(0)?,
                    r.get::<_, i64>(1)?,
                    r.get::<_, i64>(2)?,
                    r.get::<_, i64>(3)?,
                    r.get::<_, i64>(4)?,
                    r.get::<_, i64>(5)? == 1,
                    r.get::<_, String>(6)?,
                ))
            })
            .map_err(|e| e.to_string())?;
        let mut out = Vec::new();
        for row in rows {
            let (catalog, catalog_id, episode_number, stop_time, duration, completed, watched_at) =
                row.map_err(|e| e.to_string())?;
            let Some(parsed) = parse_watched_at(&watched_at) else {
                log::warn!("watch_history: unreadable watched_at {watched_at:?}, skipping row");
                continue;
            };
            out.push(ProgressRow {
                catalog,
                catalog_id,
                episode_number,
                stop_time,
                duration,
                completed,
                watched_at: parsed,
            });
        }
        Ok(out)
    }

    /// The audio and subtitle tracks the viewer last chose for a title.
    pub fn title_track_preference(
        &self,
        catalog: Catalog,
        catalog_id: i64,
    ) -> Result<Option<TrackPreference>, String> {
        let conn = self.lock()?;
        conn.query_row(
            "SELECT audio_lang, subtitle_lang, subtitle_title FROM title_track_prefs
             WHERE catalog = ?1 AND catalog_id = ?2",
            params![catalog.as_str(), catalog_id],
            |r| {
                Ok(TrackPreference {
                    audio_lang: r.get(0)?,
                    subtitle_lang: r.get(1)?,
                    subtitle_title: r.get(2)?,
                })
            },
        )
        .optional()
        .map_err(|e| e.to_string())
    }

    /// Replaces the whole preference for a title.
    ///
    /// Every column is written, `None` included: turning subtitles off is a
    /// choice the next episode has to honor, and merging only the non-null
    /// fields would make it impossible to record.
    pub fn set_title_track_preference(
        &self,
        catalog: Catalog,
        catalog_id: i64,
        pref: &TrackPreference,
    ) -> Result<(), String> {
        let conn = self.lock()?;
        conn.execute(
            "INSERT INTO title_track_prefs
                 (catalog, catalog_id, audio_lang, subtitle_lang, subtitle_title, updated_at)
             VALUES (?1, ?2, ?3, ?4, ?5, datetime('now'))
             ON CONFLICT(catalog, catalog_id) DO UPDATE SET
                 audio_lang = excluded.audio_lang,
                 subtitle_lang = excluded.subtitle_lang,
                 subtitle_title = excluded.subtitle_title,
                 updated_at = excluded.updated_at",
            params![
                catalog.as_str(),
                catalog_id,
                pref.audio_lang,
                pref.subtitle_lang,
                pref.subtitle_title
            ],
        )
        .map_err(|e| e.to_string())?;
        Ok(())
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

    /// Notes a chapter as downloaded.
    pub fn record_offline_chapter(&self, row: NewOfflineChapter<'_>) -> Result<(), String> {
        let NewOfflineChapter {
            catalog,
            catalog_id,
            chapter_id,
            chapter_number,
            title,
            page_count,
            bytes,
        } = row;
        let conn = self.lock()?;
        conn.execute(
            "INSERT INTO offline_chapters
                (catalog, catalog_id, chapter_id, chapter_number, title, page_count, bytes, downloaded_at, last_used_at)
             VALUES (?1, ?2, ?3, ?4, ?5, ?6, ?7, datetime('now'), datetime('now'))
             ON CONFLICT(catalog, catalog_id, chapter_id) DO UPDATE SET
               chapter_number = excluded.chapter_number,
               title = excluded.title,
               page_count = excluded.page_count,
               bytes = excluded.bytes,
               downloaded_at = excluded.downloaded_at,
               last_used_at = excluded.downloaded_at",
            params![
                catalog.as_str(),
                catalog_id,
                chapter_id,
                chapter_number,
                title,
                page_count,
                bytes
            ],
        )
        .map(|_| ())
        .map_err(|e| e.to_string())
    }

    /// Notes an episode as downloaded, with where the file landed.
    pub fn record_downloaded_episode(
        &self,
        catalog: Catalog,
        catalog_id: i64,
        episode: i64,
        title: Option<&str>,
        path: &str,
        bytes: i64,
    ) -> Result<(), String> {
        let conn = self.lock()?;
        conn.execute(
            "INSERT INTO downloaded_episodes
                (catalog, catalog_id, episode_number, title, path, bytes, downloaded_at)
             VALUES (?1, ?2, ?3, ?4, ?5, ?6, datetime('now'))
             ON CONFLICT(catalog, catalog_id, episode_number) DO UPDATE SET
               title = excluded.title,
               path = excluded.path,
               bytes = excluded.bytes,
               downloaded_at = excluded.downloaded_at",
            params![catalog.as_str(), catalog_id, episode, title, path, bytes],
        )
        .map(|_| ())
        .map_err(|e| e.to_string())
    }

    pub fn forget_downloaded_episode(
        &self,
        catalog: Catalog,
        catalog_id: i64,
        episode: i64,
    ) -> Result<(), String> {
        let conn = self.lock()?;
        conn.execute(
            "DELETE FROM downloaded_episodes
             WHERE catalog = ?1 AND catalog_id = ?2 AND episode_number = ?3",
            params![catalog.as_str(), catalog_id, episode],
        )
        .map(|_| ())
        .map_err(|e| e.to_string())
    }

    /// Every downloaded episode, newest first.
    pub fn downloaded_episodes(&self) -> Result<Vec<DownloadedEpisode>, String> {
        let conn = self.lock()?;
        let mut stmt = conn
            .prepare(
                "SELECT catalog, catalog_id, episode_number, title, path, bytes, downloaded_at
                 FROM downloaded_episodes ORDER BY downloaded_at DESC",
            )
            .map_err(|e| e.to_string())?;
        let rows = stmt
            .query_map([], |r| {
                Ok((
                    r.get::<_, String>(0)?,
                    r.get::<_, i64>(1)?,
                    r.get::<_, i64>(2)?,
                    r.get::<_, Option<String>>(3)?,
                    r.get::<_, String>(4)?,
                    r.get::<_, i64>(5)?,
                    r.get::<_, String>(6)?,
                ))
            })
            .map_err(|e| e.to_string())?;
        let mut out = vec![];
        for row in rows {
            let (catalog, catalog_id, episode, title, path, bytes, at) =
                row.map_err(|e| e.to_string())?;
            let Some(catalog) = Catalog::parse(&catalog) else { continue };
            out.push(DownloadedEpisode {
                catalog,
                catalog_id,
                episode_number: episode,
                title,
                path,
                bytes,
                downloaded_at: at,
            });
        }
        Ok(out)
    }

    /// Marks a downloaded chapter as just used, so the size cap evicts it
    /// last. Called on open, not on download.
    pub fn touch_offline_chapter(
        &self,
        catalog: Catalog,
        catalog_id: i64,
        chapter_id: &str,
    ) -> Result<(), String> {
        let conn = self.lock()?;
        conn.execute(
            "UPDATE offline_chapters SET last_used_at = datetime('now')
             WHERE catalog = ?1 AND catalog_id = ?2 AND chapter_id = ?3",
            params![catalog.as_str(), catalog_id, chapter_id],
        )
        .map(|_| ())
        .map_err(|e| e.to_string())
    }

    /// Downloaded chapters, least recently used first -- eviction order.
    pub fn offline_chapters_by_age(&self) -> Result<Vec<OfflineChapter>, String> {
        let mut rows = self.offline_chapters()?;
        rows.sort_by(|a, b| a.last_used_at.cmp(&b.last_used_at));
        Ok(rows)
    }

    pub fn forget_offline_chapter(
        &self,
        catalog: Catalog,
        catalog_id: i64,
        chapter_id: &str,
    ) -> Result<(), String> {
        let conn = self.lock()?;
        conn.execute(
            "DELETE FROM offline_chapters WHERE catalog = ?1 AND catalog_id = ?2 AND chapter_id = ?3",
            params![catalog.as_str(), catalog_id, chapter_id],
        )
        .map(|_| ())
        .map_err(|e| e.to_string())
    }

    /// Every downloaded chapter, newest first.
    pub fn offline_chapters(&self) -> Result<Vec<OfflineChapter>, String> {
        let conn = self.lock()?;
        let mut stmt = conn
            .prepare(
                "SELECT catalog, catalog_id, chapter_id, chapter_number, title, page_count, bytes,
                        downloaded_at, COALESCE(last_used_at, downloaded_at)
                 FROM offline_chapters ORDER BY downloaded_at DESC",
            )
            .map_err(|e| e.to_string())?;
        let rows = stmt
            .query_map([], |r| {
                Ok((
                    r.get::<_, String>(0)?,
                    r.get::<_, i64>(1)?,
                    r.get::<_, String>(2)?,
                    r.get::<_, String>(3)?,
                    r.get::<_, Option<String>>(4)?,
                    r.get::<_, i64>(5)?,
                    r.get::<_, i64>(6)?,
                    r.get::<_, String>(7)?,
                    r.get::<_, String>(8)?,
                ))
            })
            .map_err(|e| e.to_string())?;
        let mut out = vec![];
        for row in rows {
            let (catalog, catalog_id, chapter_id, chapter_number, title, page_count, bytes, at, used) =
                row.map_err(|e| e.to_string())?;
            let Some(catalog) = Catalog::parse(&catalog) else { continue };
            out.push(OfflineChapter {
                catalog,
                catalog_id,
                chapter_id,
                chapter_number,
                title,
                page_count,
                bytes,
                downloaded_at: at,
                last_used_at: used,
            });
        }
        Ok(out)
    }

    /// Records where a chapter was left.
    ///
    /// Written on every page turn, so it is an upsert on the chapter rather
    /// than an append: the row is "where you are", and a history of every
    /// page you passed through is not something anything reads.
    pub fn record_reading_progress(
        &self,
        catalog: Catalog,
        catalog_id: i64,
        chapter_id: &str,
        chapter_number: &str,
        page: i64,
        page_count: i64,
    ) -> Result<(), String> {
        let conn = self.lock()?;
        conn.execute(
            "INSERT INTO reading_history
                (catalog, catalog_id, chapter_id, chapter_number, page, page_count, read_at)
             VALUES (?1, ?2, ?3, ?4, ?5, ?6, datetime('now'))
             ON CONFLICT(catalog, catalog_id, chapter_id) DO UPDATE SET
               page = excluded.page,
               page_count = excluded.page_count,
               chapter_number = excluded.chapter_number,
               read_at = excluded.read_at",
            params![catalog.as_str(), catalog_id, chapter_id, chapter_number, page, page_count],
        )
        .map(|_| ())
        .map_err(|e| e.to_string())
    }

    /// The page a chapter was left on, and what it was out of.
    pub fn reading_progress(
        &self,
        catalog: Catalog,
        catalog_id: i64,
        chapter_id: &str,
    ) -> Result<Option<(i64, i64)>, String> {
        let conn = self.lock()?;
        conn.query_row(
            "SELECT page, page_count FROM reading_history
             WHERE catalog = ?1 AND catalog_id = ?2 AND chapter_id = ?3",
            params![catalog.as_str(), catalog_id, chapter_id],
            |row| Ok((row.get(0)?, row.get(1)?)),
        )
        .optional()
        .map_err(|e| e.to_string())
    }

    /// Chapters read, newest first -- the reading counterpart of
    /// `recent_activity`.
    pub fn recent_reading(&self, limit: i64) -> Result<Vec<ReadingEntry>, String> {
        let conn = self.lock()?;
        let mut stmt = conn
            .prepare(
                "SELECT catalog, catalog_id, chapter_id, chapter_number, page, page_count, read_at
                 FROM reading_history ORDER BY read_at DESC LIMIT ?1",
            )
            .map_err(|e| e.to_string())?;
        let rows = stmt
            .query_map(params![limit], |r| {
                Ok((
                    r.get::<_, String>(0)?,
                    r.get::<_, i64>(1)?,
                    r.get::<_, String>(2)?,
                    r.get::<_, String>(3)?,
                    r.get::<_, i64>(4)?,
                    r.get::<_, i64>(5)?,
                    r.get::<_, String>(6)?,
                ))
            })
            .map_err(|e| e.to_string())?;
        let mut out = vec![];
        for row in rows {
            let (catalog, catalog_id, chapter_id, chapter_number, page, page_count, read_at) =
                row.map_err(|e| e.to_string())?;
            let Some(catalog) = Catalog::parse(&catalog) else { continue };
            out.push(ReadingEntry {
                catalog,
                catalog_id,
                chapter_id,
                chapter_number,
                page,
                page_count,
                read_at,
            });
        }
        Ok(out)
    }

    /// The viewer's own list for a catalog AniList does not track.
    ///
    /// `local_library` has been in the schema since migration 1 and unused
    /// since: anime lists live on AniList. A film has no such home, so this
    /// is the only place a "want to watch" can be kept, and it stays on the
    /// device that recorded it.
    pub fn set_local_status(
        &self,
        catalog: Catalog,
        catalog_id: i64,
        status: Option<&str>,
    ) -> Result<(), String> {
        let conn = self.lock()?;
        match status {
            // Clearing removes the row rather than storing an empty status:
            // "not on the list" and "on the list with no status" are the same
            // thing to every reader, and one of them would sort oddly.
            None => conn
                .execute(
                    "DELETE FROM local_library WHERE catalog = ?1 AND catalog_id = ?2",
                    params![catalog.as_str(), catalog_id],
                )
                .map(|_| ())
                .map_err(|e| e.to_string()),
            Some(status) => conn
                .execute(
                    "INSERT INTO local_library (catalog, catalog_id, status, updated_at)
                     VALUES (?1, ?2, ?3, datetime('now'))
                     ON CONFLICT(catalog, catalog_id) DO UPDATE SET
                       status = excluded.status, updated_at = excluded.updated_at",
                    params![catalog.as_str(), catalog_id, status],
                )
                .map(|_| ())
                .map_err(|e| e.to_string()),
        }
    }

    pub fn local_status(&self, catalog: Catalog, catalog_id: i64) -> Result<Option<String>, String> {
        let conn = self.lock()?;
        conn.query_row(
            "SELECT status FROM local_library WHERE catalog = ?1 AND catalog_id = ?2",
            params![catalog.as_str(), catalog_id],
            |row| row.get::<_, Option<String>>(0),
        )
        .optional()
        .map(|v| v.flatten())
        .map_err(|e| e.to_string())
    }

    /// Everything on the local list, newest first. `status` narrows it;
    /// `catalogs` keeps anime's own rows out of a cinema list.
    pub fn local_library(
        &self,
        catalogs: &[Catalog],
        status: Option<&str>,
    ) -> Result<Vec<(Catalog, i64, String)>, String> {
        let conn = self.lock()?;
        let mut stmt = conn
            .prepare(
                "SELECT catalog, catalog_id, status FROM local_library
                 WHERE status IS NOT NULL ORDER BY updated_at DESC",
            )
            .map_err(|e| e.to_string())?;
        let rows = stmt
            .query_map([], |r| {
                Ok((
                    r.get::<_, String>(0)?,
                    r.get::<_, i64>(1)?,
                    r.get::<_, String>(2)?,
                ))
            })
            .map_err(|e| e.to_string())?;
        let mut out = vec![];
        for row in rows {
            let (catalog, id, row_status) = row.map_err(|e| e.to_string())?;
            let Some(catalog) = Catalog::parse(&catalog) else { continue };
            if !catalogs.is_empty() && !catalogs.contains(&catalog) {
                continue;
            }
            if let Some(status) = status {
                if !row_status.eq_ignore_ascii_case(status) {
                    continue;
                }
            }
            out.push((catalog, id, row_status));
        }
        Ok(out)
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

    /// The release that last played for this episode, if one was recorded.
    pub fn remembered_release(
        &self,
        catalog: Catalog,
        catalog_id: i64,
        episode: i64,
    ) -> Result<Option<RememberedRelease>, String> {
        let conn = self.lock()?;
        conn.query_row(
            "SELECT name, magnet, torrent_url, assume_batch, prefer_dub
             FROM resolved_releases
             WHERE catalog = ?1 AND catalog_id = ?2 AND episode_number = ?3",
            params![catalog.as_str(), catalog_id, episode],
            |r| {
                Ok(RememberedRelease {
                    name: r.get(0)?,
                    magnet: r.get(1)?,
                    torrent_url: r.get(2)?,
                    assume_batch: r.get::<_, i64>(3)? != 0,
                    prefer_dub: r.get::<_, i64>(4)? != 0,
                })
            },
        )
        .optional()
        .map_err(|e| e.to_string())
    }

    pub fn remember_release(
        &self,
        catalog: Catalog,
        catalog_id: i64,
        episode: i64,
        release: &RememberedRelease,
    ) -> Result<(), String> {
        let conn = self.lock()?;
        conn.execute(
            "INSERT INTO resolved_releases
                (catalog, catalog_id, episode_number, name, magnet, torrent_url, assume_batch, prefer_dub, resolved_at)
             VALUES (?1, ?2, ?3, ?4, ?5, ?6, ?7, ?8, datetime('now'))
             ON CONFLICT(catalog, catalog_id, episode_number) DO UPDATE SET
                name = excluded.name,
                magnet = excluded.magnet,
                torrent_url = excluded.torrent_url,
                assume_batch = excluded.assume_batch,
                prefer_dub = excluded.prefer_dub,
                resolved_at = excluded.resolved_at",
            params![
                catalog.as_str(),
                catalog_id,
                episode,
                release.name,
                release.magnet,
                release.torrent_url,
                release.assume_batch as i64,
                release.prefer_dub as i64,
            ],
        )
        .map_err(|e| e.to_string())?;
        Ok(())
    }

    /// Every remembered release, with the timestamp, for handing to another
    /// device on the LAN.
    ///
    /// This table and no other. The registry also holds per-show prefs,
    /// provider-slug overrides and track languages, and none of them are
    /// safe to copy blind: a track preference is stored by language plus
    /// `subtitle_title` as a tie-break for one release's mux, and the other
    /// device is routinely playing a different one. A remembered release is
    /// the exception because a stale one is self-healing -- `resolve` tries
    /// it under a bounded budget and falls through to an ordinary search
    /// when it is dead.
    pub fn export_resolved_releases(&self) -> Result<Vec<ExportedRelease>, String> {
        let conn = self.lock()?;
        let mut stmt = conn
            .prepare(
                "SELECT catalog, catalog_id, episode_number, name, magnet,
                        torrent_url, assume_batch, prefer_dub, resolved_at
                 FROM resolved_releases",
            )
            .map_err(|e| e.to_string())?;
        let rows = stmt
            .query_map([], |r| {
                Ok(ExportedRelease {
                    catalog: r.get(0)?,
                    catalog_id: r.get(1)?,
                    episode_number: r.get(2)?,
                    name: r.get(3)?,
                    magnet: r.get(4)?,
                    torrent_url: r.get(5)?,
                    assume_batch: r.get::<_, i64>(6)? != 0,
                    prefer_dub: r.get::<_, i64>(7)? != 0,
                    resolved_at: r.get(8)?,
                })
            })
            .map_err(|e| e.to_string())?;
        rows.collect::<Result<Vec<_>, _>>()
            .map_err(|e| e.to_string())
    }

    /// Merges another device's remembered releases in, newest wins.
    ///
    /// The `WHERE` on the upsert is what makes this safe to run in both
    /// directions and repeatedly: `resolved_at` is written by
    /// `datetime('now')` in UTC, so it compares as text, and a row that is
    /// older than the one already here is left alone rather than overwriting
    /// a resolve this device made more recently. Returns how many rows
    /// actually changed.
    pub fn import_resolved_releases(&self, rows: &[ExportedRelease]) -> Result<u32, String> {
        let mut conn = self.lock()?;
        let tx = conn.transaction().map_err(|e| e.to_string())?;
        let mut changed = 0u32;
        for row in rows {
            // A catalog this build does not know is skipped rather than
            // stored: the column is the source of truth for which id space
            // `catalog_id` is in, and an unknown one would sit in the table
            // matching nothing forever.
            if Catalog::parse(&row.catalog).is_none() {
                continue;
            }
            changed += tx
                .execute(
                    "INSERT INTO resolved_releases
                        (catalog, catalog_id, episode_number, name, magnet,
                         torrent_url, assume_batch, prefer_dub, resolved_at)
                     VALUES (?1, ?2, ?3, ?4, ?5, ?6, ?7, ?8, ?9)
                     ON CONFLICT(catalog, catalog_id, episode_number) DO UPDATE SET
                        name = excluded.name,
                        magnet = excluded.magnet,
                        torrent_url = excluded.torrent_url,
                        assume_batch = excluded.assume_batch,
                        prefer_dub = excluded.prefer_dub,
                        resolved_at = excluded.resolved_at
                     WHERE excluded.resolved_at > resolved_releases.resolved_at",
                    params![
                        row.catalog,
                        row.catalog_id,
                        row.episode_number,
                        row.name,
                        row.magnet,
                        row.torrent_url,
                        row.assume_batch as i64,
                        row.prefer_dub as i64,
                        row.resolved_at,
                    ],
                )
                .map_err(|e| e.to_string())? as u32;
        }
        tx.commit().map_err(|e| e.to_string())?;
        Ok(changed)
    }

    /// Wipes every table: resume positions, provider-slug overrides, the
    /// offline list mirror, and per-show prefs. Schema/migrations are left
    /// alone — only rows go, not structure — so the next write just refills
    /// an empty database rather than re-running `migrate`.
    /// Marks an episode finished without moving the resume position.
    ///
    /// The 85% rule only ever fires from a playback tick, so pressing "next
    /// episode" part-way through left the outgoing episode unmarked -- and
    /// unlike the AniList write, nothing else would ever set it later. The
    /// position is deliberately untouched: the viewer left where they left.
    pub fn mark_completed(
        &self,
        catalog: Catalog,
        catalog_id: i64,
        episode_number: i64,
    ) -> Result<(), String> {
        let conn = self.lock()?;
        conn.execute(
            "INSERT INTO watch_history
                 (catalog, catalog_id, episode_number, stop_time, duration, completed, watched_at)
             VALUES (?1, ?2, ?3, 0, 0, 1, datetime('now'))
             ON CONFLICT(catalog, catalog_id, episode_number) DO UPDATE SET
                 completed = 1,
                 watched_at = excluded.watched_at",
            params![catalog.as_str(), catalog_id, episode_number],
        )
        .map(|_| ())
        .map_err(|e| e.to_string())
    }

    /// Empties the watch log, and only that.
    ///
    /// Deliberately not `clear_all` under another name: that also drops the
    /// resume positions, the remembered releases and the track picks, which
    /// is a different thing to ask for. The History page has offered a
    /// "Clear history" button since it was written and had no engine call to
    /// bind it to, so the button was never drawn.
    pub fn clear_watch_history(&self) -> Result<(), String> {
        let conn = self.lock()?;
        conn.execute("DELETE FROM watch_history", [])
            .map(|_| ())
            .map_err(|e| e.to_string())
    }

    /// Forgets one watch. The row is deleted rather than zeroed: a zeroed row
    /// stays in `recent_activity` and the lifetime totals, which both read
    /// every row regardless of position.
    pub fn remove_watch(
        &self,
        catalog: Catalog,
        catalog_id: i64,
        episode_number: i64,
    ) -> Result<(), String> {
        let conn = self.lock()?;
        conn.execute(
            "DELETE FROM watch_history
             WHERE catalog = ?1 AND catalog_id = ?2 AND episode_number = ?3",
            params![catalog.as_str(), catalog_id, episode_number],
        )
        .map(|_| ())
        .map_err(|e| e.to_string())
    }

    pub fn clear_all(&self) -> Result<(), String> {
        let conn = self.lock()?;
        conn.execute_batch(
            "BEGIN TRANSACTION;
            DELETE FROM watch_history;
            DELETE FROM resolved_releases;
            DELETE FROM provider_slugs;
            DELETE FROM local_library;
            DELETE FROM media_prefs;
            DELETE FROM title_track_prefs;
            COMMIT;",
        )
        .map_err(|e| e.to_string())
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    fn exported(name: &str, resolved_at: &str) -> ExportedRelease {
        ExportedRelease {
            catalog: "anilist".into(),
            catalog_id: 21,
            episode_number: 3,
            name: name.into(),
            magnet: Some("magnet:?xt=1".into()),
            torrent_url: None,
            assume_batch: false,
            prefer_dub: false,
            resolved_at: resolved_at.into(),
        }
    }

    #[test]
    fn an_imported_release_older_than_the_local_one_is_ignored() {
        let db = Registry::open_in_memory().unwrap();
        db.import_resolved_releases(&[exported("local", "2026-09-08 12:00:00")])
            .unwrap();

        // The whole point of carrying `resolved_at` across the wire: a phone
        // that has not watched this episode in weeks must not push its stale
        // answer over the Mac's fresh one just by being the side that asked.
        let changed = db
            .import_resolved_releases(&[exported("stale", "2026-09-01 12:00:00")])
            .unwrap();
        assert_eq!(changed, 0);

        let kept = db.remembered_release(Catalog::Anilist, 21, 3).unwrap().unwrap();
        assert_eq!(kept.name, "local");
    }

    #[test]
    fn an_imported_release_newer_than_the_local_one_wins() {
        let db = Registry::open_in_memory().unwrap();
        db.import_resolved_releases(&[exported("old", "2026-09-01 12:00:00")])
            .unwrap();

        let changed = db
            .import_resolved_releases(&[exported("fresh", "2026-09-08 12:00:00")])
            .unwrap();
        assert_eq!(changed, 1);
        assert_eq!(
            db.remembered_release(Catalog::Anilist, 21, 3).unwrap().unwrap().name,
            "fresh"
        );
    }

    #[test]
    fn a_release_from_a_catalog_this_build_cannot_name_is_dropped() {
        let db = Registry::open_in_memory().unwrap();
        let mut row = exported("from the future", "2026-09-08 12:00:00");
        row.catalog = "kitsu".into();

        // Stored, the row would sit in the table matching nothing forever:
        // the column is what says which id space `catalog_id` belongs to.
        assert_eq!(db.import_resolved_releases(&[row]).unwrap(), 0);
        assert!(db.export_resolved_releases().unwrap().is_empty());
    }

    #[test]
    fn a_chapter_and_an_episode_of_one_title_do_not_overwrite_each_other() {
        let db = Registry::open_in_memory().unwrap();
        // The reason this is its own table: both are AniList id 21 here.
        db.record_progress(Catalog::Anilist, 21, 3, 600, 1400).unwrap();
        db.record_reading_progress(Catalog::Anilist, 21, "ch-3", "3", 4, 20).unwrap();

        assert_eq!(db.reading_progress(Catalog::Anilist, 21, "ch-3").unwrap(), Some((4, 20)));
        let watched = db.history_for(Catalog::Anilist, 21).unwrap();
        assert_eq!(watched.len(), 1);
        assert_eq!(watched[0].stop_time, 600);
    }

    #[test]
    fn a_page_turn_moves_the_chapter_rather_than_adding_a_row() {
        let db = Registry::open_in_memory().unwrap();
        for page in 0..5 {
            db.record_reading_progress(Catalog::Anilist, 21, "ch-10.5", "10.5", page, 18).unwrap();
        }
        let rows = db.recent_reading(10).unwrap();
        assert_eq!(rows.len(), 1, "the row is where you are, not every page you passed");
        assert_eq!(rows[0].page, 4);
        // Fractional chapters are real, which is why the number is text.
        assert_eq!(rows[0].chapter_number, "10.5");
    }

    #[test]
    fn the_local_list_keeps_catalogs_apart_and_clears_by_deleting() {
        let db = Registry::open_in_memory().unwrap();
        db.set_local_status(Catalog::TmdbMovie, 550, Some("PLANNING")).unwrap();
        db.set_local_status(Catalog::TmdbTv, 550, Some("CURRENT")).unwrap();
        // Same number, three catalogs, three different titles.
        db.set_local_status(Catalog::Anilist, 550, Some("COMPLETED")).unwrap();

        let cinema = db.local_library(&[Catalog::TmdbMovie, Catalog::TmdbTv], None).unwrap();
        assert_eq!(cinema.len(), 2, "an anime row must not reach a cinema list");
        assert_eq!(db.local_status(Catalog::TmdbMovie, 550).unwrap().as_deref(), Some("PLANNING"));

        let planning = db
            .local_library(&[Catalog::TmdbMovie, Catalog::TmdbTv], Some("PLANNING"))
            .unwrap();
        assert_eq!(planning.len(), 1);

        // Clearing removes the row: "not on the list" and "on the list with
        // no status" would otherwise be two states meaning one thing.
        db.set_local_status(Catalog::TmdbMovie, 550, None).unwrap();
        assert_eq!(db.local_status(Catalog::TmdbMovie, 550).unwrap(), None);
        assert_eq!(
            db.local_library(&[Catalog::TmdbMovie, Catalog::TmdbTv], None).unwrap().len(),
            1
        );
    }

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
    fn an_un_check_forgets_that_episode_and_the_ones_after_it() {
        // The shape of the bug this exists for: episodes watched to the end
        // stay watched locally, so nothing below the un-checked one may be
        // touched and nothing at or above it may survive.
        let db = Registry::open_in_memory().unwrap();
        for ep in 8..=11 {
            db.record_progress(Catalog::Anilist, 156023, ep, 1319, 1420).unwrap();
        }
        // Another title's episode 10 must not be swept up with it.
        db.record_progress(Catalog::Anilist, 1535, 10, 1319, 1420).unwrap();

        db.clear_progress_from(Catalog::Anilist, 156023, 10).unwrap();

        assert!(db.get_progress(Catalog::Anilist, 156023, 9).unwrap().is_some());
        assert!(db.get_progress(Catalog::Anilist, 156023, 10).unwrap().is_none());
        assert!(db.get_progress(Catalog::Anilist, 156023, 11).unwrap().is_none());
        assert!(db.get_progress(Catalog::Anilist, 1535, 10).unwrap().is_some());
        // Deleted, not zeroed: a zeroed row still counts as a watch in
        // `recent_activity` and in the lifetime statistics.
        assert!(db.recent_activity(10).unwrap().iter().all(|a| {
            !(a.catalog_id == 156023 && a.episode_number >= 10)
        }));
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
    fn clearing_the_watch_log_leaves_the_rest_of_the_registry_alone() {
        let db = Registry::open_in_memory().unwrap();
        db.record_progress(Catalog::Anilist, 21, 1, 100, 1400).unwrap();
        db.record_progress(Catalog::TmdbTv, 21, 1, 100, 1400).unwrap();
        db.set_provider_slug(Catalog::Anilist, 21, "nyaa", "One Piece").unwrap();

        db.remove_watch(Catalog::TmdbTv, 21, 1).unwrap();
        assert!(db.get_progress(Catalog::TmdbTv, 21, 1).unwrap().is_none());
        assert!(
            db.get_progress(Catalog::Anilist, 21, 1).unwrap().is_some(),
            "the same number under another catalog is a different row"
        );

        db.clear_watch_history().unwrap();
        assert!(db.get_progress(Catalog::Anilist, 21, 1).unwrap().is_none());
        assert_eq!(
            db.get_provider_slug(Catalog::Anilist, 21, "nyaa").unwrap().as_deref(),
            Some("One Piece"),
            "clearing the watch log is not clearing the registry"
        );
    }

    #[test]
    fn marking_complete_leaves_the_resume_position_alone() {
        let db = Registry::open_in_memory().unwrap();
        db.record_progress(Catalog::Anilist, 42, 3, 600, 1400).unwrap();
        db.mark_completed(Catalog::Anilist, 42, 3).unwrap();
        let row = db.get_progress(Catalog::Anilist, 42, 3).unwrap().unwrap();
        assert_eq!(row.stop_time, 600, "next-episode marks watched, it does not seek");
        assert!(row.completed);
    }

    #[test]
    fn migrate_is_idempotent() {
        let conn = Connection::open_in_memory().unwrap();
        migrate(&conn).unwrap();
        migrate(&conn).unwrap();
        let v: i64 = conn.pragma_query_value(None, "user_version", |r| r.get(0)).unwrap();
        assert_eq!(v, 7);
    }

    #[test]
    fn a_rewatch_moves_the_resume_point_without_disowning_the_watch() {
        let db = Registry::open_in_memory().unwrap();
        // Finished: 1407 of 1420 is past the 85% bar.
        db.record_progress(Catalog::Anilist, 156_023, 8, 1407, 1420).unwrap();
        assert!(db.get_progress(Catalog::Anilist, 156_023, 8).unwrap().unwrap().completed);
        // Reopened and closed 50 seconds in. The resume position follows the
        // rewatch; the completion does not.
        db.record_progress(Catalog::Anilist, 156_023, 8, 50, 1420).unwrap();
        let row = db.get_progress(Catalog::Anilist, 156_023, 8).unwrap().unwrap();
        assert_eq!(row.stop_time, 50);
        assert!(row.completed, "a rewatch must not erase that the episode was finished");
        // An explicit un-check is the one thing that clears it.
        db.clear_progress_from(Catalog::Anilist, 156_023, 8).unwrap();
        assert!(db.get_progress(Catalog::Anilist, 156_023, 8).unwrap().is_none());
    }

    #[test]
    fn a_track_preference_round_trips_and_is_replaced_whole() {
        let db = Registry::open_in_memory().unwrap();
        assert_eq!(db.title_track_preference(Catalog::Anilist, 21).unwrap(), None);

        let dubbed = TrackPreference {
            audio_lang: Some("eng".into()),
            subtitle_lang: Some("eng".into()),
            subtitle_title: Some("Signs & Songs".into()),
        };
        db.set_title_track_preference(Catalog::Anilist, 21, &dubbed).unwrap();
        assert_eq!(db.title_track_preference(Catalog::Anilist, 21).unwrap(), Some(dubbed));

        // Switching to subbed with subtitles off has to clear the columns,
        // not merge around them.
        let subbed = TrackPreference {
            audio_lang: Some("jpn".into()),
            subtitle_lang: None,
            subtitle_title: None,
        };
        db.set_title_track_preference(Catalog::Anilist, 21, &subbed).unwrap();
        assert_eq!(db.title_track_preference(Catalog::Anilist, 21).unwrap(), Some(subbed));

        db.clear_all().unwrap();
        assert_eq!(db.title_track_preference(Catalog::Anilist, 21).unwrap(), None);
    }

    #[test]
    fn an_episode_watched_twice_is_one_row_and_counts_once() {
        // The upsert on (catalog, catalog_id, episode_number) is what makes
        // the aggregation's "count each episode once" true; nothing
        // downstream dedupes, so this is where that contract is pinned.
        let db = Registry::open_in_memory().unwrap();
        db.record_progress(Catalog::Anilist, 21, 1, 1400, 1400).unwrap();
        db.record_progress(Catalog::Anilist, 21, 1, 1390, 1400).unwrap();

        let rows = db.progress_rows().unwrap();
        assert_eq!(rows.len(), 1);
        let stats = crate::db::stats::aggregate(&rows, 7, &chrono::Utc::now());
        assert_eq!(stats.total_watch_seconds, 1390);
        assert_eq!(stats.episodes_watched, 1);
        assert_eq!(stats.titles_started, 1);
    }

    #[test]
    fn progress_rows_parse_the_stored_utc_timestamp() {
        let db = Registry::open_in_memory().unwrap();
        db.record_progress(Catalog::Anilist, 21, 1, 100, 1400).unwrap();
        {
            let conn = db.conn.lock().unwrap();
            conn.execute(
                "UPDATE watch_history SET watched_at = '2026-01-30 23:30:00'",
                [],
            )
            .unwrap();
        }
        let rows = db.progress_rows().unwrap();
        assert_eq!(rows[0].watched_at.to_rfc3339(), "2026-01-30T23:30:00+00:00");
    }

    #[test]
    fn remembered_release_round_trips_and_is_replaced() {
        let db = Registry::open_in_memory().unwrap();
        assert_eq!(db.remembered_release(Catalog::Anilist, 21, 3).unwrap(), None);
        let first = RememberedRelease {
            name: "[SubsPlease] One Piece - 003 (1080p)".into(),
            magnet: Some("magnet:?xt=urn:btih:abc".into()),
            torrent_url: None,
            assume_batch: false,
            prefer_dub: false,
        };
        db.remember_release(Catalog::Anilist, 21, 3, &first).unwrap();
        assert_eq!(db.remembered_release(Catalog::Anilist, 21, 3).unwrap(), Some(first));
        // Same episode resolved again under a dub preference replaces the row
        // rather than adding one; the key is the episode, not the release.
        let second = RememberedRelease {
            name: "[Erai-raws] One Piece - 003 [1080p][Multiple Subtitle]".into(),
            magnet: None,
            torrent_url: Some("https://nyaa.si/download/1.torrent".into()),
            assume_batch: true,
            prefer_dub: true,
        };
        db.remember_release(Catalog::Anilist, 21, 3, &second).unwrap();
        assert_eq!(db.remembered_release(Catalog::Anilist, 21, 3).unwrap(), Some(second));
        db.clear_all().unwrap();
        assert_eq!(db.remembered_release(Catalog::Anilist, 21, 3).unwrap(), None);
    }
}
