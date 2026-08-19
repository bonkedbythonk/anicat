//! Cinema mode's read commands.
//!
//! Every one of these returns the same `{Page: {media, pageInfo}}` envelope
//! the AniList commands return, so `lib/api.ts` unwraps a film with the helper
//! it already uses for an anime and nothing on the frontend has to know which
//! catalog answered.

use serde_json::Value;
use tauri::State;

use crate::anilist::responses::{Page, PageInfo, PageResponse};
use crate::anilist::types::MediaItem;
use crate::cache::AniListCache;
use crate::media_id::{decode, MediaSource};
use crate::state::AppState;
use crate::tmdb::types::{gallery_urls, TmdbMovie, TmdbPage, TmdbSeasonDetail, TmdbSeries};

/// The rows cinema mode's home screen is built from. Named rather than free
/// TMDB paths so the frontend can't ask for an endpoint that doesn't exist,
/// and so each row's cache key is a fixed string.
fn row_path(row: &str) -> Option<(&'static str, bool)> {
    // (path, is_series)
    match row {
        "trending_movies" => Some(("/trending/movie/week", false)),
        "trending_series" => Some(("/trending/tv/week", true)),
        "popular_movies" => Some(("/movie/popular", false)),
        "popular_series" => Some(("/tv/popular", true)),
        "now_playing" => Some(("/movie/now_playing", false)),
        "top_rated_movies" => Some(("/movie/top_rated", false)),
        "top_rated_series" => Some(("/tv/top_rated", true)),
        _ => None,
    }
}

fn page_response(media: Vec<MediaItem>, page: Option<i64>, total_pages: Option<i64>) -> PageResponse<MediaItem> {
    let current = page.unwrap_or(1);
    PageResponse {
        page: Page {
            page_info: Some(PageInfo {
                total: None,
                current_page: Some(current),
                last_page: total_pages,
                has_next_page: total_pages.map(|last| current < last),
            }),
            media: Some(media),
        },
    }
}

/// Fetch one page of a movie or series list and normalize it.
async fn fetch_list(
    state: &AppState,
    path: &str,
    is_series: bool,
    page: i64,
) -> Result<(Vec<MediaItem>, Option<i64>), String> {
    let query = [("page", page.to_string())];
    if is_series {
        let raw: TmdbPage<TmdbSeries> = state.tmdb_client.get(path, &query).await?;
        let media = raw
            .results
            .unwrap_or_default()
            .into_iter()
            .filter_map(|s| s.into_media_item())
            .collect();
        Ok((media, raw.total_pages))
    } else {
        let raw: TmdbPage<TmdbMovie> = state.tmdb_client.get(path, &query).await?;
        let media = raw
            .results
            .unwrap_or_default()
            .into_iter()
            .filter_map(|m| m.into_media_item())
            .collect();
        Ok((media, raw.total_pages))
    }
}

#[tauri::command]
pub async fn tmdb_row(state: State<'_, AppState>, row: String, page: Option<i64>) -> Result<Value, String> {
    tmdb_row_impl(state.inner(), row, page).await
}

pub async fn tmdb_row_impl(state: &AppState, row: String, page: Option<i64>) -> Result<Value, String> {
    let (path, is_series) = row_path(&row).ok_or_else(|| format!("unknown cinema row: {}", row))?;
    let page = page.unwrap_or(1);

    let cache_key = AniListCache::key("tmdb_row", &[("row", &row), ("page", &page.to_string())]);
    if let Some(cached) = state.cache.get(&cache_key) {
        return Ok(cached);
    }

    let (media, total_pages) = match fetch_list(state, path, is_series, page).await {
        Ok(v) => v,
        Err(e) => return state.cache.stale_or_err(&cache_key, e),
    };

    let val = serde_json::to_value(page_response(media, Some(page), total_pages))
        .map_err(|e| e.to_string())?;
    state.cache.set(cache_key, val.clone(), "tmdb_row");
    Ok(val)
}

#[tauri::command]
pub async fn tmdb_search(state: State<'_, AppState>, query: String, page: Option<i64>) -> Result<Value, String> {
    tmdb_search_impl(state.inner(), query, page).await
}

