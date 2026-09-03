//! The UniFFI boundary.
//!
//! Everything Swift can call is declared here and nowhere else, so the engine's
//! internal types stay free to change shape. Two rules hold across this file:
//!
//! * **Errors are a flat enum with a message, never a `Result<_, String>`.**
//!   UniFFI maps that enum onto a Swift `Error`, so a failure arrives at a
//!   `catch` block instead of as a sentinel value some call site forgets to
//!   check.
//! * **Ids cross as `(catalog, catalog_id)`, never as one integer.** The band
//!   arithmetic that used to make one integer sufficient is gone; a Swift
//!   caller names the catalog explicitly.

use std::path::PathBuf;
use std::sync::Arc;

use crate::catalog::{anilist, Catalogs};
use crate::db::{Catalog, Registry};
use crate::media::MediaKey;
use crate::reader::mangadex::MangaDexClient;
use crate::torrent::{layout, ResolveTarget, TorrentManager};

#[derive(Debug, thiserror::Error, uniffi::Error)]
pub enum AnicatError {
    #[error("network: {msg}")]
    Network { msg: String },
    #[error("not found: {msg}")]
    NotFound { msg: String },
    #[error("storage: {msg}")]
    Storage { msg: String },
    #[error("{msg}")]
    Internal { msg: String },
}

impl AnicatError {
    fn internal(e: impl std::fmt::Display) -> Self {
        AnicatError::Internal { msg: e.to_string() }
    }
}

type FfiResult<T> = Result<T, AnicatError>;

/// Which upstream catalog an id belongs to. Mirrors `db::Catalog`; kept as its
/// own type so the FFI shape is not hostage to an internal enum's ordering.
#[derive(Debug, Clone, Copy, PartialEq, Eq, uniffi::Enum)]
pub enum FfiCatalog {
    Anilist,
    TmdbMovie,
    TmdbTv,
    MangaDex,
}

impl From<Catalog> for FfiCatalog {
    fn from(c: Catalog) -> Self {
        match c {
            Catalog::Anilist => FfiCatalog::Anilist,
            Catalog::TmdbMovie => FfiCatalog::TmdbMovie,
            Catalog::TmdbTv => FfiCatalog::TmdbTv,
            Catalog::MangaDex => FfiCatalog::MangaDex,
        }
    }
}

impl From<FfiCatalog> for Catalog {
    fn from(c: FfiCatalog) -> Self {
        match c {
            FfiCatalog::Anilist => Catalog::Anilist,
            FfiCatalog::TmdbMovie => Catalog::TmdbMovie,
            FfiCatalog::TmdbTv => Catalog::TmdbTv,
            FfiCatalog::MangaDex => Catalog::MangaDex,
        }
    }
}

/// One catalog entry, flattened to what a list row actually draws.
#[derive(Debug, Clone, uniffi::Record)]
pub struct MediaSummary {
    pub catalog: FfiCatalog,
    pub catalog_id: i64,
    pub title: String,
    pub cover_image: String,
    pub format: Option<String>,
    pub episodes: Option<i32>,
    pub chapters: Option<i32>,
    pub average_score: Option<i32>,
    /// The signed-in user's own progress, when AniList returned a list entry
    /// for this title. The Library and Manga views draw the poster tick from
    /// it, so dropping it renders every card as unwatched.
    pub progress: Option<i32>,
    /// `CURRENT`, `COMPLETED`, `PLANNING`, `PAUSED`, `DROPPED`, `REPEATING`.
    pub list_status: Option<String>,
    pub user_score: Option<f64>,
    /// Unix seconds of the last list update.
    pub updated_at: Option<i64>,
    /// Unix seconds at which the next episode airs, when one is scheduled.
    pub next_airing_at: Option<i64>,
    pub next_episode: Option<i32>,
}

#[derive(Debug, Clone, uniffi::Record)]
pub struct MangaSummary {
    pub id: String,
    pub title: String,
    pub cover_image: String,
}

