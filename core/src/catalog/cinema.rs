//! Cinema mode's catalog reads: TMDB rows, search, detail and episodes.
//!
//! A sibling of the AniList calls in `mod.rs` rather than a branch inside
//! them. Everything here answers in `MediaItem` — the same shape the anime
//! path already returns — because the whole point of `TmdbMovie`/`TmdbSeries`
//! carrying an `into_media_item` is that the FFI layer, the cards, the detail
//! page and the caches downstream never learn which catalog a title came
//! from. What they do carry is the `Catalog`, which `MediaKey` keeps beside
//! the id.
//!
//! TMDB's own responses are cached under the four `tmdb_*` TTLs `cache.rs`
//! already declares. Rows expire in six hours, a detail in a day: TMDB
//! rewrites a popularity ranking far more often than it rewrites a film.

use serde::de::DeserializeOwned;
use serde::Serialize;

use super::cache::AniListCache;
use super::tmdb::types::{TmdbMovie, TmdbPage, TmdbSeasonDetail, TmdbSeries};
use super::Catalogs;
use crate::catalog::anilist::types::MediaItem;

/// The home rows cinema mode draws, in the order the home page lists them.
///
/// Kept as data rather than as one function per row: the Swift side asks for
/// a row by name, and a name it does not know about is a caller error worth
/// an error string, not a silently empty shelf.
pub const CINEMA_ROWS: &[&str] = &[
    "trending_movies",
    "trending_series",
    "popular_movies",
    "popular_series",
    "top_movies",
    "top_series",
    "upcoming_movies",
    "airing_series",
];

/// TMDB endpoint and whether it answers with series rather than films.
fn row_endpoint(kind: &str) -> Option<(&'static str, bool)> {
    Some(match kind {
        "trending_movies" => ("/trending/movie/week", false),
        "trending_series" => ("/trending/tv/week", true),
        "popular_movies" => ("/movie/popular", false),
        "popular_series" => ("/tv/popular", true),
        "top_movies" => ("/movie/top_rated", false),
        "top_series" => ("/tv/top_rated", true),
        "upcoming_movies" => ("/movie/upcoming", false),
        "airing_series" => ("/tv/on_the_air", true),
        _ => return None,
    })
}

/// Everything a detail page needs about one film or series, plus the flat
/// episode list a series' seasons collapse into.
pub struct CinemaDetail {
    pub movie: Option<TmdbMovie>,
    pub series: Option<TmdbSeries>,
    /// Absolute-numbered, specials excluded, in season order. Empty for a
    /// film — `into_media_item` already reports one episode for it, and the
    /// player treats that single sitting as episode 1.
    pub episodes: Vec<CinemaEpisode>,
}

/// One episode, already carrying the absolute number the registry and the
/// resolve path key on, alongside the season/episode pair a release name
/// actually spells.
pub struct CinemaEpisode {
    pub absolute: u32,
    pub season: u32,
    pub episode: u32,
    pub title: Option<String>,
    pub overview: Option<String>,
    pub still_url: Option<String>,
    pub air_date: Option<String>,
    pub runtime_minutes: Option<i32>,
}

impl Catalogs {
    /// Whether a TMDB credential is present at all. Cinema mode is hidden
    /// rather than shown broken when it is not: every call below fails with
    /// `no_tmdb_token`, and eight empty shelves explain nothing.
    pub fn has_tmdb_key(&self) -> bool {
        self.tmdb.has_token()
    }

    /// A cached TMDB GET. The cache holds the parsed response as JSON, so a
    /// hit costs a `from_value` and no request.
    async fn tmdb_cached<T>(
        &self,
        key: String,
        cache_kind: &str,
        path: &str,
        query: &[(&str, String)],
    ) -> Result<T, String>
    where
        T: DeserializeOwned + Serialize,
    {
        if let Some(hit) = self.cache.get(&key) {
            if let Ok(parsed) = serde_json::from_value(hit) {
                return Ok(parsed);
            }
        }
        let fresh: T = self.tmdb.get(path, query).await?;
        if let Ok(v) = serde_json::to_value(&fresh) {
            self.cache.set(key, v, cache_kind);
        }
        Ok(fresh)
    }

