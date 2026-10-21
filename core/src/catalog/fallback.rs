//! A catalog for the days AniList refuses every request.
//!
//! During the 2026-10-21 suspension AniList answered 403 "temporarily
//! disabled" to anonymous and signed-in requests alike, so a title that was
//! not already in the response cache could be neither searched for nor
//! opened. Kitsu and AniZip kept answering, and both carry the AniList id
//! (Kitsu in `mappings`, AniZip as its own lookup key). Everything downstream
//! of the catalog is keyed by that id -- SeaDex, the torrent search, watch
//! history -- so a record rebuilt from them plays like the real one.
//!
//! These are answers of last resort: the caller reaches for them only after
//! the stale cache had nothing, and never stores them under the AniList
//! cache keys, so they stop being served the moment AniList is back. They
//! carry no relations, characters, recommendations or list entry.

use std::time::Duration;

use serde_json::{json, Value};

use super::anilist::types::MediaItem;
use super::anizip;

const KITSU_URL: &str = "https://kitsu.io/api/edge";
const ANIZIP_URL: &str = "https://api.ani.zip/mappings";

/// Bounds the outage path the way every other client in this crate is
/// bounded: an untimed call here would hold the page open behind a service
/// that is only the fallback.
const TIMEOUT: Duration = Duration::from_secs(5);

/// Kitsu pages at 20 at most.
const KITSU_PAGE: i32 = 20;

/// The marker `anilist/client.rs` puts on the suspension answer.
pub fn is_outage(msg: &str) -> bool {
    msg.starts_with("anilist_down:")
}

/// One page of a title search. `media_type` is AniList's `ANIME` or `MANGA`;
/// anything else (novels, "ALL") has no counterpart here and answers empty.
/// Only titles Kitsu can map to an AniList id are returned, since an id the
/// rest of the app cannot use would open a dead page.
pub async fn search(http: &reqwest::Client, query: &str, media_type: &str, page: i32) -> Vec<MediaItem> {
    let manga = match media_type {
        "ANIME" => false,
        "MANGA" => true,
        _ => return Vec::new(),
    };
    let kind = if manga { "manga" } else { "anime" };
    let offset = ((page.max(1) - 1) * KITSU_PAGE).to_string();
    let sent = http
        .get(format!("{KITSU_URL}/{kind}"))
        .query(&[
            ("filter[text]", query),
            ("page[limit]", &KITSU_PAGE.to_string()),
            ("page[offset]", &offset),
            ("include", "mappings"),
        ])
        .header("Accept", "application/vnd.api+json")
        .timeout(TIMEOUT)
        .send()
        .await;
    let Ok(res) = sent else { return Vec::new() };
    if !res.status().is_success() {
        return Vec::new();
    }
    match res.json::<Value>().await {
        Ok(body) => kitsu_items(&body, manga),
        Err(_) => Vec::new(),
    }
}

/// An anime's record from AniZip, filled out from Kitsu where it can be.
/// `None` when AniZip does not know the id.
pub async fn anime_detail(http: &reqwest::Client, anilist_id: i64) -> Option<MediaItem> {
    let res = http
        .get(format!("{ANIZIP_URL}?anilist_id={anilist_id}"))
        .timeout(TIMEOUT)
        .send()
        .await
        .ok()?;
    if !res.status().is_success() {
        return None;
    }
    let zip = res.json::<Value>().await.ok()?;
    // AniZip has no synopsis, status or score; Kitsu does, under the id
    // AniZip just mapped. Without it the record is still enough to list and
    // play episodes.
    let kitsu = match zip["mappings"]["kitsu_id"].as_i64() {
        Some(kid) => kitsu_record(http, kid).await,
        None => None,
    };
    Some(merge_anizip(&zip, kitsu, anilist_id))
}

