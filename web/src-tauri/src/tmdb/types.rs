//! TMDB's response shapes, and the translation into the app's own media shape.
//!
//! Cinema mode renders through the same components as anime, so TMDB results
//! are normalized into `anilist::types::MediaItem` here rather than given a
//! parallel type the frontend would have to branch on. The struct is the
//! app's internal media shape; that it is named after AniList is history.
//!
//! Two fields carry the difference:
//!
//! - `id` is banded through `media_id`, so a TMDB id can never be mistaken for
//!   an AniList one by anything downstream.
//! - `media_type` is left unset. AniList's own values are ANIME and MANGA, and
//!   inventing a third would make every consumer of that field wrong; the
//!   frontend asks `mediaSourceOf(id)` instead. `format` carries MOVIE or TV
//!   for display.

use serde::{Deserialize, Serialize};

use crate::anilist::types::{FuzzyDate, MediaCoverImage, MediaItem, MediaTitle};
use crate::media_id::{encode, MediaSource};

/// TMDB serves images from a CDN whose base is technically advertised by its
/// /configuration endpoint. In practice the host and the size buckets have
/// been stable for a decade, and spending a request per session to be told the
/// same string is not worth the startup cost.
const IMAGE_BASE: &str = "https://image.tmdb.org/t/p";

fn image_url(path: &Option<String>, size: &str) -> Option<String> {
    path.as_ref().map(|p| format!("{}/{}{}", IMAGE_BASE, size, p))
}

/// A TMDB date, always `YYYY-MM-DD` when present, sometimes an empty string
/// for titles with no announced date.
fn parse_date(raw: &Option<String>) -> Option<FuzzyDate> {
    let raw = raw.as_ref()?;
    let mut parts = raw.split('-');
    let year = parts.next()?.parse().ok()?;
    Some(FuzzyDate {
        year: Some(year),
        month: parts.next().and_then(|m| m.parse().ok()),
        day: parts.next().and_then(|d| d.parse().ok()),
    })
}

/// TMDB scores a title 0-10; AniList scores it 0-100, which is what every
/// score display in the app already expects.
fn percent_score(vote_average: Option<f64>) -> Option<i32> {
    let v = vote_average?;
    if v <= 0.0 {
        return None;
    }
    Some((v * 10.0).round() as i32)
}

#[derive(Debug, Clone, Deserialize, Serialize)]
pub struct TmdbPage<T> {
    pub page: Option<i64>,
    pub results: Option<Vec<T>>,
    pub total_pages: Option<i64>,
    pub total_results: Option<i64>,
}

/// One season, as the /tv/{id} detail response lists them. `episode_count` is
/// what the absolute numbering is built from, so seasons must be read in
/// `season_number` order and season 0 (specials) skipped — TMDB lists it
/// first, and counting it would shift every episode by the number of
/// specials.
#[derive(Debug, Clone, Deserialize, Serialize)]
pub struct TmdbSeason {
    pub season_number: Option<u32>,
    pub episode_count: Option<u32>,
    pub name: Option<String>,
    pub air_date: Option<String>,
}

/// One episode, from /tv/{id}/season/{n}.
#[derive(Debug, Clone, Deserialize, Serialize)]
pub struct TmdbEpisode {
    pub episode_number: Option<u32>,
    pub season_number: Option<u32>,
    pub name: Option<String>,
    pub overview: Option<String>,
    pub still_path: Option<String>,
    pub air_date: Option<String>,
    pub runtime: Option<i32>,
    pub vote_average: Option<f64>,
}

#[derive(Debug, Clone, Deserialize, Serialize)]
pub struct TmdbSeasonDetail {
    pub season_number: Option<u32>,
    pub episodes: Option<Vec<TmdbEpisode>>,
}

impl TmdbEpisode {
    /// Still frame url, sized for the episode strip.
    pub fn still_url(&self) -> Option<String> {
        image_url(&self.still_path, "w300")
    }
}

/// Cast and crew, from `append_to_response=credits`. TV uses
/// `aggregate_credits`, whose cast entries carry `roles` rather than a single
/// `character`; both are accepted so one struct covers each.
#[derive(Debug, Clone, Deserialize, Serialize)]
pub struct TmdbCredits {
    pub cast: Option<Vec<TmdbCastMember>>,
}

#[derive(Debug, Clone, Deserialize, Serialize)]
pub struct TmdbCastMember {
    pub id: Option<i64>,
    pub name: Option<String>,
    pub character: Option<String>,
    pub profile_path: Option<String>,
    pub order: Option<i64>,
}