    /// One home row's worth of titles.
    pub async fn cinema_row(&self, kind: &str, page: i64) -> Result<Vec<MediaItem>, String> {
        let (path, is_series) =
            row_endpoint(kind).ok_or_else(|| format!("unknown cinema row: {kind}"))?;
        let page = page.max(1);
        let page_str = page.to_string();
        let key = AniListCache::key("tmdb_row", &[("kind", kind), ("page", &page_str)]);
        let query = [("page", page_str.clone())];
        if is_series {
            let page: TmdbPage<TmdbSeries> =
                self.tmdb_cached(key, "tmdb_row", path, &query).await?;
            Ok(into_items(page.results, TmdbSeries::into_media_item))
        } else {
            let page: TmdbPage<TmdbMovie> =
                self.tmdb_cached(key, "tmdb_row", path, &query).await?;
            Ok(into_items(page.results, TmdbMovie::into_media_item))
        }
    }

    /// TMDB's genre list for films or series, for the filter row.
    ///
    /// Cached under the row TTL rather than the search one: the list changes
    /// about never, and it is asked for every time the Search section opens.
    pub async fn cinema_genres(&self, is_series: bool) -> Result<Vec<(i64, String)>, String> {
        let kind = if is_series { "tv" } else { "movie" };
        let key = AniListCache::key("tmdb_row", &[("kind", "genres"), ("type", kind)]);
        #[derive(serde::Deserialize, serde::Serialize)]
        struct GenreList {
            genres: Option<Vec<super::tmdb::types::TmdbGenre>>,
        }
        let list: GenreList = self
            .tmdb_cached(key, "tmdb_row", &format!("/genre/{kind}/list"), &[])
            .await?;
        Ok(list
            .genres
            .unwrap_or_default()
            .into_iter()
            .filter_map(|g| Some((g.id?, g.name?)))
            .collect())
    }

    /// Browse by genre, year and sort -- TMDB's `/discover`, which is what
    /// the anime side's filtered search does through AniList. A plain
    /// keyword search cannot answer "action films from 1999, most popular
    /// first"; this endpoint is the one that can.
    pub async fn cinema_discover(
        &self,
        is_series: bool,
        genre_id: Option<i64>,
        year: Option<i32>,
        sort: Option<&str>,
        page: i64,
    ) -> Result<Vec<MediaItem>, String> {
        let kind = if is_series { "tv" } else { "movie" };
        let page = page.max(1);
        let page_str = page.to_string();
        let genre_str = genre_id.map(|g| g.to_string()).unwrap_or_default();
        let year_str = year.map(|y| y.to_string()).unwrap_or_default();
        let sort = sort.unwrap_or("popularity.desc");
        let key = AniListCache::key(
            "tmdb_row",
            &[
                ("kind", "discover"),
                ("type", kind),
                ("genre", &genre_str),
                ("year", &year_str),
                ("sort", sort),
                ("page", &page_str),
            ],
        );

        let mut query: Vec<(&str, String)> = vec![
            ("page", page_str.clone()),
            ("sort_by", sort.to_string()),
            ("include_adult", "false".to_string()),
        ];
        if !genre_str.is_empty() {
            query.push(("with_genres", genre_str.clone()));
        }
        if let Some(year) = year {
            // TMDB names the year parameter after the medium: a film is
            // released, a series first airs, and the other name is ignored
            // rather than refused -- so the wrong one silently returns
            // everything.
            let param = if is_series { "first_air_date_year" } else { "primary_release_year" };
            query.push((param, year.to_string()));
        }

        if is_series {
            let page: TmdbPage<TmdbSeries> =
                self.tmdb_cached(key, "tmdb_row", &format!("/discover/{kind}"), &query).await?;
            Ok(into_items(page.results, TmdbSeries::into_media_item))
        } else {
            let page: TmdbPage<TmdbMovie> =
                self.tmdb_cached(key, "tmdb_row", &format!("/discover/{kind}"), &query).await?;
            Ok(into_items(page.results, TmdbMovie::into_media_item))
        }
    }