#[derive(Debug, Clone, uniffi::Record)]
pub struct MangaChapter {
    pub number: String,
    pub title: String,
    pub id: String,
    pub pages: u32,
}

#[derive(Debug, Clone, uniffi::Record)]
pub struct StreamHandle {
    /// What the player opens: a loopback range URL served by this engine. The
    /// file on disk is sparse while the torrent downloads, so a path would
    /// read holes; and the `FileStream` that fills them has no representation
    /// across the FFI, so the server has to be on this side.
    pub url: String,
    pub torrent_id: u64,
    pub file_id: u64,
}

/// One watch, for the History view's activity chart.
#[derive(Debug, Clone, uniffi::Record)]
pub struct ActivityRow {
    pub catalog: FfiCatalog,
    pub catalog_id: i64,
    pub episode_number: i64,
    /// `YYYY-MM-DD HH:MM:SS`, UTC, as SQLite wrote it.
    pub watched_at: String,
}

/// The signed-in AniList user and their lifetime totals.
#[derive(Debug, Clone, uniffi::Record)]
pub struct ViewerProfile {
    pub name: String,
    pub avatar_url: Option<String>,
    pub banner_url: Option<String>,
    pub anime_count: Option<i64>,
    pub episodes_watched: Option<i64>,
    pub minutes_watched: Option<i64>,
    pub anime_mean_score: Option<f64>,
    pub manga_count: Option<i64>,
    pub chapters_read: Option<i64>,
    pub manga_mean_score: Option<f64>,
    /// Most-watched genres, already ordered by count.
    pub top_genres: Vec<String>,
}

#[derive(Debug, Clone, uniffi::Record)]
pub struct WatchProgress {
    pub episode_number: i64,
    pub stop_time: i64,
    pub duration: i64,
}

/// What to resolve. Mirrors `ResolveTarget`, minus the borrowed slices and the
/// franchise-shape fields the engine works out for itself.
#[derive(Debug, Clone, uniffi::Record)]
pub struct StreamRequest {
    pub catalog: FfiCatalog,
    pub catalog_id: i64,
    pub episode: i64,
    /// Optional title from the caller, appended after the registry override
    /// and AniList's own titles rather than replacing them.
    pub title: Option<String>,
    pub prefer_dub: bool,
    /// The release the user picked from the server list, if any. It is tried
    /// first; the rest of the pool stays behind it, so a pick that turns out
    /// to be dead still plays something.
    pub chosen_name: Option<String>,
}

/// The engine. One per app launch.
#[derive(uniffi::Object)]
pub struct AnicatEngine {
    http: reqwest::Client,
    catalogs: Catalogs,
    registry: Registry,
    torrents: Arc<TorrentManager>,
    mangadex: MangaDexClient,
    /// Started on the first resolve rather than in the constructor, which is
    /// sync and so has no runtime to bind a listener on. `OnceCell` rather
    /// than a flag: two resolves racing must produce one server, not two.
    stream_port: tokio::sync::OnceCell<u16>,
}

#[uniffi::export(async_runtime = "tokio")]
impl AnicatEngine {
    /// `data_dir` holds the registry and the torrent stream cache. On iOS that
    /// is the app container; on macOS, Application Support.
    #[uniffi::constructor]
    pub fn new(
        data_dir: String,
        anilist_token: Option<String>,
        tmdb_key: Option<String>,
    ) -> FfiResult<Arc<Self>> {
        let dir = PathBuf::from(&data_dir);
        let http = reqwest::Client::builder()
            .build()
            .map_err(AnicatError::internal)?;
        let registry = Registry::open(&dir.join("registry.sqlite"))
            .map_err(|msg| AnicatError::Storage { msg })?;
        Ok(Arc::new(Self {
            catalogs: Catalogs::new(http.clone(), anilist_token, tmdb_key),
            registry,
            torrents: Arc::new(TorrentManager::with_cache_dir(dir.join("torrent-streams"))),
            mangadex: MangaDexClient::new(http.clone()),
            http,
            stream_port: tokio::sync::OnceCell::new(),
        }))
    }