impl TmdbCastMember {
    pub fn photo_url(&self) -> Option<String> {
        image_url(&self.profile_path, "w185")
    }
}

#[derive(Debug, Clone, Deserialize, Serialize)]
pub struct TmdbVideos {
    pub results: Option<Vec<TmdbVideo>>,
}

#[derive(Debug, Clone, Deserialize, Serialize)]
pub struct TmdbVideo {
    pub key: Option<String>,
    pub site: Option<String>,
    #[serde(rename = "type")]
    pub video_type: Option<String>,
    pub official: Option<bool>,
}

impl TmdbVideos {
    /// The one video worth offering: an official YouTube trailer, falling back
    /// to any YouTube trailer, then to a teaser. Anything else in this list is
    /// a featurette or a clip, which is not what a play button should open.
    pub fn best_trailer(&self) -> Option<String> {
        let results = self.results.as_ref()?;
        let youtube = |v: &&TmdbVideo| v.site.as_deref() == Some("YouTube") && v.key.is_some();
        let pick = |wanted: &str, official_only: bool| {
            results
                .iter()
                .filter(youtube)
                .find(|v| {
                    v.video_type.as_deref() == Some(wanted)
                        && (!official_only || v.official == Some(true))
                })
                .and_then(|v| v.key.clone())
        };
        pick("Trailer", true)
            .or_else(|| pick("Trailer", false))
            .or_else(|| pick("Teaser", false))
    }
}

/// From `append_to_response=images`. TMDB keys stills by language, including
/// a `null` bucket for logo-free/textless art; only that bucket and English
/// ones are worth showing without a translated-text mismatch.
#[derive(Debug, Clone, Deserialize, Serialize)]
pub struct TmdbImages {
    pub backdrops: Option<Vec<TmdbImage>>,
    pub posters: Option<Vec<TmdbImage>>,
}

#[derive(Debug, Clone, Deserialize, Serialize)]
pub struct TmdbImage {
    pub file_path: Option<String>,
    pub vote_average: Option<f64>,
    pub iso_639_1: Option<String>,
}

/// The gallery strip: backdrops first (they carry the most art, and are what
/// a first impression is made of), posters after. Cut to a sane count -- a
/// popular title can have 50+ backdrops, and past a screenful this is a
/// carousel, not a wall.
pub fn gallery_urls(images: Option<&TmdbImages>) -> Vec<String> {
    const MAX_IMAGES: usize = 12;
    let Some(images) = images else { return vec![] };
    let mut out = vec![];
    for img in images.backdrops.iter().flatten().chain(images.posters.iter().flatten()) {
        if out.len() >= MAX_IMAGES {
            break;
        }
        if let Some(url) = image_url(&img.file_path, "w780") {
            out.push(url);
        }
    }
    out
}

#[derive(Debug, Clone, Deserialize, Serialize)]
pub struct TmdbCompany {
    pub name: Option<String>,
}

#[derive(Debug, Clone, Deserialize, Serialize)]
pub struct TmdbGenre {
    pub id: Option<i64>,
    pub name: Option<String>,
}

/// One entry from a movie list or a movie detail. TMDB returns a superset on
/// the detail endpoint rather than a different shape, so one struct covers
/// both and the detail-only fields stay `None` in lists.
#[derive(Debug, Clone, Deserialize, Serialize)]
pub struct TmdbMovie {
    pub id: i64,
    pub title: Option<String>,
    pub original_title: Option<String>,
    pub overview: Option<String>,
    pub poster_path: Option<String>,
    pub backdrop_path: Option<String>,
    pub release_date: Option<String>,
    pub vote_average: Option<f64>,
    pub popularity: Option<f64>,
    /// Lists carry genre ids; details carry the named genres.
    pub genres: Option<Vec<TmdbGenre>>,
    pub runtime: Option<i32>,
    pub status: Option<String>,
    pub homepage: Option<String>,
    pub tagline: Option<String>,
    pub production_companies: Option<Vec<TmdbCompany>>,
    pub credits: Option<TmdbCredits>,
    pub videos: Option<TmdbVideos>,
    pub images: Option<TmdbImages>,
    pub recommendations: Option<TmdbPage<TmdbMovie>>,
}

