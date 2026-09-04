//! MangaDex REST client.
//!
//! Ported from the Python provider it replaces. Two behaviours are load-
//! bearing and were kept exactly:
//!
//! * **`links.al` is the match, the title is only the search.** MangaDex
//!   carries the AniList id of a manga in `attributes.links.al`, so a search
//!   result whose `al` equals the AniList entry we are looking at is the
//!   right manga regardless of how its title is romanised. Those are returned
//!   ahead of everything else rather than merged into relevance order.
//! * **The feed is deduplicated by chapter number, keeping the longest.** The
//!   same chapter is uploaded by several scanlation groups, and picking the
//!   one with the most pages avoids landing on a partial or a credits-only
//!   upload.

use std::collections::HashMap;
use std::sync::Mutex;
use std::time::{Duration, Instant};

use serde::Deserialize;

const BASE_URL: &str = "https://api.mangadex.org";
const UPLOADS_URL: &str = "https://uploads.mangadex.org";
const REQUEST_TIMEOUT: Duration = Duration::from_secs(20);
/// MangaDex asks API consumers to identify themselves; an anonymous default
/// reqwest agent gets rate limited harder than a named one.
const USER_AGENT: &str = concat!("Anicat/", env!("CARGO_PKG_VERSION"), " (+https://github.com/bonkedbythonk/anicat)");
/// A chapter feed is two requests and rarely changes within a reading session.
const CACHE_TTL: Duration = Duration::from_secs(900);
/// The feed endpoint's own per-request maximum.
const FEED_PAGE: usize = 500;

/// Every list endpoint takes the rating filter; without it MangaDex applies
/// its own default and a perfectly ordinary seinen title goes missing.
const CONTENT_RATING: &str =
    "contentRating[]=safe&contentRating[]=suggestive&contentRating[]=erotica";

#[derive(Debug, Clone, PartialEq, Eq)]
pub struct MangaSummary {
    pub id: String,
    pub title: String,
    pub cover_image: String,
    /// Whether MangaDex's own `links.al` on this result equals the AniList
    /// id we searched for — an identity confirmation, not a title guess.
    /// The caller uses this to know when it has found *the* manga rather
    /// than merely *a* plausible one: once a result is AL-confirmed, an
    /// empty chapter list on it means the title just has no English
    /// chapters on MangaDex, not "try the next search result" — falling
    /// through past a confirmed match onto an unrelated title that happens
    /// to share some words is how a completely different manga's chapters
    /// ended up being served under another title's name.
    pub matches_anilist: bool,
}

#[derive(Debug, Clone, PartialEq)]
pub struct Chapter {
    /// The chapter's own number, which is not always an integer — `10.5` is a
    /// real chapter, not a rounding artifact.
    pub number: f64,
    pub title: String,
    /// MangaDex chapter uuid, passed back to `chapter_pages`.
    pub id: String,
    pub pages: u32,
}

#[derive(Debug, Clone, PartialEq, Eq)]
pub struct MangaDetail {
    pub id: String,
    pub title: String,
    pub cover_image: String,
    pub chapters: Vec<ChapterRow>,
}

/// `Chapter` with the float dropped to a string, so `MangaDetail` can stay
/// `Eq` and so the number crosses the FFI exactly as MangaDex wrote it.
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct ChapterRow {
    pub number: String,
    pub title: String,
    pub id: String,
    pub pages: u32,
}

pub struct MangaDexClient {
    http: reqwest::Client,
    cache: Mutex<HashMap<String, (Instant, MangaDetail)>>,
}

impl MangaDexClient {
    pub fn new(http: reqwest::Client) -> Self {
        Self { http, cache: Mutex::new(HashMap::new()) }
    }

    async fn get_json<T: serde::de::DeserializeOwned>(&self, url: &str) -> Result<T, String> {
        let resp = self
            .http
            .get(url)
            .header(reqwest::header::USER_AGENT, USER_AGENT)
            .header(reqwest::header::ACCEPT, "application/json")
            .timeout(REQUEST_TIMEOUT)
            .send()
            .await
            .map_err(|e| e.to_string())?;
        if !resp.status().is_success() {
            return Err(format!("mangadex {} for {url}", resp.status()));
        }
        resp.json::<T>().await.map_err(|e| e.to_string())
    }

    /// Search by title. When `anilist_id` is given, any result MangaDex has
    /// linked to that AniList entry is moved to the front — see the module
    /// note on `links.al`.
    pub async fn search(&self, query: &str, anilist_id: Option<i64>) -> Result<Vec<MangaSummary>, String> {
        let url = format!(
            "{BASE_URL}/manga?title={}&limit=100&includes[]=cover_art&{CONTENT_RATING}&order[relevance]=desc",
            urlencode(query)
        );
        let data: MangaListResponse = self.get_json(&url).await?;
        Ok(rank_search_results(&data.data, anilist_id))
    }

