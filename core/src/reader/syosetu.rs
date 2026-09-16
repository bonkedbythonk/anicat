//! Syosetu (ncode.syosetu.com) light-novel reader — first native light-novel
//! source, ported off `scraper/novel/scrapers/syosetu.py`. Deliberately not
//! wired to RanobeDB matching (`scraper/novel/scrapers/lnori.py`'s job in the
//! Tauri app): this takes a Syosetu URL directly, so a viewer pastes the
//! `ncode.syosetu.com/nXXXXXX/` link themselves rather than the app resolving
//! one from an AniList/RanobeDB entry. That matching step is real work for a
//! later pass, not a shortcut taken here.
//!
//! Only the modern `p-eplist__`/`p-novel__` markup is handled — the legacy
//! `novel_sublist2`/`novel_honbun` classes the Python scraper also checked
//! are years retired on the live site and aren't reproduced here.
//!
//! Chapter text comes back as plain paragraphs, not HTML: each line of prose
//! sits in its own `<p id="L123">`, so pulling exactly those out and joining
//! them with blank lines is both simpler and more robust than trying to
//! regex-balance the surrounding `<div class="p-novel__body">`'s nested tags.
//! It also means the reader UI can be a plain scrolling text view instead of
//! embedding a web view to render scraped HTML.

use std::time::Duration;

use regex_lite::Regex;

const USER_AGENT: &str =
    "Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/131.0.0.0 Safari/537.36";
const REQUEST_TIMEOUT: Duration = Duration::from_secs(20);

#[derive(Debug, Clone)]
pub struct NovelChapterRef {
    pub index: i32,
    pub title: String,
    pub url: String,
    pub volume_name: Option<String>,
}

#[derive(Debug, Clone)]
pub struct NovelInfo {
    pub title: String,
    pub author: String,
    pub description: String,
    pub chapters: Vec<NovelChapterRef>,
}

#[derive(Debug, Clone)]
pub struct NovelChapterContent {
    pub title: String,
    pub text: String,
    /// Illustrations, each with the index of the paragraph it follows (-1 for
    /// one before any prose). Always empty for Syosetu, which is a web-novel
    /// site and serves text.
    pub images: Vec<(i32, String)>,
}

pub struct SyosetuClient {
    http: reqwest::Client,
}

impl SyosetuClient {
    pub fn new(http: reqwest::Client) -> Self {
        Self { http }
    }

    pub fn can_handle(url: &str) -> bool {
        let host = url.split("://").nth(1).and_then(|s| s.split('/').next()).unwrap_or("");
        host.contains("syosetu.com") && !host.contains("syosetu.org")
    }

    async fn get_html(&self, url: &str) -> Result<String, String> {
        let resp = self
            .http
            .get(url)
            .header(reqwest::header::USER_AGENT, USER_AGENT)
            // Syosetu gates its adult-fiction subdomain behind this cookie;
            // harmless on the main site, required on novel18.syosetu.com.
            .header(reqwest::header::COOKIE, "over18=yes")
            .timeout(REQUEST_TIMEOUT)
            .send()
            .await
            .map_err(|e| e.to_string())?;
        if !resp.status().is_success() {
            return Err(format!("syosetu {} for {url}", resp.status()));
        }
        resp.text().await.map_err(|e| e.to_string())
    }

    /// `https://ncode.syosetu.com/n2267be/1/` -> `https://ncode.syosetu.com/n2267be/`.
    fn normalize_base_url(url: &str) -> String {
        let re = Regex::new(r"^(https?://[^/]+)/(n[0-9a-z]+)/?").unwrap();
        match re.captures(url) {
            Some(c) => format!("{}/{}/", &c[1], &c[2]),
            None => url.to_string(),
        }
    }