/// One entry from a TV list or a TV detail. Same superset arrangement as
/// `TmdbMovie`, with TMDB's TV-side field names: `name` rather than `title`,
/// `first_air_date` rather than `release_date`.
#[derive(Debug, Clone, Deserialize, Serialize)]
pub struct TmdbSeries {
    pub id: i64,
    pub name: Option<String>,
    pub original_name: Option<String>,
    pub overview: Option<String>,
    pub poster_path: Option<String>,
    pub backdrop_path: Option<String>,
    pub first_air_date: Option<String>,
    pub last_air_date: Option<String>,
    pub vote_average: Option<f64>,
    pub popularity: Option<f64>,
    pub genres: Option<Vec<TmdbGenre>>,
    pub number_of_episodes: Option<i32>,
    pub number_of_seasons: Option<i32>,
    pub episode_run_time: Option<Vec<i32>>,
    pub status: Option<String>,
    pub homepage: Option<String>,
    pub seasons: Option<Vec<TmdbSeason>>,
    pub tagline: Option<String>,
    pub networks: Option<Vec<TmdbCompany>>,
    #[serde(alias = "aggregate_credits")]
    pub credits: Option<TmdbCredits>,
    pub videos: Option<TmdbVideos>,
    pub images: Option<TmdbImages>,
    pub recommendations: Option<TmdbPage<TmdbSeries>>,
}

fn genre_names(genres: &Option<Vec<TmdbGenre>>) -> Option<Vec<String>> {
    let list: Vec<String> = genres
        .as_ref()?
        .iter()
        .filter_map(|g| g.name.clone())
        .collect();
    if list.is_empty() {
        None
    } else {
        Some(list)
    }
}

/// A `MediaItem` with every field this app never fills for cinema titles left
/// empty, so each conversion below only states what it actually knows.
fn blank_item(id: i64) -> MediaItem {
    MediaItem {
        id,
        id_mal: None,
        media_type: None,
        title: None,
        cover_image: None,
        banner_image: None,
        description: None,
        format: None,
        status: None,
        season: None,
        season_year: None,
        episodes: None,
        chapters: None,
        duration: None,
        genres: None,
        tags: None,
        average_score: None,
        mean_score: None,
        popularity: None,
        favourites: None,
        is_favourite: None,
        trending: None,
        studios: None,
        start_date: None,
        end_date: None,
        next_airing_episode: None,
        synonyms: None,
        streaming_episodes: None,
        trailer: None,
        media_list_entry: None,
        site_url: None,
        relations: None,
        recommendations: None,
    }
}

/// TMDB's own status strings, mapped onto the vocabulary the app's status
/// badges already speak. Anything unrecognised is dropped rather than shown
/// raw, since a badge reading "Post Production" next to "RELEASING" would be
/// the only place in the app with two vocabularies.
fn map_status(raw: &Option<String>) -> Option<String> {
    let raw = raw.as_deref()?;
    let mapped = match raw {
        "Released" => "FINISHED",
        "Ended" => "FINISHED",
        "Canceled" | "Cancelled" => "CANCELLED",
        "Returning Series" => "RELEASING",
        "In Production" | "Post Production" | "Planned" | "Pilot" => "NOT_YET_RELEASED",
        _ => return None,
    };
    Some(mapped.to_string())
}

impl TmdbMovie {
    /// Returns `None` only if the id is too wide for its band, which no real
    /// TMDB id is.
    pub fn into_media_item(self) -> Option<MediaItem> {
        let start_date = parse_date(&self.release_date);
        Some(MediaItem {
            title: Some(MediaTitle {
                english: self.title.clone(),
                // The app prefers english and falls back to romaji, so the
                // original-language title belongs in the fallback slot.
                romaji: self.original_title.clone().or_else(|| self.title.clone()),
                native: None,
            }),
            cover_image: Some(MediaCoverImage {
                large: image_url(&self.poster_path, "w500"),
                medium: image_url(&self.poster_path, "w342"),
            }),
            banner_image: image_url(&self.backdrop_path, "w1280"),
            description: self.overview.clone(),
            format: Some("MOVIE".to_string()),
            status: map_status(&self.status),
            season_year: start_date.as_ref().and_then(|d| d.year),
            // A film is one sitting; treating it as a single episode is what
            // lets the existing player and history paths carry it unchanged.
            episodes: Some(1),
            duration: self.runtime,
            genres: genre_names(&self.genres),
            average_score: percent_score(self.vote_average),
            popularity: self.popularity.map(|p| p.round() as i32),
            start_date,
            site_url: self.homepage.clone(),
            ..blank_item(encode(MediaSource::TmdbMovie, self.id)?)
        })
    }
}

