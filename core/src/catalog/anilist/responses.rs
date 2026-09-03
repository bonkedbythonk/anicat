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