    /// Films and series for one query, best match first.
    ///
    /// Two searches rather than `/search/multi`: multi mixes people into the
    /// same array and distinguishes them only by a `media_type` string, so
    /// the shapes would have to be pulled apart after the fact anyway — and
    /// these two run concurrently, which multi cannot.
    pub async fn cinema_search(
        &self,
        query: &str,
        limit: i64,
        page: i64,
    ) -> Result<Vec<MediaItem>, String> {
        let trimmed = query.trim();
        if trimmed.is_empty() {
            return Ok(vec![]);
        }
        let limit_str = limit.to_string();
        let page = page.max(1);
        let page_str = page.to_string();
        let key = AniListCache::key(
            "tmdb_search",
            &[("q", trimmed), ("limit", &limit_str), ("page", &page_str)],
        );
        if let Some(hit) = self.cache.get(&key) {
            if let Ok(parsed) = serde_json::from_value(hit) {
                return Ok(parsed);
            }
        }

        let params = [
            ("query", trimmed.to_string()),
            ("include_adult", "false".to_string()),
            ("page", page_str.clone()),
        ];
        let (movies, series) = tokio::join!(
            self.tmdb.get::<TmdbPage<TmdbMovie>>("/search/movie", &params),
            self.tmdb.get::<TmdbPage<TmdbSeries>>("/search/tv", &params),
        );
        // One side failing is not the search failing: a query that matches
        // only films still has films to show.
        let mut items = into_items(movies.ok().and_then(|p| p.results), TmdbMovie::into_media_item);
        items.extend(into_items(
            series.ok().and_then(|p| p.results),
            TmdbSeries::into_media_item,
        ));
        if items.is_empty() {
            return Ok(vec![]);
        }
        // TMDB sorts each endpoint by its own relevance and the two orders
        // cannot be interleaved by relevance; popularity is the one score
        // both sides carry.
        items.sort_by_key(|i| std::cmp::Reverse(i.popularity.unwrap_or(0)));
        items.truncate(limit.max(1) as usize);
        if let Ok(v) = serde_json::to_value(&items) {
            self.cache.set(key, v, "tmdb_search");
        }
        Ok(items)
    }

    /// One film, with the credits, trailer, stills and recommendations the
    /// detail page draws. `append_to_response` folds four extra endpoints
    /// into the one request TMDB would otherwise charge four for.
    pub async fn cinema_movie_detail(&self, id: i64) -> Result<TmdbMovie, String> {
        let id_str = id.to_string();
        let key = AniListCache::key("tmdb_detail", &[("kind", "movie"), ("id", &id_str)]);
        self.tmdb_cached(
            key,
            "tmdb_detail",
            &format!("/movie/{id}"),
            &[("append_to_response", "credits,videos,images,recommendations".to_string())],
        )
        .await
    }

    /// One series. `aggregate_credits` rather than `credits`: a show's
    /// per-episode cast list is what TMDB fills in, and the plain credits
    /// endpoint is empty for most of them.
    pub async fn cinema_series_detail(&self, id: i64) -> Result<TmdbSeries, String> {
        let id_str = id.to_string();
        let key = AniListCache::key("tmdb_detail", &[("kind", "tv"), ("id", &id_str)]);
        self.tmdb_cached(
            key,
            "tmdb_detail",
            &format!("/tv/{id}"),
            &[(
                "append_to_response",
                "aggregate_credits,videos,images,recommendations".to_string(),
            )],
        )
        .await
    }

    /// One season's episodes.
    pub async fn cinema_season(
        &self,
        series_id: i64,
        season: u32,
    ) -> Result<TmdbSeasonDetail, String> {
        let id_str = series_id.to_string();
        let season_str = season.to_string();
        let key = AniListCache::key(
            "tmdb_episodes",
            &[("id", &id_str), ("season", &season_str)],
        );
        self.tmdb_cached(
            key,
            "tmdb_episodes",
            &format!("/tv/{series_id}/season/{season}"),
            &[],
        )
        .await
    }

