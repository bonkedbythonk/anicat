use serde::{Deserialize, Serialize};

#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct MediaTitle {
    pub romaji: Option<String>,
    pub english: Option<String>,
    pub native: Option<String>,
}

#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct MediaCoverImage {
    pub large: Option<String>,
    pub medium: Option<String>,
}

#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct FuzzyDate {
    pub year: Option<i32>,
    pub month: Option<i32>,
    pub day: Option<i32>,
}

#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct MediaStudioConnection {
    pub nodes: Option<Vec<MediaStudio>>,
    /// The same studios again, but carrying the id a studio page needs and
    /// the `isMain` flag that tells the animation studio from the rest of
    /// the production committee. `nodes` stays alongside it: the detail
    /// page's single `studio` string reads that, and every `media_detail`
    /// row already on disk was cached with only that shape.
    pub edges: Option<Vec<MediaStudioEdge>>,
}

#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct MediaStudioEdge {
    #[serde(rename = "isMain")]
    pub is_main: Option<bool>,
    pub node: Option<MediaStudio>,
}

#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct MediaStudio {
    pub id: Option<i64>,
    pub name: Option<String>,
}

/// One studio's own record, behind `STUDIO_DETAIL_QUERY`.
#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct StudioNode {
    pub id: i64,
    pub name: Option<String>,
    #[serde(rename = "isAnimationStudio")]
    pub is_animation_studio: Option<bool>,
    pub favourites: Option<i64>,
    pub media: Option<MediaNodeConnection>,
}

/// A media connection asked for as `nodes` rather than `edges`. `Studio.media`
/// and `Media.recommendations` both come back this way; `MediaConnection`
/// cannot read them because it only declares `edges`.
#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct MediaNodeConnection {
    pub nodes: Option<Vec<MediaItem>>,
}

#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct NextAiringEpisode {
    #[serde(rename = "airingAt")]
    pub airing_at: Option<i64>,
    pub episode: Option<i32>,
    #[serde(rename = "timeUntilAiring")]
    pub time_until_airing: Option<i64>,
}

#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct StreamingEpisode {
    pub title: Option<String>,
    pub thumbnail: Option<String>,
}

#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct MediaTrailer {
    pub id: Option<String>,
    pub site: Option<String>,
    pub thumbnail: Option<String>,
}

#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct MediaTag {
    pub name: String,
    pub rank: Option<i32>,
}

#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct MediaItem {
    pub id: i64,
    #[serde(alias = "idMal")]
    pub id_mal: Option<i64>,
    #[serde(rename = "type")]
    pub media_type: Option<String>,
    pub title: Option<MediaTitle>,
    #[serde(rename = "coverImage")]
    pub cover_image: Option<MediaCoverImage>,
    #[serde(rename = "bannerImage")]
    pub banner_image: Option<String>,
    pub description: Option<String>,
    pub format: Option<String>,
    pub status: Option<String>,
    pub season: Option<String>,
    #[serde(rename = "seasonYear")]
    pub season_year: Option<i32>,
    pub episodes: Option<i32>,
    pub chapters: Option<i32>,
    pub duration: Option<i32>,
    pub genres: Option<Vec<String>>,
    pub tags: Option<Vec<MediaTag>>,
    #[serde(rename = "averageScore")]
    pub average_score: Option<i32>,
    #[serde(rename = "meanScore")]
    pub mean_score: Option<i32>,
    pub popularity: Option<i32>,
    pub favourites: Option<i32>,
    #[serde(rename = "isFavourite")]
    pub is_favourite: Option<bool>,
    #[serde(rename = "isAdult")]
    pub is_adult: Option<bool>,
    pub trending: Option<i32>,
    pub studios: Option<MediaStudioConnection>,
    #[serde(rename = "startDate")]
    pub start_date: Option<FuzzyDate>,
    #[serde(rename = "endDate")]
    pub end_date: Option<FuzzyDate>,
    #[serde(rename = "nextAiringEpisode")]
    pub next_airing_episode: Option<NextAiringEpisode>,
    pub synonyms: Option<Vec<String>>,
    #[serde(alias = "streamingEpisodes")]
    pub streaming_episodes: Option<Vec<StreamingEpisode>>,
    pub trailer: Option<MediaTrailer>,
    #[serde(rename = "mediaListEntry")]
    pub media_list_entry: Option<MediaListEntry>,
    #[serde(rename = "siteUrl")]
    pub site_url: Option<String>,
    pub relations: Option<MediaConnection>,
    pub recommendations: Option<RecommendationConnection>,
}

#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct MediaConnection {
    pub edges: Option<Vec<MediaEdge>>,
}

