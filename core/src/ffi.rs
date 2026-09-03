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
    pub average_score: Option<i32>,
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
        Ok(page
            .page
            .media
            .unwrap_or_default()
            .into_iter()
            .map(|m| MediaSummary {
                catalog: FfiCatalog::Anilist,
                catalog_id: m.id,
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
                average_score: m.average_score,
            })
            .collect())
    }
}
