use serde::{Deserialize, Serialize};

#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct AnilistResponse<T> {
    pub data: Option<T>,
    pub errors: Option<Vec<GraphQLError>>,
}

#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct GraphQLError {
    pub message: String,
}

#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct PageResponse<T> {
    #[serde(rename = "Page")]
    pub page: Page<T>,
}

#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct Page<T> {
    pub media: Option<Vec<T>>,
    #[serde(rename = "pageInfo")]
    pub page_info: Option<PageInfo>,
}

#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct PageInfo {
    pub total: Option<i64>,
    #[serde(rename = "currentPage")]
    pub current_page: Option<i64>,
    #[serde(rename = "lastPage")]
    pub last_page: Option<i64>,
    #[serde(rename = "hasNextPage")]
    pub has_next_page: Option<bool>,
}

#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct MediaResponse {
    #[serde(rename = "Media")]
    pub media: Option<super::types::MediaItem>,
}

#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct CharacterResponse {
    #[serde(rename = "Media")]
    pub media: Option<CharacterWrapper>,
}

#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct CharacterWrapper {
    pub characters: Option<CharacterConnection>,
}

#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct CharacterConnection {
    pub edges: Option<Vec<super::types::CharacterEdge>>,
}

// --- MediaListCollection: the user's own lists -------------------------------

#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct MediaListCollectionResponse {
    #[serde(rename = "MediaListCollection")]
    pub media_list_collection: Option<MediaListCollection>,
}

#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct MediaListCollection {
    pub lists: Option<Vec<MediaListGroup>>,
}

#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct MediaListGroup {
    pub name: Option<String>,
    pub status: Option<String>,
    /// AniList repeats an entry under every custom list it belongs to, so a
    /// caller that does not skip these shows the same title several times.
    #[serde(rename = "isCustomList")]
    pub is_custom_list: Option<bool>,
    pub entries: Option<Vec<MediaListEntryRow>>,
}

/// One row of a list. The user's own progress lives here rather than inside
/// `media`, which is where every consumer of `MediaItem` looks for it — see
/// `Catalogs::user_list`, which moves it across.
#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct MediaListEntryRow {
    pub id: Option<i64>,
    pub status: Option<String>,
    pub score: Option<f64>,
    pub progress: Option<i32>,
    #[serde(rename = "progressVolumes")]
    pub progress_volumes: Option<i32>,
    pub repeat: Option<i32>,
    pub private: Option<bool>,
    pub notes: Option<String>,
    #[serde(rename = "updatedAt")]
    pub updated_at: Option<i64>,
    #[serde(rename = "startedAt")]
    pub started_at: Option<super::types::FuzzyDate>,
    #[serde(rename = "completedAt")]
    pub completed_at: Option<super::types::FuzzyDate>,
    pub media: Option<super::types::MediaItem>,
}

// --- Viewer: the signed-in user ---------------------------------------------

#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct ViewerResponse {
    #[serde(rename = "Viewer")]
    pub viewer: Option<Viewer>,
}

#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct Viewer {
    pub id: Option<i64>,
    pub name: Option<String>,
    pub about: Option<String>,
    pub avatar: Option<super::types::MediaCoverImage>,
    #[serde(rename = "bannerImage")]
    pub banner_image: Option<String>,
    #[serde(rename = "siteUrl")]
    pub site_url: Option<String>,
    pub statistics: Option<ViewerStatistics>,
}

#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct ViewerStatistics {
    pub anime: Option<AnimeStatistics>,
    pub manga: Option<MangaStatistics>,
}

#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct AnimeStatistics {
    pub count: Option<i64>,
    #[serde(rename = "episodesWatched")]
    pub episodes_watched: Option<i64>,
    #[serde(rename = "minutesWatched")]
    pub minutes_watched: Option<i64>,
    #[serde(rename = "meanScore")]
    pub mean_score: Option<f64>,
    pub genres: Option<Vec<GenreStat>>,
}

#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct MangaStatistics {
    pub count: Option<i64>,
    #[serde(rename = "chaptersRead")]
    pub chapters_read: Option<i64>,
    #[serde(rename = "volumesRead")]
    pub volumes_read: Option<i64>,
    #[serde(rename = "meanScore")]
    pub mean_score: Option<f64>,
    pub genres: Option<Vec<GenreStat>>,
}

#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct GenreStat {
    pub genre: Option<String>,
    pub count: Option<i64>,
}