/// AniList's own `MediaEdge`, which is reused for four different connections:
/// a title's relations, a character's appearances, and both of a staff
/// member's credit lists. Which fields are populated is decided by the query,
/// not by the type — `relation_type` is null on a character appearance and
/// `character_role` is null on a relation.
#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct MediaEdge {
    #[serde(rename = "relationType")]
    pub relation_type: Option<String>,
    pub node: Option<Box<MediaItem>>,
    #[serde(rename = "characterRole")]
    pub character_role: Option<String>,
    /// The staff member's production role, free text ("Director", "Key
    /// Animation") rather than an enum.
    #[serde(rename = "staffRole")]
    pub staff_role: Option<String>,
    /// On `Staff.characterMedia`: the characters this actor voiced in that
    /// title. Usually one, but a bit part can add several.
    pub characters: Option<Vec<CharacterNode>>,
    #[serde(rename = "voiceActors")]
    pub voice_actors: Option<Vec<StaffNode>>,
}

#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct RecommendationConnection {
    pub nodes: Option<Vec<RecommendationNode>>,
}

#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct RecommendationNode {
    pub rating: Option<i32>,
    #[serde(rename = "mediaRecommendation")]
    pub media_recommendation: Option<Box<MediaItem>>,
}

#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct MediaListEntry {
    pub id: Option<i64>,
    pub status: Option<String>,
    pub score: Option<f64>,
    pub progress: Option<i32>,
    #[serde(rename = "progressVolumes")]
    pub progress_volumes: Option<i32>,
    pub repeat: Option<i32>,
    pub private: Option<bool>,
    pub notes: Option<String>,
    /// Unix seconds. `MediaListCollection` sorts on it, and the Library view
    /// shows it as "updated 3d ago".
    #[serde(rename = "updatedAt")]
    pub updated_at: Option<i64>,
    #[serde(rename = "startedAt")]
    pub started_at: Option<FuzzyDate>,
    #[serde(rename = "completedAt")]
    pub completed_at: Option<FuzzyDate>,
}

#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct CharacterEdge {
    pub role: Option<String>,
    pub node: Option<CharacterNode>,
    #[serde(rename = "voiceActors")]
    pub voice_actors: Option<Vec<StaffNode>>,
}

#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct CharacterNode {
    pub id: i64,
    pub name: Option<StaffName>,
    pub image: Option<StaffImage>,
    pub description: Option<String>,
    /// A free-text range on AniList ("13-16"), not a number.
    pub age: Option<String>,
    pub gender: Option<String>,
    pub favourites: Option<i64>,
    #[serde(rename = "dateOfBirth")]
    pub date_of_birth: Option<FuzzyDate>,
    /// Only `CHARACTER_DETAIL_QUERY` asks for this; on a cast-list node it is
    /// absent. The cycle back through `MediaEdge::characters` is broken by
    /// the `Vec` on that side, so neither type needs boxing here.
    pub media: Option<MediaConnection>,
}

#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct StaffNode {
    pub id: i64,
    pub name: Option<StaffName>,
    pub image: Option<StaffImage>,
    /// AniList's deprecated `StaffLanguage` enum. `MEDIA_CHARACTERS_QUERY`
    /// still asks for it; newer queries ask for `language_v2`.
    pub language: Option<String>,
    #[serde(rename = "languageV2")]
    pub language_v2: Option<String>,
}

/// The full `Staff` record, as opposed to the name-and-portrait `StaffNode`
/// that a cast list embeds. Separate rather than more optional fields on
/// `StaffNode`, which is serialized into the cached cast list once per voice
/// actor per show.
#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct StaffDetailNode {
    pub id: i64,
    pub name: Option<StaffName>,
    pub image: Option<StaffImage>,
    pub description: Option<String>,
    #[serde(rename = "languageV2")]
    pub language_v2: Option<String>,
    #[serde(rename = "primaryOccupations")]
    pub primary_occupations: Option<Vec<String>>,
    #[serde(rename = "homeTown")]
    pub home_town: Option<String>,
    pub favourites: Option<i64>,
    /// Titles they voiced a character in.
    #[serde(rename = "characterMedia")]
    pub character_media: Option<MediaConnection>,
    /// Titles they held a production role on. A person can be in both lists
    /// for the same show.
    #[serde(rename = "staffMedia")]
    pub staff_media: Option<MediaConnection>,
}

#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct StaffName {
    pub full: Option<String>,
    pub native: Option<String>,
    /// Other names the person or character goes by. Shared with AniList's
    /// `CharacterName`, which is the same shape.
    pub alternative: Option<Vec<String>>,
}

#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct StaffImage {
    pub large: Option<String>,
    pub medium: Option<String>,
}