pub async fn tmdb_search_impl(state: &AppState, query: String, page: Option<i64>) -> Result<Value, String> {
    let page = page.unwrap_or(1);
    if query.trim().is_empty() {
        return serde_json::to_value(page_response(Vec::new(), Some(page), Some(1)))
            .map_err(|e| e.to_string());
    }

    let cache_key = AniListCache::key("tmdb_search", &[("q", &query), ("page", &page.to_string())]);
    if let Some(cached) = state.cache.get(&cache_key) {
        return Ok(cached);
    }

    // Films and series are separate endpoints, and /search/multi mixes people
    // into the results. Ask both and interleave by popularity instead, so a
    // search for a title that exists as both does not bury one of them.
    let params = [("query", query.clone()), ("page", page.to_string())];
    let movies = state
        .tmdb_client
        .get::<TmdbPage<TmdbMovie>>("/search/movie", &params)
        .await;
    let series = state
        .tmdb_client
        .get::<TmdbPage<TmdbSeries>>("/search/tv", &params)
        .await;

    // One endpoint failing is survivable; both failing is the real error, and
    // an unauthorized token fails both identically.
    if let (Err(e), Err(_)) = (&movies, &series) {
        return state.cache.stale_or_err(&cache_key, e.clone());
    }

    let mut media: Vec<MediaItem> = Vec::new();
    let mut last_page = 1;
    if let Ok(m) = movies {
        last_page = last_page.max(m.total_pages.unwrap_or(1));
        media.extend(m.results.unwrap_or_default().into_iter().filter_map(|x| x.into_media_item()));
    }
    if let Ok(s) = series {
        last_page = last_page.max(s.total_pages.unwrap_or(1));
        media.extend(s.results.unwrap_or_default().into_iter().filter_map(|x| x.into_media_item()));
    }
    media.sort_by_key(|m| std::cmp::Reverse(m.popularity.unwrap_or(0)));

    let val = serde_json::to_value(page_response(media, Some(page), Some(last_page)))
        .map_err(|e| e.to_string())?;
    state.cache.set(cache_key, val.clone(), "tmdb_search");
    Ok(val)
}

#[tauri::command]
pub async fn tmdb_detail(state: State<'_, AppState>, media_id: i64) -> Result<Value, String> {
    tmdb_detail_impl(state.inner(), media_id).await
}

/// The band decides which endpoint answers a detail lookup. An AniList id
/// reaching cinema mode is a routing bug on the frontend, not a TMDB lookup
/// with a bad id, so it is refused rather than sent.
fn cinema_source(media_id: i64) -> Result<(MediaSource, i64), String> {
    let (source, native_id) = decode(media_id);
    if !source.is_cinema() {
        return Err(format!("not a cinema id: {}", media_id));
    }
    Ok((source, native_id))
}

pub async fn tmdb_detail_impl(state: &AppState, media_id: i64) -> Result<Value, String> {
    let (source, native_id) = cinema_source(media_id)?;

    let cache_key = AniListCache::key("tmdb_detail", &[("id", &media_id.to_string())]);
    if let Some(cached) = state.cache.get(&cache_key) {
        return Ok(cached);
    }

    // Cast, trailer and recommendations ride along on the same request rather
    // than costing three more. TV names its cast endpoint differently, hence
    // the two spellings.
    let append = [(
        "append_to_response",
        if source == MediaSource::TmdbTv {
            "aggregate_credits,videos,recommendations,images".to_string()
        } else {
            "credits,videos,recommendations,images".to_string()
        },
    )];

    let (item, extras) = match source {
        MediaSource::TmdbTv => {
            match state
                .tmdb_client
                .get::<TmdbSeries>(&format!("/tv/{}", native_id), &append)
                .await
            {
                Ok(series) => {
                    let extras = serde_json::json!({
                        "tagline": series.tagline,
                        "trailer_id": series.videos.as_ref().and_then(|v| v.best_trailer()),
                        "cast": cast_json(series.credits.as_ref()),
                        "studio_names": series.networks.as_deref().map(company_names),
                        "gallery": gallery_urls(series.images.as_ref()),
                        "similar": series
                            .recommendations
                            .as_ref()
                            .map(|page| recommendation_json(page.results.as_ref())),
                    });
                    (series.into_media_item(), extras)
                }
                Err(e) => return state.cache.stale_or_err(&cache_key, e),
            }
        }
        _ => {
            match state
                .tmdb_client
                .get::<TmdbMovie>(&format!("/movie/{}", native_id), &append)
                .await
            {
                Ok(movie) => {
                    let extras = serde_json::json!({
                        "tagline": movie.tagline,
                        "trailer_id": movie.videos.as_ref().and_then(|v| v.best_trailer()),
                        "cast": cast_json(movie.credits.as_ref()),
                        "studio_names": movie.production_companies.as_deref().map(company_names),
                        "gallery": gallery_urls(movie.images.as_ref()),
                        "similar": movie
                            .recommendations
                            .as_ref()
                            .map(|page| recommendation_json(page.results.as_ref())),
                    });
                    (movie.into_media_item(), extras)
                }
                Err(e) => return state.cache.stale_or_err(&cache_key, e),
            }
        }
    };

    let Some(item) = item else {
        return Err(format!("tmdb id out of range: {}", native_id));
    };

    let mut val = serde_json::to_value(item).map_err(|e| e.to_string())?;
    // Merged into the media item rather than nested under a key, so the
    // frontend reads one object and the fields that map onto MediaItem's own
    // shape stay where every other consumer expects them.
    if let (Some(target), Some(extra)) = (val.as_object_mut(), extras.as_object()) {
        for (key, value) in extra {
            if !value.is_null() {
                target.insert(key.clone(), value.clone());
            }
        }
    }
    state.cache.set(cache_key, val.clone(), "tmdb_detail");
    Ok(val)
}

