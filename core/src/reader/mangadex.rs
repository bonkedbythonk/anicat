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
//!
//! A third one is new to this port:
//!
//! * **A sparse feed is filled from MangaKatana.** For a title licensed in
//!   English, MangaDex keeps only the chapters the publisher has not taken
//!   down, which for a Shueisha/Viz title is the last few simulpub releases:
//!   One Piece's English feed on 2026-09-07 was `total: 1`, chapter 1191,
//!   with chapters 1-4 and 1189-1192 present only as `pages: 0` links to
//!   mangaplus.shueisha.co.jp. The reader showed that one chapter and
//!   nothing else, because the MangaKatana fallback only ran when MangaDex
//!   had *nothing* readable. MangaKatana's `one-piece.49` page lists 1198
//!   chapters, 1 through 1192. See `sparse_feed` for the bar and
//!   `merge_chapter_lists` for why the two sources can share one list.

use std::collections::{HashMap, HashSet};
use std::sync::Mutex;
use std::time::{Duration, Instant};

use serde::Deserialize;

use super::mangakatana::MangaKatanaClient;

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
    /// The fill for a sparse feed runs inside `detail` rather than as a step
    /// beside it so the merged list sits in the same cache entry: a step in
    /// the FFI layer would re-run MangaKatana's search and page scrape (two
    /// requests, no cache of their own) every time the title was opened.
    katana: MangaKatanaClient,
}