    /// A film or series with its episode list flattened to absolute numbers.
    ///
    /// The seasons are fetched together rather than one after another: a long
    /// show is a dozen requests, and serially that is a detail page that
    /// takes seconds to fill. A season that fails to load contributes no
    /// episodes rather than failing the page, but it still consumes its slice
    /// of the absolute numbering — `season_map` decides the numbering from
    /// the counts the series detail already stated, so a missing season
    /// cannot shift the episodes after it.
    pub async fn cinema_detail(&self, id: i64, is_series: bool) -> Result<CinemaDetail, String> {
        if !is_series {
            let movie = self.cinema_movie_detail(id).await?;
            return Ok(CinemaDetail { movie: Some(movie), series: None, episodes: vec![] });
        }

        let series = self.cinema_series_detail(id).await?;
        let map = series.season_map();
        let fetched = futures_util::future::join_all(
            map.iter().map(|(season, _)| self.cinema_season(id, *season)),
        )
        .await;

        let mut episodes = Vec::new();
        let mut absolute = 0u32;
        for ((season, count), detail) in map.iter().zip(fetched) {
            let rows = detail.ok().and_then(|d| d.episodes).unwrap_or_default();
            for number in 1..=*count {
                absolute += 1;
                let row = rows.iter().find(|e| e.episode_number == Some(number));
                episodes.push(CinemaEpisode {
                    absolute,
                    season: *season,
                    episode: number,
                    title: row.and_then(|e| e.name.clone()),
                    overview: row.and_then(|e| e.overview.clone()),
                    still_url: row.and_then(|e| e.still_url()),
                    air_date: row.and_then(|e| e.air_date.clone()),
                    runtime_minutes: row.and_then(|e| e.runtime),
                });
            }
        }
        Ok(CinemaDetail { movie: None, series: Some(series), episodes })
    }
}

/// TMDB pages arrive as `Option<Vec<T>>` and each row converts fallibly, so
/// every caller above would otherwise repeat the same two adapters.
fn into_items<T, F>(results: Option<Vec<T>>, convert: F) -> Vec<MediaItem>
where
    F: Fn(T) -> Option<MediaItem>,
{
    results.unwrap_or_default().into_iter().filter_map(convert).collect()
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn every_declared_row_has_an_endpoint() {
        for kind in CINEMA_ROWS {
            assert!(row_endpoint(kind).is_some(), "no endpoint for {kind}");
        }
        assert!(row_endpoint("nonsense").is_none());
    }

    #[test]
    fn series_rows_are_the_tv_endpoints() {
        assert_eq!(row_endpoint("trending_series"), Some(("/trending/tv/week", true)));
        assert_eq!(row_endpoint("upcoming_movies"), Some(("/movie/upcoming", false)));
    }
}

/// The `(season, episode)` an absolute episode number lands on, given the
/// season map the series detail stated.
///
/// The app stores one absolute number per episode for every catalog, because
/// the registry, the resume position and the remembered release are all keyed
/// on it. Western releases are named `SxxEyy` instead, so this is the one
/// conversion between them. Returns `None` past the end of the map rather
/// than clamping to the last season: an episode TMDB has never heard of would
/// otherwise resolve to a real, wrong file.
pub fn locate_episode(map: &[(u32, u32)], absolute: u32) -> Option<(u32, u32)> {
    let mut remaining = absolute.checked_sub(1)?;
    for (season, count) in map {
        if remaining < *count {
            return Some((*season, remaining + 1));
        }
        remaining -= count;
    }
    None
}

#[cfg(test)]
mod episode_tests {
    use super::*;

    #[test]
    fn absolute_numbers_walk_the_seasons() {
        let map = [(1u32, 10u32), (2, 10), (3, 8)];
        assert_eq!(locate_episode(&map, 1), Some((1, 1)));
        assert_eq!(locate_episode(&map, 10), Some((1, 10)));
        assert_eq!(locate_episode(&map, 11), Some((2, 1)));
        assert_eq!(locate_episode(&map, 21), Some((3, 1)));
        assert_eq!(locate_episode(&map, 28), Some((3, 8)));
    }

    #[test]
    fn an_episode_past_the_map_is_not_guessed_at() {
        let map = [(1u32, 10u32)];
        assert_eq!(locate_episode(&map, 11), None);
        assert_eq!(locate_episode(&map, 0), None);
        assert_eq!(locate_episode(&[], 1), None);
    }