fn company_names(companies: &[crate::tmdb::types::TmdbCompany]) -> Vec<String> {
    companies.iter().filter_map(|c| c.name.clone()).collect()
}

/// The top-billed cast, capped. TMDB orders by billing, and a film's full
/// credit list runs to hundreds of names nobody scrolls.
fn cast_json(credits: Option<&crate::tmdb::types::TmdbCredits>) -> Vec<Value> {
    let Some(credits) = credits else { return vec![] };
    let Some(cast) = credits.cast.as_ref() else { return vec![] };
    let mut people: Vec<_> = cast.iter().collect();
    people.sort_by_key(|c| c.order.unwrap_or(i64::MAX));
    people
        .into_iter()
        .take(16)
        .map(|c| {
            serde_json::json!({
                "id": c.id,
                "name": c.name,
                "character": c.character,
                "photo": c.photo_url(),
            })
        })
        .collect()
}

/// Recommendations, reduced to what a poster row needs and banded so clicking
/// one opens it as a cinema title rather than looking it up on AniList.
fn recommendation_json<T: RecommendationLike>(results: Option<&Vec<T>>) -> Vec<Value> {
    let Some(results) = results else { return vec![] };
    results
        .iter()
        .take(12)
        .filter_map(|r| r.to_media_item())
        .filter_map(|item| serde_json::to_value(item).ok())
        .collect()
}

/// Lets one helper cover both recommendation shapes TMDB returns.
pub trait RecommendationLike {
    fn to_media_item(&self) -> Option<crate::anilist::types::MediaItem>;
}

impl RecommendationLike for TmdbMovie {
    fn to_media_item(&self) -> Option<crate::anilist::types::MediaItem> {
        self.clone().into_media_item()
    }
}

impl RecommendationLike for TmdbSeries {
    fn to_media_item(&self) -> Option<crate::anilist::types::MediaItem> {
        self.clone().into_media_item()
    }
}

/// The season map for a series: episode counts per season, specials excluded.
///
/// Read from the /tv/{id} detail response, which lists every season with its
/// count, so this costs no request of its own beyond the one the detail page
/// already makes. The playback path needs it to turn the single absolute
/// episode number the app stores into the SxxEyy a release name spells.
pub async fn season_map_for(state: &AppState, media_id: i64) -> Result<Vec<(u32, u32)>, String> {
    let (source, native_id) = cinema_source(media_id)?;
    if source != MediaSource::TmdbTv {
        return Err(format!("not a series: {}", media_id));
    }
    let series: TmdbSeries = state
        .tmdb_client
        .get(&format!("/tv/{}", native_id), &[])
        .await?;
    Ok(series.season_map())
}

/// Every episode of a series, flattened into the absolute order the rest of
/// the app counts in.
#[tauri::command]
pub async fn tmdb_episodes(state: State<'_, AppState>, media_id: i64) -> Result<Value, String> {
    tmdb_episodes_impl(state.inner(), media_id).await
}

