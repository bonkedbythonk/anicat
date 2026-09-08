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

use crate::catalog::{anilist, cache::AniListCache, Catalogs};
use crate::db::{Catalog, Registry};
use crate::media::MediaKey;
use crate::reader::mangadex::MangaDexClient;
use crate::reader::mangakatana::MangaKatanaClient;
use crate::reader::syosetu::SyosetuClient;
use crate::discord::DiscordClient;
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
    /// MangaDex's own `links.al` confirms this result IS the searched-for
    /// AniList entry, not merely a plausible title match. See
    /// `reader::mangadex::MangaSummary` for why the caller needs this.
    pub matches_anilist: bool,
}

#[derive(Debug, Clone, uniffi::Record)]
pub struct MangaChapter {
    pub number: String,
    pub title: String,
    pub id: String,
    pub pages: u32,
}

/// One chapter link from a Syosetu novel's table of contents.
#[derive(Debug, Clone, uniffi::Record)]
pub struct NovelChapterRef {
    pub index: i32,
    pub title: String,
    pub url: String,
    pub volume_name: Option<String>,
}

#[derive(Debug, Clone, uniffi::Record)]
pub struct NovelInfo {
    pub title: String,
    pub author: String,
    pub description: String,
    pub chapters: Vec<NovelChapterRef>,
}

#[derive(Debug, Clone, uniffi::Record)]
pub struct NovelChapterContent {
    pub title: String,
    pub text: String,
}

impl From<crate::reader::syosetu::NovelChapterRef> for NovelChapterRef {
    fn from(c: crate::reader::syosetu::NovelChapterRef) -> Self {
        Self { index: c.index, title: c.title, url: c.url, volume_name: c.volume_name }
    }
}

impl From<crate::reader::syosetu::NovelInfo> for NovelInfo {
    fn from(n: crate::reader::syosetu::NovelInfo) -> Self {
        Self {
            title: n.title,
            author: n.author,
            description: n.description,
            chapters: n.chapters.into_iter().map(Into::into).collect(),
        }
    }
}

impl From<crate::reader::syosetu::NovelChapterContent> for NovelChapterContent {
    fn from(c: crate::reader::syosetu::NovelChapterContent) -> Self {
        Self { title: c.title, text: c.text }
    }
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
    pub favourite_anime: Vec<MediaSummary>,
    pub favourite_manga: Vec<MediaSummary>,
}

/// A neighbouring entry in a franchise, for the detail page's season chain.
#[derive(Debug, Clone, uniffi::Record)]
pub struct RelatedTitle {
    pub catalog_id: i64,
    pub title: String,
    pub format: Option<String>,
    pub cover_image: String,
}

/// One episode row on the detail page.
///
/// AniList has no episode table: it gives a total count and, for some titles,
/// a `streamingEpisodes` list scraped from the streaming sites. The rows are
/// therefore synthesized from the count and enriched from that list where it
/// lines up, which is why `title` falls back to "Episode N" rather than the
/// row going missing.
#[derive(Debug, Clone, uniffi::Record)]
pub struct EpisodeRow {
    pub number: i32,
    pub title: String,
    pub thumbnail: Option<String>,
    pub is_watched: bool,
    /// 0-100 through the episode, from the local registry.
    pub progress_percent: f64,
    pub runtime_minutes: Option<i32>,
    /// From AniZip. AniList has no per-episode synopsis at all, so this is
    /// `None` for any episode AniZip has no mapping for.
    pub synopsis: Option<String>,
    /// From AniZip, `YYYY-MM-DD`. Same caveat as `synopsis`.
    pub air_date: Option<String>,
}

/// The facts a cinema page shows that `MediaDetail` has no field for.
///
/// A separate record rather than more optional fields on `MediaDetail`: none
/// of this exists on an AniList title, and half of it (box office, networks,
/// season counts) has no anime counterpart at all. Fetched from the same
/// cached TMDB detail the page already loaded, so asking for it costs no
/// request.
#[derive(Debug, Clone, uniffi::Record)]
pub struct CinemaExtras {
    pub tagline: Option<String>,
    /// ISO 639-1, as TMDB reports it. The client names it.
    pub original_language: Option<String>,
    pub release_date: Option<String>,
    pub last_air_date: Option<String>,
    pub runtime_minutes: Option<i32>,
    /// Zero means TMDB does not know, not that the film cost nothing -- most
    /// films outside the studio system report 0 -- so both are `None` here.
    pub budget: Option<i64>,
    pub revenue: Option<i64>,
    pub season_count: Option<i32>,
    pub episode_count: Option<i32>,
    /// Studios for a film, networks for a series.
    pub companies: Vec<String>,
    /// Backdrops then posters, capped -- the stills strip.
    pub gallery: Vec<String>,
    /// The newest episode TMDB has as aired, as an absolute number against
    /// the same season map the rest of the app counts by, and the date the
    /// next one is due. What a "new episode" check reads.
    pub last_aired_episode: Option<i32>,
    pub next_air_date: Option<String>,
    pub homepage: Option<String>,
    /// A link, not a rating: IMDb publishes no free API, so the score on the
    /// page stays TMDB's own.
    pub imdb_url: Option<String>,
    /// `(season number, episode count)`, specials excluded, in order.
    pub seasons: Vec<CinemaSeason>,
}

/// A person, as the cinema cast page draws them.
#[derive(Debug, Clone, uniffi::Record)]
pub struct CinemaPerson {
    pub id: i64,
    pub name: String,
    pub biography: Option<String>,
    pub photo_url: Option<String>,
    pub birthday: Option<String>,
    pub deathday: Option<String>,
    pub place_of_birth: Option<String>,
    pub known_for: Option<String>,
    /// Their credits, best known first.
    pub credits: Vec<CinemaCredit>,
    /// A link, not a rating: IMDb has no free API, so nothing but the URL
    /// can come from here.
    pub imdb_url: Option<String>,
}

#[derive(Debug, Clone, uniffi::Record)]
pub struct CinemaCredit {
    pub catalog: FfiCatalog,
    pub catalog_id: i64,
    pub title: String,
    pub character: Option<String>,
    pub cover_image: Option<String>,
    pub year: Option<i32>,
}

/// One file the scan is prepared to adopt.
struct AdoptableDownload {
    hint_index: usize,
    episode: i64,
    path: String,
    bytes: i64,
}

/// Which files under `root` can be identified, given what the app knows.
///
/// Separate from the recording so it can be tested against a directory tree
/// rather than against the viewer's own Downloads folder -- and because the
/// interesting part is entirely this: a folder name matched back to a title,
/// and a release name that does or does not yield an episode number.
fn adoptable_downloads(
    root: &std::path::Path,
    hints: &[FfiTitleHint],
    known: &[(i64, i64)],
) -> Vec<AdoptableDownload> {
    let Ok(entries) = std::fs::read_dir(root) else { return vec![] };
    let mut out = vec![];
    for entry in entries.filter_map(|e| e.ok()) {
        if !entry.path().is_dir() {
            continue;
        }
        let folder = entry.file_name().to_string_lossy().to_string();
        // The folder is named after the title the download started with,
        // sanitised for the filesystem. Matched through the same
        // normalisation the indexer search uses, so punctuation and case
        // cannot be what decides it.
        let Some(hint_index) = hints.iter().position(|hint| {
            hint.titles.iter().any(|title| {
                crate::torrent::search::normalize(title)
                    == crate::torrent::search::normalize(&folder)
            })
        }) else {
            continue;
        };
        let Ok(files) = std::fs::read_dir(entry.path()) else { continue };
        for file in files.filter_map(|f| f.ok()) {
            let path = file.path();
            if !path.is_file() {
                continue;
            }
            let name = file.file_name().to_string_lossy().to_string();
            // A name the indexer's own parser cannot read is skipped rather
            // than guessed at: adopting a file as the wrong episode is worse
            // than not adopting it, because it then plays instead of one.
            let Some(episode) = crate::torrent::search::filename_episode(&name) else {
                continue;
            };
            if known.contains(&(hints[hint_index].catalog_id, episode)) {
                continue;
            }
            out.push(AdoptableDownload {
                hint_index,
                episode,
                path: path.to_string_lossy().to_string(),
                bytes: std::fs::metadata(&path).map(|m| m.len() as i64).unwrap_or(0),
            });
        }
    }
    out
}

/// What the app knows about one title, for matching a folder name to an id.
/// `titles` is every name it goes by -- the folder was named after whichever
/// one the download happened to start with.
#[derive(Debug, Clone, uniffi::Record)]
pub struct FfiTitleHint {
    pub catalog: FfiCatalog,
    pub catalog_id: i64,
    pub titles: Vec<String>,
}

/// One episode copied into the Downloads folder.
#[derive(Debug, Clone, uniffi::Record)]
pub struct FfiDownloadedEpisode {
    pub catalog: FfiCatalog,
    pub catalog_id: i64,
    pub episode_number: i64,
    pub title: Option<String>,
    pub path: String,
    pub bytes: u64,
    pub downloaded_at: String,
}

/// One chapter kept on disk.
#[derive(Debug, Clone, uniffi::Record)]
pub struct FfiOfflineChapter {
    pub catalog: FfiCatalog,
    pub catalog_id: i64,
    pub chapter_id: String,
    pub chapter_number: String,
    pub title: Option<String>,
    pub page_count: u32,
    pub bytes: u64,
    /// `YYYY-MM-DD HH:MM:SS` in UTC, as SQLite writes it.
    pub downloaded_at: String,
}

/// How far into a chapter the viewer got.
#[derive(Debug, Clone, uniffi::Record)]
pub struct FfiReadingProgress {
    /// Zero-based index into the chapter.
    pub page: i64,
    /// What it was out of when it was recorded, so a resume can tell a
    /// half-read chapter from one whose page count has since changed.
    pub page_count: i64,
}

/// One chapter, as far as it was read.
#[derive(Debug, Clone, uniffi::Record)]
pub struct FfiReadingRow {
    pub catalog: FfiCatalog,
    pub catalog_id: i64,
    pub chapter_id: String,
    pub chapter_number: String,
    pub page: i64,
    pub page_count: i64,
    /// `YYYY-MM-DD HH:MM:SS` in UTC, as SQLite writes it.
    pub read_at: String,
}

/// One row of the local list.
#[derive(Debug, Clone, uniffi::Record)]
pub struct FfiLocalEntry {
    pub catalog: FfiCatalog,
    pub catalog_id: i64,
    pub status: String,
}

#[derive(Debug, Clone, uniffi::Record)]
pub struct FfiCinemaGenre {
    pub id: i64,
    pub name: String,
}

#[derive(Debug, Clone, uniffi::Record)]
pub struct CinemaSeason {
    pub number: i32,
    pub episode_count: i32,
}

#[derive(Debug, Clone, uniffi::Record)]
pub struct FfiCharacter {
    pub id: i64,
    pub name: String,
    pub role: String,
    pub image_url: Option<String>,
    pub voice_actor_name: Option<String>,
    pub voice_actor_image_url: Option<String>,
}

#[derive(Debug, Clone, uniffi::Record)]
pub struct FfiRelation {
    pub catalog_id: i64,
    pub relation_type: String,
    pub title: String,
    pub format: Option<String>,
    pub cover_image: String,
    pub status: Option<String>,
    pub average_score: Option<i32>,
}

#[derive(Debug, Clone, uniffi::Record)]
pub struct FfiRecommendation {
    pub catalog_id: i64,
    pub title: String,
    pub format: Option<String>,
    pub cover_image: String,
    pub average_score: Option<i32>,
    pub rating: Option<i32>,
}

#[derive(Debug, Clone, uniffi::Record)]
pub struct FfiDiscussion {
    pub id: i64,
    pub title: String,
    pub reply_count: i32,
    pub view_count: i32,
    pub author_name: Option<String>,
    pub author_avatar_url: Option<String>,
    pub replied_at: Option<i64>,
}

/// One voice actor, as listed under a character appearance.
#[derive(Debug, Clone, uniffi::Record)]
pub struct FfiVoiceActor {
    pub id: i64,
    pub name: String,
    pub image_url: Option<String>,
    /// AniList's `languageV2`: free text ("Japanese", "English"), not the
    /// screaming-case `StaffLanguage` enum the cast list's `language` uses.
    pub language: Option<String>,
}

/// One title a character appears in.
#[derive(Debug, Clone, uniffi::Record)]
pub struct FfiCharacterAppearance {
    pub catalog_id: i64,
    /// "ANIME" or "MANGA". A character page mixes both, and the row has to
    /// know which detail page to open.
    pub media_type: Option<String>,
    pub format: Option<String>,
    pub title: String,
    pub cover_image: String,
    pub year: Option<i32>,
    /// "MAIN", "SUPPORTING" or "BACKGROUND".
    pub character_role: Option<String>,
    pub voice_actors: Vec<FfiVoiceActor>,
}

#[derive(Debug, Clone, uniffi::Record)]
pub struct FfiCharacterDetail {
    pub id: i64,
    pub name: String,
    pub native_name: Option<String>,
    pub alternative_names: Vec<String>,
    pub image_url: Option<String>,
    /// Raw AniList markdown, deliberately not pre-parsed HTML: bios are full
    /// of `~!spoiler!~` markers, and only the client can decide whether to
    /// reveal one.
    pub description: Option<String>,
    pub gender: Option<String>,
    /// Free text on AniList ("13", "1000+", "17-18"), not a number.
    pub age: Option<String>,
    /// Split rather than formatted into one string because AniList birthdays
    /// routinely have a month and day and no year at all, which no single
    /// date string can express without inventing one.
    pub birth_year: Option<i32>,
    pub birth_month: Option<i32>,
    pub birth_day: Option<i32>,
    pub favourites: i32,
    pub appearances: Vec<FfiCharacterAppearance>,
}

/// A character named on a staff credit. Not `FfiCharacter`, which carries the
/// cast-list fields (role in *this* show, voice actor) that mean nothing here
/// — the staff member being looked at *is* the voice actor.
#[derive(Debug, Clone, uniffi::Record)]
pub struct FfiCreditCharacter {
    pub id: i64,
    pub name: String,
    pub image_url: Option<String>,
}

/// A title this person voiced a character in.
#[derive(Debug, Clone, uniffi::Record)]
pub struct FfiStaffCharacterCredit {
    pub catalog_id: i64,
    pub media_type: Option<String>,
    pub format: Option<String>,
    pub title: String,
    pub cover_image: String,
    pub year: Option<i32>,
    pub character_role: Option<String>,
    pub characters: Vec<FfiCreditCharacter>,
}

/// A title this person held a production role on.
#[derive(Debug, Clone, uniffi::Record)]
pub struct FfiStaffMediaCredit {
    pub catalog_id: i64,
    pub media_type: Option<String>,
    pub format: Option<String>,
    pub title: String,
    pub cover_image: String,
    pub year: Option<i32>,
    /// Free text ("Director", "Key Animation", "Theme Song Performance"),
    /// not an enum.
    pub staff_role: Option<String>,
}

#[derive(Debug, Clone, uniffi::Record)]
pub struct FfiStaffDetail {
    pub id: i64,
    pub name: String,
    pub native_name: Option<String>,
    pub image_url: Option<String>,
    /// Raw markdown, same reasoning as `FfiCharacterDetail::description`.
    pub description: Option<String>,
    pub primary_occupations: Vec<String>,
    pub home_town: Option<String>,
    pub language: Option<String>,
    pub favourites: i32,
    /// The two lists are kept apart because AniList keeps them apart, and a
    /// person can appear in both for the same show — a director who also
    /// voiced a bit part would otherwise collapse into one ambiguous row.
    pub character_credits: Vec<FfiStaffCharacterCredit>,
    pub media_credits: Vec<FfiStaffMediaCredit>,
}

/// A studio credited on a title, as the detail page links to it.
#[derive(Debug, Clone, uniffi::Record)]
pub struct FfiStudioRef {
    pub id: i64,
    pub name: String,
    /// True for the animation studio, false for the rest of the production
    /// committee. The detail page's single `studio` line has always shown the
    /// first name AniList happened to return; this is what lets a caller show
    /// the one that actually made the show.
    pub is_main: bool,
}

/// One studio's own page.
#[derive(Debug, Clone, uniffi::Record)]
pub struct FfiStudioDetail {
    pub id: i64,
    pub name: String,
    pub is_animation_studio: bool,
    pub favourites: i32,
    /// Titles this studio led, newest first.
    pub media: Vec<MediaSummary>,
}

/// One episode airing at a known time, for the season calendar.
#[derive(Debug, Clone, uniffi::Record)]
pub struct FfiAiringSlot {
    pub catalog_id: i64,
    pub title: String,
    pub cover_image: String,
    pub episode: i32,
    /// Unix seconds. The client turns it into a local time; the engine has no
    /// business deciding which zone the calendar is drawn in.
    pub airing_at: i64,
    pub format: Option<String>,
    pub episode_count: Option<i32>,
    pub on_user_list: bool,
    /// `CURRENT`, `PLANNING`, `COMPLETED`, `PAUSED`, `DROPPED`, `REPEATING`.
    pub user_status: Option<String>,
}

/// One "Because you watched" row: a title, plus the title that suggested it.
#[derive(Debug, Clone, uniffi::Record)]
pub struct FfiRecommendationRow {
    pub media: MediaSummary,
    pub because_title: String,
    pub because_catalog_id: i64,
    /// AniList's own recommendation score — how many users agreed with the
    /// pairing, not a rating of the title.
    pub rating: i32,
}

/// One comment, already flattened out of AniList's nested reply blob.
#[derive(Debug, Clone, uniffi::Record)]
pub struct FfiThreadComment {
    pub id: i64,
    /// `None` for a top-level comment. Replies arrive inline, immediately
    /// after their parent, so a list view can indent on `depth` without
    /// building a tree first.
    pub parent_id: Option<i64>,
    pub depth: i32,
    /// Markdown, as posted.
    pub body: String,
    pub author_name: Option<String>,
    pub author_avatar_url: Option<String>,
    pub created_at: i64,
    pub like_count: i32,
}

#[derive(Debug, Clone, uniffi::Record)]
pub struct FfiThreadCommentPage {
    pub comments: Vec<FfiThreadComment>,
    /// Counts top-level comments only — replies come inline inside their
    /// parent and take no slot on the page, so this can be false while the
    /// list is far longer than the page size.
    pub has_next_page: bool,
}

#[derive(Debug, Clone, uniffi::Record)]
pub struct FfiThreadDetail {
    pub id: i64,
    pub title: String,
    /// Markdown, as posted.
    pub body: String,
    pub author_name: Option<String>,
    pub author_avatar_url: Option<String>,
    pub created_at: i64,
    /// AniList's own reply total for the thread, which counts replies as well
    /// as top-level comments — it will not match `comments.len()`.
    pub reply_count: i32,
    pub view_count: i32,
    pub is_locked: bool,
    pub categories: Vec<String>,
    /// The first page of comments. Same caveat as
    /// `FfiThreadCommentPage::has_next_page`.
    pub comments: Vec<FfiThreadComment>,
    pub has_next_page: bool,
}

/// Everything the detail page draws.
#[derive(Debug, Clone, uniffi::Record)]
pub struct MediaDetail {
    pub catalog_id: i64,
    /// MyAnimeList's id for this same title, when AniList has the mapping.
    /// AniSkip (intro/outro skip times) is keyed by MAL id, not AniList's —
    /// the two catalogs are otherwise unrelated here, so this is the only
    /// bridge between them.
    pub mal_id: Option<i64>,
    pub title: String,
    pub romaji_title: Option<String>,
    pub cover_image: String,
    pub banner_image: Option<String>,
    pub format: Option<String>,
    pub status: Option<String>,
    pub year: Option<i32>,
    /// The first studio's name, which is what the header line has always
    /// drawn. Kept beside `studios` rather than replaced by it: every caller
    /// of this field wants one string, not a list to pick from.
    pub studio: Option<String>,
    /// Every credited studio with the id a studio page needs.
    pub studios: Vec<FfiStudioRef>,
    /// `YOUTUBE` or `DAILYMOTION`, with `trailer_id` the site's own video id
    /// — AniList stores no playable URL, so the client builds one.
    pub trailer_site: Option<String>,
    pub trailer_id: Option<String>,
    pub trailer_thumbnail: Option<String>,
    pub synopsis: Option<String>,
    pub genres: Vec<String>,
    pub average_score: Option<i32>,
    pub episode_count: Option<i32>,
    pub chapter_count: Option<i32>,
    pub duration_minutes: Option<i32>,
    /// The episode the resume button points at, and how far into it, from the
    /// local registry rather than from AniList — AniList tracks whole
    /// episodes and knows nothing about a position inside one.
    pub resume_episode: Option<i32>,
    pub resume_seconds: Option<i32>,
    pub prequel: Option<RelatedTitle>,
    pub sequel: Option<RelatedTitle>,
    pub relations: Vec<FfiRelation>,
    pub recommendations: Vec<FfiRecommendation>,
    pub episodes: Vec<EpisodeRow>,
    /// `CURRENT`, `PLANNING`, `COMPLETED`, `DROPPED`, `PAUSED`, `REPEATING`,
    /// or `None` when this title isn't on the signed-in user's list at all.
    pub list_status: Option<String>,
    pub user_score: Option<f64>,
    /// The list entry's own id — `DeleteMediaListEntry` is keyed on this, not
    /// on `catalog_id`. `None` alongside `list_status: None` means there is
    /// nothing to remove.
    pub list_entry_id: Option<i64>,
    /// AniList progress as the *list* has it, separate from `resume_episode`
    /// (which comes from the local watch-history registry). Marking an
    /// episode watched by hand has to advance this one.
    pub list_progress: Option<i32>,
    pub is_favourite: bool,
}

