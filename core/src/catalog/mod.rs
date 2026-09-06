//! Catalog clients: what a show *is*, as opposed to where its files are.
//!
//! AniList covers anime and manga, TMDB covers films and series. Both
//! normalize into `anilist::types::MediaItem`; that the shared shape is named
//! after AniList is history, not a claim about where a row came from.

pub mod anilist;
pub mod anizip;
pub mod cache;
pub mod jikan;
pub mod tmdb;

pub use anilist::AniListClient;
pub use tmdb::TmdbClient;

use std::collections::HashMap;
use std::sync::Arc;

use cache::AniListCache;

/// AniList's documented ceiling on `Page(perPage:)`. Paging by a larger
/// number than the server will actually return steps over comments.
const THREAD_COMMENTS_PER_PAGE: i64 = 50;

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
        Self::with_cache(http, anilist_token, tmdb_key, AniListCache::new())
    }

    /// `cache` is `AniListCache::persistent(..)` in the app and the plain
    /// in-memory one in tests.
    pub fn with_cache(
        http: reqwest::Client,
        anilist_token: Option<String>,
        tmdb_key: Option<String>,
        cache: AniListCache,
    ) -> Self {
        Self {
            anilist: Arc::new(AniListClient::new(http.clone(), anilist_token)),
            tmdb: Arc::new(TmdbClient::new(http, tmdb_key)),
            cache: Arc::new(cache),
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
        let key = "get_user_profile|viewer".to_string();
        if let Some(hit) = self.cache.get(&key) {
            if let Ok(parsed) = serde_json::from_value(hit) {
                return Ok(parsed);
            }
        }
        let res: anilist::responses::ViewerResponse = self
            .anilist
            .execute(anilist::queries::USER_PROFILE_QUERY, HashMap::new())
            .await?;
        if let Ok(v) = serde_json::to_value(&res) {
            self.cache.set(key, v, "get_user_profile");
        }
        Ok(res)
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
        let key = AniListCache::key(
            "get_user_list",
            &[("user", &user_name), ("type", media_type), ("status", status)],
        );
        if let Some(hit) = self.cache.get(&key) {
            if let Ok(parsed) = serde_json::from_value(hit) {
                return Ok(parsed);
            }
        }
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
        if let Ok(v) = serde_json::to_value(&out) {
            self.cache.set(key, v, "get_user_list");
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
        let per_page_str = per_page.to_string();
        let key = AniListCache::key(
            "get_trending",
            &[
                ("type", media_type),
                ("format", format.unwrap_or("")),
                ("limit", &per_page_str),
            ],
        );
        if let Some(hit) = self.cache.get(&key) {
            if let Ok(parsed) = serde_json::from_value(hit) {
                return Ok(parsed);
            }
        }
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
        let items = page.page.media.unwrap_or_default();
        if let Ok(v) = serde_json::to_value(&items) {
            self.cache.set(key, v, "get_trending");
        }
        Ok(items)
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
        let year_str = season_year.map(|y| y.to_string()).unwrap_or_default();
        let per_page_str = per_page.to_string();
        let key = AniListCache::key(
            "get_discover",
            &[
                ("type", media_type),
                ("status", status.unwrap_or("")),
                ("season", season.unwrap_or("")),
                ("year", &year_str),
                ("limit", &per_page_str),
            ],
        );
        if let Some(hit) = self.cache.get(&key) {
            if let Ok(parsed) = serde_json::from_value(hit) {
                return Ok(parsed);
            }
        }
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
        let items = page.page.media.unwrap_or_default();
        if let Ok(v) = serde_json::to_value(&items) {
            self.cache.set(key, v, "get_discover");
        }
        Ok(items)
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
        // Also check if the alternative type is cached for this ID to prevent redundant requests
        let alt_type = if is_manga { "ANIME" } else { "MANGA" };
        let alt_key = AniListCache::key(
            "media_detail",
            &[("id", &anilist_id.to_string()), ("type", alt_type)],
        );
        if let Some(hit) = self.cache.get(&alt_key) {
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
        let key = AniListCache::key("get_media_characters", &[("id", &media_id.to_string())]);
        if let Some(hit) = self.cache.get(&key) {
            if let Ok(parsed) = serde_json::from_value(hit) {
                return Ok(parsed);
            }
        }
        let mut vars = HashMap::new();
        vars.insert("id".to_string(), serde_json::json!(media_id));
        vars.insert("page".to_string(), serde_json::json!(1));
        vars.insert("perPage".to_string(), serde_json::json!(30));
        let res: anilist::responses::CharacterResponse = self
            .anilist
            .execute(anilist::queries::MEDIA_CHARACTERS_QUERY, vars)
            .await?;
        let edges = res
            .media
            .and_then(|m| m.characters)
            .and_then(|c| c.edges)
            .unwrap_or_default();
        if let Ok(v) = serde_json::to_value(&edges) {
            self.cache.set(key, v, "get_media_characters");
        }
        Ok(edges)
    }

    /// Fetches community discussion threads for an AniList media id.
    pub async fn media_discussions(
        &self,
        media_id: i64,
    ) -> Result<Vec<anilist::responses::DiscussionThreadItem>, String> {
        let key = AniListCache::key("get_media_discussions", &[("id", &media_id.to_string())]);
        if let Some(hit) = self.cache.get(&key) {
            if let Ok(parsed) = serde_json::from_value(hit) {
                return Ok(parsed);
            }
        }
        let mut vars = HashMap::new();
        vars.insert("id".to_string(), serde_json::json!(media_id));
        let res: anilist::responses::DiscussionResponse = self
            .anilist
            .execute(anilist::queries::MEDIA_DISCUSSIONS_QUERY, vars)
            .await?;
        let threads = res.page.threads.unwrap_or_default();
        if let Ok(v) = serde_json::to_value(&threads) {
            self.cache.set(key, v, "get_media_discussions");
        }
        Ok(threads)
    }

    /// One character's own page: bio, birthday, and the titles they appear in.
    pub async fn character_detail(
        &self,
        character_id: i64,
    ) -> Result<anilist::types::CharacterNode, String> {
        let key = AniListCache::key("character_detail", &[("id", &character_id.to_string())]);
        if let Some(hit) = self.cache.get(&key) {
            if let Ok(parsed) = serde_json::from_value(hit) {
                return Ok(parsed);
            }
        }
        let mut vars = HashMap::new();
        vars.insert("id".to_string(), serde_json::json!(character_id));
        vars.insert("perPage".to_string(), serde_json::json!(25));
        let res: anilist::responses::CharacterDetailResponse = self
            .anilist
            .execute(anilist::queries::CHARACTER_DETAIL_QUERY, vars)
            .await?;
        let character = res
            .character
            .ok_or_else(|| format!("AniList has no character {character_id}"))?;
        if let Ok(v) = serde_json::to_value(&character) {
            self.cache.set(key, v, "character_detail");
        }
        Ok(character)
    }

    /// One staff member's own page: bio plus both credit lists.
    pub async fn staff_detail(
        &self,
        staff_id: i64,
    ) -> Result<anilist::types::StaffDetailNode, String> {
        let key = AniListCache::key("staff_detail", &[("id", &staff_id.to_string())]);
        if let Some(hit) = self.cache.get(&key) {
            if let Ok(parsed) = serde_json::from_value(hit) {
                return Ok(parsed);
            }
        }
        let mut vars = HashMap::new();
        vars.insert("id".to_string(), serde_json::json!(staff_id));
        vars.insert("perPage".to_string(), serde_json::json!(25));
        let res: anilist::responses::StaffDetailResponse = self
            .anilist
            .execute(anilist::queries::STAFF_DETAIL_QUERY, vars)
            .await?;
        let staff = res.staff.ok_or_else(|| format!("AniList has no staff member {staff_id}"))?;
        if let Ok(v) = serde_json::to_value(&staff) {
            self.cache.set(key, v, "staff_detail");
        }
        Ok(staff)
    }

    /// A forum thread with its first page of comments.
    ///
    /// Cached for far less time than the rest of this module: a thread on an
    /// airing show gains replies while the episode page is open, and a reader
    /// who reopens it to see the answer to their own comment must not be
    /// served the copy from before they posted.
    pub async fn thread_detail(
        &self,
        thread_id: i64,
    ) -> Result<anilist::responses::ThreadDetailResponse, String> {
        let key = AniListCache::key("thread_detail", &[("id", &thread_id.to_string())]);
        if let Some(hit) = self.cache.get(&key) {
            if let Ok(parsed) = serde_json::from_value(hit) {
                return Ok(parsed);
            }
        }
        let mut vars = HashMap::new();
        vars.insert("id".to_string(), serde_json::json!(thread_id));
        vars.insert("page".to_string(), serde_json::json!(1));
        vars.insert("perPage".to_string(), serde_json::json!(THREAD_COMMENTS_PER_PAGE));
        let res: anilist::responses::ThreadDetailResponse = self
            .anilist
            .execute(anilist::queries::THREAD_DETAIL_QUERY, vars)
            .await?;
        // A deleted thread answers HTTP 200 with a null `Thread` rather than
        // an error, so caching the response unconditionally would keep
        // answering "gone" for the next ten minutes — including for the
        // moderator who is about to restore it. The caller turns the `None`
        // into a not-found.
        if res.thread.is_some() {
            if let Ok(v) = serde_json::to_value(&res) {
                self.cache.set(key, v, "thread_detail");
            }
        }
        Ok(res)
    }

    /// Page 2 and beyond of a thread's comments. Page 1 arrives with
    /// `thread_detail`, so a caller that starts here refetches what it has.
    pub async fn thread_comments(
        &self,
        thread_id: i64,
        page: i64,
    ) -> Result<anilist::responses::ThreadCommentPage, String> {
        let key = AniListCache::key(
            "thread_comments",
            &[("id", &thread_id.to_string()), ("page", &page.to_string())],
        );
        if let Some(hit) = self.cache.get(&key) {
            if let Ok(parsed) = serde_json::from_value(hit) {
                return Ok(parsed);
            }
        }
        let mut vars = HashMap::new();
        vars.insert("id".to_string(), serde_json::json!(thread_id));
        vars.insert("page".to_string(), serde_json::json!(page.max(1)));
        vars.insert("perPage".to_string(), serde_json::json!(THREAD_COMMENTS_PER_PAGE));
        let res: anilist::responses::ThreadCommentsResponse = self
            .anilist
            .execute(anilist::queries::THREAD_COMMENTS_QUERY, vars)
            .await?;
        let page_data = res.page.unwrap_or(anilist::responses::ThreadCommentPage {
            page_info: None,
            thread_comments: None,
        });
        if let Ok(v) = serde_json::to_value(&page_data) {
            self.cache.set(key, v, "thread_comments");
        }
        Ok(page_data)
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
        self.cache.invalidate("get_user_list");
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
        self.cache.invalidate("get_user_profile");
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
        self.cache.invalidate("get_user_list");
        Ok(())
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    /// Signed out on purpose: none of the three reads below needs a token,
    /// and a test that quietly depended on one would pass only on the
    /// developer's machine.
    fn catalogs() -> Catalogs {
        Catalogs::new(reqwest::Client::new(), None, None)
    }

    /// Live. `cargo test --lib catalog::tests -- --ignored --nocapture`
    ///
    /// These exist to prove the query strings are valid against the real
    /// schema and that the responses deserialize — neither of which any
    /// offline test can check, since a misspelled field is a server-side
    /// GraphQL error and a wrong serde shape only shows up on real JSON.
    #[tokio::test]
    #[ignore]
    async fn live_character_detail() {
        let character = catalogs().character_detail(175776).await.expect("character 175776");
        let name = character.name.as_ref().and_then(|n| n.full.as_deref()).unwrap_or("");
        println!("character: {} ({} favourites)", name, character.favourites.unwrap_or(0));
        assert!(name.contains("Frieren"), "unexpected character name: {name}");
        let edges = character
            .media
            .as_ref()
            .and_then(|m| m.edges.as_ref())
            .expect("no appearances");
        assert!(!edges.is_empty(), "character has no appearances");
        // The point of the query: a role and a Japanese cast for at least
        // one appearance. Both are edge fields, which is where a wrong
        // nesting level would show up.
        assert!(
            edges.iter().any(|e| e.character_role.is_some()),
            "no characterRole on any appearance"
        );
        assert!(
            edges.iter().any(|e| e.voice_actors.as_ref().is_some_and(|v| !v.is_empty())),
            "no voice actors on any appearance"
        );
    }

    /// Live. The staff id is discovered rather than hardcoded: it comes off
    /// the character above, so the test cannot rot on an id that was guessed
    /// at and turns out to be someone else.
    #[tokio::test]
    #[ignore]
    async fn live_staff_detail() {
        let catalogs = catalogs();
        let character = catalogs.character_detail(175776).await.expect("character 175776");
        let staff_id = character
            .media
            .as_ref()
            .and_then(|m| m.edges.as_ref())
            .and_then(|edges| {
                edges.iter().find_map(|e| e.voice_actors.as_ref()?.first().map(|v| v.id))
            })
            .expect("no voice actor to look up");
        let staff = catalogs.staff_detail(staff_id).await.expect("staff detail");
        let name = staff.name.as_ref().and_then(|n| n.full.as_deref()).unwrap_or("");
        println!("staff {staff_id}: {name} ({:?})", staff.primary_occupations);
        assert!(!name.is_empty(), "staff {staff_id} has no name");
        let character_edges = staff
            .character_media
            .as_ref()
            .and_then(|m| m.edges.as_ref())
            .expect("no characterMedia");
        assert!(!character_edges.is_empty(), "voice actor with no roles");
        // `characters` is the field that distinguishes this connection from
        // an ordinary relations list.
        assert!(
            character_edges
                .iter()
                .any(|e| e.characters.as_ref().is_some_and(|c| !c.is_empty())),
            "no characters on any role"
        );
        // staffMedia is a second connection on the same query; an actor with
        // no production credits is normal, so only the shape is asserted.
        if let Some(edges) = staff.staff_media.as_ref().and_then(|m| m.edges.as_ref()) {
            println!("production credits: {}", edges.len());
        }
    }

    /// Live. The thread id comes from `media_discussions` for the same show,
    /// because forum threads are deleted far more often than catalog entries
    /// are.
    #[tokio::test]
    #[ignore]
    async fn live_thread_detail() {
        let catalogs = catalogs();
        let threads = catalogs.media_discussions(154587).await.expect("discussions");
        // The busiest thread, not the first with any replies: `replyCount`
        // counts top-level comments too, so a thread that satisfies
        // `> 0` can have no nested replies at all — and nested replies are
        // the half of this response nothing else can check.
        let thread_id = threads
            .iter()
            .max_by_key(|t| t.reply_count.unwrap_or(0))
            .map(|t| t.id)
            .expect("no discussion threads at all");
        let detail = catalogs.thread_detail(thread_id).await.expect("thread detail");
        let thread = detail.thread.expect("no Thread in response");
        assert_eq!(thread.id, thread_id);
        println!("thread {thread_id}: {:?} ({:?} replies)", thread.title, thread.reply_count);
        let page = detail.page.expect("no Page beside the Thread");
        let comments = page.thread_comments.unwrap_or_default();
        assert!(!comments.is_empty(), "thread {thread_id} came back with no comments");
        // Proves `childComments` arrives as the untyped Json scalar rather
        // than erroring, which is the only part of the shape a fixture test
        // cannot vouch for.
        println!(
            "{} top-level comments, {} of them with a reply blob",
            comments.len(),
            comments.iter().filter(|c| c.child_comments.is_some()).count()
        );

        let page_two = catalogs.thread_comments(thread_id, 2).await.expect("page 2");
        println!(
            "page 2: {} comments",
            page_two.thread_comments.as_ref().map(|c| c.len()).unwrap_or(0)
        );
    }
}