    /// The loopback port the range server is on, starting it if it is not up
    /// yet. Always ask rather than assume a number: the OS assigns it, and a
    /// hardcoded port is how the Tauri build ended up playing video perfectly
    /// while every player callback went to whatever else owned 13370.
    pub async fn stream_port(&self) -> FfiResult<u16> {
        self.ensure_stream_server().await
    }

    /// Sign in (or out, with `None`) without rebuilding the engine.
    ///
    /// The engine is constructed once at launch, before the user has pasted
    /// anything, so a token that arrives later has to be handed to the live
    /// client. Passing it to the constructor a second time does nothing: the
    /// host already holds an engine and the new one is never used.
    ///
    /// Clears the cached viewer name too, since the next token is a different
    /// person and `user_list` is keyed by that name.
    pub fn set_anilist_token(&self, token: Option<String>) {
        self.catalogs
            .anilist
            .set_token(token.filter(|t| !t.trim().is_empty()));
    }

    /// Whether the engine currently holds an AniList token. Says nothing
    /// about whether it is still valid — `viewer_profile` answers that.
    pub fn has_anilist_token(&self) -> bool {
        self.catalogs.anilist.has_token()
    }

    pub async fn search_anime(&self, query: String) -> FfiResult<Vec<MediaSummary>> {
        self.search_catalog(query, "ANIME").await
    }

    pub async fn search_manga_catalog(&self, query: String) -> FfiResult<Vec<MediaSummary>> {
        self.search_catalog(query, "MANGA").await
    }

    /// Find a torrent for an episode and hand back what the player opens.
    pub async fn resolve_stream(&self, req: StreamRequest) -> FfiResult<StreamHandle> {
        // cinema.rs and series.rs are in the crate but not reachable from
        // here: `ResolveTarget::movie`/`series` would have to be populated
        // from TMDB detail, which Phase 2 wires up. Refusing is the honest
        // answer — falling through would silently run the anime search for a
        // film and return some unrelated release.
        if req.catalog != FfiCatalog::Anilist {
            return Err(AnicatError::NotFound {
                msg: format!("{:?} playback is not wired up yet", req.catalog),
            });
        }
        let port = self.ensure_stream_server().await?;
        let media = MediaKey::new(req.catalog.into(), req.catalog_id);
        let info = crate::torrent::gather_media_info(
            &self.registry,
            &self.catalogs,
            media,
            req.title.clone(),
        )
        .await;
        if info.titles.is_empty() {
            return Err(AnicatError::NotFound {
                msg: format!("no search titles for {media}"),
            });
        }

        let url = self
            .torrents
            .resolve(
                &self.http,
                ResolveTarget {
                    media,
                    episode: req.episode,
                    titles: &info.titles,
                    // A film has no episode number in its release name.
                    allow_episodeless: info.hint.kind == layout::EntryKind::Movie,
                    episode_count: info.episode_count,
                    prefer_dub: req.prefer_dub,
                    // libmpv decodes everything a release can be encoded in,
                    // so nothing here is filtered on codec. This flag existed
                    // for the WebKit `<video>` element, which is gone.
                    browser_client: false,
                    chosen_name: req.chosen_name.clone(),
                    movie: None,
                    series: None,
                    entry: info.hint,
                    sibling_titles: &info.siblings,
                },
                port,
            )
            .await
            .map_err(|msg| AnicatError::NotFound { msg })?;

        let (torrent_id, file_id) = self
            .torrents
            .resolved_ids(media, req.episode)
            .await
            .ok_or_else(|| AnicatError::Internal {
                msg: "resolve returned a url with nothing behind it".into(),
            })?;
        Ok(StreamHandle {
            url,
            torrent_id: torrent_id as u64,
            file_id: file_id as u64,
        })
    }

