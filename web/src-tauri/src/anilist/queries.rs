use serde::{Deserialize, Serialize};
use std::collections::HashMap;

pub const MEDIA_DETAIL_QUERY: &str = r#"
query ($id: Int, $type: MediaType, $isAdult: Boolean) {
  Media(id: $id, type: $type) {
    id
    type
    title { romaji english native }
    coverImage { large medium }
    bannerImage
    description
    format
    status
    season
    seasonYear
    episodes
    duration
    genres
    averageScore
    meanScore
    popularity
    favourites
    trending
    studios { nodes { name } }
    startDate { year month day }
    endDate { year month day }
    nextAiringEpisode { airingAt episode timeUntilAiring }
    trailer { id site thumbnail }
    siteUrl
    mediaListEntry {
      id status score progress progressVolumes repeat private notes
      startedAt { year month day } completedAt { year month day }
    }
  }
}
"#;

pub const MEDIA_SEARCH_QUERY: &str = r#"
query ($page: Int, $perPage: Int, $search: String, $type: MediaType, $genre: [String], $seasonYear: Int, $season: MediaSeason, $format: [MediaFormat], $status: MediaStatus, $sort: [MediaSort], $isAdult: Boolean) {
  Page(page: $page, perPage: $perPage) {
    media(search: $search, type: $type, genre_in: $genre, seasonYear: $seasonYear, season: $season, format_in: $format, status: $status, sort: $sort, isAdult: $isAdult) {
      id type
      title { romaji english native }
      coverImage { large medium }
      bannerImage description format status season seasonYear episodes duration genres averageScore meanScore popularity favourites trending
      startDate { year month day } endDate { year month day }
      nextAiringEpisode { airingAt episode timeUntilAiring }
      mediaListEntry { id status score progress }
      siteUrl
    }
    pageInfo { total currentPage lastPage hasNextPage }
  }
}
"#;

pub const MEDIA_TRENDING_QUERY: &str = r#"
query ($page: Int, $perPage: Int, $type: MediaType, $isAdult: Boolean) {
  Page(page: $page, perPage: $perPage) {
    media(sort: [TRENDING_DESC, POPULARITY_DESC], type: $type, isAdult: $isAdult) {
      id type
      title { romaji english native }
      coverImage { large medium }
      bannerImage format status season seasonYear episodes duration genres averageScore meanScore popularity favourites trending
      nextAiringEpisode { airingAt episode timeUntilAiring }
      mediaListEntry { id status score progress }
      siteUrl
    }
    pageInfo { total currentPage lastPage hasNextPage }
  }
}
"#;

pub const MEDIA_SEASONAL_QUERY: &str = r#"
query ($page: Int, $perPage: Int, $season: MediaSeason, $seasonYear: Int, $type: MediaType, $isAdult: Boolean) {
  Page(page: $page, perPage: $perPage) {
    media(season: $season, seasonYear: $seasonYear, type: $type, sort: [POPULARITY_DESC], isAdult: $isAdult) {
      id type
      title { romaji english native }
      coverImage { large medium }
      bannerImage format status season seasonYear episodes duration genres averageScore meanScore popularity favourites trending
      nextAiringEpisode { airingAt episode timeUntilAiring }
      mediaListEntry { id status score progress }
      siteUrl
    }
    pageInfo { total currentPage lastPage hasNextPage }
  }
}
"#;

pub const MEDIA_UPCOMING_QUERY: &str = r#"
query ($page: Int, $perPage: Int, $type: MediaType, $isAdult: Boolean) {
  Page(page: $page, perPage: $perPage) {
    media(status: NOT_YET_RELEASED, type: $type, sort: [POPULARITY_DESC], isAdult: $isAdult) {
      id type
      title { romaji english native }
      coverImage { large medium }
      bannerImage format status season seasonYear episodes duration genres averageScore meanScore popularity favourites trending
      nextAiringEpisode { airingAt episode timeUntilAiring }
      mediaListEntry { id status score progress }
      siteUrl
    }
    pageInfo { total currentPage lastPage hasNextPage }
  }
}
"#;

pub const USER_LIST_QUERY: &str = r#"
query ($userId: Int, $userName: String, $type: MediaType, $status: MediaListStatus, $sort: [MediaListSort]) {
  MediaListCollection(userId: $userId, userName: $userName, type: $type, status: $status, sort: $sort) {
    lists {
      name status
      entries {
        id status score progress progressVolumes repeat private notes
        startedAt { year month day } completedAt { year month day }
        media {
          id type
          title { romaji english native }
          coverImage { large medium }
          bannerImage episodes chapters duration format status season seasonYear genres averageScore meanScore
          nextAiringEpisode { airingAt episode timeUntilAiring }
        }
      }
    }
  }
}
"#;