async fn kitsu_record(http: &reqwest::Client, kitsu_id: i64) -> Option<Value> {
    let res = http
        .get(format!("{KITSU_URL}/anime/{kitsu_id}"))
        .header("Accept", "application/vnd.api+json")
        .timeout(TIMEOUT)
        .send()
        .await
        .ok()?;
    if !res.status().is_success() {
        return None;
    }
    res.json::<Value>().await.ok().map(|body| body["data"]["attributes"].clone())
}

/// Each Kitsu hit that maps to an AniList id, adult titles dropped: the
/// AniList path asks with `isAdult: false` and this one has to hold to the
/// same line, since Kitsu does not filter unless told to.
fn kitsu_items(body: &Value, manga: bool) -> Vec<MediaItem> {
    let (anilist_site, mal_site) = if manga {
        ("anilist/manga", "myanimelist/manga")
    } else {
        ("anilist/anime", "myanimelist/anime")
    };
    let mapped = |entry: &Value, site: &str| -> Option<i64> {
        let ids: Vec<&str> = entry["relationships"]["mappings"]["data"]
            .as_array()?
            .iter()
            .filter_map(|r| r["id"].as_str())
            .collect();
        body["included"]
            .as_array()?
            .iter()
            .filter(|m| m["type"] == "mappings" && m["id"].as_str().is_some_and(|id| ids.contains(&id)))
            .find(|m| m["attributes"]["externalSite"] == site)
            .and_then(|m| m["attributes"]["externalId"].as_str()?.parse().ok())
    };
    let mut out = Vec::new();
    for entry in body["data"].as_array().into_iter().flatten() {
        let attrs = &entry["attributes"];
        if is_adult(attrs) {
            continue;
        }
        let Some(id) = mapped(entry, anilist_site) else { continue };
        if let Some(item) = kitsu_media(attrs, id, mapped(entry, mal_site), manga) {
            out.push(item);
        }
    }
    out
}

fn is_adult(attrs: &Value) -> bool {
    attrs["nsfw"] == true || attrs["ageRating"] == "R18"
}

/// Kitsu's attributes in AniList's shape, built as JSON and read back
/// through `MediaItem`'s own deserializer: every field not named here stays
/// `None` without this module spelling out the other thirty.
fn kitsu_media(attrs: &Value, id: i64, id_mal: Option<i64>, manga: bool) -> Option<MediaItem> {
    let date = |key: &str| -> Value {
        let mut parts = attrs[key].as_str().unwrap_or("").split('-').map(|p| p.parse::<i32>().ok());
        json!({ "year": parts.next().flatten(), "month": parts.next().flatten(), "day": parts.next().flatten() })
    };
    let start = date("startDate");
    let status = match attrs["status"].as_str() {
        Some("current") => Some("RELEASING"),
        Some("finished") => Some("FINISHED"),
        Some("tba" | "unreleased" | "upcoming") => Some("NOT_YET_RELEASED"),
        _ => None,
    };
    let format = match attrs["subtype"].as_str().map(str::to_ascii_lowercase).as_deref() {
        Some("tv") => Some("TV"),
        Some("movie") => Some("MOVIE"),
        Some("ova") => Some("OVA"),
        Some("ona") => Some("ONA"),
        Some("special") => Some("SPECIAL"),
        Some("music") => Some("MUSIC"),
        Some("manga" | "manhwa" | "manhua" | "doujin") => Some("MANGA"),
        Some("novel") => Some("NOVEL"),
        Some("oneshot") => Some("ONE_SHOT"),
        _ => None,
    };
    let score = attrs["averageRating"].as_str().and_then(|s| s.parse::<f64>().ok()).map(|s| s.round() as i32);
    serde_json::from_value(json!({
        "id": id,
        "idMal": id_mal,
        "type": if manga { "MANGA" } else { "ANIME" },
        "title": {
            "romaji": attrs["titles"]["en_jp"],
            "english": attrs["titles"]["en"],
            "native": attrs["titles"]["ja_jp"],
        },
        "coverImage": { "large": attrs["posterImage"]["large"], "medium": attrs["posterImage"]["medium"] },
        "bannerImage": attrs["coverImage"]["large"],
        "description": attrs["synopsis"],
        "format": format,
        "status": status,
        "seasonYear": start["year"],
        "startDate": start,
        "endDate": date("endDate"),
        "episodes": attrs["episodeCount"],
        "chapters": attrs["chapterCount"],
        "duration": attrs["episodeLength"],
        "averageScore": score,
        "isAdult": false,
    }))
    .ok()
}