    /// One status bucket of the user's AniList list.
    ///
    /// `status` is an AniList `MediaListStatus` (`CURRENT`, `COMPLETED`,
    /// `PLANNING`, `PAUSED`, `DROPPED`, `REPEATING`) and `media_type` is
    /// `ANIME` or `MANGA`.
    pub async fn user_list(
        &self,
        status: String,
        media_type: String,
    ) -> FfiResult<Vec<MediaSummary>> {
        let items = self
            .catalogs
            .user_list(&status, &media_type)
            .await
            .map_err(|msg| AnicatError::Network { msg })?;
        Ok(items.iter().map(summarize).collect())
    }

    /// Trending titles. `format` narrows to one AniList format — pass `NOVEL`
    /// with `MANGA` for light novels, which are not a type of their own.
    pub async fn trending(
        &self,
        media_type: String,
        format: Option<String>,
        limit: i32,
    ) -> FfiResult<Vec<MediaSummary>> {
        let items = self
            .catalogs
            .trending(&media_type, format.as_deref(), limit.max(1) as i64)
            .await
            .map_err(|msg| AnicatError::Network { msg })?;
        Ok(items.iter().map(summarize).collect())
    }

    /// The signed-in user. Errors when there is no token, which the History
    /// view renders as its signed-out state.
    pub async fn viewer_profile(&self) -> FfiResult<ViewerProfile> {
        let res = self
            .catalogs
            .viewer_profile()
            .await
            .map_err(|msg| AnicatError::Network { msg })?;
        let v = res.viewer.ok_or_else(|| AnicatError::NotFound {
            msg: "AniList returned no viewer".into(),
        })?;
        let anime = v.statistics.as_ref().and_then(|s| s.anime.as_ref());
        let manga = v.statistics.as_ref().and_then(|s| s.manga.as_ref());
        Ok(ViewerProfile {
            name: v.name.unwrap_or_default(),
            avatar_url: v.avatar.as_ref().and_then(|a| a.large.clone().or_else(|| a.medium.clone())),
            banner_url: v.banner_image,
            anime_count: anime.and_then(|a| a.count),
            episodes_watched: anime.and_then(|a| a.episodes_watched),
            minutes_watched: anime.and_then(|a| a.minutes_watched),
            anime_mean_score: anime.and_then(|a| a.mean_score),
            manga_count: manga.and_then(|m| m.count),
            chapters_read: manga.and_then(|m| m.chapters_read),
            manga_mean_score: manga.and_then(|m| m.mean_score),
            top_genres: anime
                .and_then(|a| a.genres.as_ref())
                .map(|g| g.iter().filter_map(|x| x.genre.clone()).collect())
                .unwrap_or_default(),
        })
    }

    /// Local watch history, newest first. Unlike everything else on the
    /// History view this needs no token — the registry recorded it.
    pub fn watch_activity(&self, limit: i32) -> FfiResult<Vec<ActivityRow>> {
        let rows = self
            .registry
            .recent_activity(limit.max(1) as i64)
            .map_err(|msg| AnicatError::Storage { msg })?;
        Ok(rows
            .into_iter()
            .map(|r| ActivityRow {
                catalog: Catalog::parse(&r.catalog)
                    .map(FfiCatalog::from)
                    .unwrap_or(FfiCatalog::Anilist),
                catalog_id: r.catalog_id,
                episode_number: r.episode_number,
                watched_at: r.watched_at,
            })
            .collect())
    }

    pub async fn search_manga(
        &self,
        query: String,
        anilist_id: Option<i64>,
    ) -> FfiResult<Vec<MangaSummary>> {
        let out = self
            .mangadex
            .search(&query, anilist_id)
            .await
            .map_err(|msg| AnicatError::Network { msg })?;
        Ok(out
            .into_iter()
            .map(|m| MangaSummary {
                id: m.id,
                title: m.title,
                cover_image: m.cover_image,
            })
            .collect())
    }