#[derive(Debug, Clone, uniffi::Record)]
pub struct WatchProgress {
    pub episode_number: i64,
    pub stop_time: i64,
    pub duration: i64,
}

/// The audio and subtitle tracks chosen for one title. Languages, not track
/// indexes — see the `title_track_prefs` migration for why.
#[derive(Debug, Clone, uniffi::Record)]
pub struct FfiTrackPreference {
    pub audio_lang: Option<String>,
    pub subtitle_lang: Option<String>,
    /// The track's own name, for packs that ship two tracks of one language
    /// ("Signs & Songs" beside "Full Subtitles").
    pub subtitle_title: Option<String>,
}

/// One day of the activity calendar.
#[derive(Debug, Clone, uniffi::Record)]
pub struct FfiDayCount {
    /// `YYYY-MM-DD`, in the device's own timezone.
    pub date: String,
    pub episodes: i32,
    pub seconds: i64,
}

#[derive(Debug, Clone, uniffi::Record)]
pub struct FfiTitleCount {
    pub catalog: FfiCatalog,
    pub catalog_id: i64,
    pub episodes: i32,
    pub seconds: i64,
}

/// What the local watch history adds up to. Nothing here comes from AniList:
/// it tracks whole episodes and records no time of day, so a calendar, a
/// streak and an hour histogram can only be built from this device's rows.
#[derive(Debug, Clone, uniffi::Record)]
pub struct FfiWatchStats {
    pub total_watch_seconds: i64,
    /// Episodes past 85%, the same threshold the player advances progress at.
    pub episodes_watched: i32,
    /// Distinct titles with any playback recorded, 85% gate or not — one
    /// abandoned four seconds in still counts as started.
    pub titles_started: i32,
    /// Oldest first, ending today, with untouched days present and zeroed.
    /// `episodes` here counts every episode touched that day rather than only
    /// the finished ones, so it does not match `episodes_watched` and is not
    /// meant to.
    pub per_day: Vec<FfiDayCount>,
    pub current_streak_days: i32,
    pub longest_streak_days: i32,
    pub top_titles: Vec<FfiTitleCount>,
    /// 0-23 local. 0 when there is no history at all.
    pub busiest_hour: i32,
    pub first_watch_at: Option<String>,
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
    /// Where playback will actually start, as a fraction (0.0-1.0) of the
    /// episode's length — the caller's own `stopTime / duration`. `None` for
    /// a fresh play. See `torrent::ResolveTarget::resume_fraction` for why
    /// this has to reach the pre-buffer gate, not just mpv's `--start`.
    pub resume_fraction: Option<f64>,
    /// A speculative resolve for an episode nobody is watching yet (the
    /// next one, near the end of the current one). It fills the reuse cache
    /// so the real play is instant, but must not claim the playing-file pin:
    /// that belongs to the episode mpv is reading, and moving it would let
    /// `retain_recent` evict the file under the player.
    pub preload: bool,
}

/// Status of a "Download Episode" — mirrors `torrent::EpisodeDownloadStatus`,
/// which has no uniffi derive for the same reason `FfiTorrentChoice` doesn't
/// share one with `TorrentChoice`.
#[derive(Debug, Clone, uniffi::Enum)]
pub enum FfiDownloadStatus {
    NotStarted,
    Downloading { percent: f64 },
    Done { path: String },
    Failed { message: String },
}

impl From<crate::torrent::EpisodeDownloadStatus> for FfiDownloadStatus {
    fn from(s: crate::torrent::EpisodeDownloadStatus) -> Self {
        match s {
            crate::torrent::EpisodeDownloadStatus::NotStarted => Self::NotStarted,
            crate::torrent::EpisodeDownloadStatus::Downloading { percent } => Self::Downloading { percent },
            crate::torrent::EpisodeDownloadStatus::Done { path } => Self::Done { path },
            crate::torrent::EpisodeDownloadStatus::Failed { message } => Self::Failed { message },
        }
    }
}

/// One release from the indexers, for the "Stream Servers" picker. Mirrors
/// `torrent::TorrentChoice` — a separate type because that one is a plain
/// crate-internal struct with no uniffi derive, and adding one there would
/// pull uniffi into a module that has no other reason to know about FFI.
#[derive(Debug, Clone, uniffi::Record)]
pub struct FfiTorrentChoice {
    pub name: String,
    pub seeders: u64,
    pub is_dub: bool,
}

#[derive(Debug, Clone, Default, PartialEq, Eq, uniffi::Record)]
pub struct SearchFilters {
    pub genre: Option<String>,
    pub year: Option<i32>,
    /// `WINTER`/`SPRING`/`SUMMER`/`FALL`. Only sent alongside `year` — see
    /// `build_search_variables`.
    pub season: Option<String>,
    /// One `MediaFormat`: `TV`, `TV_SHORT`, `MOVIE`, `SPECIAL`, `OVA`, `ONA`,
    /// `MUSIC` for anime; `MANGA`, `NOVEL`, `ONE_SHOT` for manga.
    pub format: Option<String>,
    pub min_score: Option<i32>,
    pub status: Option<String>,
    pub sort: Option<String>,
}

