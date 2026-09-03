//! Catalog clients: what a show *is*, as opposed to where its files are.
//!
//! AniList covers anime and manga, TMDB covers films and series. Both
//! normalize into `anilist::types::MediaItem`; that the shared shape is named
//! after AniList is history, not a claim about where a row came from.

pub mod anilist;
pub mod cache;
pub mod tmdb;

pub use anilist::AniListClient;
pub use tmdb::TmdbClient;

use std::collections::HashMap;
use std::sync::Arc;

use cache::AniListCache;

/// The catalog clients plus the response cache they share.
///
/// A struct rather than three loose arguments because every caller that needs
/// one needs the cache too: an uncached AniList detail fetch on the play path
/// costs a round trip inside the window the resolve is racing against.
pub struct Catalogs {
    pub anilist: Arc<AniListClient>,
    pub tmdb: Arc<TmdbClient>,
    pub cache: Arc<AniListCache>,
}

impl Catalogs {
    pub fn new(http: reqwest::Client, anilist_token: Option<String>, tmdb_key: Option<String>) -> Self {
        Self {
            anilist: Arc::new(AniListClient::new(http.clone(), anilist_token)),
            tmdb: Arc::new(TmdbClient::new(http, tmdb_key)),
            cache: Arc::new(AniListCache::new()),
        }
    }

    /// One AniList entry, served from the response cache when it is warm.
    pub async fn media_detail(
        &self,
        anilist_id: i64,
        is_manga: bool,
    ) -> Result<anilist::responses::MediaResponse, String> {
        let media_type = if is_manga { "MANGA" } else { "ANIME" };
        let key = AniListCache::key(
            "media_detail",
            &[("id", &anilist_id.to_string()), ("type", media_type)],
        );
        if let Some(hit) = self.cache.get(&key) {
            if let Ok(parsed) = serde_json::from_value(hit) {
                return Ok(parsed);
            }
        }
        let mut vars = HashMap::new();
        vars.insert("id".to_string(), serde_json::json!(anilist_id));
        vars.insert("type".to_string(), serde_json::json!(media_type));
        let result: anilist::responses::MediaResponse = self
            .anilist
            .execute(anilist::queries::MEDIA_DETAIL_QUERY, vars)
            .await?;
        if let Ok(v) = serde_json::to_value(&result) {
            self.cache.set(key, v, "media_detail");
        }
        Ok(result)
    }
}