    /// A show whose first season TMDB numbers as 2 (some do, when a pilot
    /// season is filed as season 0 and dropped by `season_map`).
    #[test]
    fn the_first_season_need_not_be_season_one() {
        let map = [(2u32, 6u32), (3, 6)];
        assert_eq!(locate_episode(&map, 1), Some((2, 1)));
        assert_eq!(locate_episode(&map, 7), Some((3, 1)));
    }
}

#[cfg(test)]
mod live_tests {
    use super::*;
    use crate::catalog::Catalogs;

    /// Live. Run against a deployed proxy:
    ///
    /// ```text
    /// ANICAT_TMDB_PROXY=https://... cargo test --lib cinema::live -- --ignored --nocapture
    /// ```
    ///
    /// or against a key directly with `ANICAT_TMDB_KEY`. These are the only
    /// way to see whether cinema mode actually works without opening the app:
    /// everything else in this module is shape and arithmetic, and none of it
    /// proves TMDB answers.
    fn catalogs() -> Option<Catalogs> {
        let key = std::env::var("ANICAT_TMDB_KEY").ok().filter(|k| !k.is_empty());
        let proxy = std::env::var("ANICAT_TMDB_PROXY").ok().filter(|p| !p.is_empty());
        if key.is_none() && proxy.is_none() {
            eprintln!("set ANICAT_TMDB_PROXY or ANICAT_TMDB_KEY to run this");
            return None;
        }
        Some(Catalogs::new(reqwest::Client::new(), None, key, proxy))
    }

    #[tokio::test]
    #[ignore]
    async fn live_every_home_row_answers() {
        let Some(catalogs) = catalogs() else { return };
        for kind in CINEMA_ROWS {
            let started = std::time::Instant::now();
            let items = catalogs.cinema_row(kind, 1).await.expect(kind);
            println!("{kind}: {} titles in {:?}", items.len(), started.elapsed());
            assert!(!items.is_empty(), "{kind} came back empty");
            let first = &items[0];
            assert!(first.id > 0);
            assert!(first.title.is_some(), "{kind}'s first title has no name");
            assert!(
                first.cover_image.is_some(),
                "{kind}'s first title has no poster -- a shelf of blanks"
            );
        }
    }

    #[tokio::test]
    #[ignore]
    async fn live_search_finds_films_and_series() {
        let Some(catalogs) = catalogs() else { return };
        let items = catalogs.cinema_search("dune", 20, 1).await.expect("search");
        println!("dune: {} results", items.len());
        assert!(!items.is_empty());
        // The 2021 film is the one anybody searching this means; if it is not
        // in the first twenty by popularity, the merge or the sort is wrong.
        assert!(
            items.iter().any(|i| i.season_year == Some(2021)),
            "no 2021 title among the results"
        );
    }

    #[tokio::test]
    #[ignore]
    async fn live_a_film_and_a_series_both_come_back_whole() {
        let Some(catalogs) = catalogs() else { return };
        // Fight Club (1999) and Silo, the two the resolve tests already use.
        let film = catalogs.cinema_detail(550, false).await.expect("film detail");
        let movie = film.movie.expect("a film detail with no film in it");
        println!("film: {:?} ({:?})", movie.title, movie.release_date);
        assert!(movie.release_date.is_some(), "no year -- the film search cannot run without one");
        assert!(film.episodes.is_empty(), "a film has no episode list");

        let series = catalogs.cinema_detail(125988, true).await.expect("series detail");
        let show = series.series.expect("a series detail with no series in it");
        println!(
            "series: {:?}, {} seasons, {} episodes flattened",
            show.name,
            show.season_map().len(),
            series.episodes.len()
        );
        assert!(!series.episodes.is_empty());
        // Absolute numbering has to be contiguous from 1, or every remembered
        // release and resume position points at the wrong episode.
        for (index, episode) in series.episodes.iter().enumerate() {
            assert_eq!(episode.absolute as usize, index + 1);
        }
        let first = &series.episodes[0];
        assert_eq!((first.season, first.episode), (1, 1));
    }
}