/// The engine. One per app launch.
#[derive(uniffi::Object)]
pub struct AnicatEngine {
    http: reqwest::Client,
    catalogs: Catalogs,
    /// Shared so a background watcher can outlive the call that started it:
    /// a download records itself when it lands, whatever the UI is doing.
    registry: Arc<Registry>,
    offline: crate::reader::offline::OfflineLibrary,
    /// Bytes the offline library may occupy before the least recently used
    /// chapters are evicted. Settable, because what is a reasonable slice of
    /// a disk is not something this can know.
    offline_cap_bytes: std::sync::atomic::AtomicU64,
    /// The chapter open in the reader, which eviction skips. Downloading one
    /// chapter must never delete the one being read out from under it -- the
    /// same pin the torrent cache keeps on the file a player is reading.
    reading_chapter: std::sync::Mutex<Option<(Catalog, i64, String)>>,
    torrents: Arc<TorrentManager>,
    mangadex: MangaDexClient,
    mangakatana: MangaKatanaClient,
    syosetu: SyosetuClient,
    discord: DiscordClient,
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
        // Base URL of a proxy holding the TMDB key, when the build ships one.
        // With it, no key reaches the app at all -- see
        // `catalog::tmdb::client`'s header for why that is the only version
        // of "the key cannot be extracted" that is true.
        tmdb_proxy: Option<String>,
    ) -> FfiResult<Arc<Self>> {
        // stderr, `RUST_LOG` respected, info by default. `try_init` because
        // a test binary or a second engine may already have installed one.
        // librqbit and the DHT are chatty at info and say nothing a viewer
        // of this log can act on, so they sit at warn unless asked for.
        let _ = env_logger::Builder::from_env(
            env_logger::Env::default().default_filter_or("info,librqbit=warn,librqbit_dht=warn,librqbit_core=warn,hyper=warn,reqwest=warn,tracing::span=off"),
        )
        .format_timestamp_millis()
        .try_init();
        let dir = PathBuf::from(&data_dir);
        // Named, not anonymous. TMDB's API terms forbid concealing the
        // identity of the application making the request, and Anicat asks
        // with one key shared by every install -- so the request has to say
        // whose it is. AniList, MangaDex and AniZip see the same string.
        let http = reqwest::Client::builder()
            .user_agent(concat!(
                "Anicat/",
                env!("CARGO_PKG_VERSION"),
                " (+https://github.com/bonkedbythonk/anicat)"
            ))
            .build()
            .map_err(AnicatError::internal)?;
        let registry = Registry::open(&dir.join("registry.sqlite"))
            .map_err(|msg| AnicatError::Storage { msg })?;
        Ok(Arc::new(Self {
            // Its own file, not a registry table: it is disposable, it can
            // grow to tens of megabytes of JSON, and it must never be part
            // of what "wipe the registry" touches or what a registry
            // migration has to carry.
            catalogs: Catalogs::with_cache(
                http.clone(),
                anilist_token,
                tmdb_key,
                tmdb_proxy,
                AniListCache::persistent(&dir.join("catalog-cache.sqlite")),
            ),
            registry: Arc::new(registry),
            // Chapters kept for offline reading. Application Support rather
            // than Caches: this is what the viewer asked to keep, and the
            // system empties Caches whenever it likes.
            offline: crate::reader::offline::OfflineLibrary::new(
                dir.join("offline-manga"),
                http.clone(),
            ),
            offline_cap_bytes: std::sync::atomic::AtomicU64::new(DEFAULT_OFFLINE_CAP_BYTES),
            reading_chapter: std::sync::Mutex::new(None),
            torrents: Arc::new(TorrentManager::with_cache_dir(dir.join("torrent-streams"))),
            mangadex: MangaDexClient::new(http.clone()),
            mangakatana: MangaKatanaClient::new(http.clone()),
            syosetu: SyosetuClient::new(http.clone()),
            discord: DiscordClient::new(),
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

    /// Brings up everything a first play would otherwise pay for on the
    /// spot: the loopback range server and the librqbit session with its
    /// DHT bootstrap. Called by the host right after construction, off the
    /// path that paints the first screen. Failures are logged, not
    /// returned; the same work is retried by the first real resolve.
    pub async fn warm_up(&self) {
        let started = std::time::Instant::now();
        if let Err(e) = self.ensure_stream_server().await {
            log::warn!("warm_up: range server: {e:?}");
        }
        match self.torrents.session().await {
            Ok(_) => log::info!("warm_up: torrent session ready in {}ms", started.elapsed().as_millis()),
            Err(e) => log::warn!("warm_up: torrent session: {e}"),
        }
    }

    /// The player has stopped reading. Releases the playing-file pin and
    /// pauses every torrent in the session; without this a closed player
    /// left librqbit pulling the rest of the episode, and any preloaded
    /// next one, at full speed until the cache evicted them.
    pub async fn playback_stopped(&self) {
        self.torrents.pause_all().await;
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
    /// Kept for `BridgeTests`, which exercises the search path through the
    /// narrowest surface it can. The MANGA and NOVEL siblings had no caller
    /// at all and are gone.
    pub async fn search_anime(&self, query: String) -> FfiResult<Vec<MediaSummary>> {
        self.search_catalog(Some(query), Some("ANIME".to_string()), None, None).await
    }

    pub async fn search_catalog(
        &self,
        query: Option<String>,
        media_type: Option<String>,
        filters: Option<SearchFilters>,
        page: Option<i32>,
    ) -> FfiResult<Vec<MediaSummary>> {
        let page_num = page.unwrap_or(1);
        let page_str = page_num.to_string();
        let year_str = filters.as_ref().and_then(|f| f.year).map(|y| y.to_string()).unwrap_or_default();
        let min_score_str = filters.as_ref().and_then(|f| f.min_score).map(|s| s.to_string()).unwrap_or_default();
        let cache_key = AniListCache::key("search_media", &[
            ("q", query.as_deref().unwrap_or("")),
            ("page", &page_str),
            ("type", media_type.as_deref().unwrap_or("")),
            ("genre", filters.as_ref().and_then(|f| f.genre.as_deref()).unwrap_or("")),
            ("year", &year_str),
            ("season", filters.as_ref().and_then(|f| f.season.as_deref()).unwrap_or("")),
            ("format", filters.as_ref().and_then(|f| f.format.as_deref()).unwrap_or("")),
            ("min", &min_score_str),
            ("status", filters.as_ref().and_then(|f| f.status.as_deref()).unwrap_or("")),
            ("sort", filters.as_ref().and_then(|f| f.sort.as_deref()).unwrap_or("")),
        ]);
        if let Some(hit) = self.catalogs.cache.get(&cache_key) {
            if let Ok(items) = serde_json::from_value::<Vec<anilist::types::MediaItem>>(hit) {
                return Ok(items.iter().map(summarize).collect());
            }
        }
        let vars = build_search_variables(
            query.as_deref(),
            media_type.as_deref(),
            filters.as_ref(),
            page_num,
        );
        let page: anilist::responses::PageResponse<anilist::types::MediaItem> = self
            .catalogs
            .anilist
            .execute(anilist::queries::MEDIA_SEARCH_QUERY, vars)
            .await
            .map_err(|msg| AnicatError::Network { msg })?;
        let items = page.page.media.unwrap_or_default();
        if let Ok(v) = serde_json::to_value(&items) {
            self.catalogs.cache.set(cache_key, v, "search_media");
        }
        Ok(items.iter().map(summarize).collect())
    }

    /// Find a torrent for an episode and hand back what the player opens.
    pub async fn resolve_stream(&self, req: StreamRequest) -> FfiResult<StreamHandle> {
        // A film or an episode of a western series is searched on year or on
        // SxxEyy, neither of which the anime path has any notion of. Falling
        // through would silently run the anime search for a film and return
        // some unrelated release.
        if req.catalog != FfiCatalog::Anilist {
            return self.resolve_cinema_stream(req).await;
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

        // Last time's release for this exact episode, when it was picked
        // under the same Sub/Dub preference. A flip is a request for a
        // different release, so it goes to the search.
        let remembered = self
            .registry
            .remembered_release(media.catalog, media.id, req.episode)
            .ok()
            .flatten()
            .filter(|r| r.prefer_dub == req.prefer_dub);

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
                    aired_episodes: info.aired_episodes,
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
                    resume_fraction: req.resume_fraction,
                    remembered,
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
        // Persist the winner so the next play of this episode, in any later
        // process, starts from it instead of a search. A reuse has no
        // winner recorded in this process and changes nothing on disk.
        if let Some(winner) = self.torrents.winning_release(media, req.episode).await {
            if let Err(e) = self
                .registry
                .remember_release(media.catalog, media.id, req.episode, &winner)
            {
                log::warn!("registry: could not remember release for {media} ep {}: {e}", req.episode);
            }
        }
        if !req.preload {
            self.torrents.set_playing(media, req.episode).await;
        }
        Ok(StreamHandle {
            url,
            torrent_id: torrent_id as u64,
            file_id: file_id as u64,
        })
    }

    /// Bytes the torrent stream cache is holding on disk.
    ///
    /// Scanned on call rather than tracked: librqbit writes to the same
    /// directory — preallocating a file to its full length before a byte of
    /// it arrives — so a counter kept alongside would drift immediately.
    pub async fn stream_cache_bytes(&self) -> u64 {
        self.torrents.cache_bytes().await
    }

    /// Drops everything in the stream cache except what a player is reading.
    ///
    /// The cap that governs the cache during playback is sized to hold an
    /// episode and its preload; it is the wrong budget for a device that has
    /// stopped watching, which on a phone is most of the time. Safe to call
    /// while something is playing: the playing torrent is exempt.
    pub async fn purge_stream_cache(&self) -> FfiResult<()> {
        self.torrents.purge_stream_cache().await;
        Ok(())
    }

    /// Whether cinema mode has a TMDB credential to read with.
    ///
    /// The mode is hidden without one rather than shown broken: every call
    /// below fails with `no_tmdb_token`, and eight empty shelves explain
    /// nothing to whoever is looking at them.
    pub fn has_tmdb_key(&self) -> bool {
        self.catalogs.has_tmdb_key()
    }

    /// The cinema home rows, in the order the page draws them. Named by the
    /// engine so it stays the only place that knows which TMDB endpoints
    /// exist -- a row the Swift side invents has no endpoint behind it.
    pub fn cinema_row_kinds(&self) -> Vec<String> {
        crate::catalog::cinema::CINEMA_ROWS.iter().map(|k| k.to_string()).collect()
    }

    /// One cinema home row.
    pub async fn cinema_row(&self, kind: String, page: i32) -> FfiResult<Vec<MediaSummary>> {
        let items = self
            .catalogs
            .cinema_row(&kind, page.max(1) as i64)
            .await
            .map_err(|msg| AnicatError::Network { msg })?;
        Ok(items.iter().map(summarize_cinema).collect())
    }

    /// Films and series matching a query, most popular first. `page` is
    /// TMDB's own, twenty results to a page.
    pub async fn search_cinema(
        &self,
        query: String,
        limit: i32,
        page: i32,
    ) -> FfiResult<Vec<MediaSummary>> {
        let items = self
            .catalogs
            .cinema_search(&query, limit.max(1) as i64, page.max(1) as i64)
            .await
            .map_err(|msg| AnicatError::Network { msg })?;
        Ok(items.iter().map(summarize_cinema).collect())
    }

    /// TMDB's genre list, for the filter row.
    pub async fn cinema_genres(&self, is_series: bool) -> FfiResult<Vec<FfiCinemaGenre>> {
        let rows = self
            .catalogs
            .cinema_genres(is_series)
            .await
            .map_err(|msg| AnicatError::Network { msg })?;
        Ok(rows
            .into_iter()
            .map(|(id, name)| FfiCinemaGenre { id, name })
            .collect())
    }

    /// Browse by genre, year and sort. A keyword search cannot answer
    /// "action films from 1999, most popular first"; this is the endpoint
    /// that can, and it is what the anime side's filtered search does
    /// through AniList.
    pub async fn cinema_discover(
        &self,
        is_series: bool,
        genre_id: Option<i64>,
        year: Option<i32>,
        sort: Option<String>,
        page: i32,
    ) -> FfiResult<Vec<MediaSummary>> {
        let items = self
            .catalogs
            .cinema_discover(is_series, genre_id, year, sort.as_deref(), page.max(1) as i64)
            .await
            .map_err(|msg| AnicatError::Network { msg })?;
        Ok(items.iter().map(summarize_cinema).collect())
    }

    /// Every episode downloaded to the Downloads folder, newest first.
    ///
    /// Rows whose file has since been moved or deleted are dropped on the way
    /// out, and forgotten: the table is an index, the file is the truth, and
    /// offering to play something that is not there is worse than forgetting
    /// it was ever fetched.
    pub fn downloaded_episodes(&self) -> FfiResult<Vec<FfiDownloadedEpisode>> {
        let rows = self
            .registry
            .downloaded_episodes()
            .map_err(|msg| AnicatError::Storage { msg })?;
        let mut out = vec![];
        for row in rows {
            if !std::path::Path::new(&row.path).exists() {
                let _ = self.registry.forget_downloaded_episode(
                    row.catalog,
                    row.catalog_id,
                    row.episode_number,
                );
                continue;
            }
            out.push(FfiDownloadedEpisode {
                catalog: row.catalog.into(),
                catalog_id: row.catalog_id,
                episode_number: row.episode_number,
                title: row.title,
                path: row.path,
                bytes: row.bytes as u64,
                downloaded_at: row.downloaded_at,
            });
        }
        Ok(out)
    }

    /// Adopts files already sitting in the Downloads folder.
    ///
    /// Downloads made before there was a table to record them -- and any a
    /// crash lost -- are on disk under `Downloads/Anicat/<title>/`, invisible
    /// to an app that only knows what it wrote down. This walks that folder
    /// once and indexes what it can identify.
    ///
    /// Identification is the whole difficulty: a directory name is a title
    /// the app has to match back to a catalog id, and a filename is a release
    /// name that has to yield an episode number. `hints` is what the caller
    /// knows -- its own lists -- because nothing on disk carries an id, and
    /// the release-name parsing is the indexer's own, so a name it cannot
    /// read is skipped rather than guessed at.
    ///
    /// Returns how many were adopted. Idempotent: an episode already indexed
    /// is left alone, so running it every launch costs a directory walk.
    pub fn scan_downloads_folder(&self, hints: Vec<FfiTitleHint>) -> FfiResult<u32> {
        let root = dirs::download_dir()
            .unwrap_or_else(std::env::temp_dir)
            .join("Anicat");
        let known: Vec<(i64, i64)> = self
            .registry
            .downloaded_episodes()
            .map_err(|msg| AnicatError::Storage { msg })?
            .into_iter()
            .map(|row| (row.catalog_id, row.episode_number))
            .collect();

        let mut adopted = 0;
        for found in adoptable_downloads(&root, &hints, &known) {
            let hint = &hints[found.hint_index];
            if self
                .registry
                .record_downloaded_episode(
                    hint.catalog.into(),
                    hint.catalog_id,
                    found.episode,
                    hint.titles.first().map(|t| t.as_str()),
                    &found.path,
                    found.bytes,
                )
                .is_ok()
            {
                adopted += 1;
            }
        }
        if adopted > 0 {
            log::info!("[downloads] adopted {adopted} file(s) already in the Downloads folder");
        }
        Ok(adopted)
    }

    /// Forgets a downloaded episode, and deletes the file when asked to.
    ///
    /// The file is in the viewer's own Downloads folder, which is theirs --
    /// so removing the row and deleting the copy are separate decisions and
    /// the caller makes both.
    pub fn remove_downloaded_episode(
        &self,
        catalog: FfiCatalog,
        catalog_id: i64,
        episode: i64,
        delete_file: bool,
    ) -> FfiResult<()> {
        if delete_file {
            if let Ok(rows) = self.registry.downloaded_episodes() {
                if let Some(row) = rows.iter().find(|r| {
                    r.catalog == catalog.into()
                        && r.catalog_id == catalog_id
                        && r.episode_number == episode
                }) {
                    let _ = std::fs::remove_file(&row.path);
                }
            }
        }
        self.registry
            .forget_downloaded_episode(catalog.into(), catalog_id, episode)
            .map_err(|msg| AnicatError::Storage { msg })
    }

    /// Downloads a chapter's pages for reading with no network.
    ///
    /// The pages are ordinary image URLs, so this is a fetch and a write; the
    /// reader is handed `file://` URLs afterwards and cannot tell the
    /// difference. A partial download is discarded rather than kept: half a
    /// chapter reads as a chapter that ends early, with nothing on the page
    /// to say otherwise.
    pub async fn download_chapter(
        &self,
        catalog: FfiCatalog,
        catalog_id: i64,
        chapter_id: String,
        chapter_number: String,
        title: Option<String>,
    ) -> FfiResult<u32> {
        let pages = self.get_manga_pages(chapter_id.clone()).await?;
        let catalog: Catalog = catalog.into();
        let stored = self
            .offline
            .download(catalog.as_str(), catalog_id, &chapter_id, &pages)
            .await
            .map_err(|msg| AnicatError::Storage { msg })?;
        self.registry
            .record_offline_chapter(crate::db::service::NewOfflineChapter {
                catalog,
                catalog_id,
                chapter_id: &chapter_id,
                chapter_number: &chapter_number,
                title: title.as_deref(),
                page_count: stored.pages.len() as i64,
                bytes: stored.bytes as i64,
            })
            .map_err(|msg| AnicatError::Storage { msg })?;
        log::info!(
            "[offline] {} ch {} stored: {} pages, {} KB",
            catalog_id,
            chapter_number,
            stored.pages.len(),
            stored.bytes / 1024
        );
        // The library only grows one way, so this is the moment to trim it.
        let _ = self.enforce_offline_limit();
        Ok(stored.pages.len() as u32)
    }

    /// The stored pages of a chapter as `file://` URLs, or empty when it is
    /// not downloaded.
    ///
    /// Answered from the directory, not from the registry row: files deleted
    /// underneath the app -- a sync tool, a manual clean -- must read as "not
    /// downloaded" rather than as a chapter with holes in it.
    pub fn offline_chapter_pages(
        &self,
        catalog: FfiCatalog,
        catalog_id: i64,
        chapter_id: String,
    ) -> Vec<String> {
        let catalog: Catalog = catalog.into();
        self.offline
            .pages(catalog.as_str(), catalog_id, &chapter_id)
            .map(|paths| {
                paths
                    .into_iter()
                    .map(|p| file_url(&p))
                    .collect()
            })
            .unwrap_or_default()
    }

    /// The size the offline library is held to. Zero means no cap.
    pub fn set_offline_limit_bytes(&self, bytes: u64) {
        self.offline_cap_bytes
            .store(bytes, std::sync::atomic::Ordering::Relaxed);
    }

    pub fn offline_limit_bytes(&self) -> u64 {
        self.offline_cap_bytes
            .load(std::sync::atomic::Ordering::Relaxed)
    }

    /// Names the chapter open in the reader, so eviction leaves it alone.
    /// Cleared with `None` when the reader closes.
    pub fn set_reading_chapter(
        &self,
        catalog: FfiCatalog,
        catalog_id: i64,
        chapter_id: Option<String>,
    ) {
        let catalog: Catalog = catalog.into();
        if let Ok(mut pin) = self.reading_chapter.lock() {
            *pin = chapter_id.clone().map(|id| (catalog, catalog_id, id));
        }
        // Opening is using: the cap evicts by when a chapter was last read,
        // not by when it was fetched.
        if let Some(chapter_id) = chapter_id {
            let _ = self
                .registry
                .touch_offline_chapter(catalog, catalog_id, &chapter_id);
        }
    }

    /// Brings the offline library back under its cap, least recently used
    /// first. Returns how many chapters were removed.
    ///
    /// Run after a download rather than on a timer: the library only grows
    /// one way, and doing it here means the chapter just fetched is the
    /// newest and so the last thing considered.
    pub fn enforce_offline_limit(&self) -> FfiResult<u32> {
        let cap = self.offline_limit_bytes();
        if cap == 0 {
            return Ok(0);
        }
        let pinned = self.reading_chapter.lock().ok().and_then(|p| p.clone());
        let mut rows = self
            .registry
            .offline_chapters_by_age()
            .map_err(|msg| AnicatError::Storage { msg })?;
        let sizes: Vec<(u64, bool)> = rows
            .iter()
            .map(|row| {
                let is_pinned = pinned
                    .as_ref()
                    .map(|(c, id, chapter)| {
                        row.catalog == *c && row.catalog_id == *id && row.chapter_id == *chapter
                    })
                    .unwrap_or(false);
                (row.bytes.max(0) as u64, is_pinned)
            })
            .collect();
        let doomed = chapters_to_evict(&sizes, cap);
        let mut total: u64 = sizes.iter().map(|(bytes, _)| bytes).sum();
        let mut evicted = 0;
        // Removed back to front so the indices stay valid.
        for index in doomed.into_iter().rev() {
            let row = rows.remove(index);
            self.offline
                .delete(row.catalog.as_str(), row.catalog_id, &row.chapter_id)
                .map_err(|msg| AnicatError::Storage { msg })?;
            self.registry
                .forget_offline_chapter(row.catalog, row.catalog_id, &row.chapter_id)
                .map_err(|msg| AnicatError::Storage { msg })?;
            total = total.saturating_sub(row.bytes.max(0) as u64);
            evicted += 1;
            log::info!(
                "[offline] evicted {} ch {} ({} KB), {} KB left of {} KB",
                row.catalog_id,
                row.chapter_number,
                row.bytes / 1024,
                total / 1024,
                cap / 1024
            );
        }
        Ok(evicted)
    }

    /// Every chapter kept on disk, newest first.
    pub fn offline_chapters(&self) -> FfiResult<Vec<FfiOfflineChapter>> {
        let rows = self
            .registry
            .offline_chapters()
            .map_err(|msg| AnicatError::Storage { msg })?;
        Ok(rows
            .into_iter()
            .map(|r| FfiOfflineChapter {
                catalog: r.catalog.into(),
                catalog_id: r.catalog_id,
                chapter_id: r.chapter_id,
                chapter_number: r.chapter_number,
                title: r.title,
                page_count: r.page_count as u32,
                bytes: r.bytes as u64,
                downloaded_at: r.downloaded_at,
            })
            .collect())
    }

    /// Removes a downloaded chapter, files first.
    ///
    /// If the files go and the row stays, the app offers to read something
    /// that is not there; the other way round it merely forgets a directory,
    /// which the next download overwrites.
    pub fn delete_offline_chapter(
        &self,
        catalog: FfiCatalog,
        catalog_id: i64,
        chapter_id: String,
    ) -> FfiResult<()> {
        let catalog: Catalog = catalog.into();
        self.offline
            .delete(catalog.as_str(), catalog_id, &chapter_id)
            .map_err(|msg| AnicatError::Storage { msg })?;
        self.registry
            .forget_offline_chapter(catalog, catalog_id, &chapter_id)
            .map_err(|msg| AnicatError::Storage { msg })
    }

    /// Bytes the offline library occupies.
    pub fn offline_size_bytes(&self) -> u64 {
        self.offline.size_bytes()
    }

    /// Records where a chapter was left, so reopening it lands on the page
    /// it was closed on rather than on page one.
    ///
    /// Called on every page turn: it is an upsert on the chapter, not an
    /// append, so the cost is one small write and the row always says "where
    /// you are" rather than everywhere you have been.
    pub fn record_reading_progress(
        &self,
        catalog: FfiCatalog,
        catalog_id: i64,
        chapter_id: String,
        chapter_number: String,
        page: i64,
        page_count: i64,
    ) -> FfiResult<()> {
        self.registry
            .record_reading_progress(
                catalog.into(),
                catalog_id,
                &chapter_id,
                &chapter_number,
                page,
                page_count,
            )
            .map_err(|msg| AnicatError::Storage { msg })
    }

    /// The page a chapter was left on. `None` for one never opened.
    pub fn reading_progress(
        &self,
        catalog: FfiCatalog,
        catalog_id: i64,
        chapter_id: String,
    ) -> FfiResult<Option<FfiReadingProgress>> {
        let row = self
            .registry
            .reading_progress(catalog.into(), catalog_id, &chapter_id)
            .map_err(|msg| AnicatError::Storage { msg })?;
        Ok(row.map(|(page, page_count)| FfiReadingProgress { page, page_count }))
    }

    /// Chapters read, newest first -- the reading counterpart of
    /// `watch_activity`, and like it, needing no token: the registry
    /// recorded it.
    pub fn reading_activity(&self, limit: i32) -> FfiResult<Vec<FfiReadingRow>> {
        let rows = self
            .registry
            .recent_reading(limit.max(1) as i64)
            .map_err(|msg| AnicatError::Storage { msg })?;
        Ok(rows
            .into_iter()
            .map(|r| FfiReadingRow {
                catalog: r.catalog.into(),
                catalog_id: r.catalog_id,
                chapter_id: r.chapter_id,
                chapter_number: r.chapter_number,
                page: r.page,
                page_count: r.page_count,
                read_at: r.read_at,
            })
            .collect())
    }

    /// Puts a film or series on the local list, or takes it off.
    ///
    /// Local because there is nowhere else: AniList has no entry for a TMDB
    /// title, and cinema tracking is deliberately this device's registry and
    /// nothing external. `status` is `PLANNING`, `CURRENT`, `COMPLETED` or
    /// `DROPPED`, matching what the anime side's list statuses are called so
    /// one set of labels serves both.
    pub fn set_cinema_list_status(
        &self,
        catalog: FfiCatalog,
        catalog_id: i64,
        status: Option<String>,
    ) -> FfiResult<()> {
        self.registry
            .set_local_status(catalog.into(), catalog_id, status.as_deref())
            .map_err(|msg| AnicatError::Storage { msg })
    }

    pub fn cinema_list_status(
        &self,
        catalog: FfiCatalog,
        catalog_id: i64,
    ) -> FfiResult<Option<String>> {
        self.registry
            .local_status(catalog.into(), catalog_id)
            .map_err(|msg| AnicatError::Storage { msg })
    }

    /// The local list, newest first. `status` narrows it; the rows carry no
    /// titles because the registry has never known any -- the caller names
    /// them from its own snapshots.
    pub fn cinema_list(&self, status: Option<String>) -> FfiResult<Vec<FfiLocalEntry>> {
        let rows = self
            .registry
            .local_library(
                &[Catalog::TmdbMovie, Catalog::TmdbTv],
                status.as_deref(),
            )
            .map_err(|msg| AnicatError::Storage { msg })?;
        Ok(rows
            .into_iter()
            .map(|(catalog, catalog_id, status)| FfiLocalEntry {
                catalog: catalog.into(),
                catalog_id,
                status,
            })
            .collect())
    }

    /// The cast, top-billed first. Answered from the same cached TMDB detail
    /// the page already loaded, so this is a second call and not a second
    /// request.
    ///
    /// `id` is TMDB's person id, which is not AniList's character id and
    /// opens no page here -- the client shows these as faces and names only.
    pub async fn cinema_cast(
        &self,
        catalog: FfiCatalog,
        catalog_id: i64,
    ) -> FfiResult<Vec<FfiCharacter>> {
        let is_series = catalog == FfiCatalog::TmdbTv;
        let detail = self
            .catalogs
            .cinema_detail(catalog_id, is_series)
            .await
            .map_err(|msg| AnicatError::Network { msg })?;
        let credits = detail
            .movie
            .as_ref()
            .and_then(|m| m.credits.as_ref())
            .or_else(|| detail.series.as_ref().and_then(|s| s.credits.as_ref()));
        let mut cast: Vec<_> = credits
            .and_then(|c| c.cast.as_ref())
            .map(|rows| rows.iter().collect())
            .unwrap_or_default();
        cast.sort_by_key(|m| m.order.unwrap_or(i64::MAX));
        Ok(cast
            .into_iter()
            .take(30)
            .map(|m| FfiCharacter {
                id: m.id.unwrap_or_default(),
                name: m.name.clone().unwrap_or_default(),
                role: m.character.clone().unwrap_or_default(),
                image_url: m.photo_url(),
                voice_actor_name: None,
                voice_actor_image_url: None,
            })
            .collect())
    }

    /// One member of the cast, with their credits.
    ///
    /// TMDB person ids are TMDB's own -- they are not AniList character ids,
    /// and this is the page that makes a cast portrait worth pressing.
    pub async fn cinema_person(&self, person_id: i64) -> FfiResult<CinemaPerson> {
        let person = self
            .catalogs
            .cinema_person(person_id)
            .await
            .map_err(|msg| AnicatError::Network { msg })?;

        let mut credits: Vec<_> = person
            .combined_credits
            .as_ref()
            .and_then(|c| c.cast.as_ref())
            .map(|rows| rows.iter().collect())
            .unwrap_or_default();
        // Best known first: TMDB returns these in no useful order, and a
        // filmography that opens on a walk-on part reads as the wrong person.
        credits.sort_by(|a, b| {
            b.popularity
                .unwrap_or(0.0)
                .partial_cmp(&a.popularity.unwrap_or(0.0))
                .unwrap_or(std::cmp::Ordering::Equal)
        });

        // Talk-show and awards-show appearances, where the credit is the
        // person themselves. TMDB files them as ordinary cast credits, so a
        // filmography led by popularity opens on The Tonight Show rather
        // than on anything they acted in. Dropped unless that leaves
        // nothing -- a presenter whose whole career is credited "Self" gets
        // their real list back rather than an empty page.
        let acted: Vec<_> = credits.iter().filter(|c| !is_self_credit(c.character.as_deref())).copied().collect();
        let credits = if acted.is_empty() { credits } else { acted };

        Ok(CinemaPerson {
            id: person.id,
            name: person.name.clone().unwrap_or_default(),
            biography: person.biography.clone().filter(|b| !b.trim().is_empty()),
            photo_url: person.photo_url(),
            birthday: person.birthday.clone(),
            deathday: person.deathday.clone(),
            place_of_birth: person.place_of_birth.clone(),
            known_for: person.known_for_department.clone(),
            credits: credits
                .into_iter()
                // Anything that is neither a film nor a series -- TMDB files
                // some credits with no media_type at all -- has no page here
                // to open, so it is not offered.
                .filter_map(|c| {
                    let catalog = match c.media_type.as_deref()? {
                        "movie" => FfiCatalog::TmdbMovie,
                        "tv" => FfiCatalog::TmdbTv,
                        _ => return None,
                    };
                    Some(CinemaCredit {
                        catalog,
                        catalog_id: c.id,
                        title: c.display_title()?,
                        character: c.character.clone().filter(|s| !s.is_empty()),
                        cover_image: c.poster_url(),
                        year: c.year(),
                    })
                })
                .take(40)
                .collect(),
            imdb_url: person
                .external_ids
                .as_ref()
                .and_then(|e| e.imdb_id.clone())
                .filter(|id| !id.is_empty())
                .map(|id| format!("https://www.imdb.com/name/{id}/")),
        })
    }

    /// The facts a cinema page shows that `MediaDetail` has no field for.
    pub async fn cinema_extras(
        &self,
        catalog: FfiCatalog,
        catalog_id: i64,
    ) -> FfiResult<CinemaExtras> {
        let is_series = catalog == FfiCatalog::TmdbTv;
        let detail = self
            .catalogs
            .cinema_detail(catalog_id, is_series)
            .await
            .map_err(|msg| AnicatError::Network { msg })?;

        // TMDB reports 0 for a budget or a gross it has no figure for, which
        // is a different claim from "cost nothing" and must not be rendered
        // as one.
        let money = |v: Option<i64>| v.filter(|n| *n > 0);
        if let Some(m) = &detail.movie {
            return Ok(CinemaExtras {
                tagline: m.tagline.clone().filter(|t| !t.is_empty()),
                original_language: m.original_language.clone(),
                release_date: m.release_date.clone(),
                last_air_date: None,
                runtime_minutes: m.runtime,
                budget: money(m.budget),
                revenue: money(m.revenue),
                season_count: None,
                episode_count: None,
                last_aired_episode: None,
                next_air_date: None,
                companies: m
                    .production_companies
                    .iter()
                    .flatten()
                    .filter_map(|c| c.name.clone())
                    .collect(),
                gallery: crate::catalog::tmdb::types::gallery_urls(m.images.as_ref()),
                homepage: m.homepage.clone().filter(|h| !h.is_empty()),
                imdb_url: m
                    .external_ids
                    .as_ref()
                    .and_then(|e| e.imdb_id.clone())
                    .filter(|id| !id.is_empty())
                    .map(|id| format!("https://www.imdb.com/title/{id}/")),
                seasons: vec![],
            });
        }
        let s = detail.series.ok_or_else(|| AnicatError::NotFound {
            msg: format!("TMDB has no {catalog:?} {catalog_id}"),
        })?;
        Ok(CinemaExtras {
            tagline: s.tagline.clone().filter(|t| !t.is_empty()),
            original_language: s.original_language.clone(),
            release_date: s.first_air_date.clone(),
            last_air_date: s.last_air_date.clone(),
            runtime_minutes: s.episode_run_time.as_ref().and_then(|r| r.first().copied()),
            budget: None,
            revenue: None,
            season_count: s.number_of_seasons,
            episode_count: s.number_of_episodes,
            // Converted out of (season, episode) into the absolute number the
            // registry, the resume position and the remembered release all
            // key on, so a caller can compare it against progress without
            // knowing the season map.
            last_aired_episode: s.last_episode_to_air.as_ref().and_then(|ep| {
                let season = ep.season_number?;
                let number = ep.episode_number?;
                let mut absolute = 0;
                for (map_season, count) in s.season_map() {
                    if map_season == season {
                        return Some((absolute + number) as i32);
                    }
                    absolute += count;
                }
                None
            }),
            next_air_date: s.next_episode_to_air.as_ref().and_then(|ep| ep.air_date.clone()),
            companies: s.networks.iter().flatten().filter_map(|c| c.name.clone()).collect(),
            gallery: crate::catalog::tmdb::types::gallery_urls(s.images.as_ref()),
            homepage: s.homepage.clone().filter(|h| !h.is_empty()),
            imdb_url: s
                .external_ids
                .as_ref()
                .and_then(|e| e.imdb_id.clone())
                .filter(|id| !id.is_empty())
                .map(|id| format!("https://www.imdb.com/title/{id}/")),
            seasons: s
                .season_map()
                .into_iter()
                .map(|(number, count)| CinemaSeason {
                    number: number as i32,
                    episode_count: count as i32,
                })
                .collect(),
        })
    }

    /// One film or series, in the same `MediaDetail` the anime path answers
    /// with -- so the detail page, its caches and the player read one shape
    /// whichever catalog the title came from.
    pub async fn cinema_detail(
        &self,
        catalog: FfiCatalog,
        catalog_id: i64,
    ) -> FfiResult<MediaDetail> {
        self.cinema_media_detail(catalog, catalog_id).await
    }

    /// Every release the indexers found for one episode, best first — the
    /// "Stream Servers" picker's list. A separate call from `resolve_stream`
    /// rather than a byproduct of it: the auto-pick only races the top two
    /// and keeps two more as fallbacks (see `torrent/search.rs`'s header
    /// comment), so it never even looks at most of what a full search turns
    /// up, and doesn't need to — the picker is the one place that does.
    pub async fn list_release_candidates(
        &self,
        catalog: FfiCatalog,
        catalog_id: i64,
        episode: i64,
        title: Option<String>,
    ) -> FfiResult<Vec<FfiTorrentChoice>> {
        let media = MediaKey::new(catalog.into(), catalog_id);
        // The picker searches on the same terms the auto-pick does, or the
        // list it shows is not the list the play would have chosen from.
        let cinema = if catalog == FfiCatalog::Anilist {
            None
        } else {
            Some(self.cinema_search_inputs(catalog, catalog_id, episode, title.clone()).await?)
        };
        let info = crate::torrent::gather_media_info(&self.registry, &self.catalogs, media, title).await;
        if cinema.is_none() && info.titles.is_empty() {
            return Err(AnicatError::NotFound {
                msg: format!("no search titles for {media}"),
            });
        }

        let preview_dub = false;
        let choices = self
            .torrents
            .list_candidates(
                &self.http,
                ResolveTarget {
                    media,
                    episode,
                    titles: match &cinema {
                        Some(c) => &c.titles,
                        None => &info.titles,
                    },
                    allow_episodeless: match &cinema {
                        Some(c) => !c.is_series,
                        None => info.hint.kind == layout::EntryKind::Movie,
                    },
                    episode_count: cinema
                        .as_ref()
                        .map(|c| Some(c.episode_count))
                        .unwrap_or(info.episode_count),
                    aired_episodes: cinema
                        .as_ref()
                        .map(|c| Some(c.episode_count))
                        .unwrap_or(info.aired_episodes),
                    // The picker shows every release regardless of dub
                    // preference — that choice belongs to whoever is
                    // picking, not to the same default the auto-pick uses.
                    prefer_dub: preview_dub,
                    browser_client: false,
                    chosen_name: None,
                    movie: cinema.as_ref().and_then(|c| c.movie_criteria),
                    series: cinema.as_ref().and_then(|c| c.series_criteria),
                    entry: match &cinema {
                        Some(c) if !c.is_series => layout::EntryHint {
                            kind: layout::EntryKind::Movie,
                            ..Default::default()
                        },
                        Some(_) => layout::EntryHint::default(),
                        None => info.hint,
                    },
                    sibling_titles: if cinema.is_some() { &[] } else { &info.siblings },
                    resume_fraction: None,
                    remembered: None,
                },
            )
            .await;

        Ok(choices
            .into_iter()
            .map(|c| FfiTorrentChoice {
                name: c.name,
                seeders: c.seeders,
                is_dub: c.is_dub,
            })
            .collect())
    }

    /// Starts downloading one episode to the user's Downloads folder,
    /// resolving it exactly like a play would (same candidate search, same
    /// release). Returns once the download has *started*, not once it's
    /// done — poll `episode_download_status` for progress. Calling this
    /// again for the same episode while a download is already running or
    /// finished is a no-op on the core side (`spawn_episode_download`
    /// dedupes on `(torrent_id, file_id)`), so a second tap of the button
    /// before the first status poll lands doesn't start a second copy.
    pub async fn start_episode_download(
        &self,
        catalog: FfiCatalog,
        catalog_id: i64,
        episode: i64,
        title: Option<String>,
        prefer_dub: bool,
    ) -> FfiResult<()> {
        let media = MediaKey::new(catalog.into(), catalog_id);
        // A cinema download searches on exactly what a cinema play searches
        // on -- same titles, same year or SxxEyy. They resolve into the same
        // reuse cache keyed on the episode, so a download that searched
        // differently would fetch a second, different release of the file
        // already on disk.
        let cinema = if catalog == FfiCatalog::Anilist {
            None
        } else {
            Some(self.cinema_search_inputs(catalog, catalog_id, episode, title.clone()).await?)
        };
        let info = crate::torrent::gather_media_info(&self.registry, &self.catalogs, media, title.clone()).await;
        if cinema.is_none() && info.titles.is_empty() {
            return Err(AnicatError::NotFound {
                msg: format!("no search titles for {media}"),
            });
        }
        // The proxy port is irrelevant to a download (nothing streams it
        // over HTTP), but `resolve` builds its return value from it
        // regardless — cheaper to hand it a real one than to special-case a
        // download-only resolve path.
        let port = self.ensure_stream_server().await?;
        self.torrents
            .resolve(
                &self.http,
                ResolveTarget {
                    media,
                    episode,
                    titles: match &cinema {
                        Some(c) => &c.titles,
                        None => &info.titles,
                    },
                    allow_episodeless: match &cinema {
                        Some(c) => !c.is_series,
                        None => info.hint.kind == layout::EntryKind::Movie,
                    },
                    episode_count: cinema
                        .as_ref()
                        .map(|c| Some(c.episode_count))
                        .unwrap_or(info.episode_count),
                    aired_episodes: cinema
                        .as_ref()
                        .map(|c| Some(c.episode_count))
                        .unwrap_or(info.aired_episodes),
                    prefer_dub,
                    browser_client: false,
                    chosen_name: None,
                    movie: cinema.as_ref().and_then(|c| c.movie_criteria),
                    series: cinema.as_ref().and_then(|c| c.series_criteria),
                    entry: match &cinema {
                        Some(c) if !c.is_series => layout::EntryHint {
                            kind: layout::EntryKind::Movie,
                            ..Default::default()
                        },
                        Some(_) => layout::EntryHint::default(),
                        None => info.hint,
                    },
                    sibling_titles: if cinema.is_some() { &[] } else { &info.siblings },
                    resume_fraction: None,
                    remembered: None,
                },
                port,
            )
            .await
            .map_err(|msg| AnicatError::NotFound { msg })?;

        let (torrent_id, file_id) = self
            .torrents
            .resolved_ids(media, episode)
            .await
            .ok_or_else(|| AnicatError::Internal {
                msg: "resolve returned nothing to download".into(),
            })?;

        let session = self.torrents.session().await.map_err(|msg| AnicatError::Internal { msg })?;
        let display_title = title.unwrap_or_else(|| match &cinema {
            Some(c) => c.titles[0].clone(),
            None => info.titles[0].clone(),
        });
        self.torrents
            .spawn_episode_download(&session, torrent_id, file_id, display_title.clone());
        // Watched here as well as by whatever UI is open: the engine's own
        // download map is session-only, and the copy it leaves in the
        // Downloads folder outlives every process. Without a row written when
        // it finishes, the app forgets on the next launch that it has the
        // episode -- and re-fetches a file already on the disk.
        self.watch_download(catalog, catalog_id, episode, display_title);
        Ok(())
    }

    /// Progress of a download started with `start_episode_download`, or
    /// `NotStarted` if this episode was never resolved at all (before any
    /// play or download attempt) — a caller can't tell that case apart from
    /// "resolved but no download running" without an extra round trip, but
    /// the episode row only ever polls this after it has already shown a
    /// download in progress, so the distinction doesn't reach the UI.
    pub async fn episode_download_status(
        &self,
        catalog: FfiCatalog,
        catalog_id: i64,
        episode: i64,
    ) -> FfiDownloadStatus {
        // Every catalog: films and series download through the same path
        // now, and answering NotStarted for them left their rows spinning.
        let media = MediaKey::new(catalog.into(), catalog_id);
        let Some((torrent_id, file_id)) = self.torrents.resolved_ids(media, episode).await else {
            return FfiDownloadStatus::NotStarted;
        };
        self.torrents.download_status(torrent_id, file_id).await.into()
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

    /// Filtered discovery for the home page's configurable rows: a release
    /// `status` ("Newly Releasing" wants `RELEASING`) or a `season`/
    /// `season_year` pair ("Seasonal Highlights"). Leave both unset for a
    /// plain popularity-sorted row.
    pub async fn discover(
        &self,
        media_type: String,
        status: Option<String>,
        season: Option<String>,
        season_year: Option<i32>,
        limit: i32,
    ) -> FfiResult<Vec<MediaSummary>> {
        let items = self
            .catalogs
            .discover(&media_type, status.as_deref(), season.as_deref(), season_year, limit.max(1) as i64)
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
        let favourite_anime = v
            .favourites
            .as_ref()
            .and_then(|f| f.anime.as_ref())
            .and_then(|c| c.nodes.as_ref())
            .map(|nodes| nodes.iter().map(summarize).collect())
            .unwrap_or_default();
        let favourite_manga = v
            .favourites
            .as_ref()
            .and_then(|f| f.manga.as_ref())
            .and_then(|c| c.nodes.as_ref())
            .map(|nodes| nodes.iter().map(summarize).collect())
            .unwrap_or_default();
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
            favourite_anime,
            favourite_manga,
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

    /// One title, with its episode list and this device's progress folded in.
    pub async fn media_detail(&self, catalog_id: i64, is_manga: bool) -> FfiResult<MediaDetail> {
        // AniZip only needs `catalog_id`, not anything from the AniList
        // response, so it doesn't have to wait for AniList to answer first —
        // running them together instead of one-after-the-other cuts a
        // detail-page open down to whichever of the two is slower, not their
        // sum. A manga entry has no episodes to enrich, so it skips straight
        // to an empty map rather than spending a request on AniZip's 404.
        let anizip_fut = async {
            if is_manga {
                std::collections::HashMap::new()
            } else {
                self.anizip_meta(catalog_id).await
            }
        };
        let (detail_res, anizip) = tokio::join!(self.catalogs.media_detail(catalog_id, is_manga), anizip_fut);
        let res = detail_res.map_err(|msg| AnicatError::Network { msg })?;
        let m = res.media.ok_or_else(|| AnicatError::NotFound {
            msg: format!("AniList has no media {catalog_id}"),
        })?;

        let history = self
            .registry
            .history_for(Catalog::Anilist, catalog_id)
            .unwrap_or_default();

        let episode_count = m.episodes.unwrap_or(0);
        let streaming = m.streaming_episodes.clone().unwrap_or_default();
        // AniList's own progress on this title's list entry. The local
        // watch-history registry is per-device — a fresh install (or a
        // second Mac) has none of it even for a title watched to episode 10
        // elsewhere, and every episode read back as unwatched with the
        // primary button offering "Start Episode 1". `is_watched` below
        // treats an episode as watched when EITHER source says so, so the
        // device that actually played it keeps its precise resume-seconds
        // behavior while every other device still opens on the right
        // episode.
        let list_progress = m.media_list_entry.as_ref().and_then(|e| e.progress);

        // AniList streaming_episodes often lists episodes in reverse order (e.g. Ep 12 down to 1).
        // Map each streaming episode by parsing the episode number from its title:
        // "Episode 12 - First Love with Him" -> 12.
        let mut stream_by_num: std::collections::HashMap<i32, &crate::catalog::anilist::types::StreamingEpisode> = std::collections::HashMap::new();
        for s in &streaming {
            if let Some(ref title) = s.title {
                let lower = title.to_lowercase();
                let num_opt = if let Some(rest) = lower.strip_prefix("episode ") {
                    rest.chars().take_while(|c| c.is_ascii_digit()).collect::<String>().parse::<i32>().ok()
                } else if let Some(rest) = lower.strip_prefix("ep ") {
                    rest.chars().take_while(|c| c.is_ascii_digit()).collect::<String>().parse::<i32>().ok()
                } else if let Some(rest) = lower.strip_prefix("ep. ") {
                    rest.chars().take_while(|c| c.is_ascii_digit()).collect::<String>().parse::<i32>().ok()
                } else {
                    None
                };
                if let Some(num) = num_opt {
                    stream_by_num.insert(num, s);
                }
            }
        }

        let mut episodes = Vec::new();
        for number in 1..=episode_count {
            let entry = history.iter().find(|e| e.episode_number == number as i64);
            // 85% is the same threshold the player uses to advance AniList
            // progress, so "watched" means the same thing in both places.
            let percent = entry
                .filter(|e| e.duration > 0)
                .map(|e| (e.stop_time as f64 / e.duration as f64) * 100.0)
                .unwrap_or(0.0);
            let locally_completed = entry.is_some_and(|e| e.completed);

            // Match by parsed episode number, or fallback to positional index
            let from_stream = stream_by_num.get(&number).copied().or_else(|| {
                streaming.get((number - 1) as usize)
            });

            let az = anizip.get(&number);

            let raw_title = from_stream
                .and_then(|s| s.title.clone())
                .filter(|t| !t.trim().is_empty())
                .unwrap_or_else(|| format!("Episode {number}"));

            // Strip "Episode X - " or "Episode X: " prefix so title is clean
            let clean_title = {
                let t = raw_title.trim();
                let p1 = format!("Episode {} - ", number);
                let p2 = format!("Episode {}: ", number);
                let p3 = format!("Episode {}. ", number);
                if let Some(c) = t.strip_prefix(&p1) {
                    c.trim().to_string()
                } else if let Some(c) = t.strip_prefix(&p2) {
                    c.trim().to_string()
                } else if let Some(c) = t.strip_prefix(&p3) {
                    c.trim().to_string()
                } else {
                    t.to_string()
                }
            };

            // AniZip is keyed by episode number and carries real titles and
            // stills; AniList's streamingEpisodes is a positional array
            // scraped from streaming sites that drifts on shows with
            // specials or numbering gaps. AniZip wins wherever it has an
            // answer for this number.
            let title = az.and_then(|a| a.title.clone()).unwrap_or(clean_title);
            let thumbnail = az
                .and_then(|a| a.thumbnail.clone())
                .or_else(|| from_stream.and_then(|s| s.thumbnail.clone()));
            let runtime_minutes = az.and_then(|a| a.runtime_minutes).or(m.duration);

            episodes.push(EpisodeRow {
                number,
                title,
                thumbnail,
                is_watched: episode_is_watched(number, percent, locally_completed, list_progress),
                progress_percent: percent,
                runtime_minutes,
                synopsis: az.and_then(|a| a.overview.clone()),
                air_date: az.and_then(|a| a.air_date.clone()),
            });
        }

        let resume = resume_episode(&history, list_progress);

        // AniList leaves `idMal` null on a newly added entry for weeks, and
        // AniSkip is keyed by MAL id — so the intro/outro skip went missing
        // for precisely the shows being watched as they air. The guard is
        // what keeps this free: a title that already has the mapping never
        // touches Jikan, and neither does any manga. It cannot join the
        // AniZip `join!` above because it needs the titles and year AniList
        // has just answered with.
        let mal_id = match m.id_mal {
            Some(id) => Some(id),
            None if is_manga => None,
            None => self.jikan_mal_id(catalog_id, &m).await,
        };

        let (prequel, sequel) = relations(&m);

        let mut relations_list = Vec::new();
        if let Some(edges) = m.relations.as_ref().and_then(|r| r.edges.as_ref()) {
            for edge in edges {
                if let Some(ref node) = edge.node {
                    let rel_type = edge.relation_type.clone().unwrap_or_else(|| "RELATED".to_string());
                    let title = node
                        .title
                        .as_ref()
                        .and_then(|t| t.english.clone().or_else(|| t.romaji.clone()))
                        .unwrap_or_default();
                    let cover = node
                        .cover_image
                        .as_ref()
                        .and_then(|c| c.large.clone().or_else(|| c.medium.clone()))
                        .unwrap_or_default();
                    relations_list.push(FfiRelation {
                        catalog_id: node.id,
                        relation_type: rel_type,
                        title,
                        format: node.format.clone(),
                        cover_image: cover,
                        status: node.status.clone(),
                        average_score: node.average_score,
                    });
                }
            }
        }

        let mut recommendations_list = Vec::new();
        if let Some(nodes) = m.recommendations.as_ref().and_then(|r| r.nodes.as_ref()) {
            for node in nodes {
                if let Some(ref rec) = node.media_recommendation {
                    let title = rec
                        .title
                        .as_ref()
                        .and_then(|t| t.english.clone().or_else(|| t.romaji.clone()))
                        .unwrap_or_default();
                    let cover = rec
                        .cover_image
                        .as_ref()
                        .and_then(|c| c.large.clone().or_else(|| c.medium.clone()))
                        .unwrap_or_default();
                    recommendations_list.push(FfiRecommendation {
                        catalog_id: rec.id,
                        title,
                        format: rec.format.clone(),
                        cover_image: cover,
                        average_score: rec.average_score,
                        rating: node.rating,
                    });
                }
            }
        }

        Ok(MediaDetail {
            catalog_id,
            mal_id,
            title: m
                .title
                .as_ref()
                .and_then(|t| t.english.clone().or_else(|| t.romaji.clone()))
                .unwrap_or_default(),
            romaji_title: m.title.as_ref().and_then(|t| t.romaji.clone()),
            cover_image: m
                .cover_image
                .as_ref()
                .and_then(|c| c.large.clone().or_else(|| c.medium.clone()))
                .unwrap_or_default(),
            banner_image: m.banner_image.clone(),
            format: m.format.clone(),
            status: m.status.clone(),
            year: m.season_year.or_else(|| m.start_date.as_ref().and_then(|d| d.year)),
            studio: m
                .studios
                .as_ref()
                .and_then(|s| s.nodes.as_ref())
                .and_then(|n| n.first())
                .and_then(|s| s.name.clone()),
            studios: studio_refs(&m),
            trailer_site: m.trailer.as_ref().and_then(|t| t.site.clone()),
            trailer_id: m.trailer.as_ref().and_then(|t| t.id.clone()),
            trailer_thumbnail: m.trailer.as_ref().and_then(|t| t.thumbnail.clone()),
            synopsis: m.description.as_ref().map(|d| strip_html(d)),
            genres: m.genres.clone().unwrap_or_default(),
            average_score: m.average_score,
            episode_count: m.episodes,
            chapter_count: m.chapters,
            duration_minutes: m.duration,
            resume_episode: resume.map(|e| e.episode_number as i32),
            resume_seconds: resume.map(|e| e.stop_time as i32),
            prequel,
            sequel,
            relations: relations_list,
            recommendations: recommendations_list,
            episodes,
            list_status: m.media_list_entry.as_ref().and_then(|e| e.status.clone()),
            user_score: m.media_list_entry.as_ref().and_then(|e| e.score),
            list_entry_id: m.media_list_entry.as_ref().and_then(|e| e.id),
            list_progress: m.media_list_entry.as_ref().and_then(|e| e.progress),
            is_favourite: m.is_favourite.unwrap_or(false),
        })
    }

    /// Creates/updates the signed-in user's list entry for a title — status
    /// change, score edit, or a manual progress bump (mark-watched). Each
    /// argument is independent; pass `None` to leave that field alone.
    pub async fn update_list_entry(
        &self,
        catalog_id: i64,
        status: Option<String>,
        score: Option<f64>,
        progress: Option<i64>,
    ) -> FfiResult<()> {
        self.catalogs
            .save_media_list_entry(catalog_id, status.as_deref(), score, progress)
            .await
            .map_err(|msg| AnicatError::Network { msg })
    }

    /// Toggles the AniList favourite heart for a title. `currently_favourite`
    /// is what the page shows; the return value is what AniList holds after
    /// the toggle (see `Catalogs::toggle_favourite`).
    pub async fn toggle_favourite(
        &self,
        catalog_id: i64,
        is_manga: bool,
        currently_favourite: bool,
    ) -> FfiResult<bool> {
        self.catalogs
            .toggle_favourite(catalog_id, is_manga, currently_favourite)
            .await
            .map_err(|msg| AnicatError::Network { msg })
    }

    /// Removes a title from the signed-in user's list. Takes
    /// `MediaDetail::list_entry_id`, not the catalog id.
    pub async fn remove_from_list(&self, list_entry_id: i64) -> FfiResult<()> {
        self.catalogs
            .delete_media_list_entry(list_entry_id)
            .await
            .map_err(|msg| AnicatError::Network { msg })
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
                matches_anilist: m.matches_anilist,
            })
            .collect())
    }

    pub async fn get_manga_chapters(&self, manga_id: String) -> FfiResult<Vec<MangaChapter>> {
        let detail = if is_mangakatana_id(&manga_id) {
            self.mangakatana.detail(&manga_id).await
        } else {
            self.mangadex.detail(&manga_id).await
        }
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
        if is_mangakatana_id(&chapter_id) {
            self.mangakatana.chapter_pages(&chapter_id).await
        } else {
            self.mangadex.chapter_pages(&chapter_id).await
        }
        .map_err(|msg| AnicatError::Network { msg })
    }

    /// Fallback search against MangaKatana, tried only after MangaDex has
    /// confirmed the AniList match but come up with no readable chapters —
    /// see `reader::mangakatana`'s module comment for why. MangaKatana has
    /// no AniList cross-reference, so every result comes back with
    /// `matches_anilist: false`.
    pub async fn search_manga_katana(&self, query: String) -> FfiResult<Vec<MangaSummary>> {
        let out = self
            .mangakatana
            .search(&query)
            .await
            .map_err(|msg| AnicatError::Network { msg })?;
        Ok(out
            .into_iter()
            .map(|m| MangaSummary {
                id: m.id,
                title: m.title,
                cover_image: m.cover_image,
                matches_anilist: m.matches_anilist,
            })
            .collect())
    }

    /// A Syosetu novel's title, author, synopsis and full table of contents,
    /// from a `ncode.syosetu.com/nXXXXXX/` URL pasted in by the viewer — see
    /// `reader::syosetu`'s module comment for why this takes a URL directly
    /// rather than an AniList/RanobeDB id.
    pub async fn novel_info(&self, url: String) -> FfiResult<NovelInfo> {
        if !SyosetuClient::can_handle(&url) {
            return Err(AnicatError::NotFound { msg: format!("not a syosetu.com URL: {url}") });
        }
        self.syosetu
            .novel_info(&url)
            .await
            .map(Into::into)
            .map_err(|msg| AnicatError::Network { msg })
    }

    /// One chapter's text, from a URL out of `novel_info`'s chapter list.
    pub async fn novel_chapter(&self, url: String) -> FfiResult<NovelChapterContent> {
        if !SyosetuClient::can_handle(&url) {
            return Err(AnicatError::NotFound { msg: format!("not a syosetu.com URL: {url}") });
        }
        self.syosetu
            .chapter_content(&url)
            .await
            .map(Into::into)
            .map_err(|msg| AnicatError::Network { msg })
    }

    /// Connects to the local Discord client over IPC, if one is running.
    /// Silently a no-op when Discord isn't installed or open — this is a
    /// presence nicety, never something playback should fail over.
    pub fn discord_connect(&self) {
        self.discord.connect();
    }

    pub fn discord_disconnect(&self) {
        self.discord.disconnect();
    }

    /// `episode_title` empty means "show Episode N instead"; `duration <= 0`
    /// means unknown, which drops the "time remaining" countdown entirely
    /// rather than showing a nonsensical one.
    #[allow(clippy::too_many_arguments)]
    pub fn discord_set_presence(
        &self,
        title: String,
        episode: i64,
        episode_title: String,
        total_episodes: i64,
        pos: i64,
        duration: i64,
        paused: bool,
    ) {
        self.discord.set_presence(&title, episode, &episode_title, total_episodes, pos, duration, paused);
    }

    pub fn discord_clear_presence(&self) {
        self.discord.clear_presence();
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

    /// Forgets the local watch record for `episode_number` and everything
    /// after it. The episode list's un-check calls this alongside the AniList
    /// write; see `Registry::clear_progress_from` for why the AniList write
    /// alone could not make an un-check stick.
    pub fn clear_progress_from(
        &self,
        catalog: FfiCatalog,
        catalog_id: i64,
        episode_number: i64,
    ) -> FfiResult<()> {
        self.registry
            .clear_progress_from(catalog.into(), catalog_id, episode_number)
            .map_err(|msg| AnicatError::Storage { msg })
    }

    /// Wipes resume positions, provider overrides, the offline list mirror,
    /// and per-show prefs. Settings' "Clear Local Registry" action.
    /// Empties the watch log without touching resume positions, remembered
    /// releases or track picks -- what the History page's "Clear history"
    /// means, as against Settings' wipe.
    pub fn clear_watch_history(&self) -> FfiResult<()> {
        self.registry.clear_watch_history().map_err(|msg| AnicatError::Storage { msg })
    }

    /// Forgets one watch, for the History row's own context menu.
    pub fn remove_watch(
        &self,
        catalog: FfiCatalog,
        catalog_id: i64,
        episode_number: i64,
    ) -> FfiResult<()> {
        self.registry
            .remove_watch(catalog.into(), catalog_id, episode_number)
            .map_err(|msg| AnicatError::Storage { msg })
    }

    pub fn clear_local_registry(&self) -> FfiResult<()> {
        self.registry.clear_all().map_err(|msg| AnicatError::Storage { msg })
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

    /// Fetches the cast and staff for an AniList media id.
    pub async fn media_characters(&self, catalog_id: i64) -> FfiResult<Vec<FfiCharacter>> {
        let edges = self
            .catalogs
            .media_characters(catalog_id)
            .await
            .map_err(|msg| AnicatError::Network { msg })?;
        Ok(edges
            .into_iter()
            .filter_map(|e| {
                let node = e.node?;
                let va = e.voice_actors.as_ref().and_then(|vas| {
                    vas.iter().find(|v| v.language.as_deref() == Some("JAPANESE"))
                        .or_else(|| vas.first())
                });
                Some(FfiCharacter {
                    id: node.id,
                    name: node.name.and_then(|n| n.full.or(n.native)).unwrap_or_default(),
                    role: e.role.unwrap_or_else(|| "MAIN".to_string()),
                    image_url: node.image.and_then(|i| i.large.or(i.medium)),
                    voice_actor_name: va.and_then(|v| v.name.as_ref().and_then(|n| n.full.clone())),
                    voice_actor_image_url: va.and_then(|v| v.image.as_ref().and_then(|i| i.large.clone().or_else(|| i.medium.clone()))),
                })
            })
            .collect())
    }

    /// Fetches community discussions for an AniList media id.
    pub async fn media_discussions(&self, catalog_id: i64) -> FfiResult<Vec<FfiDiscussion>> {
        let threads = self
            .catalogs
            .media_discussions(catalog_id)
            .await
            .map_err(|msg| AnicatError::Network { msg })?;
        Ok(threads
            .into_iter()
            .map(|t| FfiDiscussion {
                id: t.id,
                title: t.title,
                reply_count: t.reply_count.unwrap_or(0),
                view_count: t.view_count.unwrap_or(0),
                author_name: t.user.as_ref().and_then(|u| u.name.clone()),
                author_avatar_url: t.user.as_ref().and_then(|u| u.avatar.as_ref().and_then(|a| a.large.clone().or_else(|| a.medium.clone()))),
                replied_at: t.replied_at.or(t.created_at),
            })
            .collect())
    }

    /// One character's own page, for the rows a cast list links to.
    pub async fn character_detail(&self, character_id: i64) -> FfiResult<FfiCharacterDetail> {
        let c = self
            .catalogs
            .character_detail(character_id)
            .await
            .map_err(|msg| AnicatError::Network { msg })?;
        let name = c.name.clone();
        let dob = c.date_of_birth.clone();
        Ok(FfiCharacterDetail {
            id: c.id,
            name: name
                .as_ref()
                .and_then(|n| n.full.clone().or_else(|| n.native.clone()))
                .unwrap_or_default(),
            native_name: name.as_ref().and_then(|n| n.native.clone()),
            alternative_names: name
                .as_ref()
                .and_then(|n| n.alternative.clone())
                .unwrap_or_default(),
            image_url: c.image.as_ref().and_then(|i| i.large.clone().or_else(|| i.medium.clone())),
            description: c.description.clone(),
            gender: c.gender.clone(),
            age: c.age.clone(),
            birth_year: dob.as_ref().and_then(|d| d.year),
            birth_month: dob.as_ref().and_then(|d| d.month),
            birth_day: dob.as_ref().and_then(|d| d.day),
            favourites: c.favourites.unwrap_or(0) as i32,
            appearances: media_edges(c.media.as_ref())
                .filter_map(|edge| {
                    let node = edge.node.as_ref()?;
                    Some(FfiCharacterAppearance {
                        catalog_id: node.id,
                        media_type: node.media_type.clone(),
                        format: node.format.clone(),
                        title: edge_title(node),
                        cover_image: edge_cover(node),
                        year: edge_year(node),
                        character_role: edge.character_role.clone(),
                        voice_actors: edge
                            .voice_actors
                            .as_deref()
                            .unwrap_or_default()
                            .iter()
                            .map(|va| FfiVoiceActor {
                                id: va.id,
                                name: va
                                    .name
                                    .as_ref()
                                    .and_then(|n| n.full.clone().or_else(|| n.native.clone()))
                                    .unwrap_or_default(),
                                image_url: va
                                    .image
                                    .as_ref()
                                    .and_then(|i| i.medium.clone().or_else(|| i.large.clone())),
                                language: va.language_v2.clone().or_else(|| va.language.clone()),
                            })
                            .collect(),
                    })
                })
                .collect(),
        })
    }

    /// One staff member's own page, for the rows a cast list links to.
    pub async fn staff_detail(&self, staff_id: i64) -> FfiResult<FfiStaffDetail> {
        let s = self
            .catalogs
            .staff_detail(staff_id)
            .await
            .map_err(|msg| AnicatError::Network { msg })?;
        Ok(FfiStaffDetail {
            id: s.id,
            name: s
                .name
                .as_ref()
                .and_then(|n| n.full.clone().or_else(|| n.native.clone()))
                .unwrap_or_default(),
            native_name: s.name.as_ref().and_then(|n| n.native.clone()),
            image_url: s.image.as_ref().and_then(|i| i.large.clone().or_else(|| i.medium.clone())),
            description: s.description.clone(),
            primary_occupations: s.primary_occupations.clone().unwrap_or_default(),
            home_town: s.home_town.clone(),
            language: s.language_v2.clone(),
            favourites: s.favourites.unwrap_or(0) as i32,
            character_credits: media_edges(s.character_media.as_ref())
                .filter_map(|edge| {
                    let node = edge.node.as_ref()?;
                    Some(FfiStaffCharacterCredit {
                        catalog_id: node.id,
                        media_type: node.media_type.clone(),
                        format: node.format.clone(),
                        title: edge_title(node),
                        cover_image: edge_cover(node),
                        year: edge_year(node),
                        character_role: edge.character_role.clone(),
                        characters: edge
                            .characters
                            .as_deref()
                            .unwrap_or_default()
                            .iter()
                            .map(|ch| FfiCreditCharacter {
                                id: ch.id,
                                name: ch
                                    .name
                                    .as_ref()
                                    .and_then(|n| n.full.clone().or_else(|| n.native.clone()))
                                    .unwrap_or_default(),
                                image_url: ch
                                    .image
                                    .as_ref()
                                    .and_then(|i| i.medium.clone().or_else(|| i.large.clone())),
                            })
                            .collect(),
                    })
                })
                .collect(),
            media_credits: media_edges(s.staff_media.as_ref())
                .filter_map(|edge| {
                    let node = edge.node.as_ref()?;
                    Some(FfiStaffMediaCredit {
                        catalog_id: node.id,
                        media_type: node.media_type.clone(),
                        format: node.format.clone(),
                        title: edge_title(node),
                        cover_image: edge_cover(node),
                        year: edge_year(node),
                        staff_role: edge.staff_role.clone(),
                    })
                })
                .collect(),
        })
    }

    /// One studio, with the shows it led. `MediaDetail::studios` is where the
    /// ids come from.
    pub async fn studio_detail(&self, studio_id: i64) -> FfiResult<FfiStudioDetail> {
        let studio = self
            .catalogs
            .studio_detail(studio_id)
            .await
            .map_err(|msg| AnicatError::Network { msg })?;
        Ok(FfiStudioDetail {
            id: studio.id,
            name: studio.name.clone().unwrap_or_default(),
            is_animation_studio: studio.is_animation_studio.unwrap_or(false),
            favourites: studio.favourites.unwrap_or(0) as i32,
            media: studio
                .media
                .as_ref()
                .and_then(|m| m.nodes.as_ref())
                .map(|nodes| {
                    nodes
                        .iter()
                        .filter(|m| !m.is_adult.unwrap_or(false))
                        .map(summarize)
                        .collect()
                })
                .unwrap_or_default(),
        })
    }

    /// Every episode airing between two unix timestamps, for a calendar.
    ///
    /// The window is the caller's: the engine has no opinion about where a
    /// week starts, and a client that draws Monday-first must not have to
    /// undo an assumption made here.
    pub async fn airing_schedule(&self, from_unix: i64, to_unix: i64) -> FfiResult<Vec<FfiAiringSlot>> {
        let slots = self
            .catalogs
            .airing_schedule(from_unix, to_unix)
            .await
            .map_err(|msg| AnicatError::Network { msg })?;
        Ok(slots
            .into_iter()
            .map(|slot| {
                let entry = slot.media.media_list_entry.as_ref();
                FfiAiringSlot {
                    catalog_id: slot.media.id,
                    title: slot
                        .media
                        .title
                        .as_ref()
                        .and_then(|t| t.english.clone().or_else(|| t.romaji.clone()))
                        .unwrap_or_default(),
                    cover_image: slot
                        .media
                        .cover_image
                        .as_ref()
                        .and_then(|c| c.large.clone().or_else(|| c.medium.clone()))
                        .unwrap_or_default(),
                    episode: slot.episode,
                    airing_at: slot.airing_at,
                    format: slot.media.format.clone(),
                    episode_count: slot.media.episodes,
                    on_user_list: entry.is_some(),
                    user_status: entry.and_then(|e| e.status.clone()),
                }
            })
            .collect())
    }

    /// The "Because you watched" shelf. Empty, not an error, when signed out.
    pub async fn recommendations_for_viewer(&self, limit: i32) -> FfiResult<Vec<FfiRecommendationRow>> {
        let rows = self
            .catalogs
            .viewer_recommendations(limit.max(1) as usize)
            .await
            .map_err(|msg| AnicatError::Network { msg })?;
        Ok(rows
            .into_iter()
            .map(|row| FfiRecommendationRow {
                media: summarize(&row.media),
                because_title: row.because_title,
                because_catalog_id: row.because_catalog_id,
                rating: row.rating,
            })
            .collect())
    }

    /// What this device's watch history adds up to: lifetime totals, plus a
    /// `days`-long calendar strip. Local registry only, so it answers signed
    /// out and during an AniList outage.
    /// Watch statistics over the last `days`.
    ///
    /// `catalogs` narrows which of them count; empty means all. Cinema mode
    /// asks for TMDB's alone, because a Stats page that answers about anime
    /// while the app is showing films is not a mixed view, it is a wrong one.
    pub fn watch_stats(&self, days: i32, catalogs: Vec<FfiCatalog>) -> FfiResult<FfiWatchStats> {
        let mut rows = self
            .registry
            .progress_rows()
            .map_err(|msg| AnicatError::Storage { msg })?;
        if !catalogs.is_empty() {
            let wanted: Vec<Catalog> = catalogs.into_iter().map(Catalog::from).collect();
            rows.retain(|r| {
                Catalog::parse(&r.catalog).map(|c| wanted.contains(&c)).unwrap_or(false)
            });
        }
        // `chrono::Local` is read here, at the edge, and handed to an
        // aggregation that takes any timezone — the day boundaries that
        // decide every streak in there would otherwise be untestable off the
        // host's own clock.
        let stats = crate::db::stats::aggregate(&rows, days, &chrono::Local::now());
        Ok(FfiWatchStats {
            total_watch_seconds: stats.total_watch_seconds,
            episodes_watched: stats.episodes_watched,
            titles_started: stats.titles_started,
            per_day: stats
                .per_day
                .into_iter()
                .map(|d| FfiDayCount { date: d.date, episodes: d.episodes, seconds: d.seconds })
                .collect(),
            current_streak_days: stats.current_streak_days,
            longest_streak_days: stats.longest_streak_days,
            top_titles: stats
                .top_titles
                .into_iter()
                .map(|t| FfiTitleCount {
                    catalog: Catalog::parse(&t.catalog)
                        .map(FfiCatalog::from)
                        .unwrap_or(FfiCatalog::Anilist),
                    catalog_id: t.catalog_id,
                    episodes: t.episodes,
                    seconds: t.seconds,
                })
                .collect(),
            busiest_hour: stats.busiest_hour,
            first_watch_at: stats.first_watch_at,
        })
    }

    /// Remembers the audio and subtitle tracks the viewer picked for a title,
    /// so the next episode opens the same way.
    ///
    /// Every argument is written, `None` included: "no subtitles" is a choice
    /// the next episode has to honor, and a merge that skipped nulls could
    /// not record it.
    pub fn record_title_track_preference(
        &self,
        catalog: FfiCatalog,
        catalog_id: i64,
        audio_lang: Option<String>,
        subtitle_lang: Option<String>,
        subtitle_title: Option<String>,
    ) -> FfiResult<()> {
        self.registry
            .set_title_track_preference(
                catalog.into(),
                catalog_id,
                &crate::db::service::TrackPreference { audio_lang, subtitle_lang, subtitle_title },
            )
            .map_err(|msg| AnicatError::Storage { msg })
    }

    pub fn title_track_preference(
        &self,
        catalog: FfiCatalog,
        catalog_id: i64,
    ) -> FfiResult<Option<FfiTrackPreference>> {
        let pref = self
            .registry
            .title_track_preference(catalog.into(), catalog_id)
            .map_err(|msg| AnicatError::Storage { msg })?;
        Ok(pref.map(|p| FfiTrackPreference {
            audio_lang: p.audio_lang,
            subtitle_lang: p.subtitle_lang,
            subtitle_title: p.subtitle_title,
        }))
    }

    /// A forum thread with its first page of comments, replies flattened in.
    pub async fn thread_detail(&self, thread_id: i64) -> FfiResult<FfiThreadDetail> {
        let res = self
            .catalogs
            .thread_detail(thread_id)
            .await
            .map_err(|msg| AnicatError::Network { msg })?;
        // Not `Network`, unlike every other failure here: forum threads get
        // deleted, and a UI that read a deletion as a connection problem
        // would sit there retrying it.
        let thread = res
            .thread
            .ok_or_else(|| AnicatError::NotFound { msg: format!("thread {thread_id}") })?;
        let (comments, has_next_page) = match res.page {
            Some(page) => (
                flatten_thread_comments(page.thread_comments.unwrap_or_default()),
                page.page_info.and_then(|p| p.has_next_page).unwrap_or(false),
            ),
            None => (Vec::new(), false),
        };
        Ok(FfiThreadDetail {
            id: thread.id,
            title: thread.title.unwrap_or_default(),
            body: thread.body.unwrap_or_default(),
            author_name: thread.user.as_ref().and_then(|u| u.name.clone()),
            author_avatar_url: thread
                .user
                .as_ref()
                .and_then(|u| u.avatar.as_ref())
                .and_then(|a| a.medium.clone().or_else(|| a.large.clone())),
            created_at: thread.created_at.unwrap_or(0),
            reply_count: thread.reply_count.unwrap_or(0),
            view_count: thread.view_count.unwrap_or(0),
            is_locked: thread.is_locked.unwrap_or(false),
            categories: thread
                .categories
                .unwrap_or_default()
                .into_iter()
                .filter_map(|c| c.name)
                .collect(),
            comments,
            has_next_page,
        })
    }

    /// Page 2 and beyond of a thread's comments. Page 1 comes back with
    /// `thread_detail`, so the first call here is for page 2.
    pub async fn thread_comments(
        &self,
        thread_id: i64,
        page: i64,
    ) -> FfiResult<FfiThreadCommentPage> {
        let res = self
            .catalogs
            .thread_comments(thread_id, page)
            .await
            .map_err(|msg| AnicatError::Network { msg })?;
        Ok(FfiThreadCommentPage {
            comments: flatten_thread_comments(res.thread_comments.unwrap_or_default()),
            has_next_page: res.page_info.and_then(|p| p.has_next_page).unwrap_or(false),
        })
    }
}

/// The edges of an optional `MediaConnection`, as an iterator, so the three
/// credit lists above do not each repeat the same two `as_ref` hops.
fn media_edges(
    connection: Option<&anilist::types::MediaConnection>,
) -> impl Iterator<Item = &anilist::types::MediaEdge> {
    connection.and_then(|c| c.edges.as_deref()).unwrap_or_default().iter()
}

fn edge_title(node: &anilist::types::MediaItem) -> String {
    node.title
        .as_ref()
        .and_then(|t| t.english.clone().or_else(|| t.romaji.clone()))
        .unwrap_or_default()
}

fn edge_cover(node: &anilist::types::MediaItem) -> String {
    node.cover_image
        .as_ref()
        .and_then(|c| c.large.clone().or_else(|| c.medium.clone()))
        .unwrap_or_default()
}

fn edge_year(node: &anilist::types::MediaItem) -> Option<i32> {
    node.season_year.or_else(|| node.start_date.as_ref().and_then(|d| d.year))
}

/// Turns AniList's comment tree into one indentable list.
///
/// Only top-level comments come back as `ThreadComment` objects; a reply
/// lives inside its parent's `childComments`, which AniList declares as the
/// untyped `Json` scalar. So this walks raw `Value`s and takes every field
/// leniently: a blob that returns `false` instead of an array, or an object
/// that lost a key, has to mean "no replies" rather than fail the thread.
///
/// Order is pre-order — a comment, then its whole subtree, then the next
/// comment — so a list view can render straight through and indent on
/// `depth`. Recursion depth is bounded by serde_json's own 128-level parse
/// limit, which the blob already passed to get here.
fn flatten_thread_comments(
    nodes: Vec<anilist::responses::ThreadCommentNode>,
) -> Vec<FfiThreadComment> {
    let mut out = Vec::new();
    for node in nodes {
        out.push(FfiThreadComment {
            id: node.id,
            parent_id: None,
            depth: 0,
            body: node.comment.unwrap_or_default(),
            author_name: node.user.as_ref().and_then(|u| u.name.clone()),
            author_avatar_url: node
                .user
                .as_ref()
                .and_then(|u| u.avatar.as_ref())
                .and_then(|a| a.medium.clone().or_else(|| a.large.clone())),
            created_at: node.created_at.unwrap_or(0),
            like_count: node.like_count.unwrap_or(0),
        });
        push_child_comments(&mut out, node.child_comments.as_ref(), node.id, 1);
    }
    out
}

fn push_child_comments(
    out: &mut Vec<FfiThreadComment>,
    raw: Option<&serde_json::Value>,
    parent_id: i64,
    depth: i32,
) {
    let Some(items) = raw.and_then(|v| v.as_array()) else { return };
    for item in items {
        // A reply with no readable id is dropped along with its own subtree:
        // those grandchildren have no valid `parent_id` to point at, and
        // attaching them to this comment's parent would silently reparent
        // someone else's conversation under the wrong post.
        let Some(id) = item.get("id").and_then(|v| v.as_i64()) else { continue };
        out.push(FfiThreadComment {
            id,
            parent_id: Some(parent_id),
            depth,
            body: item.get("comment").and_then(|v| v.as_str()).unwrap_or_default().to_string(),
            author_name: item
                .pointer("/user/name")
                .and_then(|v| v.as_str())
                .map(str::to_string),
            author_avatar_url: item
                .pointer("/user/avatar/medium")
                .or_else(|| item.pointer("/user/avatar/large"))
                .and_then(|v| v.as_str())
                .map(str::to_string),
            created_at: item.get("createdAt").and_then(|v| v.as_i64()).unwrap_or(0),
            like_count: item.get("likeCount").and_then(|v| v.as_i64()).unwrap_or(0) as i32,
        });
        push_child_comments(out, item.get("childComments"), id, depth + 1);
    }
}

impl AnicatEngine {
    /// Records a download once it lands, whatever the UI is doing.
    ///
    /// Polls the same status the episode row polls, at the same interval, and
    /// stops on the first terminal state. Bounded by the download's own
    /// ceiling rather than a timer of its own: a stalled download reports
    /// `Failed` and this ends with it.
    fn watch_download(&self, catalog: FfiCatalog, catalog_id: i64, episode: i64, title: String) {
        let registry = self.registry.clone();
        let torrents = self.torrents.clone();
        let media = MediaKey::new(catalog.into(), catalog_id);
        tokio::spawn(async move {
            loop {
                tokio::time::sleep(std::time::Duration::from_secs(1)).await;
                let Some((torrent_id, file_id)) = torrents.resolved_ids(media, episode).await else {
                    return;
                };
                match torrents.download_status(torrent_id, file_id).await.into() {
                    FfiDownloadStatus::Done { path } => {
                        let bytes = std::fs::metadata(&path).map(|m| m.len() as i64).unwrap_or(0);
                        if let Err(e) = registry.record_downloaded_episode(
                            catalog.into(),
                            catalog_id,
                            episode,
                            Some(&title),
                            &path,
                            bytes,
                        ) {
                            log::warn!("registry: could not record download: {e}");
                        }
                        return;
                    }
                    FfiDownloadStatus::Failed { .. } | FfiDownloadStatus::NotStarted => return,
                    FfiDownloadStatus::Downloading { .. } => {}
                }
            }
        });
    }

    /// The cinema counterpart of `resolve_stream`.
    ///
    /// A separate path rather than another branch inside it: everything
    /// `gather_media_info` reads -- relations, synonyms, airing counts,
    /// franchise shape -- is AniList's alone, and what the cinema search
    /// needs instead (a film's year, an episode's SxxEyy) comes from the TMDB
    /// detail. What stays shared is everything after the search: the same
    /// `resolve`, the same remembered-release reuse, the same playing pin.
    async fn resolve_cinema_stream(&self, req: StreamRequest) -> FfiResult<StreamHandle> {
        let port = self.ensure_stream_server().await?;
        let catalog: Catalog = req.catalog.into();
        let media = MediaKey::new(catalog, req.catalog_id);
        let CinemaSearchInputs { titles, movie_criteria, series_criteria, episode_count, is_series } =
            self.cinema_search_inputs(req.catalog, req.catalog_id, req.episode, req.title.clone())
                .await?;

        let remembered = self
            .registry
            .remembered_release(media.catalog, media.id, req.episode)
            .ok()
            .flatten()
            .filter(|r| r.prefer_dub == req.prefer_dub);

        let url = self
            .torrents
            .resolve(
                &self.http,
                ResolveTarget {
                    media,
                    episode: req.episode,
                    titles: &titles,
                    // A film has no episode number in its release name; an
                    // episode of a series always does.
                    allow_episodeless: !is_series,
                    episode_count: Some(episode_count),
                    aired_episodes: Some(episode_count),
                    prefer_dub: req.prefer_dub,
                    browser_client: false,
                    chosen_name: req.chosen_name.clone(),
                    movie: movie_criteria,
                    series: series_criteria,
                    entry: layout::EntryHint {
                        kind: if is_series {
                            layout::EntryKind::Tv
                        } else {
                            layout::EntryKind::Movie
                        },
                        ..Default::default()
                    },
                    sibling_titles: &[],
                    resume_fraction: req.resume_fraction,
                    remembered,
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
        if let Some(winner) = self.torrents.winning_release(media, req.episode).await {
            if let Err(e) = self
                .registry
                .remember_release(media.catalog, media.id, req.episode, &winner)
            {
                log::warn!("registry: could not remember release for {media} ep {}: {e}", req.episode);
            }
        }
        if !req.preload {
            self.torrents.set_playing(media, req.episode).await;
        }
        Ok(StreamHandle {
            url,
            torrent_id: torrent_id as u64,
            file_id: file_id as u64,
        })
    }

    /// What a cinema search needs, for a stream or for a download.
    ///
    /// Shared because the two must not drift: a download that searched on
    /// different titles or a different SxxEyy than the stream would fetch a
    /// different release for the same episode, and the reuse cache and the
    /// remembered-release map are keyed on the episode, not on which button
    /// asked for it.
    async fn cinema_search_inputs(
        &self,
        catalog: FfiCatalog,
        catalog_id: i64,
        episode: i64,
        frontend_title: Option<String>,
    ) -> FfiResult<CinemaSearchInputs> {
        let media = MediaKey::new(catalog.into(), catalog_id);
        let is_series = catalog == FfiCatalog::TmdbTv;
        let detail = self
            .catalogs
            .cinema_detail(catalog_id, is_series)
            .await
            .map_err(|msg| AnicatError::Network { msg })?;

        // Releases are named with either title TMDB carries -- a film on a
        // western indexer is as likely to be listed under its original title
        // as its english one -- and the page's own title goes in behind both,
        // because it may be showing a translation of either.
        let mut titles: Vec<String> = vec![];
        let mut year: Option<i32> = None;
        let mut season_map: Vec<(u32, u32)> = vec![];
        if let Some(m) = &detail.movie {
            push_title(&mut titles, m.title.clone());
            push_title(&mut titles, m.original_title.clone());
            year = release_year(m.release_date.as_deref());
        }
        if let Some(series) = &detail.series {
            push_title(&mut titles, series.name.clone());
            push_title(&mut titles, series.original_name.clone());
            season_map = series.season_map();
        }
        push_title(&mut titles, frontend_title);
        if titles.is_empty() {
            return Err(AnicatError::NotFound {
                msg: format!("no search titles for {media}"),
            });
        }

        let series_criteria = if is_series {
            let (season, ep) =
                crate::catalog::cinema::locate_episode(&season_map, episode.max(0) as u32)
                    .ok_or_else(|| AnicatError::NotFound {
                        msg: format!(
                            "episode {} is past the {} seasons TMDB lists for {media}",
                            episode,
                            season_map.len()
                        ),
                    })?;
            Some(crate::torrent::series::EpisodeCriteria {
                season,
                episode: ep,
                browser_client: false,
            })
        } else {
            None
        };
        let movie_criteria = if is_series {
            None
        } else {
            Some(crate::torrent::cinema::MovieCriteria { year, browser_client: false })
        };
        let episode_count: i64 = if is_series {
            season_map.iter().map(|(_, count)| *count as i64).sum()
        } else {
            1
        };

        Ok(CinemaSearchInputs {
            titles,
            movie_criteria,
            series_criteria,
            episode_count,
            is_series,
        })
    }

    /// One film or series as a `MediaDetail`.
    ///
    /// The title's own fields come from the same `into_media_item` the rows
    /// and the search use, so a card and the page it opens can never disagree
    /// about a title, a year or a poster. Only what a card has no room for --
    /// the episode list, the trailer, the credits, the local progress -- is
    /// assembled here.
    async fn cinema_media_detail(
        &self,
        catalog: FfiCatalog,
        catalog_id: i64,
    ) -> FfiResult<MediaDetail> {
        let is_series = catalog == FfiCatalog::TmdbTv;
        let detail = self
            .catalogs
            .cinema_detail(catalog_id, is_series)
            .await
            .map_err(|msg| AnicatError::Network { msg })?;
        let item = match (detail.movie.clone(), detail.series.clone()) {
            (Some(m), _) => m.into_media_item(),
            (_, Some(s)) => s.into_media_item(),
            _ => None,
        }
        .ok_or_else(|| AnicatError::NotFound {
            msg: format!("TMDB has no {catalog:?} {catalog_id}"),
        })?;

        let history = self
            .registry
            .history_for(catalog.into(), catalog_id)
            .unwrap_or_default();

        let mut episodes: Vec<EpisodeRow> = Vec::new();
        let watched_percent = |number: i32| -> f64 {
            history
                .iter()
                .find(|e| e.episode_number == number as i64 && e.duration > 0)
                .map(|e| (e.stop_time as f64 / e.duration as f64) * 100.0)
                .unwrap_or(0.0)
        };
        let watched_completed = |number: i32| -> bool {
            history
                .iter()
                .any(|e| e.episode_number == number as i64 && e.completed)
        };
        if is_series {
            for ep in &detail.episodes {
                let number = ep.absolute as i32;
                let percent = watched_percent(number);
                episodes.push(EpisodeRow {
                    number,
                    // The season is stated in the row rather than left for
                    // the client to work back out of the absolute number:
                    // the season map lives in the engine, and "Episode 34" on
                    // its own tells a viewer of a five-season show nothing.
                    title: ep.title.clone().unwrap_or_else(|| {
                        format!("S{:02}E{:02}", ep.season, ep.episode)
                    }),
                    thumbnail: ep.still_url.clone(),
                    is_watched: episode_is_watched(number, percent, watched_completed(number), None),
                    progress_percent: percent,
                    runtime_minutes: ep.runtime_minutes,
                    synopsis: ep.overview.clone(),
                    air_date: ep.air_date.clone(),
                });
            }
        } else {
            // A film is one sitting, and the player, the registry and the
            // resume position all key on an episode number, so it is
            // episode 1 rather than a special case in each of them.
            let percent = watched_percent(1);
            episodes.push(EpisodeRow {
                number: 1,
                title: item
                    .title
                    .as_ref()
                    .and_then(|t| t.english.clone().or_else(|| t.romaji.clone()))
                    .unwrap_or_else(|| "Film".to_string()),
                thumbnail: item.banner_image.clone(),
                is_watched: episode_is_watched(1, percent, watched_completed(1), None),
                progress_percent: percent,
                runtime_minutes: item.duration,
                synopsis: item.description.clone(),
                air_date: detail.movie.as_ref().and_then(|m| m.release_date.clone()),
            });
        }

        let resume = resume_episode(&history, None);
        let trailer_id = detail
            .movie
            .as_ref()
            .and_then(|m| m.videos.as_ref())
            .or_else(|| detail.series.as_ref().and_then(|s| s.videos.as_ref()))
            .and_then(|v| v.best_trailer());
        let studio = detail
            .movie
            .as_ref()
            .and_then(|m| m.production_companies.as_ref())
            .or_else(|| detail.series.as_ref().and_then(|s| s.networks.as_ref()))
            .and_then(|c| c.first())
            .and_then(|c| c.name.clone());
        let recommendations = detail
            .movie
            .as_ref()
            .and_then(|m| m.recommendations.as_ref())
            .and_then(|p| p.results.as_ref())
            .map(|rows| {
                rows.iter()
                    .filter_map(|r| r.clone().into_media_item())
                    .map(|i| cinema_recommendation(&i))
                    .collect::<Vec<_>>()
            })
            .or_else(|| {
                detail
                    .series
                    .as_ref()
                    .and_then(|s| s.recommendations.as_ref())
                    .and_then(|p| p.results.as_ref())
                    .map(|rows| {
                        rows.iter()
                            .filter_map(|r| r.clone().into_media_item())
                            .map(|i| cinema_recommendation(&i))
                            .collect::<Vec<_>>()
                    })
            })
            .unwrap_or_default();

        Ok(MediaDetail {
            catalog_id,
            mal_id: None,
            title: item
                .title
                .as_ref()
                .and_then(|t| t.english.clone().or_else(|| t.romaji.clone()))
                .unwrap_or_default(),
            romaji_title: item.title.as_ref().and_then(|t| t.romaji.clone()),
            cover_image: item
                .cover_image
                .as_ref()
                .and_then(|c| c.large.clone().or_else(|| c.medium.clone()))
                .unwrap_or_default(),
            banner_image: item.banner_image.clone(),
            format: item.format.clone(),
            status: item.status.clone(),
            year: item.season_year,
            studio,
            // TMDB company ids are not AniList studio ids, and a studio page
            // keyed on one would open somebody else's. The named line above
            // is what the header draws; this list is what makes it clickable,
            // so it stays empty until there is a page to click through to.
            studios: vec![],
            trailer_site: trailer_id.as_ref().map(|_| "YOUTUBE".to_string()),
            trailer_id,
            trailer_thumbnail: None,
            synopsis: item.description.clone(),
            genres: item.genres.clone().unwrap_or_default(),
            average_score: item.average_score,
            episode_count: Some(episodes.len() as i32),
            chapter_count: None,
            duration_minutes: item.duration,
            resume_episode: resume.map(|e| e.episode_number as i32),
            resume_seconds: resume.map(|e| e.stop_time as i32),
            prequel: None,
            sequel: None,
            relations: vec![],
            recommendations,
            episodes,
            // Cinema titles are tracked locally only: AniList has no entry to
            // write to, and nothing else is wired up.
            list_status: None,
            user_score: None,
            list_entry_id: None,
            list_progress: None,
            is_favourite: false,
        })
    }
    async fn ensure_stream_server(&self) -> FfiResult<u16> {
        self.stream_port
            .get_or_try_init(|| crate::torrent::stream::serve(self.torrents.clone()))
            .await
            .copied()
            .map_err(|msg| AnicatError::Internal { msg })
    }

    /// Cached wrapper around `catalog::anizip::fetch`. Not part of the
    /// `#[uniffi::export]` impl block above — `AniZipEpisode`/`HashMap`
    /// have no uniffi `Lower` impl, and nothing outside this crate needs to
    /// call it directly. `anizip::fetch` itself never errors (a failed or
    /// unmapped id just returns empty), so there is nothing here to
    /// propagate — only a cache to check and fill.
    async fn anizip_meta(&self, anilist_id: i64) -> std::collections::HashMap<i32, crate::catalog::anizip::AniZipEpisode> {
        let key = crate::catalog::cache::AniListCache::key("anizip_meta", &[("id", &anilist_id.to_string())]);
        if let Some(cached) = self.catalogs.cache.get(&key) {
            if let Ok(map) = serde_json::from_value(cached) {
                return map;
            }
        }
        let map = crate::catalog::anizip::fetch(&self.http, anilist_id).await;
        if let Ok(v) = serde_json::to_value(&map) {
            self.catalogs.cache.set(key, v, "anizip_meta");
        }
        map
    }

    /// The MAL id Jikan can find by title, cached on the AniList id.
    ///
    /// Hit and miss are stored under two cmds because `AniListCache::ttl`
    /// keys on the cmd alone, and the two want very different lifetimes —
    /// see the arms in `cache.rs`. Both are consulted before any request, so
    /// a title costs at most one lookup per launch even when the answer was
    /// "no".
    async fn jikan_mal_id(&self, anilist_id: i64, m: &crate::catalog::anilist::types::MediaItem) -> Option<i64> {
        use crate::catalog::cache::AniListCache;
        use crate::catalog::jikan::MalLookup;
        let id = anilist_id.to_string();
        let hit_key = AniListCache::key("jikan_mal_id", &[("id", &id)]);
        let miss_key = AniListCache::key("jikan_mal_id_miss", &[("id", &id)]);
        // `and_then` rather than `map`: a row that survived but no longer
        // reads as a number falls through to a fresh lookup instead of
        // answering None for the rest of the week-long hit TTL.
        if let Some(id) = self.catalogs.cache.get(&hit_key).and_then(|v| v.as_i64()) {
            return Some(id);
        }
        if self.catalogs.cache.get(&miss_key).is_some() {
            return None;
        }

        // Romaji leads because MAL's own `title` is romanised, so it is the
        // likeliest exact hit and the one worth spending the first of the
        // two queries on. Everything after the second entry is only ever
        // matched against, never sent.
        let mut titles = Vec::new();
        if let Some(t) = m.title.as_ref() {
            titles.extend([t.romaji.clone(), t.english.clone(), t.native.clone()].into_iter().flatten());
        }
        titles.extend(m.synonyms.clone().unwrap_or_default());
        if titles.is_empty() {
            return None;
        }

        let year = m.season_year.or_else(|| m.start_date.as_ref().and_then(|d| d.year));
        let found = crate::catalog::jikan::search_mal_id(&self.http, &titles, year, m.format.as_deref()).await;
        match found {
            MalLookup::Found(id) => {
                self.catalogs.cache.set(hit_key, serde_json::json!(id), "jikan_mal_id");
                Some(id)
            }
            MalLookup::NoMatch => {
                self.catalogs.cache.set(miss_key, serde_json::json!(true), "jikan_mal_id_miss");
                None
            }
            // Deliberately not cached. An outage that wrote a miss row
            // would outlive itself by the whole negative TTL, and re-asking
            // is cheap: a 504 comes back in well under a second.
            MalLookup::Unavailable => None,
        }
    }
}

/// An episode counts as watched when EITHER source says so: the local
/// watch-history registry (>=85%, the same threshold the player itself uses
/// to advance AniList progress) or AniList's own list progress. The registry
/// is per-device — a title watched to episode 10 on another Mac, or through
/// the Tauri build, has zero rows in a fresh install's SQLite file, and
/// checking only that source read every episode back as unwatched with the
/// primary button offering "Start Episode 1" regardless of what AniList
/// said. AniList has no per-second position, so it can only ever confirm
/// whole episodes — the local source still owns `resume_seconds`.
/// `locally_completed` is migration 5's sticky flag: a rewatch resets
/// `stop_time`, so the percentage alone reported a finished episode as
/// unwatched the moment someone reopened it and stopped early.
fn episode_is_watched(
    number: i32,
    local_percent: f64,
    locally_completed: bool,
    anilist_progress: Option<i32>,
) -> bool {
    locally_completed || local_percent >= 85.0 || anilist_progress.is_some_and(|p| number <= p)
}

/// The local-history episode the primary button should offer to resume
/// into. A completed episode is not something to resume into (the `< 0.85`
/// filter), and once AniList has a confirmed progress, the *only* valid
/// candidate is the one episode immediately after it — not just anything
/// with an incomplete local position, however far away.
///
/// That distinction matters because local history isn't a clean log of
/// what's been watched in order: scrubbing past a slow part, sampling a few
/// episodes out of order, or briefly opening one while testing all leave a
/// row with `stop_time` under 85% for whatever episode number that was.
/// Taking the *furthest* such row — the original version of this function —
/// meant a stray incomplete open of episode 12 outranked genuine partial
/// watches of 3, 7, and 9 sitting between it and AniList's confirmed
/// progress of 9, and the button offered "Continue Episode 12" for a title
/// the viewer had only actually reached episode 9 of.
///
/// A completed-elsewhere title still needs the same guard as before: a row
/// left over from a title played partway through Anicat once, then finished
/// elsewhere (the AniList app, a browser, another device), must not override
/// `list_progress` forever — episode `list_progress + 1` is exactly the one
/// case that can't be "elsewhere", since AniList's own progress already
/// accounts for everything up to and including `list_progress`.
///
/// With no AniList progress at all (fresh install, first-ever open), there's
/// no boundary to anchor to, so this falls back to the plain furthest
/// unfinished episode — the same behavior `episode_is_watched` falls back to
/// for the same reason.
fn resume_episode(
    history: &[crate::db::service::WatchEntry],
    list_progress: Option<i32>,
) -> Option<&crate::db::service::WatchEntry> {
    history
        .iter()
        .filter(|e| e.duration > 0 && e.stop_time > 0)
        .filter(|e| (e.stop_time as f64 / e.duration as f64) < 0.85)
        .filter(|e| match list_progress {
            Some(p) => e.episode_number == p as i64 + 1,
            None => true,
        })
        .max_by_key(|e| e.episode_number)
}

/// MangaKatana ids are the site's own page URLs (it has no numeric id of its
/// own); MangaDex ids are UUIDs. That is enough to route a manga/chapter id
/// back to the client that produced it without adding a second
/// provider-tagging field to `MangaSummary`/`MangaChapter`.
fn is_mangakatana_id(id: &str) -> bool {
    id.starts_with("http")
}

fn build_search_variables(
    query: Option<&str>,
    media_type: Option<&str>,
    filters: Option<&SearchFilters>,
    page: i32,
) -> std::collections::HashMap<String, serde_json::Value> {
    let mut vars = std::collections::HashMap::new();

    let trimmed_query = query.map(str::trim).filter(|s| !s.is_empty());
    vars.insert(
        "search".to_string(),
        match trimmed_query {
            Some(q) => serde_json::json!(q),
            // Explicit null, not an empty string: AniList treats null as "no filter",
            // while an empty string is a real search term and returns zero results.
            None => serde_json::json!(null),
        },
    );

    let mtype = media_type.unwrap_or("ANIME");
    if mtype == "NOVEL" {
        vars.insert("type".to_string(), serde_json::json!("MANGA"));
        vars.insert("format".to_string(), serde_json::json!(["NOVEL"]));
    } else if mtype != "ALL" {
        vars.insert("type".to_string(), serde_json::json!(mtype));
    }

    vars.insert("page".to_string(), serde_json::json!(page));
    vars.insert("perPage".to_string(), serde_json::json!(25));
    vars.insert("isAdult".to_string(), serde_json::json!(false));

    if let Some(f) = filters {
        if let Some(ref g) = f.genre {
            let trimmed = g.trim();
            if !trimmed.is_empty() {
                vars.insert("genre".to_string(), serde_json::json!(vec![trimmed]));
            }
        }
        if let Some(y) = f.year {
            vars.insert("seasonYear".to_string(), serde_json::json!(y));
        }
        if let Some(ref se) = f.season {
            let trimmed = se.trim();
            // AniList's `season` without a `seasonYear` matches that season in
            // every year it has, so "WINTER" alone returns a list nobody asked
            // for, ordered by popularity across three decades. Dropping it is
            // the honest answer: the year dropdown is what makes it mean
            // something.
            if !trimmed.is_empty() && f.year.is_some() {
                vars.insert("season".to_string(), serde_json::json!(trimmed));
            }
        }
        // A NOVEL search is already `type: MANGA, format: [NOVEL]` — that pair
        // is the whole definition of the mode, so a user format pick cannot be
        // allowed to overwrite it or "Novels" would quietly search manga.
        if mtype != "NOVEL" {
            if let Some(ref fmt) = f.format {
                let trimmed = fmt.trim();
                if !trimmed.is_empty() {
                    vars.insert("format".to_string(), serde_json::json!([trimmed]));
                }
            }
        }
        if let Some(s) = f.min_score {
            vars.insert("averageScoreGreater".to_string(), serde_json::json!(s));
        }
        if let Some(ref st) = f.status {
            let trimmed = st.trim();
            if !trimmed.is_empty() {
                vars.insert("status".to_string(), serde_json::json!(trimmed));
            }
        }
        if let Some(ref sort) = f.sort {
            let trimmed = sort.trim();
            if !trimmed.is_empty() {
                vars.insert("sort".to_string(), serde_json::json!([trimmed]));
            }
        }
    }

    // Default sort when searching without a text query so AniList returns
    // popular titles rather than arbitrary ID ordering.
    if trimmed_query.is_none() && !vars.contains_key("sort") {
        vars.insert("sort".to_string(), serde_json::json!(["POPULARITY_DESC"]));
    }

    vars
}

/// AniList descriptions are HTML fragments — `<br>`, `<i>`, the odd `<b>`.
/// SwiftUI's `Text` renders markup literally, so a raw description shows the
/// tags as text. Strips them rather than rendering, which is all a synopsis
/// needs.
fn strip_html(input: &str) -> String {
    let mut out = String::with_capacity(input.len());
    let mut in_tag = false;
    for ch in input.chars() {
        match ch {
            '<' => in_tag = true,
            '>' => {
                in_tag = false;
                // A `<br>` is a real line break in the source text.
                out.push(' ');
            }
            c if !in_tag => out.push(c),
            _ => {}
        }
    }
    out.replace("&mdash;", "\u{2014}")
        .replace("&amp;", "&")
        .replace("&quot;", "\"")
        .replace("&#039;", "'")
        .split_whitespace()
        .collect::<Vec<_>>()
        .join(" ")
}

/// The franchise's immediate neighbours, if AniList names them.
/// Filters candidates so anime only links to anime seasons and manga only links to manga,
/// ranking by format priority (TV/TV_SHORT/ONA over OVA/SPECIAL/MOVIE) and release year.
fn relations(m: &anilist::types::MediaItem) -> (Option<RelatedTitle>, Option<RelatedTitle>) {
    let is_current_anime = match m.media_type.as_deref() {
        Some("ANIME") => true,
        Some("MANGA") => false,
        _ => !matches!(m.format.as_deref(), Some("MANGA" | "NOVEL" | "ONE_SHOT")),
    };

    let m_year = m.season_year.or_else(|| m.start_date.as_ref().and_then(|d| d.year));

    let mut best_prequel: Option<(RelatedTitle, i32, Option<i32>, i64)> = None;
    let mut best_sequel: Option<(RelatedTitle, i32, Option<i32>, i64)> = None;

    for edge in m.relations.as_ref().and_then(|r| r.edges.as_ref()).into_iter().flatten() {
        let Some(node) = edge.node.as_ref() else { continue };

        let is_node_anime = match node.media_type.as_deref() {
            Some("ANIME") => true,
            Some("MANGA") => false,
            _ => !matches!(node.format.as_deref(), Some("MANGA" | "NOVEL" | "ONE_SHOT")),
        };

        // Don't cross media boundaries for season chains: anime should only link to anime,
        // and manga should only link to manga. Source manga / adaptations belong in main relations.
        if is_current_anime != is_node_anime {
            continue;
        }

        let format_priority = if is_current_anime {
            match node.format.as_deref() {
                Some("TV") => 100,
                Some("TV_SHORT") => 90,
                Some("ONA") => 85,
                Some("MOVIE") => 70,
                Some("OVA") => 50,
                Some("SPECIAL") => 40,
                Some("MUSIC") => 10,
                _ => 60,
            }
        } else {
            match node.format.as_deref() {
                Some("MANGA") => 100,
                Some("ONE_SHOT") => 80,
                Some("NOVEL") => 60,
                _ => 50,
            }
        };

        let node_year = node.start_date.as_ref().and_then(|d| d.year);
        let card = RelatedTitle {
            catalog_id: node.id,
            title: node
                .title
                .as_ref()
                .and_then(|t| t.english.clone().or_else(|| t.romaji.clone()))
                .unwrap_or_default(),
            format: node.format.clone(),
            cover_image: node
                .cover_image
                .as_ref()
                .and_then(|c| c.large.clone().or_else(|| c.medium.clone()))
                .unwrap_or_default(),
        };

        match edge.relation_type.as_deref() {
            Some("PREQUEL") => {
                let is_better = match &best_prequel {
                    None => true,
                    Some((_, best_pri, best_yr, best_id)) => {
                        if format_priority != *best_pri {
                            format_priority > *best_pri
                        } else {
                            match (node_year, *best_yr, m_year) {
                                (Some(ny), Some(by), Some(my)) => {
                                    let n_valid = ny <= my;
                                    let b_valid = by <= my;
                                    if n_valid != b_valid {
                                        n_valid
                                    } else if n_valid {
                                        ny > by
                                    } else {
                                        ny < by
                                    }
                                }
                                (Some(ny), Some(by), None) => ny > by,
                                (Some(_), None, _) => true,
                                (None, Some(_), _) => false,
                                (None, None, _) => node.id > *best_id,
                            }
                        }
                    }
                };
                if is_better {
                    best_prequel = Some((card, format_priority, node_year, node.id));
                }
            }
            Some("SEQUEL") => {
                let is_better = match &best_sequel {
                    None => true,
                    Some((_, best_pri, best_yr, best_id)) => {
                        if format_priority != *best_pri {
                            format_priority > *best_pri
                        } else {
                            match (node_year, *best_yr, m_year) {
                                (Some(ny), Some(by), Some(my)) => {
                                    let n_valid = ny >= my;
                                    let b_valid = by >= my;
                                    if n_valid != b_valid {
                                        n_valid
                                    } else if n_valid {
                                        ny < by
                                    } else {
                                        ny > by
                                    }
                                }
                                (Some(ny), Some(by), None) => ny < by,
                                (Some(_), None, _) => true,
                                (None, Some(_), _) => false,
                                (None, None, _) => node.id < *best_id,
                            }
                        }
                    }
                };
                if is_better {
                    best_sequel = Some((card, format_priority, node_year, node.id));
                }
            }
            _ => {}
        }
    }

    (best_prequel.map(|(c, _, _, _)| c), best_sequel.map(|(c, _, _, _)| c))
}

/// The credited studios, main ones first.
///
/// Comes back empty for a `media_detail` row cached before the query started
/// asking for `edges`, which is why `MediaDetail::studio` still exists: the
/// header line has to keep drawing something for the rest of that row's TTL.
fn studio_refs(m: &anilist::types::MediaItem) -> Vec<FfiStudioRef> {
    let Some(edges) = m.studios.as_ref().and_then(|s| s.edges.as_ref()) else {
        return Vec::new();
    };
    let mut out: Vec<FfiStudioRef> = edges
        .iter()
        .filter_map(|edge| {
            let node = edge.node.as_ref()?;
            Some(FfiStudioRef {
                id: node.id?,
                name: node.name.clone()?,
                is_main: edge.is_main.unwrap_or(false),
            })
        })
        .collect();
    out.sort_by_key(|s| !s.is_main);
    out
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

/// Everything a cinema resolve needs that the catalog has to answer first.
struct CinemaSearchInputs {
    titles: Vec<String>,
    movie_criteria: Option<crate::torrent::cinema::MovieCriteria>,
    series_criteria: Option<crate::torrent::series::EpisodeCriteria>,
    episode_count: i64,
    is_series: bool,
}

/// Whether a credit is someone appearing as themselves.
///
/// TMDB writes these as the character: "Self", "Self - Guest",
/// "Himself", "Herself - Host". Matched on the first word so the variants do
/// not each need listing, and a real character called "Selfridge" is not one
/// of them.
fn is_self_credit(character: Option<&str>) -> bool {
    let Some(character) = character else { return false };
    let first = character
        .split([' ', '-', '(', ','])
        .next()
        .unwrap_or("")
        .trim()
        .to_ascii_lowercase();
    matches!(first.as_str(), "self" | "himself" | "herself" | "themself" | "themselves")
}

/// Which rows to drop to bring a library under `cap`, given each row's size
/// and whether it is pinned, least recently used first.
///
/// Separated from the deleting so the arithmetic can be tested: the failure
/// this guards against is silent, since an over-eager eviction looks exactly
/// like a chapter that was never downloaded.
fn chapters_to_evict(sizes: &[(u64, bool)], cap: u64) -> Vec<usize> {
    let mut total: u64 = sizes.iter().map(|(bytes, _)| bytes).sum();
    let mut doomed = vec![];
    for (index, (bytes, pinned)) in sizes.iter().enumerate() {
        if total <= cap {
            break;
        }
        // The chapter being read stays, even over the cap: deleting the pages
        // on screen is a worse answer than a library one chapter too large.
        if *pinned {
            continue;
        }
        doomed.push(index);
        total = total.saturating_sub(*bytes);
    }
    doomed
}

/// What the offline library may hold before it starts evicting.
///
/// Two gigabytes: a chapter runs 10-20 MB, so this is a hundred-odd chapters
/// -- more than anyone has open questions about on a flight -- while staying
/// a fraction of the 3 GB the stream cache already takes.
const DEFAULT_OFFLINE_CAP_BYTES: u64 = 2 * 1024 * 1024 * 1024;

/// A `file://` URL for a path on disk.
///
/// Built here rather than pulled in with the `url` crate: the only characters
/// that need escaping in these paths are the ones Application Support puts
/// there (a space) and anything a title id contributes, and a whole URL
/// dependency for that is a dependency for one function.
fn file_url(path: &std::path::Path) -> String {
    let mut out = String::from("file://");
    for byte in path.to_string_lossy().as_bytes() {
        match byte {
            b'A'..=b'Z' | b'a'..=b'z' | b'0'..=b'9' | b'-' | b'_' | b'.' | b'~' | b'/' => {
                out.push(*byte as char)
            }
            _ => out.push_str(&format!("%{byte:02X}")),
        }
    }
    out
}

/// Adds a title to the search list when it has one and it is not already
/// there. TMDB repeats the same string in `title` and `original_title` for
/// any english-language film, and a duplicated title is a duplicated search.
fn push_title(titles: &mut Vec<String>, candidate: Option<String>) {
    if let Some(t) = candidate.map(|t| t.trim().to_string()).filter(|t| !t.is_empty()) {
        if !titles.contains(&t) {
            titles.push(t);
        }
    }
}

/// The year out of TMDB's `YYYY-MM-DD`. The whole cinema search hangs on it
/// -- two films of the same name are told apart by nothing else -- so a
/// malformed or missing date answers `None` rather than a guess.
fn release_year(date: Option<&str>) -> Option<i32> {
    date?.get(..4)?.parse().ok()
}

/// A recommendation card for a cinema title.
fn cinema_recommendation(m: &anilist::types::MediaItem) -> FfiRecommendation {
    let s = summarize_cinema(m);
    FfiRecommendation {
        catalog_id: s.catalog_id,
        title: s.title,
        format: s.format,
        cover_image: s.cover_image,
        average_score: s.average_score,
        rating: None,
    }
}

/// A cinema title's card.
///
/// The catalog comes from the format TMDB's own conversion sets -- a film
/// converts with `MOVIE`, a series with `TV` -- because a row or a search
/// answers in `MediaItem`, which carries the id but not which of TMDB's two
/// id spaces it belongs to. Getting this wrong opens the wrong detail page,
/// so it is decided here once rather than at each call site.
fn summarize_cinema(m: &anilist::types::MediaItem) -> MediaSummary {
    let catalog = if m.format.as_deref() == Some("MOVIE") {
        FfiCatalog::TmdbMovie
    } else {
        FfiCatalog::TmdbTv
    };
    MediaSummary { catalog, ..summarize(m) }
}

#[cfg(test)]
mod offline_live_tests {
    use super::*;

    /// Live. `cargo test --lib offline_live -- --ignored --nocapture`
    ///
    /// Downloads two real chapters under a cap that fits only one, and
    /// asserts the older one left and the newer one stayed -- files and
    /// registry row both. The arithmetic has unit tests; this is the part
    /// they cannot check, that the deleting actually follows them.
    #[tokio::test]
    #[ignore]
    async fn live_a_download_over_the_cap_evicts_the_oldest() {
        let _ = env_logger::Builder::from_env(env_logger::Env::default().default_filter_or("info"))
            .try_init();
        let dir = std::env::temp_dir().join("anicat-offline-cap-test");
        let _ = std::fs::remove_dir_all(&dir);
        let engine = AnicatEngine::new(dir.to_string_lossy().to_string(), None, None, None)
            .expect("engine");

        // Tomodachi Game, the title the reader tests already use.
        // MangaDex first, MangaKatana behind it -- the same order the reader
        // uses, and necessary here: this title is one of the ones MangaDex
        // has matched and has nothing readable under.
        let mut chapters = vec![];
        if let Some(manga) = engine
            .search_manga("Tomodachi Game".to_string(), Some(85911))
            .await
            .ok()
            .and_then(|m| m.into_iter().next())
        {
            chapters = engine.get_manga_chapters(manga.id).await.unwrap_or_default();
        }
        if chapters.len() < 2 {
            let fallback = engine
                .search_manga_katana("Tomodachi Game".to_string())
                .await
                .expect("katana search");
            let manga = fallback.first().expect("no match on either source");
            chapters = engine.get_manga_chapters(manga.id.clone()).await.expect("chapters");
        }
        assert!(chapters.len() >= 2, "need two chapters to evict between");
        let first = &chapters[0];
        let second = &chapters[1];

        let pages = engine
            .download_chapter(
                FfiCatalog::Anilist,
                85911,
                first.id.clone(),
                first.number.clone(),
                Some("Tomodachi Game".to_string()),
            )
            .await
            .expect("first download");
        println!("first chapter: {pages} pages");

        // A cap that the two together cannot fit under, taken from what the
        // first one actually cost -- chapter sizes vary and a fixed number
        // would make this test about the guess rather than the eviction.
        let after_first = engine.offline_size_bytes();
        engine.set_offline_limit_bytes(after_first + 1);

        let pages = engine
            .download_chapter(
                FfiCatalog::Anilist,
                85911,
                second.id.clone(),
                second.number.clone(),
                Some("Tomodachi Game".to_string()),
            )
            .await
            .expect("second download");
        println!("second chapter: {pages} pages, cap {} bytes", after_first + 1);

        let rows = engine.offline_chapters().expect("rows");
        println!(
            "kept: {:?}",
            rows.iter().map(|r| r.chapter_number.clone()).collect::<Vec<_>>()
        );
        assert_eq!(rows.len(), 1, "the cap should have left exactly one chapter");
        assert_eq!(rows[0].chapter_id, second.id, "the newest is the one kept");
        assert!(
            engine
                .offline_chapter_pages(FfiCatalog::Anilist, 85911, first.id.clone())
                .is_empty(),
            "the evicted chapter's files should be gone"
        );
        assert!(
            !engine
                .offline_chapter_pages(FfiCatalog::Anilist, 85911, second.id.clone())
                .is_empty(),
            "the kept chapter's files should still be there"
        );

        let _ = std::fs::remove_dir_all(&dir);
    }
}

#[cfg(test)]
mod cinema_live_tests {
    use super::*;

    /// Live, and the only test that walks the path a viewer actually takes:
    /// engine construction, TMDB detail, the year the film search hangs on,
    /// the indexer search, and a stream URL with a torrent behind it.
    ///
    /// ```text
    /// ANICAT_TMDB_PROXY=https://... cargo test --lib cinema_live -- --ignored --nocapture
    /// ```
    ///
    /// `catalog::cinema`'s own live tests prove TMDB answers; this proves the
    /// answer is enough to play something.
    #[tokio::test]
    #[ignore]
    async fn live_a_film_resolves_through_the_cinema_path() {
        let _ = env_logger::Builder::from_env(
            env_logger::Env::default().default_filter_or("info,librqbit=warn,librqbit_dht=warn"),
        )
        .try_init();
        let key = std::env::var("ANICAT_TMDB_KEY").ok().filter(|k| !k.is_empty());
        let proxy = std::env::var("ANICAT_TMDB_PROXY").ok().filter(|p| !p.is_empty());
        if key.is_none() && proxy.is_none() {
            eprintln!("set ANICAT_TMDB_PROXY or ANICAT_TMDB_KEY to run this");
            return;
        }
        let dir = std::env::temp_dir().join("anicat-cinema-ffi-test");
        let _ = std::fs::remove_dir_all(&dir);
        let engine = AnicatEngine::new(
            dir.to_string_lossy().to_string(),
            None,
            key,
            proxy,
        )
        .expect("engine");

        let started = std::time::Instant::now();
        let handle = engine
            .resolve_stream(StreamRequest {
                catalog: FfiCatalog::TmdbMovie,
                // Fight Club (1999). One of the few films whose release names
                // are unambiguous enough to make a failure here mean the
                // path is broken rather than the swarm being thin.
                catalog_id: 550,
                episode: 1,
                title: None,
                prefer_dub: false,
                chosen_name: None,
                resume_fraction: None,
                preload: false,
            })
            .await
            .expect("resolve");
        println!("film stream url: {} in {:?}", handle.url, started.elapsed());
        assert!(handle.url.starts_with("http://127.0.0.1:"));

        engine.playback_stopped().await;
        let _ = std::fs::remove_dir_all(&dir);
    }

    /// The series half: the same path, but the episode number the app stores
    /// has to become the `SxxEyy` a release is named with, against the season
    /// map TMDB stated. Episode 11 of Silo is season 2 episode 1 -- an
    /// off-by-one in `locate_episode` resolves a real file of the wrong
    /// episode, which is the failure this is here to catch.
    #[tokio::test]
    #[ignore]
    async fn live_an_episode_resolves_at_its_absolute_number() {
        let _ = env_logger::Builder::from_env(
            env_logger::Env::default().default_filter_or("info,librqbit=warn,librqbit_dht=warn"),
        )
        .try_init();
        let key = std::env::var("ANICAT_TMDB_KEY").ok().filter(|k| !k.is_empty());
        let proxy = std::env::var("ANICAT_TMDB_PROXY").ok().filter(|p| !p.is_empty());
        if key.is_none() && proxy.is_none() {
            eprintln!("set ANICAT_TMDB_PROXY or ANICAT_TMDB_KEY to run this");
            return;
        }
        let dir = std::env::temp_dir().join("anicat-cinema-series-ffi-test");
        let _ = std::fs::remove_dir_all(&dir);
        let engine =
            AnicatEngine::new(dir.to_string_lossy().to_string(), None, key, proxy).expect("engine");

        let started = std::time::Instant::now();
        let handle = engine
            .resolve_stream(StreamRequest {
                catalog: FfiCatalog::TmdbTv,
                // Silo, absolute episode 11 -- the first episode of season 2.
                catalog_id: 125988,
                episode: 11,
                title: None,
                prefer_dub: false,
                chosen_name: None,
                resume_fraction: None,
                preload: false,
            })
            .await
            .expect("resolve");
        println!("episode stream url: {} in {:?}", handle.url, started.elapsed());
        assert!(handle.url.starts_with("http://127.0.0.1:"));

        engine.playback_stopped().await;
        let _ = std::fs::remove_dir_all(&dir);
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn the_downloads_scan_adopts_what_it_can_identify_and_skips_the_rest() {
        let root = std::env::temp_dir().join("anicat-adopt-test");
        let _ = std::fs::remove_dir_all(&root);
        let show = root.join("An Archdemon's Dilemma - How to Love Your Elf Bride");
        std::fs::create_dir_all(&show).unwrap();
        std::fs::write(show.join("[Group] Archdemon - 03 [1080p].mkv"), b"x").unwrap();
        std::fs::write(show.join("[Group] Archdemon - 04 [1080p].mkv"), b"xx").unwrap();
        // No episode number anywhere in it.
        std::fs::write(show.join("cover art.jpg"), b"x").unwrap();
        // A folder for a title the app has never heard of.
        let stranger = root.join("Some Show Nobody Listed");
        std::fs::create_dir_all(&stranger).unwrap();
        std::fs::write(stranger.join("Some Show - 01.mkv"), b"x").unwrap();

        let hints = vec![FfiTitleHint {
            catalog: FfiCatalog::Anilist,
            catalog_id: 12345,
            // The punctuation differs from the folder, which is the point:
            // matching goes through the indexer's own normalisation.
            titles: vec!["An Archdemon's Dilemma: How to Love Your Elf Bride".to_string()],
        }];

        // Episode 3 is already indexed, so only 4 is new.
        let found = adoptable_downloads(&root, &hints, &[(12345, 3)]);
        assert_eq!(found.len(), 1, "one new episode, and nothing else");
        assert_eq!(found[0].episode, 4);
        assert_eq!(found[0].bytes, 2);

        // With nothing indexed, both episodes come back -- and still neither
        // the cover art nor the unknown title.
        let fresh = adoptable_downloads(&root, &hints, &[]);
        let mut episodes: Vec<i64> = fresh.iter().map(|f| f.episode).collect();
        episodes.sort();
        assert_eq!(episodes, vec![3, 4]);

        let _ = std::fs::remove_dir_all(&root);
    }

    #[test]
    fn eviction_takes_the_oldest_until_it_is_under_the_cap() {
        // Least recently used first, 10 MB each, cap of 25 MB.
        let mb = 1024 * 1024;
        let sizes = vec![(10 * mb, false), (10 * mb, false), (10 * mb, false)];
        // 30 over 25: one goes, and only one.
        assert_eq!(chapters_to_evict(&sizes, 25 * mb), vec![0]);
        // 30 over 15: two.
        assert_eq!(chapters_to_evict(&sizes, 15 * mb), vec![0, 1]);
        // Under the cap already: nothing is touched.
        assert_eq!(chapters_to_evict(&sizes, 30 * mb), Vec::<usize>::new());
    }

    #[test]
    fn the_chapter_being_read_survives_its_turn() {
        let mb = 1024 * 1024;
        // The oldest is the one open in the reader.
        let sizes = vec![(10 * mb, true), (10 * mb, false), (10 * mb, false)];
        assert_eq!(chapters_to_evict(&sizes, 15 * mb), vec![1, 2]);

        // And when it is the only thing left, the library stays over the cap
        // rather than deleting the pages on screen.
        let only_pinned = vec![(10 * mb, true)];
        assert_eq!(chapters_to_evict(&only_pinned, 1), Vec::<usize>::new());
    }

    #[test]
    fn a_cap_of_zero_is_no_cap() {
        // What "unlimited" is spelled as, so a viewer who wants everything
        // kept does not have to guess a large number.
        let sizes = vec![(u64::MAX / 2, false)];
        assert_eq!(chapters_to_evict(&sizes, u64::MAX), Vec::<usize>::new());
    }

    #[test]
    fn an_appearance_as_oneself_is_not_a_role() {
        // The forms TMDB actually writes for a talk-show booking.
        assert!(is_self_credit(Some("Self")));
        assert!(is_self_credit(Some("Self - Guest")));
        assert!(is_self_credit(Some("Himself")));
        assert!(is_self_credit(Some("Herself - Host")));
        assert!(is_self_credit(Some("self (archive footage)")));

        // Real parts, including one that starts with the same letters.
        assert!(!is_self_credit(Some("Juliette Nichols")));
        assert!(!is_self_credit(Some("Selfridge")));
        assert!(!is_self_credit(Some("Lady Jessica")));
        assert!(!is_self_credit(None));
    }

    #[test]
    fn studio_refs_lead_with_the_animation_studio() {
        let m: anilist::types::MediaItem = serde_json::from_str(
            r#"{
                "id": 1,
                "studios": {
                    "nodes": [{ "name": "Aniplex" }, { "name": "ufotable" }],
                    "edges": [
                        { "isMain": false, "node": { "id": 61, "name": "Aniplex" } },
                        { "isMain": true, "node": { "id": 43, "name": "ufotable" } },
                        { "isMain": false, "node": { "id": 1, "name": "Shueisha" } }
                    ]
                }
            }"#,
        )
        .unwrap();
        let refs = studio_refs(&m);
        assert_eq!(
            refs.iter().map(|s| s.id).collect::<Vec<_>>(),
            [43, 61, 1],
            "the main studio leads; the rest keep AniList's own order"
        );
        assert!(refs[0].is_main);
    }

    #[test]
    fn a_detail_row_cached_before_edges_existed_still_yields_a_studio_line() {
        // The exact shape of a `media_detail` cache row written by the build
        // before the query asked for `edges`: it has to keep deserializing,
        // and the header's single studio name has to survive.
        let m: anilist::types::MediaItem =
            serde_json::from_str(r#"{ "id": 1, "studios": { "nodes": [{ "name": "Bones" }] } }"#)
                .unwrap();
        assert!(studio_refs(&m).is_empty());
        assert_eq!(
            m.studios
                .as_ref()
                .and_then(|s| s.nodes.as_ref())
                .and_then(|n| n.first())
                .and_then(|s| s.name.as_deref()),
            Some("Bones")
        );
    }

    #[test]
    fn anilist_progress_marks_episodes_watched_with_no_local_history() {
        // The exact scenario this existed to fix: AniList says 10, this
        // device's registry has nothing at all.
        assert!(episode_is_watched(1, 0.0, false, Some(10)));
        assert!(episode_is_watched(10, 0.0, false, Some(10)));
        assert!(!episode_is_watched(11, 0.0, false, Some(10)));
    }

    #[test]
    fn local_history_alone_still_marks_watched_with_no_anilist_entry() {
        assert!(episode_is_watched(3, 90.0, false, None));
        assert!(!episode_is_watched(3, 40.0, false, None));
    }

    #[test]
    fn either_source_is_enough() {
        // Watched locally on this device (past 85%) but AniList hasn't
        // synced yet — still watched.
        assert!(episode_is_watched(5, 86.0, false, Some(2)));
        // Synced on AniList from elsewhere but not finished locally.
        assert!(episode_is_watched(5, 20.0, false, Some(5)));
    }

    #[test]
    fn a_rewatch_that_stops_early_does_not_unwatch_the_episode() {
        // 50 seconds into a 1420s episode already finished: the percentage
        // has collapsed to 3.5 and AniList is not there to cover for it
        // (a local-only title, or a signed-out device).
        assert!(!episode_is_watched(8, 3.5, false, None));
        assert!(episode_is_watched(8, 3.5, true, None));
    }

    fn progress(episode_number: i64, stop_time: i64, duration: i64) -> crate::db::service::WatchEntry {
        crate::db::service::WatchEntry { episode_number, stop_time, duration, completed: false }
    }

    #[test]
    fn resumes_into_furthest_unfinished_local_episode() {
        let history = vec![progress(1, 1200, 1400), progress(2, 300, 1400)];
        let resume = resume_episode(&history, None);
        assert_eq!(resume.map(|e| e.episode_number), Some(2));
    }

    #[test]
    fn stale_local_row_does_not_override_anilist_progress_already_past_it() {
        // The exact bug: episode 1 was started once and abandoned partway
        // through, but AniList says the show is caught up to episode 6 —
        // resuming into episode 1 forever would be wrong.
        let history = vec![progress(1, 300, 1400)];
        assert!(resume_episode(&history, Some(6)).is_none());
    }

    #[test]
    fn local_row_still_wins_when_anilist_has_not_caught_up_to_it() {
        // Watched further locally than AniList has synced — still resumable.
        let history = vec![progress(7, 300, 1400)];
        let resume = resume_episode(&history, Some(6));
        assert_eq!(resume.map(|e| e.episode_number), Some(7));
    }

    #[test]
    fn stray_incomplete_episode_far_past_progress_is_not_offered() {
        // The exact real-world bug: AniList says progress 9, but local
        // history has incomplete rows scattered from skipping/testing —
        // episodes 3, 7, 9, and a stray open of 12. `max_by_key` on episode
        // number alone picked 12 ("Continue Episode 12") even though the
        // viewer had only actually reached 9. Only `list_progress + 1` (10,
        // not present here) is a valid resume target once progress is known.
        let history = vec![
            progress(3, 290, 1432),
            progress(7, 28, 1420),
            progress(9, 649, 1420),
            progress(12, 328, 1432),
        ];
        assert!(resume_episode(&history, Some(9)).is_none());
    }

    #[test]
    fn only_the_episode_right_after_progress_is_a_valid_resume_target() {
        let history = vec![progress(3, 290, 1432), progress(10, 200, 1432)];
        let resume = resume_episode(&history, Some(9));
        assert_eq!(resume.map(|e| e.episode_number), Some(10));
    }

    #[test]
    fn finished_local_episode_is_not_a_resume_target() {
        let history = vec![progress(3, 1300, 1400)]; // 92.8%, past the 85% cutoff
        assert!(resume_episode(&history, None).is_none());
    }

    #[test]
    fn plain_anime_query_leaves_sort_unset_for_relevance() {
        let vars = build_search_variables(Some("Frieren"), Some("ANIME"), None, 1);
        assert_eq!(vars.get("search"), Some(&serde_json::json!("Frieren")));
        assert_eq!(vars.get("type"), Some(&serde_json::json!("ANIME")));
        assert_eq!(vars.get("sort"), None);
    }

    #[test]
    fn empty_query_defaults_search_to_null_and_sort_to_popularity() {
        let vars = build_search_variables(Some("   "), Some("ANIME"), None, 1);
        assert_eq!(vars.get("search"), Some(&serde_json::json!(null)));
        assert_eq!(vars.get("sort"), Some(&serde_json::json!(["POPULARITY_DESC"])));
    }

    #[test]
    fn novel_sets_type_manga_and_format_novel() {
        let vars = build_search_variables(Some("Slime"), Some("NOVEL"), None, 1);
        assert_eq!(vars.get("type"), Some(&serde_json::json!("MANGA")));
        assert_eq!(vars.get("format"), Some(&serde_json::json!(["NOVEL"])));
    }

    #[test]
    fn all_media_type_omits_type_variable() {
        let vars = build_search_variables(Some("Naruto"), Some("ALL"), None, 1);
        assert_eq!(vars.get("type"), None);
    }

    #[test]
    fn filters_thread_into_variables() {
        let filters = SearchFilters {
            genre: Some("Action".to_string()),
            year: Some(2024),
            min_score: Some(80),
            status: Some("RELEASING".to_string()),
            sort: Some("SCORE_DESC".to_string()),
            ..Default::default()
        };
        let vars = build_search_variables(None, Some("ANIME"), Some(&filters), 1);
        assert_eq!(vars.get("genre"), Some(&serde_json::json!(["Action"])));
        assert_eq!(vars.get("seasonYear"), Some(&serde_json::json!(2024)));
        assert_eq!(vars.get("averageScoreGreater"), Some(&serde_json::json!(80)));
        assert_eq!(vars.get("status"), Some(&serde_json::json!("RELEASING")));
        assert_eq!(vars.get("sort"), Some(&serde_json::json!(["SCORE_DESC"])));
    }

    #[test]
    fn season_rides_along_with_a_year() {
        let filters = SearchFilters {
            year: Some(2024),
            season: Some("WINTER".to_string()),
            ..Default::default()
        };
        let vars = build_search_variables(None, Some("ANIME"), Some(&filters), 1);
        // Scalar `MediaSeason`, not a list — `format_in` takes an array,
        // `season` does not, and the wrong shape only fails at the API.
        assert_eq!(vars.get("season"), Some(&serde_json::json!("WINTER")));
        assert_eq!(vars.get("seasonYear"), Some(&serde_json::json!(2024)));
    }

    #[test]
    fn season_without_a_year_is_dropped() {
        let filters = SearchFilters {
            season: Some("SUMMER".to_string()),
            ..Default::default()
        };
        let vars = build_search_variables(None, Some("ANIME"), Some(&filters), 1);
        assert_eq!(vars.get("season"), None);
    }

    #[test]
    fn format_filter_becomes_a_single_element_list() {
        let filters = SearchFilters {
            format: Some("MOVIE".to_string()),
            ..Default::default()
        };
        let vars = build_search_variables(Some("Ghibli"), Some("ANIME"), Some(&filters), 1);
        assert_eq!(vars.get("format"), Some(&serde_json::json!(["MOVIE"])));
    }

    #[test]
    fn novel_media_type_keeps_its_format_against_a_filter() {
        let filters = SearchFilters {
            format: Some("MANGA".to_string()),
            ..Default::default()
        };
        let vars = build_search_variables(Some("Slime"), Some("NOVEL"), Some(&filters), 1);
        assert_eq!(vars.get("type"), Some(&serde_json::json!("MANGA")));
        assert_eq!(vars.get("format"), Some(&serde_json::json!(["NOVEL"])));
    }

    #[test]
    fn relations_ignores_manga_for_anime_and_prefers_tv_season() {
        let m: crate::catalog::anilist::types::MediaItem = serde_json::from_value(serde_json::json!({
            "id": 10,
            "type": "ANIME",
            "format": "TV",
            "seasonYear": 2020,
            "relations": {
                "edges": [
                    {
                        "relationType": "PREQUEL",
                        "node": {
                            "id": 99,
                            "type": "MANGA",
                            "format": "MANGA",
                            "title": { "english": "Prequel Light Novel / Manga" }
                        }
                    },
                    {
                        "relationType": "PREQUEL",
                        "node": {
                            "id": 9,
                            "type": "ANIME",
                            "format": "TV",
                            "title": { "english": "Real Previous Season" }
                        }
                    },
                    {
                        "relationType": "SEQUEL",
                        "node": {
                            "id": 11,
                            "type": "ANIME",
                            "format": "OVA",
                            "title": { "english": "Side Story OVA" }
                        }
                    },
                    {
                        "relationType": "SEQUEL",
                        "node": {
                            "id": 12,
                            "type": "ANIME",
                            "format": "TV",
                            "title": { "english": "Next TV Season" }
                        }
                    }
                ]
            }
        })).unwrap();

        let (prequel, sequel) = relations(&m);
        assert_eq!(prequel.map(|p| p.catalog_id), Some(9));
        assert_eq!(sequel.map(|s| s.catalog_id), Some(12));
    }

    #[test]
    fn relations_picks_closest_year_among_same_format() {
        let m: crate::catalog::anilist::types::MediaItem = serde_json::from_value(serde_json::json!({
            "id": 20,
            "type": "ANIME",
            "format": "TV",
            "seasonYear": 2020,
            "relations": {
                "edges": [
                    {
                        "relationType": "SEQUEL",
                        "node": {
                            "id": 30,
                            "type": "ANIME",
                            "format": "TV",
                            "title": { "english": "Season 3" },
                            "startDate": { "year": 2024 }
                        }
                    },
                    {
                        "relationType": "SEQUEL",
                        "node": {
                            "id": 21,
                            "type": "ANIME",
                            "format": "TV",
                            "title": { "english": "Season 2" },
                            "startDate": { "year": 2021 }
                        }
                    }
                ]
            }
        })).unwrap();

        let (_, sequel) = relations(&m);
        // Season 2 (2021) is closer next season than Season 3 (2024)
        assert_eq!(sequel.map(|s| s.catalog_id), Some(21));
    }

    fn thread_comment_fixture() -> Vec<anilist::responses::ThreadCommentNode> {
        // Shaped like AniList's own reply blob: two levels of nesting, one
        // leaf whose `childComments` is null, and one reply that arrived
        // without an id.
        serde_json::from_value(serde_json::json!([
            {
                "id": 1,
                "comment": "top level",
                "createdAt": 1700000000,
                "likeCount": 4,
                "user": { "id": 7, "name": "aoi", "avatar": { "medium": "https://a/med.png", "large": "https://a/large.png" } },
                "childComments": [
                    {
                        "id": 2,
                        "comment": "reply",
                        "createdAt": 1700000100,
                        "likeCount": 1,
                        "user": { "id": 8, "name": "kenji", "avatar": { "large": "https://k/large.png" } },
                        "childComments": [
                            {
                                "id": 3,
                                "comment": "reply to the reply",
                                "createdAt": 1700000200,
                                "likeCount": 0,
                                "user": { "id": 7, "name": "aoi" },
                                "childComments": null
                            }
                        ]
                    },
                    {
                        "comment": "no id, and a subtree that dies with it",
                        "childComments": [ { "id": 99, "comment": "orphan" } ]
                    }
                ]
            },
            {
                "id": 4,
                "comment": "second top level",
                "createdAt": 1700000300,
                "likeCount": 0,
                "user": { "id": 9, "name": "mei", "avatar": { "medium": "https://m/med.png" } },
                "childComments": false
            }
        ]))
        .expect("fixture does not deserialize")
    }

    #[test]
    fn replies_flatten_in_reading_order_with_parent_and_depth() {
        let flat = flatten_thread_comments(thread_comment_fixture());
        // Pre-order: a comment, then its whole subtree, then the next one.
        // The id-less reply and its child are gone, so 4 of the 6 survive.
        let shape: Vec<(i64, Option<i64>, i32)> =
            flat.iter().map(|c| (c.id, c.parent_id, c.depth)).collect();
        assert_eq!(
            shape,
            vec![(1, None, 0), (2, Some(1), 1), (3, Some(2), 2), (4, None, 0)]
        );
    }

    #[test]
    fn a_reply_without_an_id_takes_its_subtree_with_it() {
        // Keeping the grandchild would have reparented it onto comment 1,
        // which is someone else's post.
        let flat = flatten_thread_comments(thread_comment_fixture());
        assert!(!flat.iter().any(|c| c.id == 99), "orphaned grandchild was kept");
    }

    #[test]
    fn a_non_array_child_comments_means_no_replies_not_a_failure() {
        // AniList sends `false` for a comment nobody replied to.
        let flat = flatten_thread_comments(thread_comment_fixture());
        assert_eq!(flat.iter().filter(|c| c.parent_id == Some(4)).count(), 0);
    }

    #[test]
    fn nested_reply_fields_survive_the_untyped_blob() {
        let flat = flatten_thread_comments(thread_comment_fixture());
        let reply = flat.iter().find(|c| c.id == 2).expect("reply 2 missing");
        assert_eq!(reply.body, "reply");
        assert_eq!(reply.author_name.as_deref(), Some("kenji"));
        // No medium avatar on this one, so the large one stands in.
        assert_eq!(reply.author_avatar_url.as_deref(), Some("https://k/large.png"));
        assert_eq!(reply.created_at, 1700000100);
        assert_eq!(reply.like_count, 1);

        // A reply whose user has no avatar object at all must not invent one.
        let leaf = flat.iter().find(|c| c.id == 3).expect("reply 3 missing");
        assert_eq!(leaf.author_avatar_url, None);
    }

    /// Live. `cargo test --lib ffi::tests -- --ignored --nocapture`
    ///
    /// The fixture tests above check this flattening against a blob this
    /// file wrote, which proves nothing about the key names inside
    /// `childComments`: AniList declares it as the untyped `Json` scalar, so
    /// unlike every other field in these three queries there is no schema to
    /// check `comment`/`createdAt`/`likeCount`/`user.name` against. A reply
    /// whose keys moved still flattens — into an empty body with no author —
    /// so this asserts one real reply survived intact.
    #[tokio::test]
    #[ignore]
    async fn live_replies_keep_their_fields_through_the_untyped_blob() {
        let catalogs = Catalogs::new(reqwest::Client::new(), None, None, None);
        let threads = catalogs.media_discussions(154587).await.expect("discussions");
        let thread_id = threads
            .iter()
            .max_by_key(|t| t.reply_count.unwrap_or(0))
            .map(|t| t.id)
            .expect("no discussion threads at all");
        let detail = catalogs.thread_detail(thread_id).await.expect("thread detail");
        let comments = detail.page.and_then(|p| p.thread_comments).unwrap_or_default();
        let flat = flatten_thread_comments(comments);
        println!("thread {thread_id}: {} comments once flattened", flat.len());
        match flat.iter().find(|c| c.depth >= 1) {
            Some(reply) => {
                assert!(
                    !reply.body.is_empty(),
                    "reply {} flattened to an empty body: the childComments key names moved",
                    reply.id
                );
                assert!(reply.author_name.is_some(), "reply {} lost its author", reply.id);
                assert!(reply.parent_id.is_some(), "reply {} has no parent", reply.id);
                println!("deepest reply: depth {} by {:?}", reply.depth, reply.author_name);
            }
            // Not a failure: a thread where nobody replied to anybody is a
            // perfectly ordinary thread. It just proves nothing here.
            None => println!("thread {thread_id} has no nested replies; key names unproven"),
        }
    }

    #[test]
    fn top_level_comments_prefer_the_medium_avatar() {
        // Matches `media_discussions`, which sizes thread rows the same way.
        let flat = flatten_thread_comments(thread_comment_fixture());
        let top = flat.first().expect("empty");
        assert_eq!(top.author_avatar_url.as_deref(), Some("https://a/med.png"));
        assert_eq!(top.like_count, 4);
    }
}

