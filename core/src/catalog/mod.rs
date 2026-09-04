//! Catalog clients: what a show *is*, as opposed to where its files are.
//!
//! AniList covers anime and manga, TMDB covers films and series. Both
//! normalize into `anilist::types::MediaItem`; that the shared shape is named
//! after AniList is history, not a claim about where a row came from.

pub mod anilist;
pub mod anizip;
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

    /// The signed-in user's AniList name, fetched once and remembered.
    ///
    /// `USER_LIST_QUERY` is keyed by `$userName`, not by the bearer token, so
    /// a list request without this comes back empty against a perfectly valid
    /// token — the failure looks like "the user has nothing on their list"
    /// rather than like a missing parameter. Nothing else in the crate calls
    /// `set_username`, so this is the only thing that populates it.
    pub async fn viewer_name(&self) -> Result<String, String> {
        if let Some(name) = self.anilist.get_username() {
            return Ok(name);
        }
        if !self.anilist.has_token() {
            return Err("not signed in to AniList".to_string());
        }
        let profile: anilist::responses::ViewerResponse = self
            .anilist
            .execute(anilist::queries::USER_PROFILE_QUERY, HashMap::new())
            .await?;
        let name = profile
            .viewer
            .as_ref()
            .and_then(|v| v.name.clone())
            .ok_or_else(|| "AniList did not return a viewer name".to_string())?;
        self.anilist.set_username(Some(name.clone()));
        Ok(name)
    }

    /// The signed-in user's profile, including lifetime statistics.
    pub async fn viewer_profile(&self) -> Result<anilist::responses::ViewerResponse, String> {
        if !self.anilist.has_token() {
            return Err("not signed in to AniList".to_string());
        }
        self.anilist
            .execute(anilist::queries::USER_PROFILE_QUERY, HashMap::new())
            .await
    }

    /// One status bucket of the user's list, flattened out of AniList's
    /// list-of-lists shape.
    ///
    /// Custom lists are skipped: AniList repeats an entry under every custom
    /// list it belongs to, so keeping them shows the same show three times in
    /// one tab.
    pub async fn user_list(
        &self,
        status: &str,
        media_type: &str,
    ) -> Result<Vec<anilist::types::MediaItem>, String> {
        let user_name = self.viewer_name().await?;
        let mut vars = HashMap::new();
        vars.insert("userName".to_string(), serde_json::json!(user_name));
        vars.insert("type".to_string(), serde_json::json!(media_type));
        vars.insert("status".to_string(), serde_json::json!(status));
        vars.insert("sort".to_string(), serde_json::json!(["UPDATED_TIME_DESC"]));
        let res: anilist::responses::MediaListCollectionResponse = self
            .anilist
            .execute(anilist::queries::USER_LIST_QUERY, vars)
            .await?;

        let mut out = Vec::new();
        for list in res.media_list_collection.into_iter().flat_map(|c| c.lists.unwrap_or_default()) {
            if list.is_custom_list.unwrap_or(false) {
                continue;
            }
            for entry in list.entries.unwrap_or_default() {
                let Some(mut media) = entry.media else { continue };
                // The collection query nests the user's own progress beside
                // the media rather than inside it, which is where every
                // consumer of `MediaItem` looks for it.
                media.media_list_entry = Some(anilist::types::MediaListEntry {
                    id: entry.id,
                    status: entry.status,
                    score: entry.score,
                    progress: entry.progress,
                    progress_volumes: entry.progress_volumes,
                    repeat: entry.repeat,
                    private: entry.private,
                    notes: entry.notes,
                    updated_at: entry.updated_at,
                    started_at: entry.started_at,
                    completed_at: entry.completed_at,
                });
                out.push(media);
            }
        }
        Ok(out)
    }

    /// Trending titles of a type, optionally narrowed to one format.
    ///
    /// `MEDIA_TRENDING_QUERY` declares only `$type` and `$isAdult`, so a
    /// format filter cannot go through it — light novels are AniList's
    /// `NOVEL` format under the `MANGA` type, and asking the trending query
    /// for them would silently return all manga. Those go through the search
    /// query sorted by trend instead, which is what the web build does.
    pub async fn trending(
        &self,
        media_type: &str,
        format: Option<&str>,
        per_page: i64,
    ) -> Result<Vec<anilist::types::MediaItem>, String> {
        let mut vars = HashMap::new();
        vars.insert("page".to_string(), serde_json::json!(1));
        vars.insert("perPage".to_string(), serde_json::json!(per_page));
        vars.insert("type".to_string(), serde_json::json!(media_type));
        vars.insert("isAdult".to_string(), serde_json::json!(false));

        let page: anilist::responses::PageResponse<anilist::types::MediaItem> = match format {
            Some(f) => {
                vars.insert("format".to_string(), serde_json::json!([f]));
                vars.insert("sort".to_string(), serde_json::json!(["TRENDING_DESC", "POPULARITY_DESC"]));
                self.anilist.execute(anilist::queries::MEDIA_SEARCH_QUERY, vars).await?
            }
            None => self.anilist.execute(anilist::queries::MEDIA_TRENDING_QUERY, vars).await?,
        };
        Ok(page.page.media.unwrap_or_default())
    }

    /// Filtered discovery: a release-status row ("Newly Releasing") or a
    /// season/year row ("Seasonal Highlights"). Both go through
    /// `MEDIA_SEARCH_QUERY` rather than a dedicated query — it already
    /// declares `$status`, `$season` and `$seasonYear`, so a second query
    /// would only duplicate its field list for a filter it already supports.
    pub async fn discover(
        &self,
        media_type: &str,
        status: Option<&str>,
        season: Option<&str>,
        season_year: Option<i32>,
        per_page: i64,
    ) -> Result<Vec<anilist::types::MediaItem>, String> {
        let mut vars = HashMap::new();
        vars.insert("page".to_string(), serde_json::json!(1));
        vars.insert("perPage".to_string(), serde_json::json!(per_page));
        vars.insert("type".to_string(), serde_json::json!(media_type));
        vars.insert("isAdult".to_string(), serde_json::json!(false));
        // Explicit null, not an empty string: AniList's `search` argument
        // treats null as "no filter" (unlike `type`, where null matches
        // nothing — see `insert_search_media_type` on the Tauri side for that
        // footgun). An empty string is a real search term and returns zero
        // results.
        vars.insert("search".to_string(), serde_json::json!(null));
        vars.insert("sort".to_string(), serde_json::json!(["POPULARITY_DESC"]));
        if let Some(s) = status {
            vars.insert("status".to_string(), serde_json::json!(s));
        }
        if let Some(s) = season {
            vars.insert("season".to_string(), serde_json::json!(s));
        }
        if let Some(y) = season_year {
            vars.insert("seasonYear".to_string(), serde_json::json!(y));
        }
        let page: anilist::responses::PageResponse<anilist::types::MediaItem> =
            self.anilist.execute(anilist::queries::MEDIA_SEARCH_QUERY, vars).await?;
        Ok(page.page.media.unwrap_or_default())
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

    /// Fetches the cast and staff (characters and voice actors) for an AniList media id.
    pub async fn media_characters(
        &self,
        media_id: i64,
    ) -> Result<Vec<anilist::types::CharacterEdge>, String> {
        let mut vars = HashMap::new();
        vars.insert("id".to_string(), serde_json::json!(media_id));
        vars.insert("page".to_string(), serde_json::json!(1));
        vars.insert("perPage".to_string(), serde_json::json!(30));
        let res: anilist::responses::CharacterResponse = self
            .anilist
            .execute(anilist::queries::MEDIA_CHARACTERS_QUERY, vars)
            .await?;
        Ok(res
            .media
            .and_then(|m| m.characters)
            .and_then(|c| c.edges)
            .unwrap_or_default())
    }

    /// Fetches community discussion threads for an AniList media id.
    pub async fn media_discussions(
        &self,
        media_id: i64,
    ) -> Result<Vec<anilist::responses::DiscussionThreadItem>, String> {
        let mut vars = HashMap::new();
        vars.insert("id".to_string(), serde_json::json!(media_id));
        let res: anilist::responses::DiscussionResponse = self
            .anilist
            .execute(anilist::queries::MEDIA_DISCUSSIONS_QUERY, vars)
            .await?;
        Ok(res.page.threads.unwrap_or_default())
    }

    /// Creates or updates the signed-in user's list entry for a title.
    /// `status`/`score`/`progress` are each optional so a caller can change
    /// just one field — AniList's `SaveMediaListEntry` only touches the
    /// arguments it's given, leaving the rest of the entry as it was.
    pub async fn save_media_list_entry(
        &self,
        media_id: i64,
        status: Option<&str>,
        score: Option<f64>,
        progress: Option<i64>,
    ) -> Result<(), String> {
        let mut vars = HashMap::new();
        vars.insert("mediaId".to_string(), serde_json::json!(media_id));
        if let Some(s) = status {
            vars.insert("status".to_string(), serde_json::json!(s));
        }
        if let Some(s) = score {
            vars.insert("score".to_string(), serde_json::json!(s));
        }
        if let Some(p) = progress {
            vars.insert("progress".to_string(), serde_json::json!(p));
        }
        let _: serde_json::Value =
            self.anilist.execute(anilist::queries::SAVE_MEDIA_LIST_ENTRY_MUTATION, vars).await?;
        // `media_detail` caches the mediaListEntry alongside everything else,
        // so a status/score/progress edit that isn't invalidated here reads
        // back as unchanged the moment the detail page reopens.
        self.cache.invalidate("media_detail");
        Ok(())
    }

    /// Toggles the AniList favourite heart for a title.
    pub async fn toggle_favourite(&self, media_id: i64, is_manga: bool) -> Result<(), String> {
        let mut vars = HashMap::new();
        let key = if is_manga { "mangaId" } else { "animeId" };
        vars.insert(key.to_string(), serde_json::json!(media_id));
        let _: serde_json::Value =
            self.anilist.execute(anilist::queries::TOGGLE_FAVOURITE_MUTATION, vars).await?;
        self.cache.invalidate("media_detail");
        Ok(())
    }

    /// Removes a title from the signed-in user's list entirely. Takes the
    /// list *entry's* id (`MediaListEntry.id`), not the media's AniList id —
    /// `DeleteMediaListEntry` is keyed on the former.
    pub async fn delete_media_list_entry(&self, entry_id: i64) -> Result<(), String> {
        let mut vars = HashMap::new();
        vars.insert("id".to_string(), serde_json::json!(entry_id));
        let _: serde_json::Value =
            self.anilist.execute(anilist::queries::DELETE_MEDIA_LIST_ENTRY_MUTATION, vars).await?;
        self.cache.invalidate("media_detail");
        Ok(())
    }
}
