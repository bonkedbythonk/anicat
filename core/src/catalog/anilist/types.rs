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
}

#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct MediaStudio {
    pub name: Option<String>,
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

#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct MediaEdge {
    #[serde(rename = "relationType")]
    pub relation_type: Option<String>,
    pub node: Option<Box<MediaItem>>,
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
}

#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct StaffNode {
    pub id: i64,
    pub name: Option<StaffName>,
    pub image: Option<StaffImage>,
    pub language: Option<String>,
}

#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct StaffName {
    pub full: Option<String>,
    pub native: Option<String>,
}

#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct StaffImage {
    pub large: Option<String>,
    pub medium: Option<String>,
}