    /// Manga detail plus its full English chapter feed.
    pub async fn detail(&self, manga_id: &str) -> Result<MangaDetail, String> {
        if let Some(hit) = self.cached(manga_id) {
            return Ok(hit);
        }

        let url = format!("{BASE_URL}/manga/{manga_id}?includes[]=cover_art");
        let detail: MangaSingleResponse = self.get_json(&url).await?;
        let title = pick_title(&detail.data.attributes.title);
        let cover_image = cover_url(&detail.data.id, &detail.data.relationships);

        let mut feed: Vec<ChapterEntity> = Vec::new();
        let mut offset = 0usize;
        loop {
            let url = format!(
                "{BASE_URL}/manga/{manga_id}/feed?translatedLanguage[]=en&includeExternalUrl=0\
                 &limit={FEED_PAGE}&offset={offset}&order[chapter]=asc&{CONTENT_RATING}"
            );
            let page: ChapterListResponse = match self.get_json(&url).await {
                Ok(p) => p,
                // A failed later page is a short feed, not a failed detail:
                // the chapters already collected are still readable.
                Err(e) if offset > 0 => {
                    log::warn!("[mangadex] feed page at offset {offset} failed: {e}");
                    break;
                }
                Err(e) => return Err(e),
            };
            let got = page.data.len();
            feed.extend(page.data);
            offset += FEED_PAGE;
            if got < FEED_PAGE || page.total <= offset {
                break;
            }
        }

        let out = MangaDetail {
            id: manga_id.to_string(),
            title,
            cover_image,
            chapters: collapse_feed(&feed),
        };
        if let Ok(mut c) = self.cache.lock() {
            c.insert(manga_id.to_string(), (Instant::now(), out.clone()));
        }
        Ok(out)
    }

    /// Page image URLs for a chapter, in reading order.
    pub async fn chapter_pages(&self, chapter_id: &str) -> Result<Vec<String>, String> {
        let url = format!("{BASE_URL}/at-home/server/{chapter_id}");
        let data: AtHomeResponse = self.get_json(&url).await?;
        if data.chapter.hash.is_empty() || data.chapter.data.is_empty() || data.base_url.is_empty() {
            return Err(format!("mangadex returned no pages for chapter {chapter_id}"));
        }
        Ok(data
            .chapter
            .data
            .iter()
            .map(|f| format!("{}/data/{}/{f}", data.base_url.trim_end_matches('/'), data.chapter.hash))
            .collect())
    }

    fn cached(&self, manga_id: &str) -> Option<MangaDetail> {
        let c = self.cache.lock().ok()?;
        let (at, hit) = c.get(manga_id)?;
        (at.elapsed() < CACHE_TTL).then(|| hit.clone())
    }
}

// --- pure helpers, unit-tested against captured payload shapes ---------------

fn parse_chapter_number(title: &str) -> Option<(String, f64)> {
    let lower = title.to_lowercase();
    let trimmed = lower.trim();
    let rest = if let Some(r) = trimmed.strip_prefix("chapter ") {
        r
    } else if let Some(r) = trimmed.strip_prefix("ch. ") {
        r
    } else if let Some(r) = trimmed.strip_prefix("ch.") {
        r
    } else if let Some(r) = trimmed.strip_prefix("ch ") {
        r
    } else if let Some(r) = trimmed.strip_prefix("ep. ") {
        r
    } else if let Some(r) = trimmed.strip_prefix("ep ") {
        r
    } else {
        trimmed
    };

    let num_str: String = rest.chars().take_while(|c| c.is_ascii_digit() || *c == '.').collect();
    if let Ok(val) = num_str.parse::<f64>() {
        Some((num_str, val))
    } else {
        None
    }
}

fn urlencode(s: &str) -> String {
    let mut out = String::with_capacity(s.len());
    for b in s.as_bytes() {
        match b {
            b'A'..=b'Z' | b'a'..=b'z' | b'0'..=b'9' | b'-' | b'_' | b'.' | b'~' => out.push(*b as char),
            b' ' => out.push('+'),
            _ => out.push_str(&format!("%{b:02X}")),
        }
    }
    out
}

/// English, else the romanised Japanese, else whatever language exists. A
/// manga with only a `ja` title is still a manga we can open.
fn pick_title(titles: &HashMap<String, String>) -> String {
    titles
        .get("en")
        .or_else(|| titles.get("ja-ro"))
        .cloned()
        .or_else(|| titles.values().next().cloned())
        .unwrap_or_else(|| "Unknown".to_string())
}

fn cover_url(manga_id: &str, rels: &[Relationship]) -> String {
    rels.iter()
        .find(|r| r.kind == "cover_art")
        .and_then(|r| r.attributes.as_ref())
        .and_then(|a| a.file_name.as_ref())
        .map(|f| format!("{UPLOADS_URL}/covers/{manga_id}/{f}.512.jpg"))
        .unwrap_or_default()
}