impl TmdbSeries {
    /// Episode counts per season, in season order, specials excluded.
    ///
    /// This is what turns the single absolute episode number the app stores
    /// into the SxxEyy a release name spells. Seasons with no episodes yet
    /// (announced but unaired) are dropped: counting a zero would be harmless,
    /// but a season TMDB has not filled in yet reports null rather than 0.
    pub fn season_map(&self) -> Vec<(u32, u32)> {
        let mut map: Vec<(u32, u32)> = self
            .seasons
            .as_ref()
            .map(|seasons| {
                seasons
                    .iter()
                    .filter_map(|s| {
                        let number = s.season_number?;
                        let count = s.episode_count?;
                        // Season 0 is specials. Including it would shift every
                        // absolute number by however many specials exist.
                        if number == 0 || count == 0 {
                            return None;
                        }
                        Some((number, count))
                    })
                    .collect()
            })
            .unwrap_or_default();
        map.sort_by_key(|(number, _)| *number);
        map
    }

    pub fn into_media_item(self) -> Option<MediaItem> {
        let start_date = parse_date(&self.first_air_date);
        Some(MediaItem {
            title: Some(MediaTitle {
                english: self.name.clone(),
                romaji: self.original_name.clone().or_else(|| self.name.clone()),
                native: None,
            }),
            cover_image: Some(MediaCoverImage {
                large: image_url(&self.poster_path, "w500"),
                medium: image_url(&self.poster_path, "w342"),
            }),
            banner_image: image_url(&self.backdrop_path, "w1280"),
            description: self.overview.clone(),
            format: Some("TV".to_string()),
            status: map_status(&self.status),
            season_year: start_date.as_ref().and_then(|d| d.year),
            episodes: self.number_of_episodes,
            // TMDB gives a list because a show's runtime can change between
            // seasons. The first entry is the one that describes the show as
            // it started, which is the closest thing to a single number.
            duration: self.episode_run_time.as_ref().and_then(|r| r.first().copied()),
            genres: genre_names(&self.genres),
            average_score: percent_score(self.vote_average),
            popularity: self.popularity.map(|p| p.round() as i32),
            start_date,
            end_date: parse_date(&self.last_air_date),
            site_url: self.homepage.clone(),
            ..blank_item(encode(MediaSource::TmdbTv, self.id)?)
        })
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::media_id::{decode, source_of};

    /// Trimmed from a real /3/movie/550 response: the fields this app reads,
    /// with TMDB's own spelling and types.
    const MOVIE_JSON: &str = r#"{
        "id": 550,
        "title": "Fight Club",
        "original_title": "Fight Club",
        "overview": "A ticking-time-bomb insomniac...",
        "poster_path": "/pB8BM7pdSp6B6Ih7QZ4DrQ3PmJK.jpg",
        "backdrop_path": "/hZkgoQYus5vegHoetLkCJzb17zJ.jpg",
        "release_date": "1999-10-15",
        "vote_average": 8.4,
        "popularity": 61.4,
        "runtime": 139,
        "status": "Released",
        "genres": [{"id": 18, "name": "Drama"}]
    }"#;

