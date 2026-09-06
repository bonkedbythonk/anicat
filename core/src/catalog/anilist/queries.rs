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
      name status isCustomList
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

/// One character's own page: who they are, and everywhere they appear.
///
/// `description` is asked for as markdown (`asHtml: false`), unlike
/// `MEDIA_CHARACTERS_QUERY` above — AniList bios are full of `~!spoiler!~`
/// and `__bold__` markers that only the client can decide how to reveal, and
/// the pre-parsed HTML has already thrown that structure away.
///
/// `media` caps at 25 per page server-side, so asking for more silently
/// returns 25 anyway.
pub const CHARACTER_DETAIL_QUERY: &str = r#"
query ($id: Int, $perPage: Int) {
  Character(id: $id) {
    id
    name { full native alternative }
    image { large }
    description(asHtml: false)
    gender
    age
    favourites
    dateOfBirth { year month day }
    media(sort: [POPULARITY_DESC], perPage: $perPage) {
      edges {
        characterRole
        node {
          id type format
          title { romaji english }
          coverImage { large medium }
          seasonYear
        }
        voiceActors(language: JAPANESE) { id name { full } image { medium large } languageV2 }
      }
    }
  }
}
"#;

/// One staff member's own page. Two separate credit lists because AniList
/// keeps them apart: `characterMedia` is where they voiced someone,
/// `staffMedia` is where they held a production role, and a person can be in
/// both for the same show.
///
/// Sorted newest-first as a filmography. The previous, unshipped version of
/// this query used POPULARITY_DESC on the grounds that it surfaces what an
/// actor is known for; the cost of START_DATE_DESC is that announced-but-
/// unaired titles lead the list. Both lists cap at 25 per page server-side.
pub const STAFF_DETAIL_QUERY: &str = r#"
query ($id: Int, $perPage: Int) {
  Staff(id: $id) {
    id
    name { full native }
    image { large }
    description(asHtml: false)
    languageV2
    primaryOccupations
    homeTown
    favourites
    characterMedia(perPage: $perPage, sort: [START_DATE_DESC]) {
      edges {
        characterRole
        node {
          id type format
          title { romaji english }
          coverImage { large medium }
          seasonYear
        }
        characters { id name { full } image { medium large } }
      }
    }
    staffMedia(perPage: $perPage, sort: [START_DATE_DESC]) {
      edges {
        staffRole
        node {
          id type format
          title { romaji english }
          coverImage { large medium }
          seasonYear
        }
      }
    }
  }
}
"#;

/// A forum thread and its first page of comments in one round trip.
///
/// `Thread` and `Page` are two roots of the same query rather than a nested
/// pair: `Thread` has no comment connection at all, and `threadComments`
/// only exists under `Page`.
pub const THREAD_DETAIL_QUERY: &str = r#"
query ($id: Int, $page: Int, $perPage: Int) {
  Thread(id: $id) {
    id
    title
    body(asHtml: false)
    createdAt
    replyCount
    viewCount
    isLocked
    categories { id name }
    user { id name avatar { medium large } }
  }
  Page(page: $page, perPage: $perPage) {
    pageInfo { total currentPage lastPage hasNextPage }
    threadComments(threadId: $id, sort: [ID]) {
      id
      comment(asHtml: false)
      createdAt
      likeCount
      childComments
      user { id name avatar { medium large } }
    }
  }
}
"#;

/// Page 2 and beyond of `THREAD_DETAIL_QUERY`'s comment half. Kept as its own
/// string rather than reusing that one with a page variable, so paging does
/// not refetch the thread body on every scroll.
pub const THREAD_COMMENTS_QUERY: &str = r#"
query ($id: Int, $page: Int, $perPage: Int) {
  Page(page: $page, perPage: $perPage) {
    pageInfo { total currentPage lastPage hasNextPage }
    threadComments(threadId: $id, sort: [ID]) {
      id
      comment(asHtml: false)
      createdAt
      likeCount
      childComments
      user { id name avatar { medium large } }
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

pub const MEDIA_REVIEWS_QUERY: &str = r#"
query ($mediaId: Int, $page: Int, $perPage: Int) {
  Media(id: $mediaId) {
    reviews(page: $page, perPage: $perPage, sort: [RATING_DESC, ID_DESC]) {
      pageInfo {
        total
        perPage
        currentPage
        lastPage
        hasNextPage
      }
      nodes {
        id
        summary
        body(asHtml: false)
        rating
        ratingAmount
        score
        user {
          id
          name
          avatar {
            large
            medium
          }
        }
        createdAt
        updatedAt
      }
    }
  }
}
"#;

pub const MEDIA_DISCUSSIONS_QUERY: &str = r#"
query ($id: Int) {
  Page(page: 1, perPage: 25) {
    threads(mediaCategoryId: $id, sort: [REPLIED_AT_DESC]) {
      id
      title
      replyCount
      viewCount
      repliedAt
      createdAt
      user {
        id
        name
        avatar {
          medium
          large
        }
      }
    }
  }
}
"#;

#[derive(Debug, Serialize)]
pub struct GraphQLRequest {
    pub query: String,
    pub variables: HashMap<String, serde_json::Value>,
}

