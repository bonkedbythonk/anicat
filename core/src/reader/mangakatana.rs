//! MangaKatana HTML scraper — the fallback source when MangaDex has confirmed
//! the AniList match but has nothing readable under it (a publisher takedown
//! leaves every English chapter at `pages: 0`; see `reader::mangadex`'s
//! `matches_anilist` doc comment for the concrete case: "Tomodachi Game" has
//! 127 chapters on MangaKatana and zero readable ones on MangaDex). MangaKatana
//! carries no AniList cross-reference, so results here are title-matched only
//! and are always tried after MangaDex, never instead of it.
//!
//! Ported from the Python provider (`scraper/mangakatana.py`) this replaces.
//! The site has no Cloudflare challenge in front of it (confirmed against the
//! live site), so a plain browser `User-Agent` is enough — no TLS
//! fingerprint impersonation needed, unlike the sites that pushed the Python
//! sidecar towards `curl_cffi`.

use std::time::Duration;

use regex_lite::Regex;

use super::mangadex::{ChapterRow, MangaDetail, MangaSummary};

const BASE_URL: &str = "https://mangakatana.com";
const REQUEST_TIMEOUT: Duration = Duration::from_secs(20);
const USER_AGENT: &str =
    "Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/131.0.0.0 Safari/537.36";

pub struct MangaKatanaClient {
    http: reqwest::Client,
}

impl MangaKatanaClient {
    pub fn new(http: reqwest::Client) -> Self {
        Self { http }
    }

    async fn get_html(&self, url: &str) -> Result<(String, String), String> {
        let resp = self
            .http
            .get(url)
            .header(reqwest::header::USER_AGENT, USER_AGENT)
            .header(reqwest::header::REFERER, BASE_URL)
            .timeout(REQUEST_TIMEOUT)
            .send()
            .await
            .map_err(|e| e.to_string())?;
        if !resp.status().is_success() {
            return Err(format!("mangakatana {} for {url}", resp.status()));
        }
        let final_url = resp.url().to_string();
        let html = resp.text().await.map_err(|e| e.to_string())?;
        Ok((html, final_url))
    }

    /// Title search. A single strong hit redirects straight to the manga page
    /// rather than a results list, so both shapes have to be handled.
    pub async fn search(&self, query: &str) -> Result<Vec<MangaSummary>, String> {
        let url = format!("{BASE_URL}/?search={}&search_by=book_name", urlencode(query));
        let (html, final_url) = self.get_html(&url).await?;
        if final_url.contains("/manga/") && !final_url.contains("search=") {
            Ok(parse_single_result(&html, &final_url))
        } else {
            Ok(parse_search_results(&html))
        }
    }

    /// Manga detail plus its chapter list. `manga_id` is the manga's page URL
    /// — MangaKatana has no separate numeric id, and the URL is stable.
    pub async fn detail(&self, manga_id: &str) -> Result<MangaDetail, String> {
        let (html, _) = self.get_html(manga_id).await?;
        let (title, cover_image, chapters) = parse_manga_page(&html);
        Ok(MangaDetail { id: manga_id.to_string(), title, cover_image, chapters })
    }

    /// Page image URLs for a chapter. `chapter_id` is the chapter's page URL.
    pub async fn chapter_pages(&self, chapter_id: &str) -> Result<Vec<String>, String> {
        let (html, _) = self.get_html(chapter_id).await?;
        let pages = parse_chapter_pages(&html);
        if pages.is_empty() {
            return Err(format!("mangakatana returned no pages for chapter {chapter_id}"));
        }
        Ok(pages)
    }
}

// --- pure helpers, unit-tested against captured markup shapes ---------------

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

fn first_capture(re: &Regex, haystack: &str) -> Option<String> {
    re.captures(haystack).and_then(|c| c.get(1)).map(|m| m.as_str().to_string())
}

