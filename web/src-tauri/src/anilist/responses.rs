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

#[allow(dead_code)]
#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct SaveMediaListEntryResponse {
    #[serde(rename = "SaveMediaListEntry")]
    pub save_media_list_entry: Option<super::types::MediaListEntry>,
}

#[allow(dead_code)]
#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct DeleteMediaListEntryResponse {
    #[serde(rename = "DeleteMediaListEntry")]
    pub delete_media_list_entry: Option<DeleteResult>,
}

#[allow(dead_code)]
#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct DeleteResult {
    pub deleted: Option<bool>,
}

#[allow(dead_code)]
#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct UpdateProgressResponse {
    #[serde(rename = "SaveMediaListEntry")]
    pub save_media_list_entry: Option<ProgressResult>,
}

#[allow(dead_code)]
#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct ProgressResult {
    pub id: Option<i64>,
    pub progress: Option<i32>,
}

#[allow(dead_code)]
#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct ViewerResponse {
    #[serde(rename = "Viewer")]
    pub viewer: Option<super::types::Viewer>,
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