fn rank_search_results(items: &[MangaEntity], anilist_id: Option<i64>) -> Vec<MangaSummary> {
    let (mut matched, mut rest) = (Vec::new(), Vec::new());
    for item in items {
        let linked = anilist_id.is_some_and(|want| {
            item.attributes
                .links
                .as_ref()
                .and_then(|l| l.al.as_ref())
                .and_then(|al| al.trim().parse::<i64>().ok())
                == Some(want)
        });
        let entry = MangaSummary {
            id: item.id.clone(),
            title: pick_title(&item.attributes.title),
            cover_image: cover_url(&item.id, &item.relationships),
            matches_anilist: linked,
        };
        if linked {
            matched.push(entry);
        } else {
            rest.push(entry);
        }
    }
    matched.extend(rest);
    matched
}

fn collapse_feed(feed: &[ChapterEntity]) -> Vec<ChapterRow> {
    let mut best: HashMap<String, (f64, ChapterRow)> = HashMap::new();
    for ch in feed {
        let a = &ch.attributes;
        // `externalUrl` chapters are hosted off MangaDex and have no pages to
        // fetch; `pages == 0` is an upload still being processed.
        if a.pages == 0 || a.external_url.is_some() {
            continue;
        }
        let (num_str, num) = match a.chapter.as_deref() {
            Some(s) => match s.trim().parse::<f64>() {
                Ok(n) => (s.trim().to_string(), n),
                Err(_) => continue,
            },
            None => {
                if let Some(ref t) = a.title {
                    if let Some(parsed) = parse_chapter_number(t) {
                        parsed
                    } else {
                        continue;
                    }
                } else {
                    continue;
                }
            }
        };

        let title = match a.title.as_deref().filter(|t| !t.trim().is_empty()) {
            Some(t) => format!("Chapter {num_str}: {t}"),
            None => format!("Chapter {num_str}"),
        };
        let row = ChapterRow {
            number: num_str.clone(),
            title,
            id: ch.id.clone(),
            pages: a.pages,
        };
        match best.get(&num_str) {
            Some((_, prev)) if prev.pages >= a.pages => {}
            _ => {
                best.insert(num_str, (num, row));
            }
        }
    }

    let mut out: Vec<(f64, ChapterRow)> = best.into_values().collect();
    out.sort_by(|a, b| a.0.partial_cmp(&b.0).unwrap_or(std::cmp::Ordering::Equal));
    let mut rows: Vec<ChapterRow> = out.into_iter().map(|(_, r)| r).collect();

    // A oneshot has pages but no chapter number, so the loop above discards
    // every entry and the manga reads as having nothing to open.
    if rows.is_empty() {
        if let Some(ch) = feed
            .iter()
            .find(|c| c.attributes.pages > 0 && c.attributes.external_url.is_none())
        {
            let t = ch.attributes.title.clone().unwrap_or_else(|| "Oneshot".into());
            rows.push(ChapterRow {
                number: "1".into(),
                title: format!("Chapter 1: {t}"),
                id: ch.id.clone(),
                pages: ch.attributes.pages,
            });
        }
    }
    rows
}

// --- wire types -------------------------------------------------------------

#[derive(Deserialize)]
struct MangaListResponse {
    #[serde(default)]
    data: Vec<MangaEntity>,
}

#[derive(Deserialize)]
struct MangaSingleResponse {
    data: MangaEntity,
}

#[derive(Deserialize)]
struct MangaEntity {
    #[serde(default)]
    id: String,
    #[serde(default)]
    attributes: MangaAttributes,
    #[serde(default)]
    relationships: Vec<Relationship>,
}

#[derive(Deserialize, Default)]
struct MangaAttributes {
    #[serde(default)]
    title: HashMap<String, String>,
    #[serde(default)]
    links: Option<Links>,
}

#[derive(Deserialize)]
struct Links {
    #[serde(default)]
    al: Option<String>,
}

#[derive(Deserialize)]
struct Relationship {
    #[serde(rename = "type", default)]
    kind: String,
    #[serde(default)]
    attributes: Option<RelationshipAttributes>,
}

#[derive(Deserialize)]
struct RelationshipAttributes {
    #[serde(rename = "fileName", default)]
    file_name: Option<String>,
}

#[derive(Deserialize)]
struct ChapterListResponse {
    #[serde(default)]
    data: Vec<ChapterEntity>,
    #[serde(default)]
    total: usize,
}

#[derive(Deserialize)]
struct ChapterEntity {
    #[serde(default)]
    id: String,
    #[serde(default)]
    attributes: ChapterAttributes,
}

#[derive(Deserialize, Default)]
struct ChapterAttributes {
    #[serde(default)]
    chapter: Option<String>,
    #[serde(default)]
    title: Option<String>,
    #[serde(default)]
    pages: u32,
    #[serde(rename = "externalUrl", default)]
    external_url: Option<String>,
}

#[derive(Deserialize)]
struct AtHomeResponse {
    #[serde(rename = "baseUrl", default)]
    base_url: String,
    #[serde(default)]
    chapter: AtHomeChapter,
}

#[derive(Deserialize, Default)]
struct AtHomeChapter {
    #[serde(default)]
    hash: String,
    #[serde(default)]
    data: Vec<String>,
}

#[cfg(test)]
mod tests;