/// AniZip's answer laid over the Kitsu record, or over an empty one when
/// Kitsu had nothing. AniZip fills only what is still missing: Kitsu's
/// poster, title and counts are what the AniList page would have shown.
fn merge_anizip(zip: &Value, kitsu: Option<Value>, anilist_id: i64) -> MediaItem {
    let mut item = kitsu
        .and_then(|attrs| kitsu_media(&attrs, anilist_id, None, false))
        .unwrap_or_else(|| {
            serde_json::from_value(json!({ "id": anilist_id, "type": "ANIME" }))
                .expect("a bare id is a valid MediaItem")
        });
    let text = |v: &Value| v.as_str().filter(|s| !s.trim().is_empty()).map(String::from);

    item.id_mal = item.id_mal.or(zip["mappings"]["mal_id"].as_i64());
    let title = item.title.get_or_insert(super::anilist::types::MediaTitle {
        romaji: None,
        english: None,
        native: None,
    });
    title.romaji = title.romaji.take().or_else(|| text(&zip["titles"]["x-jat"]));
    title.english = title.english.take().or_else(|| text(&zip["titles"]["en"]));
    title.native = title.native.take().or_else(|| text(&zip["titles"]["ja"]));

    let image = |kind: &str| {
        zip["images"]
            .as_array()?
            .iter()
            .find(|i| i["coverType"] == kind)
            .and_then(|i| text(&i["url"]))
    };
    if item.cover_image.as_ref().and_then(|c| c.large.as_ref()).is_none() {
        item.cover_image = image("Poster").map(|url| super::anilist::types::MediaCoverImage {
            large: Some(url),
            medium: None,
        });
    }
    item.banner_image = item.banner_image.take().or_else(|| image("Banner"));
    item.format = item.format.take().or_else(|| text(&zip["mappings"]["type"]).map(|t| t.to_ascii_uppercase()));
    item.episodes = item.episodes.or_else(|| zip["episodeCount"].as_i64().filter(|&n| n > 0).map(|n| n as i32));

    if item.status.as_deref() != Some("FINISHED") {
        item.next_airing_episode = next_airing(&anizip::parse(zip), chrono::Utc::now().date_naive());
    }
    item
}

/// The first episode AniZip dates today or later, which is what stops the
/// detail page offering an unaired episode as playable: with AniList gone
/// there is no `nextAiringEpisode`, and a page with none reads every
/// episode as aired. AniZip dates are whole days, so the slot is the end of
/// that day in UTC. A broadcast is out of the torrent indexes by then; the
/// start of the day would have offered an episode that has not yet aired in
/// Japan.
fn next_airing(
    episodes: &std::collections::HashMap<i32, anizip::AniZipEpisode>,
    today: chrono::NaiveDate,
) -> Option<super::anilist::types::NextAiringEpisode> {
    let (episode, day) = episodes
        .iter()
        .filter_map(|(n, e)| {
            let day = chrono::NaiveDate::parse_from_str(e.air_date.as_deref()?, "%Y-%m-%d").ok()?;
            (day >= today).then_some((*n, day))
        })
        .min_by_key(|(n, _)| *n)?;
    let airing_at = day.succ_opt()?.and_hms_opt(0, 0, 0)?.and_utc().timestamp();
    Some(super::anilist::types::NextAiringEpisode {
        airing_at: Some(airing_at),
        episode: Some(episode),
        time_until_airing: Some(airing_at - chrono::Utc::now().timestamp()),
    })
}

#[cfg(test)]
mod tests {
    use super::*;