fn parse_single_result(html: &str, url: &str) -> Vec<MangaSummary> {
    let title_re = Regex::new(r"<h1[^>]*>([^<]+)</h1>").unwrap();
    let cover_re = Regex::new(r#"class="cover"[^>]*>(?s:.*?)<img[^>]+src="([^"]+)""#).unwrap();
    let title = first_capture(&title_re, html).unwrap_or_else(|| "Unknown".to_string());
    let cover_image = first_capture(&cover_re, html).unwrap_or_default();
    vec![MangaSummary { id: url.to_string(), title, cover_image, matches_anilist: false }]
}

fn parse_search_results(html: &str) -> Vec<MangaSummary> {
    // A result item's internal div nesting makes matching a whole `.item`
    // block with a regex unreliable, so items are instead located by their
    // one reliably non-nested anchor — the title link — and each cover is
    // recovered by scanning backward from that anchor to the nearest `<img>`,
    // which sits earlier in the same item's markup.
    let title_re = Regex::new(r#"class="title"[^>]*>\s*<a[^>]+href="([^"]+)"[^>]*>([^<]+)</a>"#).unwrap();
    let cover_re = Regex::new(r#"<img[^>]+src="([^"]+)""#).unwrap();

    let mut out = Vec::new();
    for cap in title_re.captures_iter(html) {
        let start = cap.get(0).unwrap().start();
        let href = cap[1].to_string();
        let title = cap[2].trim().to_string();
        // `start` always lands on a boundary (it is a regex match start),
        // but subtracting a fixed byte count can land mid-codepoint when a
        // multibyte title sits in the preceding 600 bytes, so the cut point
        // is walked forward to the next valid boundary rather than sliced
        // blind — a raw slice there panics instead of just missing a cover.
        let mut window_start = start.saturating_sub(600);
        while window_start < start && !html.is_char_boundary(window_start) {
            window_start += 1;
        }
        let window = &html[window_start..start];
        let cover_image = cover_re
            .captures_iter(window)
            .last()
            .map(|c| c[1].to_string())
            .unwrap_or_default();
        let manga_url = if href.starts_with("http") { href } else { format!("{BASE_URL}{href}") };
        out.push(MangaSummary { id: manga_url, title, cover_image, matches_anilist: false });
    }
    out
}

fn parse_manga_page(html: &str) -> (String, String, Vec<ChapterRow>) {
    let title_re = Regex::new(r#"<h1 class="heading">([^<]+)</h1>"#)
        .unwrap();
    let title_fallback_re = Regex::new(r"<h1[^>]*>([^<]+)</h1>").unwrap();
    let title = first_capture(&title_re, html)
        .or_else(|| first_capture(&title_fallback_re, html))
        .unwrap_or_else(|| "Unknown".to_string())
        .trim()
        .to_string();

    let cover_re = Regex::new(r#"class="cover"[^>]*>(?s:.*?)<img[^>]+src="([^"]+)""#).unwrap();
    let cover_image = first_capture(&cover_re, html).unwrap_or_default();

    let chapters = parse_chapter_list(html);
    (title, cover_image, chapters)
}

fn parse_chapter_number(title: &str) -> Option<String> {
    let re = Regex::new(r"Chapter\s+(\d+(?:\.\d+)?)").unwrap();
    re.captures(title).map(|c| c[1].to_string())
}

fn parse_chapter_list(html: &str) -> Vec<ChapterRow> {
    let anchor_re = Regex::new(r#"class="chapter"><a href="([^"]+)">([^<]+)</a>"#).unwrap();
    let mut rows: Vec<ChapterRow> = Vec::new();
    for cap in anchor_re.captures_iter(html) {
        let href = cap[1].to_string();
        // MangaKatana's own titles carry raw `&quot;`/`&amp;` entities;
        // decoding just the handful that actually show up in chapter names
        // avoids pulling in a whole HTML-entity crate for four escapes.
        let raw_title = html_unescape(cap[2].trim());
        let Some(number) = parse_chapter_number(&raw_title) else { continue };
        let url = if href.starts_with("http") { href } else { format!("{BASE_URL}{href}") };
        rows.push(ChapterRow { number, title: raw_title, id: url, pages: 1 });
    }
    // The site lists newest first; readers expect ascending order.
    rows.reverse();
    rows
}

fn html_unescape(s: &str) -> String {
    s.replace("&quot;", "\"")
        .replace("&amp;", "&")
        .replace("&#39;", "'")
        .replace("&lt;", "<")
        .replace("&gt;", ">")
}

fn parse_chapter_pages(html: &str) -> Vec<String> {
    // The reader's pages live in a JS array literal the chapter-view script
    // assigns on load, e.g. `var thzq=['https://.../1.jpg','https://.../2.jpg'];`
    // — the variable name is generated per-build, so it is matched
    // structurally (an assignment to a bracketed, comma-separated string
    // list) rather than by name.
    let array_re = Regex::new(r"var\s+\w+\s*=\s*\[([^\]]+)\]\s*;").unwrap();
    let url_re = Regex::new(r#"['"]([^'"]+\.(?:jpg|jpeg|png|webp)[^'"]*)['"]"#).unwrap();

    for cap in array_re.captures_iter(html) {
        let urls: Vec<String> = url_re.captures_iter(&cap[1]).map(|m| m[1].to_string()).collect();
        if urls.len() > 1 {
            return urls;
        }
    }

    // Fall back to scanning the reader's own image container directly.
    if let Some(section) = Regex::new(r#"(?s)id="imgs"[^>]*>(.*?)</div>"#).unwrap().captures(html) {
        let img_re = Regex::new(r#"<img[^>]+src="([^"]+\.(?:jpg|jpeg|png|webp)[^"]*)""#).unwrap();
        return img_re.captures_iter(&section[1]).map(|m| m[1].to_string()).collect();
    }
    Vec::new()
}

#[cfg(test)]
mod tests;
