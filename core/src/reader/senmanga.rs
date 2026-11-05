//! Sen Manga (raw.senmanga.com) -- the Japanese-language source. MangaDex has
//! 1,364 Japanese chapters across 153 titles against 615,495 English ones
//! (measured 2026-11-05), and One Piece and Chainsaw Man have none, so raws
//! come from here instead.
//!
//! The site is a JavaScript app over a plain JSON API, so there is no HTML to
//! scrape: `/api/manga/<slug>` (detail plus `chapterList`) and
//! `/api/read/<slug>/<chapter url>` (page image URLs). The page images sit on
//! a CDN that needs no Referer.
//!
//! **There is no search.** `/api/search` and `/api/directory` ignore every
//! query parameter we tried (q, query, s, title, keyword, search, name) and
//! answer the same unfiltered page, and the site's own search box shows that
//! page too; the directory is open-ended (`totalPages` grows with the page
//! asked for), so it cannot be indexed either. A slug is the title in
//! kebab-case romaji (`chainsaw-man`, `one-piece`), which is what AniList
//! calls these titles, so `search` slugifies the query and asks for that
//! manga directly: one exact request, empty on a 404.
//!
//! A manga id is `senmanga:<slug>` and a chapter id is
//! `senmanga:<slug>/<chapter url>`; the prefix is how the FFI layer routes a
//! chapter back here without a provider field on the shared types.
//!
//! The catalogue mixes in adult titles, and the app never shows those:
//! `detail` refuses one tagged Adult or Hentai. Not "Mature", which the site
//! also puts on Chainsaw Man.

use std::time::Duration;

use serde::Deserialize;

use super::mangadex::{ChapterRow, MangaDetail, MangaSummary};

const BASE_URL: &str = "https://raw.senmanga.com";
const REQUEST_TIMEOUT: Duration = Duration::from_secs(20);
const USER_AGENT: &str =
    "Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/131.0.0.0 Safari/537.36";
pub const ID_PREFIX: &str = "senmanga:";

pub fn is_senmanga_id(id: &str) -> bool {
    id.starts_with(ID_PREFIX)
}

#[derive(Deserialize)]
struct DetailResponse {
    title: String,
    #[serde(default)]
    cover: String,
    #[serde(default)]
    genre: Option<String>,
    #[serde(default, rename = "chapterList")]
    chapter_list: Vec<ChapterItem>,
}

#[derive(Deserialize)]
struct ChapterItem {
    title: String,
    number: String,
    url: String,
}

#[derive(Deserialize)]
struct ReadResponse {
    #[serde(default)]
    pages: Vec<String>,
}

pub struct SenMangaClient {
    http: reqwest::Client,
}

impl SenMangaClient {
    pub fn new(http: reqwest::Client) -> Self {
        Self { http }
    }

    async fn get_json<T: serde::de::DeserializeOwned>(&self, url: &str) -> Result<T, String> {
        self.get_json_opt(url).await?.ok_or_else(|| format!("senmanga 404 for {url}"))
    }

    /// `None` for a manga the site does not have. It answers 500, not 404,
    /// for an unknown slug (`/api/manga/zzzz-not-a-manga` and Nisekoi both
    /// give `{"status":500,"error":"Internal Error"}`, measured 2026-11-05),
    /// so a real outage reads as "not on the site" here as well; the reader
    /// shows the same empty state either way.
    async fn get_json_opt<T: serde::de::DeserializeOwned>(&self, url: &str) -> Result<Option<T>, String> {
        let resp = self
            .http
            .get(url)
            .header(reqwest::header::USER_AGENT, USER_AGENT)
            .header(reqwest::header::REFERER, BASE_URL)
            .timeout(REQUEST_TIMEOUT)
            .send()
            .await
            .map_err(|e| e.to_string())?;
        if matches!(resp.status(), reqwest::StatusCode::NOT_FOUND | reqwest::StatusCode::INTERNAL_SERVER_ERROR) {
            return Ok(None);
        }
        if !resp.status().is_success() {
            return Err(format!("senmanga {} for {url}", resp.status()));
        }
        resp.json::<T>().await.map(Some).map_err(|e| e.to_string())
    }

    /// At most one hit: the manga whose slug is the query's. See the module
    /// note for why this is not a search.
    pub async fn search(&self, query: &str) -> Result<Vec<MangaSummary>, String> {
        let slug = slugify(query);
        if slug.is_empty() {
            return Ok(Vec::new());
        }
        let found: Option<DetailResponse> = self.get_json_opt(&format!("{BASE_URL}/api/manga/{slug}")).await?;
        Ok(found
            .map(|d| MangaSummary {
                id: format!("{ID_PREFIX}{slug}"),
                title: d.title,
                cover_image: d.cover,
                matches_anilist: false,
            })
            .into_iter()
            .collect())
    }

    pub async fn detail(&self, manga_id: &str) -> Result<MangaDetail, String> {
        let slug = manga_id.strip_prefix(ID_PREFIX).ok_or("not a senmanga id")?;
        let data: DetailResponse = self.get_json(&format!("{BASE_URL}/api/manga/{slug}")).await?;
        if is_adult(data.genre.as_deref()) {
            return Err(format!("senmanga title {slug} is adult"));
        }
        Ok(MangaDetail {
            id: manga_id.to_string(),
            title: data.title,
            cover_image: data.cover,
            chapters: chapter_rows(slug, data.chapter_list),
        })
    }

    pub async fn chapter_pages(&self, chapter_id: &str) -> Result<Vec<String>, String> {
        let path = chapter_id.strip_prefix(ID_PREFIX).ok_or("not a senmanga id")?;
        let data: ReadResponse = self.get_json(&format!("{BASE_URL}/api/read/{path}")).await?;
        if data.pages.is_empty() {
            return Err(format!("senmanga returned no pages for chapter {chapter_id}"));
        }
        Ok(data.pages)
    }
}

fn is_adult(genre: Option<&str>) -> bool {
    genre.is_some_and(|g| {
        g.split(',').any(|t| matches!(t.trim().to_ascii_lowercase().as_str(), "adult" | "hentai"))
    })
}

/// The site lists newest first; the reader wants oldest first. Reversing is
/// safe here, unlike MangaKatana, because this list is one JSON array in the
/// API's own order, not a table with a client-side sort toggle.
fn chapter_rows(slug: &str, items: Vec<ChapterItem>) -> Vec<ChapterRow> {
    let mut rows: Vec<(f64, ChapterRow)> = items
        .into_iter()
        .filter_map(|c| {
            let value = c.number.parse::<f64>().ok()?;
            Some((
                value,
                ChapterRow {
                    number: c.number,
                    title: c.title,
                    id: format!("{ID_PREFIX}{slug}/{}", c.url),
                    pages: 1,
                    scanlation_group: None,
                },
            ))
        })
        .collect();
    rows.sort_by(|a, b| a.0.partial_cmp(&b.0).unwrap_or(std::cmp::Ordering::Equal));
    rows.into_iter().map(|(_, r)| r).collect()
}

/// `Chainsaw Man` -> `chainsaw-man`; punctuation drops out and runs of
/// anything else become one hyphen, which is how the site spells its slugs.
fn slugify(s: &str) -> String {
    let mut out = String::new();
    for c in s.chars() {
        if c.is_ascii_alphanumeric() {
            out.push(c.to_ascii_lowercase());
        } else if !matches!(c, '\'' | '\u{2019}' | '"') && !out.ends_with('-') && !out.is_empty() {
            out.push('-');
        }
    }
    out.trim_end_matches('-').to_string()
}

#[cfg(test)]
mod tests;