impl MangaDexClient {
    pub fn new(http: reqwest::Client) -> Self {
        Self {
            katana: MangaKatanaClient::new(http.clone()),
            http,
            cache: Mutex::new(HashMap::new()),
        }
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

    /// Manga detail plus its English chapter feed, filled from MangaKatana
    /// when the feed is sparse (see the module note).
    pub async fn detail(&self, manga_id: &str) -> Result<MangaDetail, String> {
        if let Some(hit) = self.cached(manga_id) {
            return Ok(hit);
        }

        let url = format!("{BASE_URL}/manga/{manga_id}?includes[]=cover_art");
        let detail: MangaSingleResponse = self.get_json(&url).await?;
        let title = pick_title(&detail.data.attributes.title);
        let cover_image = cover_url(&detail.data.id, &detail.data.relationships);
        let known_titles = all_titles(&detail.data.attributes, &title);
        let declared_last = detail
            .data
            .attributes
            .last_chapter
            .as_deref()
            .and_then(chapter_value)
            .filter(|n| *n > 0.0);

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

        let mut chapters = collapse_feed(&feed);
        if let Some(why) = sparse_feed(&chapters, declared_last) {
            chapters = self.fill_from_katana(&known_titles, chapters, why).await;
        }

        let out = MangaDetail {
            id: manga_id.to_string(),
            title,
            cover_image,
            chapters,
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

    /// Adds MangaKatana's chapters for the same title to a feed that
    /// `sparse_feed` judged to be missing most of its run. A failure on the
    /// MangaKatana side is logged and the MangaDex rows are returned as they
    /// were: they are readable on their own, and a title that opened before
    /// must keep opening while the fallback site is down.
    async fn fill_from_katana(&self, titles: &[String], rows: Vec<ChapterRow>, why: SparseFeed) -> Vec<ChapterRow> {
        let Some(query) = titles.first() else { return rows };
        let results = match self.katana.search(query).await {
            Ok(r) => r,
            Err(e) => {
                log::warn!("[mangadex] \"{query}\" feed is sparse ({why}); mangakatana search failed: {e}");
                return rows;
            }
        };
        let Some(hit) = pick_fallback(&results, titles) else {
            log::info!(
                "[mangadex] \"{query}\" feed is sparse ({why}); none of {} mangakatana results share its title",
                results.len()
            );
            return rows;
        };
        let fill = match self.katana.detail(&hit.id).await {
            Ok(d) => d.chapters,
            Err(e) => {
                log::warn!("[mangadex] \"{query}\" feed is sparse ({why}); mangakatana detail {} failed: {e}", hit.id);
                return rows;
            }
        };
        let before = rows.len();
        let merged = merge_chapter_lists(rows, fill);
        log::info!(
            "[mangadex] \"{query}\" feed is sparse ({why}); +{} chapters from {}",
            merged.len() - before,
            hit.id
        );
        merged
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

/// Every name MangaDex knows the manga by, the display title first: the
/// display title is the search query, the rest widen the match against what
/// MangaKatana calls it. One Piece's `title` is `{ja-ro: "One Piece"}` with
/// every other name under `altTitles`; the display title alone matches
/// there, but a title whose `en` is a publisher's rename and whose
/// MangaKatana page keeps the romaji only matches through the alternates.
fn all_titles(attrs: &MangaAttributes, display: &str) -> Vec<String> {
    let mut out = vec![display.to_string()];
    let more = attrs.title.values().chain(attrs.alt_titles.iter().flat_map(|m| m.values()));
    for t in more {
        if !out.iter().any(|seen| seen == t) {
            out.push(t.clone());
        }
    }
    out
}

/// The numeric value of a chapter number as either source wrote it.
fn chapter_value(number: &str) -> Option<f64> {
    number.trim().parse::<f64>().ok().filter(|n| n.is_finite())
}

/// What `sparse_feed` saw, carried into the log line so a wrong call can be
/// read off the log instead of reproduced.
#[derive(Debug, Clone, Copy, PartialEq)]
struct SparseFeed {
    count: usize,
    lowest: f64,
    expected: f64,
}

impl std::fmt::Display for SparseFeed {
    fn fmt(&self, f: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
        write!(f, "{} chapters, lowest {}, run reaches {}", self.count, self.lowest, self.expected)
    }
}

/// Whether a feed with readable chapters is nonetheless missing most of the
/// run, so that MangaKatana should be asked for the rest.
///
/// Two bars, either one is enough:
///
/// * The lowest chapter is above 1. A feed that begins at chapter 1191 (One
///   Piece) or at chapter 20 cannot be started from, whatever else it holds.
/// * Fewer than half the chapters the run is known to have. "Known" is the
///   larger of MangaDex's own `lastChapter` and the highest number in the
///   feed: `lastChapter` is `""` for an ongoing title (One Piece) and `"0"`
///   for some finished ones, while the highest chapter present proves the
///   run goes at least that far.
///
/// An empty feed is not sparse. That is the takedown case, and the caller
/// already has a path for it (`reader::mangakatana`'s module comment).
fn sparse_feed(rows: &[ChapterRow], declared_last: Option<f64>) -> Option<SparseFeed> {
    let values: Vec<f64> = rows.iter().filter_map(|r| chapter_value(&r.number)).collect();
    if values.is_empty() {
        return None;
    }
    let lowest = values.iter().copied().fold(f64::INFINITY, f64::min);
    let highest = values.iter().copied().fold(f64::NEG_INFINITY, f64::max);
    let expected = declared_last.unwrap_or(0.0).max(highest);
    let count = rows.len();
    let starts_late = lowest > 1.0;
    let mostly_missing = (count as f64) * 2.0 < expected;
    (starts_late || mostly_missing).then_some(SparseFeed { count, lowest, expected })
}

/// The MangaKatana result that is this manga, by title, or none.
///
/// Equality after `normalize_title`, never "the first result": the search
/// page for "One Piece" lists five real hits and then the site's sidebar
/// ("Grand Blue", "Sakamoto Days", ...), which the scraper cannot tell
/// apart, and "One Piece Episode Ace" sits second. The first result happens
/// to be right for One Piece and wrong for any title whose own page is
/// outranked by a spin-off with a longer name.
fn pick_fallback<'a>(results: &'a [MangaSummary], titles: &[String]) -> Option<&'a MangaSummary> {
    let wanted: Vec<String> = titles.iter().map(|t| normalize_title(t)).filter(|t| !t.is_empty()).collect();
    results.iter().find(|r| {
        let got = normalize_title(&r.title);
        !got.is_empty() && wanted.contains(&got)
    })
}

/// Lowercase alphanumerics only, so "ONE PIECE", "One Piece" and "One-Piece"
/// compare equal while "One Piece Party" does not.
fn normalize_title(title: &str) -> String {
    title.chars().filter(|c| c.is_alphanumeric()).flat_map(char::to_lowercase).collect()
}

/// One chapter list out of two sources, deduplicated by chapter number with
/// the MangaDex row winning a collision, sorted numerically.
///
/// The rows can share a list because a chapter id already names its source:
/// MangaDex ids are UUIDs, MangaKatana ids are the site's page URLs, and
/// `AnicatEngine::get_manga_pages` routes on that shape. No provider field
/// is needed on the row and the FFI record is unchanged.
///
/// The number is compared as a value, not a string: MangaDex stores what the
/// uploader typed, so "10" and "10.0" are one chapter, and a string key
/// would list it twice.
fn merge_chapter_lists(primary: Vec<ChapterRow>, fill: Vec<ChapterRow>) -> Vec<ChapterRow> {
    // `+ 0.0` folds a negative zero into positive so the bit patterns agree.
    let key = |n: f64| (n + 0.0).to_bits();
    let mut seen: HashSet<u64> = primary.iter().filter_map(|r| chapter_value(&r.number)).map(key).collect();
    let mut out = primary;
    for row in fill {
        match chapter_value(&row.number) {
            Some(n) if !seen.insert(key(n)) => continue,
            _ => out.push(row),
        }
    }
    // Stable, and a row without a parseable number sorts last rather than
    // being dropped: both parsers only emit numeric strings today, but a
    // future oneshot row must not vanish from the merged list.
    out.sort_by(|a, b| match (chapter_value(&a.number), chapter_value(&b.number)) {
        (Some(x), Some(y)) => x.partial_cmp(&y).unwrap_or(std::cmp::Ordering::Equal),
        (Some(_), None) => std::cmp::Ordering::Less,
        (None, Some(_)) => std::cmp::Ordering::Greater,
        (None, None) => std::cmp::Ordering::Equal,
    });
    out
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
    #[serde(rename = "altTitles", default)]
    alt_titles: Vec<HashMap<String, String>>,
    /// A string on the wire: `""` for an ongoing title and `"0"` for some
    /// finished ones, which is why `detail` parses and filters it before
    /// `sparse_feed` sees it.
    #[serde(rename = "lastChapter", default)]
    last_chapter: Option<String>,
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