    fn kitsu_page() -> Value {
        json!({
            "data": [
                {
                    "id": "46474",
                    "attributes": {
                        "titles": { "en": "Frieren: Beyond Journey's End", "en_jp": "Sousou no Frieren", "ja_jp": "葬送のフリーレン" },
                        "subtype": "TV", "status": "finished", "startDate": "2023-09-29", "endDate": "2024-03-22",
                        "episodeCount": 28, "episodeLength": 24, "averageRating": "88.85", "nsfw": false, "ageRating": "PG",
                        "posterImage": { "large": "https://k/p-large.jpg", "medium": "https://k/p-medium.jpg" },
                        "coverImage": { "large": "https://k/c-large.jpg" },
                        "synopsis": "After the party of heroes defeated the Demon King"
                    },
                    "relationships": { "mappings": { "data": [{ "id": "1" }, { "id": "2" }] } }
                },
                {
                    "id": "99",
                    "attributes": { "titles": { "en_jp": "Adult Show" }, "nsfw": true },
                    "relationships": { "mappings": { "data": [{ "id": "3" }] } }
                },
                {
                    "id": "100",
                    "attributes": { "titles": { "en_jp": "Rated R18" }, "nsfw": false, "ageRating": "R18" },
                    "relationships": { "mappings": { "data": [{ "id": "3" }] } }
                },
                {
                    "id": "101",
                    "attributes": { "titles": { "en_jp": "Unmapped" }, "nsfw": false },
                    "relationships": { "mappings": { "data": [{ "id": "4" }] } }
                }
            ],
            "included": [
                { "id": "1", "type": "mappings", "attributes": { "externalSite": "myanimelist/anime", "externalId": "52991" } },
                { "id": "2", "type": "mappings", "attributes": { "externalSite": "anilist/anime", "externalId": "154587" } },
                { "id": "3", "type": "mappings", "attributes": { "externalSite": "anilist/anime", "externalId": "777" } },
                { "id": "4", "type": "mappings", "attributes": { "externalSite": "thetvdb/series", "externalId": "5" } }
            ]
        })
    }

    #[test]
    fn a_kitsu_hit_comes_back_under_its_anilist_id() {
        let items = kitsu_items(&kitsu_page(), false);
        assert_eq!(items.len(), 1);
        let m = &items[0];
        assert_eq!(m.id, 154587);
        assert_eq!(m.id_mal, Some(52991));
        assert_eq!(m.media_type.as_deref(), Some("ANIME"));
        let title = m.title.as_ref().unwrap();
        assert_eq!(title.romaji.as_deref(), Some("Sousou no Frieren"));
        assert_eq!(title.english.as_deref(), Some("Frieren: Beyond Journey's End"));
        assert_eq!(m.cover_image.as_ref().unwrap().large.as_deref(), Some("https://k/p-large.jpg"));
        assert_eq!(m.banner_image.as_deref(), Some("https://k/c-large.jpg"));
        assert_eq!(m.format.as_deref(), Some("TV"));
        assert_eq!(m.status.as_deref(), Some("FINISHED"));
        assert_eq!(m.season_year, Some(2023));
        assert_eq!(m.episodes, Some(28));
        assert_eq!(m.average_score, Some(89));
    }

    #[test]
    fn adult_and_unmapped_titles_are_dropped() {
        let ids: Vec<i64> = kitsu_items(&kitsu_page(), false).iter().map(|m| m.id).collect();
        assert_eq!(ids, vec![154587]);
    }

    #[test]
    fn a_manga_search_reads_the_manga_mappings() {
        // The page's mappings are all anime sites, so a manga read finds none.
        assert!(kitsu_items(&kitsu_page(), true).is_empty());
    }