pub async fn tmdb_episodes_impl(state: &AppState, media_id: i64) -> Result<Value, String> {
    let (source, native_id) = cinema_source(media_id)?;
    if source != MediaSource::TmdbTv {
        return Err(format!("not a series: {}", media_id));
    }

    let cache_key = AniListCache::key("tmdb_episodes", &[("id", &media_id.to_string())]);
    if let Some(cached) = state.cache.get(&cache_key) {
        return Ok(cached);
    }

    let seasons = match season_map_for(state, media_id).await {
        Ok(s) => s,
        Err(e) => return state.cache.stale_or_err(&cache_key, e),
    };

    // One request per season, concurrently. TMDB has no endpoint that returns
    // every episode of a show at once, and a long-running series is a dozen
    // requests rather than hundreds.
    let fetches = seasons.iter().map(|(season_number, _)| {
        let path = format!("/tv/{}/season/{}", native_id, season_number);
        async move { state.tmdb_client.get::<TmdbSeasonDetail>(&path, &[]).await }
    });
    let results = futures_util::future::join_all(fetches).await;

    let mut out: Vec<Value> = vec![];
    let mut absolute: i64 = 0;
    for result in results {
        let Ok(detail) = result else { continue };
        for episode in detail.episodes.unwrap_or_default() {
            absolute += 1;
            out.push(serde_json::json!({
                // What the app stores and counts in. The season and episode
                // are carried alongside for display and for the release
                // search, but never as the identity.
                "number": absolute,
                "season": episode.season_number,
                "episode_in_season": episode.episode_number,
                "title": episode.name,
                "description": episode.overview,
                "thumbnail": episode.still_url(),
                "air_date": episode.air_date,
                "duration": episode.runtime,
            }));
        }
    }

    let val = serde_json::json!({ "episodes": out });
    state.cache.set(cache_key, val.clone(), "tmdb_episodes");
    Ok(val)
}

/// Whether cinema mode has a usable token, so the UI can say "add a token"
/// rather than showing an empty grid.
#[tauri::command]
pub async fn tmdb_configured(state: State<'_, AppState>) -> Result<bool, String> {
    Ok(state.tmdb_client.has_token())
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn only_the_named_rows_resolve_to_an_endpoint() {
        assert_eq!(row_path("trending_movies").unwrap(), ("/trending/movie/week", false));
        assert_eq!(row_path("popular_series").unwrap(), ("/tv/popular", true));
        // A row name the frontend invented must not become a TMDB path.
        assert!(row_path("/movie/550").is_none());
        assert!(row_path("").is_none());
    }

    #[test]
    fn the_envelope_matches_what_the_frontend_unwraps() {
        let val = serde_json::to_value(page_response(Vec::new(), Some(2), Some(9))).unwrap();
        let page = val.get("Page").expect("frontend reads result.Page");
        assert!(page.get("media").is_some());
        let info = page.get("pageInfo").expect("frontend reads Page.pageInfo");
        assert_eq!(info.get("currentPage").unwrap(), 2);
        assert_eq!(info.get("hasNextPage").unwrap(), true);
    }

    #[test]
    fn the_last_page_reports_no_next_page() {
        let val = serde_json::to_value(page_response(Vec::new(), Some(9), Some(9))).unwrap();
        let info = val.get("Page").unwrap().get("pageInfo").unwrap();
        assert_eq!(info.get("hasNextPage").unwrap(), false);
    }

    #[test]
    fn an_anilist_id_is_refused_rather_than_looked_up_on_tmdb() {
        // 21202 is a real AniList id and also a plausible TMDB one, which is
        // exactly why the band has to decide and not the number.
        let err = cinema_source(21202).unwrap_err();
        assert!(err.contains("not a cinema id"), "{}", err);

        let movie = crate::media_id::encode(MediaSource::TmdbMovie, 550).unwrap();
        assert_eq!(cinema_source(movie).unwrap(), (MediaSource::TmdbMovie, 550));
        let series = crate::media_id::encode(MediaSource::TmdbTv, 1396).unwrap();
        assert_eq!(cinema_source(series).unwrap(), (MediaSource::TmdbTv, 1396));
    }
}
