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

#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct DiscussionResponse {
    #[serde(rename = "Page")]
    pub page: DiscussionPage,
}

#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct DiscussionPage {
    pub threads: Option<Vec<DiscussionThreadItem>>,
}

#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct DiscussionThreadItem {
    pub id: i64,
    pub title: String,
    #[serde(rename = "replyCount")]
    pub reply_count: Option<i32>,
    #[serde(rename = "viewCount")]
    pub view_count: Option<i32>,
    #[serde(rename = "repliedAt")]
    pub replied_at: Option<i64>,
    #[serde(rename = "createdAt")]
    pub created_at: Option<i64>,
    pub user: Option<DiscussionUser>,
}

#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct DiscussionUser {
    pub id: Option<i64>,
    pub name: Option<String>,
    pub avatar: Option<super::types::StaffImage>,
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
    pub favourites: Option<FavouritesConnection>,
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

#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct FavouritesConnection {
    pub anime: Option<FavouriteMediaConnection>,
    pub manga: Option<FavouriteMediaConnection>,
}

#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct FavouriteMediaConnection {
    pub nodes: Option<Vec<super::types::MediaItem>>,
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn viewer_deserializes_favourites_nodes() {
        let json = r#"{
            "Viewer": {
                "id": 42,
                "name": "Taro",
                "favourites": {
                    "anime": {
                        "nodes": [
                            {
                                "id": 1,
                                "type": "ANIME",
                                "title": { "romaji": "Cowboy Bebop", "english": "Cowboy Bebop" },
                                "coverImage": { "large": "https://img.large", "medium": "https://img.med" },
                                "averageScore": 86,
                                "genres": ["Action", "Sci-Fi"],
                                "format": "TV"
                            }
                        ]
                    },
                    "manga": {
                        "nodes": [
                            {
                                "id": 2,
                                "type": "MANGA",
                                "title": { "romaji": "Berserk", "english": null },
                                "coverImage": { "large": "https://manga.large", "medium": null },
                                "averageScore": 93,
                                "genres": ["Action", "Dark Fantasy"],
                                "format": "MANGA"
                            }
                        ]
                    }
                }
            }
        }"#;
        let res: ViewerResponse = serde_json::from_str(json).expect("failed to deserialize ViewerResponse");
        let viewer = res.viewer.expect("viewer missing");
        let favs = viewer.favourites.expect("favourites missing");
        let anime_nodes = favs.anime.expect("anime missing").nodes.expect("anime nodes missing");
        assert_eq!(anime_nodes.len(), 1);
        assert_eq!(anime_nodes[0].id, 1);
        assert_eq!(anime_nodes[0].average_score, Some(86));

        let manga_nodes = favs.manga.expect("manga missing").nodes.expect("manga nodes missing");
        assert_eq!(manga_nodes.len(), 1);
        assert_eq!(manga_nodes[0].id, 2);
        assert_eq!(manga_nodes[0].format.as_deref(), Some("MANGA"));
    }
}