    pub async fn novel_info(&self, url: &str) -> Result<NovelInfo, String> {
        let base_url = Self::normalize_base_url(url);
        let html = self.get_html(&base_url).await?;

        let title_re = Regex::new(r#"class="p-novel__title[^"]*"[^>]*>([^<]+)</h1>"#).unwrap();
        let title = capture(&title_re, &html).unwrap_or_else(|| "Unknown Novel".to_string());

        let author_re = Regex::new(r#"p-novel__author"[^>]*>作者：(?s:(.*?))</div>"#).unwrap();
        let author = capture(&author_re, &html)
            .map(|s| strip_tags(&s).trim().to_string())
            .unwrap_or_else(|| "Unknown Author".to_string());

        let summary_re = Regex::new(r#"p-novel__summary"[^>]*>(?s:(.*?))</div>"#).unwrap();
        let description = capture(&summary_re, &html)
            .map(|s| html_to_text(&s))
            .unwrap_or_default();

        let page_re = Regex::new(r"\?p=(\d+)").unwrap();
        let total_pages = page_re
            .captures_iter(&html)
            .filter_map(|c| c[1].parse::<u32>().ok())
            .max()
            .unwrap_or(1);

        let mut chapters = parse_toc_page(&html, &base_url, 0);
        for p in 2..=total_pages {
            let page_html = self.get_html(&format!("{base_url}?p={p}")).await?;
            let start = chapters.len() as i32;
            chapters.extend(parse_toc_page(&page_html, &base_url, start));
        }

        Ok(NovelInfo { title, author, description, chapters })
    }

    pub async fn chapter_content(&self, url: &str) -> Result<NovelChapterContent, String> {
        let html = self.get_html(url).await?;

        let title_re = Regex::new(r#"class="p-novel__title[^"]*"[^>]*>([^<]+)</h1>"#).unwrap();
        let title = capture(&title_re, &html).unwrap_or_default();

        let para_re = Regex::new(r#"<p id="L\d+"[^>]*>(?s:(.*?))</p>"#).unwrap();
        let paragraphs: Vec<String> = para_re
            .captures_iter(&html)
            .map(|c| strip_tags(&c[1]).trim().to_string())
            .collect();
        if paragraphs.is_empty() {
            return Err(format!("syosetu returned no chapter text for {url}"));
        }
        let text = paragraphs.join("\n\n");
        Ok(NovelChapterContent { title, text, images: Vec::new() })
    }
}

// --- pure helpers, unit-tested against captured markup shapes ---------------

fn capture(re: &Regex, haystack: &str) -> Option<String> {
    re.captures(haystack).and_then(|c| c.get(1)).map(|m| m.as_str().to_string())
}

fn strip_tags(html: &str) -> String {
    let tag_re = Regex::new(r"<[^>]+>").unwrap();
    decode_entities(&tag_re.replace_all(html, ""))
}

/// `<br>`/`<br />` become newlines before the tags are stripped, so a
/// multi-line block (the author line, the summary) keeps its line breaks
/// instead of running everything together.
fn html_to_text(html: &str) -> String {
    let br_re = Regex::new(r"(?i)<br\s*/?>").unwrap();
    strip_tags(&br_re.replace_all(html, "\n")).trim().to_string()
}

fn decode_entities(s: &str) -> String {
    s.replace("&nbsp;", " ")
        .replace("&amp;", "&")
        .replace("&lt;", "<")
        .replace("&gt;", ">")
        .replace("&quot;", "\"")
        .replace("&#39;", "'")
}

/// One TOC page's chapters, in document order. `p-eplist__chapter-title`
/// (a volume header) and `p-eplist__sublist` (one chapter link) are scanned
/// together with a single alternation so the volume a chapter belongs to is
/// whatever header most recently appeared above it in the source — matching
/// what the reader sees on the page.
fn parse_toc_page(html: &str, base_url: &str, start_idx: i32) -> Vec<NovelChapterRef> {
    let re = Regex::new(
        r#"(?:class="p-eplist__chapter-title"[^>]*>([^<]+)<)|(?:class="p-eplist__sublist"[^>]*>\s*<a[^>]+href="([^"]+)"[^>]*>(?s:(.*?))</a>)"#,
    )
    .unwrap();

    // `href` is already root-relative (`/n2267be/1/`), not relative to
    // `base_url`'s path — joining against the origin only, not the full
    // base URL, is what avoids doubling the ncode segment.
    let origin = Regex::new(r"^(https?://[^/]+)").unwrap().find(base_url).map(|m| m.as_str().to_string()).unwrap_or_default();

    let mut chapters = Vec::new();
    let mut current_volume: Option<String> = None;
    let mut idx = start_idx;
    for cap in re.captures_iter(html) {
        if let Some(vol) = cap.get(1) {
            current_volume = Some(vol.as_str().trim().to_string());
            continue;
        }
        let href = cap.get(2).map(|m| m.as_str()).unwrap_or_default();
        let title = cap.get(3).map(|m| strip_tags(m.as_str()).trim().to_string()).unwrap_or_default();
        if href.is_empty() {
            continue;
        }
        idx += 1;
        let url = if href.starts_with("http") { href.to_string() } else { format!("{origin}{href}") };
        chapters.push(NovelChapterRef { index: idx, title, url, volume_name: current_volume.clone() });
    }
    chapters
}

#[cfg(test)]
mod tests {
    use super::*;

    const TOC_SNIPPET: &str = r#"
<div class="p-eplist__chapter-title">第一章　『怒涛の一日目』</div>
<div class="p-eplist__sublist">
<a href="/n2267be/1/" class="p-eplist__subtitle">
プロローグ　『始まりの余熱』
</a>
</div>
<div class="p-eplist__sublist">
<a href="/n2267be/2/" class="p-eplist__subtitle">
第一章１　　『ギザ十は使えない』
</a>
</div>
"#;

    #[test]
    fn parses_volume_header_and_chapters_in_order() {
        let chapters = parse_toc_page(TOC_SNIPPET, "https://ncode.syosetu.com/n2267be/", 0);
        assert_eq!(chapters.len(), 2);
        assert_eq!(chapters[0].volume_name.as_deref(), Some("第一章　『怒涛の一日目』"));
        assert_eq!(chapters[0].url, "https://ncode.syosetu.com/n2267be/1/");
        assert_eq!(chapters[1].index, 2);
    }

    #[test]
    fn normalizes_a_chapter_url_down_to_the_novel_base() {
        assert_eq!(
            SyosetuClient::normalize_base_url("https://ncode.syosetu.com/n2267be/1/"),
            "https://ncode.syosetu.com/n2267be/"
        );
    }

    #[test]
    fn strips_line_paragraphs_into_readable_text() {
        let html = r#"<p id="L1">Hello.</p><p id="L2"><br /></p><p id="L3">World.</p>"#;
        let para_re = Regex::new(r#"<p id="L\d+"[^>]*>(?s:(.*?))</p>"#).unwrap();
        let paragraphs: Vec<String> = para_re.captures_iter(html).map(|c| strip_tags(&c[1]).trim().to_string()).collect();
        assert_eq!(paragraphs, vec!["Hello.".to_string(), "".to_string(), "World.".to_string()]);
    }
}