    pub async fn get_manga_chapters(&self, manga_id: String) -> FfiResult<Vec<MangaChapter>> {
        let detail = self
            .mangadex
            .detail(&manga_id)
            .await
            .map_err(|msg| AnicatError::Network { msg })?;
        Ok(detail
            .chapters
            .into_iter()
            .map(|c| MangaChapter {
                number: c.number,
                title: c.title,
                id: c.id,
                pages: c.pages,
            })
            .collect())
    }

    pub async fn get_manga_pages(&self, chapter_id: String) -> FfiResult<Vec<String>> {
        self.mangadex
            .chapter_pages(&chapter_id)
            .await
            .map_err(|msg| AnicatError::Network { msg })
    }

    pub fn record_progress(
        &self,
        catalog: FfiCatalog,
        catalog_id: i64,
        episode_number: i64,
        stop_time: i64,
        duration: i64,
    ) -> FfiResult<()> {
        self.registry
            .record_progress(catalog.into(), catalog_id, episode_number, stop_time, duration)
            .map_err(|msg| AnicatError::Storage { msg })
    }

    pub fn get_progress(
        &self,
        catalog: FfiCatalog,
        catalog_id: i64,
        episode_number: i64,
    ) -> FfiResult<Option<WatchProgress>> {
        let hit = self
            .registry
            .get_progress(catalog.into(), catalog_id, episode_number)
            .map_err(|msg| AnicatError::Storage { msg })?;
        Ok(hit.map(|e| WatchProgress {
            episode_number: e.episode_number,
            stop_time: e.stop_time,
            duration: e.duration,
        }))
    }
}

impl AnicatEngine {
    async fn ensure_stream_server(&self) -> FfiResult<u16> {
        self.stream_port
            .get_or_try_init(|| crate::torrent::stream::serve(self.torrents.clone()))
            .await
            .copied()
            .map_err(|msg| AnicatError::Internal { msg })
    }

    async fn search_catalog(&self, query: String, media_type: &str) -> FfiResult<Vec<MediaSummary>> {
        let mut vars = std::collections::HashMap::new();
        vars.insert("search".to_string(), serde_json::json!(query));
        vars.insert("type".to_string(), serde_json::json!(media_type));
        vars.insert("page".to_string(), serde_json::json!(1));
        vars.insert("perPage".to_string(), serde_json::json!(25));
        let page: anilist::responses::PageResponse<anilist::types::MediaItem> = self
            .catalogs
            .anilist
            .execute(anilist::queries::MEDIA_SEARCH_QUERY, vars)
            .await
            .map_err(|msg| AnicatError::Network { msg })?;
        Ok(page.page.media.unwrap_or_default().iter().map(summarize).collect())
    }
}

/// One place that flattens `MediaItem` for the FFI, so a field added for one
/// view cannot go missing on another. Every list, shelf and grid in the app
/// draws from the record this returns.
fn summarize(m: &anilist::types::MediaItem) -> MediaSummary {
    let entry = m.media_list_entry.as_ref();
    MediaSummary {
        catalog: FfiCatalog::Anilist,
        catalog_id: m.id,
        // English first, romaji behind it — AniList leaves `english` null for
        // plenty of titles and a blank card is worse than a romaji one.
        title: m
            .title
            .as_ref()
            .and_then(|t| t.english.clone().or_else(|| t.romaji.clone()))
            .unwrap_or_default(),
        cover_image: m
            .cover_image
            .as_ref()
            .and_then(|c| c.large.clone().or_else(|| c.medium.clone()))
            .unwrap_or_default(),
        format: m.format.clone(),
        episodes: m.episodes,
        chapters: m.chapters,
        average_score: m.average_score,
        progress: entry.and_then(|e| e.progress),
        list_status: entry.and_then(|e| e.status.clone()),
        user_score: entry.and_then(|e| e.score),
        updated_at: entry.and_then(|e| e.updated_at),
        next_airing_at: m.next_airing_episode.as_ref().and_then(|n| n.airing_at),
        next_episode: m.next_airing_episode.as_ref().and_then(|n| n.episode),
    }
}