pub const USER_PROFILE_QUERY: &str = r#"
query {
  Viewer {
    id name about
    avatar { large medium }
    bannerImage
    options { displayAdultContent }
    statistics {
      anime { count meanScore minutesWatched episodesWatched }
    }
  }
}
"#;

pub const USER_NOTIFICATIONS_QUERY: &str = r#"
query ($page: Int, $perPage: Int) {
  Page(page: $page, perPage: $perPage) {
    notifications {
      ... on AiringNotification {
        id type episode contexts createdAt
        media { id type title { romaji english native } coverImage { large medium } }
      }
      ... on FollowingNotification {
        id type context createdAt
        media { id type title { romaji english native } coverImage { large medium } }
      }
      ... on ActivityMessageNotification {
        id type context createdAt
        media { id type title { romaji english native } coverImage { large medium } }
      }
      ... on ActivityMentionNotification {
        id type context createdAt
        media { id type title { romaji english native } coverImage { large medium } }
      }
      ... on ActivityReplyNotification {
        id type context createdAt
        media { id type title { romaji english native } coverImage { large medium } }
      }
      ... on ActivityReplySubscribedNotification {
        id type context createdAt
        media { id type title { romaji english native } coverImage { large medium } }
      }
      ... on ActivityLikeNotification {
        id type context createdAt
        media { id type title { romaji english native } coverImage { large medium } }
      }
      ... on ActivityReplyLikeNotification {
        id type context createdAt
        media { id type title { romaji english native } coverImage { large medium } }
      }
      ... on ThreadCommentMentionNotification {
        id type context createdAt
        media { id type title { romaji english native } coverImage { large medium } }
      }
      ... on ThreadCommentReplyNotification {
        id type context createdAt
        media { id type title { romaji english native } coverImage { large medium } }
      }
      ... on ThreadCommentSubscribedNotification {
        id type context createdAt
        media { id type title { romaji english native } coverImage { large medium } }
      }
      ... on ThreadCommentLikeNotification {
        id type context createdAt
        media { id type title { romaji english native } coverImage { large medium } }
      }
      ... on ThreadLikeNotification {
        id type context createdAt
        media { id type title { romaji english native } coverImage { large medium } }
      }
      ... on RelatedMediaAdditionNotification {
        id type context createdAt
        media { id type title { romaji english native } coverImage { large medium } }
      }
      ... on MediaDataChangeNotification {
        id type context createdAt
        media { id type title { romaji english native } coverImage { large medium } }
      }
      ... on MediaMergeNotification {
        id type context createdAt
        media { id type title { romaji english native } coverImage { large medium } }
      }
      ... on MediaDeletionNotification {
        id type context createdAt deletedMediaTitle
      }
    }
    pageInfo { total currentPage lastPage hasNextPage }
  }
}
"#;

pub const SAVE_MEDIA_LIST_ENTRY_MUTATION: &str = r#"
mutation ($mediaId: Int, $status: MediaListStatus, $score: Float, $progress: Int, $progressVolumes: Int, $repeat: Int, $private: Boolean, $notes: String, $startedAt: FuzzyDateInput, $completedAt: FuzzyDateInput) {
  SaveMediaListEntry(mediaId: $mediaId, status: $status, score: $score, progress: $progress, progressVolumes: $progressVolumes, repeat: $repeat, private: $private, notes: $notes, startedAt: $startedAt, completedAt: $completedAt) {
    id status score progress progressVolumes repeat private notes
    startedAt { year month day } completedAt { year month day }
  }
}
"#;

pub const DELETE_MEDIA_LIST_ENTRY_MUTATION: &str = r#"
mutation ($id: Int) {
  DeleteMediaListEntry(id: $id) { deleted }
}
"#;

pub const MEDIA_CHARACTERS_QUERY: &str = r#"
query ($id: Int, $page: Int, $perPage: Int) {
  Media(id: $id) {
    characters(page: $page, perPage: $perPage, sort: [ROLE, RELEVANCE]) {
      edges {
        role
        node { id name { full } image { large } }
        voiceActors(language: JAPANESE) { id name { full } image { large } language }
      }
    }
  }
}
"#;

pub const SMART_PLAYLIST_QUERY: &str = r#"
query ($genre: [String], $format: MediaFormat, $status: MediaStatus, $seasonYear: Int, $season: MediaSeason, $sort: [MediaSort], $isAdult: Boolean) {
  Page(page: 1, perPage: 8) {
    media(genre_in: $genre, format: $format, status: $status, seasonYear: $seasonYear, season: $season, sort: $sort, type: ANIME, isAdult: $isAdult) {
      id type
      title { romaji english native }
      coverImage { large medium }
      bannerImage format status season seasonYear episodes duration genres averageScore meanScore
      mediaListEntry { id status }
      siteUrl
    }
  }
}
"#;

#[derive(Debug, Serialize)]
pub struct GraphQLRequest {
    pub query: String,
    pub variables: HashMap<String, serde_json::Value>,
}