    /// Trimmed from a real /3/tv/1396 response.
    const SERIES_JSON: &str = r#"{
        "id": 1396,
        "name": "Breaking Bad",
        "original_name": "Breaking Bad",
        "overview": "Walter White, a New Mexico chemistry teacher...",
        "poster_path": "/ggFHVNu6YYI5L9pCfOacjizRGt.jpg",
        "backdrop_path": "/tsRy63Mu5cu8etL1X7ZLyf7UP1M.jpg",
        "first_air_date": "2008-01-20",
        "last_air_date": "2013-09-29",
        "vote_average": 8.9,
        "popularity": 291.3,
        "number_of_episodes": 62,
        "number_of_seasons": 5,
        "episode_run_time": [45, 47],
        "status": "Ended",
        "genres": [{"id": 18, "name": "Drama"}, {"id": 80, "name": "Crime"}]
    }"#;

    #[test]
    fn a_movie_becomes_a_media_item_the_existing_components_can_render() {
        let movie: TmdbMovie = serde_json::from_str(MOVIE_JSON).unwrap();
        let item = movie.into_media_item().unwrap();

        assert_eq!(item.title.as_ref().unwrap().english.as_deref(), Some("Fight Club"));
        assert_eq!(
            item.cover_image.as_ref().unwrap().large.as_deref(),
            Some("https://image.tmdb.org/t/p/w500/pB8BM7pdSp6B6Ih7QZ4DrQ3PmJK.jpg")
        );
        assert_eq!(item.description.as_deref(), Some("A ticking-time-bomb insomniac..."));
        assert_eq!(item.format.as_deref(), Some("MOVIE"));
        assert_eq!(item.status.as_deref(), Some("FINISHED"));
        assert_eq!(item.average_score, Some(84));
        assert_eq!(item.duration, Some(139));
        assert_eq!(item.episodes, Some(1));
        assert_eq!(item.season_year, Some(1999));
        assert_eq!(item.genres.as_deref(), Some(&["Drama".to_string()][..]));
        let d = item.start_date.as_ref().unwrap();
        assert_eq!((d.year, d.month, d.day), (Some(1999), Some(10), Some(15)));
    }

    #[test]
    fn a_series_becomes_a_media_item_with_its_episode_count() {
        let series: TmdbSeries = serde_json::from_str(SERIES_JSON).unwrap();
        let item = series.into_media_item().unwrap();

        assert_eq!(item.title.as_ref().unwrap().english.as_deref(), Some("Breaking Bad"));
        assert_eq!(item.format.as_deref(), Some("TV"));
        assert_eq!(item.status.as_deref(), Some("FINISHED"));
        assert_eq!(item.episodes, Some(62));
        // The runtime list is per-season; the first entry describes the show
        // as it began.
        assert_eq!(item.duration, Some(45));
        assert_eq!(item.average_score, Some(89));
        assert_eq!(item.end_date.as_ref().unwrap().year, Some(2013));
    }

    #[test]
    fn the_id_is_banded_so_nothing_downstream_confuses_it_with_anilist() {
        let movie: TmdbMovie = serde_json::from_str(MOVIE_JSON).unwrap();
        let series: TmdbSeries = serde_json::from_str(SERIES_JSON).unwrap();
        let movie_item = movie.into_media_item().unwrap();
        let series_item = series.into_media_item().unwrap();

        assert_eq!(source_of(movie_item.id), MediaSource::TmdbMovie);
        assert_eq!(decode(movie_item.id), (MediaSource::TmdbMovie, 550));
        assert_eq!(source_of(series_item.id), MediaSource::TmdbTv);
        // AniList 550 exists and is not Fight Club.
        assert_ne!(movie_item.id, 550);
    }

    #[test]
    fn media_type_stays_unset_rather_than_claiming_a_third_anilist_value() {
        let movie: TmdbMovie = serde_json::from_str(MOVIE_JSON).unwrap();
        assert_eq!(movie.into_media_item().unwrap().media_type, None);
    }

    #[test]
    fn a_list_entry_missing_every_detail_only_field_still_converts() {
        // What a /trending or /search result actually looks like: no runtime,
        // no status, no named genres.
        let bare: TmdbMovie = serde_json::from_str(
            r#"{"id": 27205, "title": "Inception", "poster_path": null, "vote_average": 0}"#,
        )
        .unwrap();
        let item = bare.into_media_item().unwrap();
        assert_eq!(item.title.as_ref().unwrap().english.as_deref(), Some("Inception"));
        assert_eq!(item.cover_image.as_ref().unwrap().large, None);
        assert_eq!(item.status, None);
        assert_eq!(item.genres, None);
        // A zero vote average means unrated, not a score of zero.
        assert_eq!(item.average_score, None);
        assert!(item.start_date.is_none());
    }

    #[test]
    fn an_unmapped_tmdb_status_is_dropped_rather_than_shown_raw() {
        assert_eq!(map_status(&Some("Rumored".into())), None);
        assert_eq!(map_status(&Some("Returning Series".into())).as_deref(), Some("RELEASING"));
        assert_eq!(map_status(&Some("Canceled".into())).as_deref(), Some("CANCELLED"));
    }

    #[test]
    fn a_page_of_results_parses_with_its_paging_fields() {
        let page: TmdbPage<TmdbMovie> = serde_json::from_str(
            r#"{"page": 1, "results": [{"id": 550, "title": "Fight Club"}],
                "total_pages": 42, "total_results": 831}"#,
        )
        .unwrap();
        assert_eq!(page.page, Some(1));
        assert_eq!(page.total_pages, Some(42));
        assert_eq!(page.results.unwrap().len(), 1);
    }
}
