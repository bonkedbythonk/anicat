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
    registry: Registry,
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
                AniListCache::persistent(&dir.join("catalog-cache.sqlite")),
            ),
            registry,
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
    pub fn has_anilist_token(&self) -> bool {
        self.catalogs.anilist.has_token()
    }

    pub async fn search_anime(&self, query: String) -> FfiResult<Vec<MediaSummary>> {
        self.search_catalog(Some(query), Some("ANIME".to_string()), None, None).await
    }

    pub async fn search_manga_catalog(&self, query: String) -> FfiResult<Vec<MediaSummary>> {
        self.search_catalog(Some(query), Some("MANGA".to_string()), None, None).await
    }

    pub async fn search_novel(&self, query: String) -> FfiResult<Vec<MediaSummary>> {
        self.search_catalog(Some(query), Some("NOVEL".to_string()), None, None).await
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

    /// Films and series matching a query, most popular first.
    pub async fn search_cinema(&self, query: String, limit: i32) -> FfiResult<Vec<MediaSummary>> {
        let items = self
            .catalogs
            .cinema_search(&query, limit.max(1) as i64)
            .await
            .map_err(|msg| AnicatError::Network { msg })?;
        Ok(items.iter().map(summarize_cinema).collect())
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
        if catalog != FfiCatalog::Anilist {
            return Err(AnicatError::NotFound {
                msg: format!("{:?} playback is not wired up yet", catalog),
            });
        }
        let media = MediaKey::new(catalog.into(), catalog_id);
        let info = crate::torrent::gather_media_info(&self.registry, &self.catalogs, media, title).await;
        if info.titles.is_empty() {
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
                    titles: &info.titles,
                    allow_episodeless: info.hint.kind == layout::EntryKind::Movie,
                    episode_count: info.episode_count,
                    aired_episodes: info.aired_episodes,
                    // The picker shows every release regardless of dub
                    // preference — that choice belongs to whoever is
                    // picking, not to the same default the auto-pick uses.
                    prefer_dub: preview_dub,
                    browser_client: false,
                    chosen_name: None,
                    movie: None,
                    series: None,
                    entry: info.hint,
                    sibling_titles: &info.siblings,
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
        if catalog != FfiCatalog::Anilist {
            return Err(AnicatError::NotFound {
                msg: format!("{:?} downloads are not wired up yet", catalog),
            });
        }
        let media = MediaKey::new(catalog.into(), catalog_id);
        let info = crate::torrent::gather_media_info(&self.registry, &self.catalogs, media, title.clone()).await;
        if info.titles.is_empty() {
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
                    titles: &info.titles,
                    allow_episodeless: info.hint.kind == layout::EntryKind::Movie,
                    episode_count: info.episode_count,
                    aired_episodes: info.aired_episodes,
                    prefer_dub,
                    browser_client: false,
                    chosen_name: None,
                    movie: None,
                    series: None,
                    entry: info.hint,
                    sibling_titles: &info.siblings,
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
        let display_title = title.unwrap_or_else(|| info.titles[0].clone());
        self.torrents.spawn_episode_download(&session, torrent_id, file_id, display_title);
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
        if catalog != FfiCatalog::Anilist {
            return FfiDownloadStatus::NotStarted;
        }
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
                is_watched: episode_is_watched(number, percent, list_progress),
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

    /// Wipes resume positions, provider overrides, the offline list mirror,
    /// and per-show prefs. Settings' "Clear Local Registry" action.
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
    pub fn watch_stats(&self, days: i32) -> FfiResult<FfiWatchStats> {
        let rows = self
            .registry
            .progress_rows()
            .map_err(|msg| AnicatError::Storage { msg })?;
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
        catalog_id: i64,
        audio_lang: Option<String>,
        subtitle_lang: Option<String>,
        subtitle_title: Option<String>,
    ) -> FfiResult<()> {
        self.registry
            .set_title_track_preference(
                Catalog::Anilist,
                catalog_id,
                &crate::db::service::TrackPreference { audio_lang, subtitle_lang, subtitle_title },
            )
            .map_err(|msg| AnicatError::Storage { msg })
    }

    pub fn title_track_preference(&self, catalog_id: i64) -> FfiResult<Option<FfiTrackPreference>> {
        let pref = self
            .registry
            .title_track_preference(Catalog::Anilist, catalog_id)
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
        let is_series = req.catalog == FfiCatalog::TmdbTv;
        let detail = self
            .catalogs
            .cinema_detail(req.catalog_id, is_series)
            .await
            .map_err(|msg| AnicatError::Network { msg })?;

        // Releases are named with either title TMDB carries -- an anime film
        // on a western indexer is as likely to be listed under its original
        // title as its english one -- and the page's own title goes in behind
        // both, because it may be showing a translation of either.
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
        push_title(&mut titles, req.title.clone());
        if titles.is_empty() {
            return Err(AnicatError::NotFound {
                msg: format!("no search titles for {media}"),
            });
        }

        let series_criteria = if is_series {
            let (season, episode) =
                crate::catalog::cinema::locate_episode(&season_map, req.episode.max(0) as u32)
                    .ok_or_else(|| AnicatError::NotFound {
                        msg: format!(
                            "episode {} is past the {} seasons TMDB lists for {media}",
                            req.episode,
                            season_map.len()
                        ),
                    })?;
            Some(crate::torrent::series::EpisodeCriteria {
                season,
                episode,
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
                    is_watched: episode_is_watched(number, percent, None),
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
                is_watched: episode_is_watched(1, percent, None),
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
fn episode_is_watched(number: i32, local_percent: f64, anilist_progress: Option<i32>) -> bool {
    local_percent >= 85.0 || anilist_progress.is_some_and(|p| number <= p)
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
mod tests {
    use super::*;

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
        assert!(episode_is_watched(1, 0.0, Some(10)));
        assert!(episode_is_watched(10, 0.0, Some(10)));
        assert!(!episode_is_watched(11, 0.0, Some(10)));
    }

    #[test]
    fn local_history_alone_still_marks_watched_with_no_anilist_entry() {
        assert!(episode_is_watched(3, 90.0, None));
        assert!(!episode_is_watched(3, 40.0, None));
    }

    #[test]
    fn either_source_is_enough() {
        // Watched locally on this device (past 85%) but AniList hasn't
        // synced yet — still watched.
        assert!(episode_is_watched(5, 86.0, Some(2)));
        // Synced on AniList from elsewhere but not finished locally.
        assert!(episode_is_watched(5, 20.0, Some(5)));
    }

    fn progress(episode_number: i64, stop_time: i64, duration: i64) -> crate::db::service::WatchEntry {
        crate::db::service::WatchEntry { episode_number, stop_time, duration }
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
        let catalogs = Catalogs::new(reqwest::Client::new(), None, None);
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