    #[test]
    fn anizip_fills_what_kitsu_left_out() {
        let zip = json!({
            "titles": { "en": "Frieren", "x-jat": "Sousou no Frieren", "ja": "葬送のフリーレン" },
            "images": [
                { "coverType": "Banner", "url": "https://z/banner.jpg" },
                { "coverType": "Poster", "url": "https://z/poster.jpg" }
            ],
            "episodeCount": 28,
            "mappings": { "mal_id": 52991, "type": "TV", "kitsu_id": 46474 },
            "episodes": {}
        });
        let m = merge_anizip(&zip, None, 154587);
        assert_eq!(m.id, 154587);
        assert_eq!(m.id_mal, Some(52991));
        assert_eq!(m.title.as_ref().unwrap().romaji.as_deref(), Some("Sousou no Frieren"));
        assert_eq!(m.cover_image.as_ref().unwrap().large.as_deref(), Some("https://z/poster.jpg"));
        assert_eq!(m.banner_image.as_deref(), Some("https://z/banner.jpg"));
        assert_eq!(m.format.as_deref(), Some("TV"));
        assert_eq!(m.episodes, Some(28));
    }

    #[test]
    fn kitsu_wins_over_anizip_where_it_has_an_answer() {
        let attrs = kitsu_page()["data"][0]["attributes"].clone();
        let zip = json!({
            "titles": { "x-jat": "Wrong" },
            "images": [{ "coverType": "Poster", "url": "https://z/poster.jpg" }],
            "episodeCount": 99,
            "mappings": {},
            "episodes": {}
        });
        let m = merge_anizip(&zip, Some(attrs), 154587);
        assert_eq!(m.title.as_ref().unwrap().romaji.as_deref(), Some("Sousou no Frieren"));
        assert_eq!(m.cover_image.as_ref().unwrap().large.as_deref(), Some("https://k/p-large.jpg"));
        assert_eq!(m.episodes, Some(28));
    }

    #[test]
    fn the_next_unaired_episode_is_the_earliest_one_dated_today_or_later() {
        let ep = |date: &str| anizip::AniZipEpisode { air_date: Some(date.to_string()), ..Default::default() };
        let episodes = std::collections::HashMap::from([
            (1, ep("2026-10-01")),
            (2, ep("2026-10-08")),
            (3, ep("2026-10-21")),
            (4, ep("2026-10-28")),
            (5, anizip::AniZipEpisode::default()),
        ]);
        let today = chrono::NaiveDate::from_ymd_opt(2026, 10, 21).unwrap();
        let next = next_airing(&episodes, today).unwrap();
        assert_eq!(next.episode, Some(3));
        // The end of 2026-10-21 UTC, so episode 3 is not offered until the
        // day is over.
        assert_eq!(next.airing_at, Some(1792627200));
        let past = chrono::NaiveDate::from_ymd_opt(2026, 11, 30).unwrap();
        assert!(next_airing(&episodes, past).is_none());
    }

    /// Live. `cargo test --lib fallback -- --ignored --nocapture`
    #[tokio::test]
    #[ignore]
    async fn live_search_and_detail_answer_without_anilist() {
        let http = reqwest::Client::new();
        let hits = search(&http, "frieren", "ANIME", 1).await;
        println!("search: {:?}", hits.iter().map(|m| (m.id, m.title.as_ref().and_then(|t| t.romaji.clone()))).collect::<Vec<_>>());
        assert!(hits.iter().any(|m| m.id == 154587), "Frieren season 1 under its AniList id");

        let detail = anime_detail(&http, 154587).await.expect("AniZip knows Frieren");
        println!("detail: {detail:#?}");
        assert_eq!(detail.id, 154587);
        assert!(detail.title.as_ref().and_then(|t| t.romaji.as_ref()).is_some());
        assert!(detail.description.is_some(), "synopsis came from Kitsu");
        assert!(detail.episodes.is_some_and(|n| n > 0));
    }

    #[test]
    fn only_the_suspension_answer_counts_as_an_outage() {
        assert!(is_outage("anilist_down:The AniList API has been temporarily disabled"));
        assert!(!is_outage("AniList: Invalid token"));
        assert!(!is_outage("AniList HTTP 429: Too Many Requests"));
    }
}
