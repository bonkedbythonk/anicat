use serde::Serialize;
use std::collections::HashMap;

pub const MEDIA_DETAIL_QUERY: &str = r#"
query ($id: Int, $type: MediaType) {
  Media(id: $id, type: $type) {
    id
    idMal
    type
    title { romaji english native }
    synonyms
    coverImage { large medium }
    bannerImage
    description
    format
    status
    season
    seasonYear
    episodes
    chapters
    duration
    genres
    averageScore
    meanScore
    popularity
    favourites
    isFavourite
    trending
    studios { nodes { name } }
    startDate { year month day }
    endDate { year month day }
    nextAiringEpisode { airingAt episode timeUntilAiring }
    streamingEpisodes { title thumbnail }
    trailer { id site thumbnail }
    siteUrl
    mediaListEntry {
      id status score progress progressVolumes repeat private notes
      startedAt { year month day } completedAt { year month day }
    }
    relations {
      edges {
        relationType(version: 2)
        node {
          id type
          title { romaji english }
          coverImage { large medium }
          format status averageScore
          startDate { year }
        }
      }
    }
    recommendations(page: 1, perPage: 10, sort: [RATING_DESC]) {
      nodes {
        rating
        mediaRecommendation {
          id type
          title { romaji english }
          coverImage { large medium }
          format status averageScore genres
        }
      }
    }
  }
}
"#;

pub const MEDIA_SEARCH_QUERY: &str = r#"
query ($page: Int, $perPage: Int, $search: String, $type: MediaType, $genre: [String], $seasonYear: Int, $season: MediaSeason, $format: [MediaFormat], $status: MediaStatus, $sort: [MediaSort], $isAdult: Boolean, $averageScoreGreater: Int) {
  Page(page: $page, perPage: $perPage) {
    media(search: $search, type: $type, genre_in: $genre, seasonYear: $seasonYear, season: $season, format_in: $format, status: $status, sort: $sort, isAdult: $isAdult, averageScore_greater: $averageScoreGreater) {
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
query ($userName: String, $type: MediaType, $status: MediaListStatus, $sort: [MediaListSort]) {
  MediaListCollection(userName: $userName, type: $type, status: $status, sort: $sort) {
    lists {
      name status
      entries {
        id status score progress progressVolumes repeat private notes
        updatedAt startedAt { year month day } completedAt { year month day }
        media {
          id type
          title { romaji english native }
          coverImage { large medium }
          bannerImage episodes chapters duration format status season seasonYear genres tags { name rank } averageScore meanScore
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
    id name about bannerImage siteUrl
    avatar { large medium }
    options { displayAdultContent }
    mediaListOptions { scoreFormat }
    statistics {
      anime { count episodesWatched minutesWatched meanScore genres(limit: 10, sort: COUNT_DESC) { genre count } }
      manga { count chaptersRead volumesRead meanScore genres(limit: 10, sort: COUNT_DESC) { genre count } }
    }
    favourites {
      anime(perPage: 20) {
        nodes { id type title { romaji english } coverImage { large medium } averageScore genres format }
      }
      manga(perPage: 20) {
        nodes { id type title { romaji english } coverImage { large medium } averageScore genres format }
      }
    }
  }
}
"#;

pub const HEALTH_CHECK_QUERY: &str = r#"
query {
  Viewer {
    name
  }
}
"#;

pub const USER_NOTIFICATIONS_QUERY: &str = r#"
query ($page: Int, $perPage: Int, $reset: Boolean) {
  Page(page: $page, perPage: $perPage) {
    notifications(resetNotificationCount: $reset, type_in: [AIRING, RELATED_MEDIA_ADDITION, MEDIA_DATA_CHANGE, MEDIA_MERGE]) {
      ... on AiringNotification {
        id type episode contexts createdAt
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

pub const TOGGLE_FAVOURITE_MUTATION: &str = r#"
mutation ($animeId: Int, $mangaId: Int) {
  ToggleFavourite(animeId: $animeId, mangaId: $mangaId) {
    anime { nodes { id } }
    manga { nodes { id } }
  }
}
"#;

pub const MEDIA_CHARACTERS_QUERY: &str = r#"
query ($id: Int, $page: Int, $perPage: Int) {
  Media(id: $id) {
    characters(page: $page, perPage: $perPage, sort: [ROLE, RELEVANCE]) {
      edges {
        role
        node {
          id
          name { full native }
          image { large }
          description(asHtml: true)
          age gender favourites
          dateOfBirth { year month day }
        }
        # Every language, not just Japanese: a dub viewer needs the English
        # cast, and the client decides which languages to surface.
        voiceActors(sort: [LANGUAGE, RELEVANCE]) { id name { full } image { large } language }
      }
    }
  }
}
"#;

/// A voice actor's roles, most popular show first — POPULARITY_DESC surfaces
/// what they are actually known for, where START_DATE_DESC would lead with
/// unaired announcements. Prolific actors have 500+ credits, hence the paging.
pub const STAFF_DETAIL_QUERY: &str = r#"
query ($id: Int, $page: Int, $perPage: Int) {
  Staff(id: $id) {
    id
    name { full native }
    image { large }
    description(asHtml: true)
    languageV2
    primaryOccupations
    age
    homeTown
    yearsActive
    favourites
    dateOfBirth { year month day }
    characterMedia(page: $page, perPage: $perPage, sort: [POPULARITY_DESC]) {
      pageInfo { hasNextPage total }
      edges {
        characterRole
        node {
          id type
          title { romaji english }
          coverImage { large medium }
          format status seasonYear averageScore
        }
        characters { id name { full } image { large } }
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

// Batched per-seed recommendations: fetches AniList's own "people who watched
// this also liked" edges for many seed titles in one round trip (Page.media
// accepts id_in), instead of one MEDIA_DETAIL_QUERY per seed. Feeds the local
// picker's candidate pool — trending/seasonal would only surface currently
// airing shows, which makes for a weak recommender.
pub const MEDIA_BATCH_RECOMMENDATIONS_QUERY: &str = r#"
query ($ids: [Int], $perPage: Int, $type: MediaType) {
  Page(page: 1, perPage: 50) {
    media(id_in: $ids, type: $type) {
      id
      recommendations(page: 1, perPage: $perPage, sort: [RATING_DESC]) {
        nodes {
          rating
          mediaRecommendation {
            id type
            title { romaji english native }
            coverImage { large medium }
            bannerImage format status season seasonYear episodes duration genres tags { name rank } averageScore meanScore
            mediaListEntry { id status score progress }
            siteUrl
          }
        }
      }
    }
  }
}
"#;

pub const AIRING_SCHEDULE_QUERY: &str = r#"
query ($page: Int, $perPage: Int, $airingAt_greater: Int, $airingAt_lesser: Int, $mediaId_in: [Int]) {
  Page(page: $page, perPage: $perPage) {
    airingSchedules(
      airingAt_greater: $airingAt_greater,
      airingAt_lesser: $airingAt_lesser,
      mediaId_in: $mediaId_in,
      sort: TIME
    ) {
      id airingAt episode
      media {
        id type
        title { romaji english }
        coverImage { large medium }
        bannerImage format status genres averageScore
        mediaListEntry { id status progress }
      }
    }
    pageInfo { total currentPage hasNextPage }
  }
}
"#;

#[derive(Debug, Serialize)]
pub struct GraphQLRequest {
    pub query: String,
    pub variables: HashMap<String, serde_json::Value>,
}
