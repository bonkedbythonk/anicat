//! Lnori (lnori.com) — the first light-novel source that can be reached from a
//! catalogue entry instead of a pasted URL. `reader::syosetu` reads Japanese web
//! novels and only from a link the viewer supplies; this one takes the AniList
//! title strings and finds the English release, which is what the Light Novels
//! section needed to stop being a placeholder.
//!
//! Ported from the Python provider (`scraper/novel/scrapers/lnori.py`) this
//! replaces, minus its RanobeDB dependency: that scraper mapped a RanobeDB
//! series id straight onto a URL, and nothing in the Swift build has one. The
//! index here is the series sitemap and the key is the title.
//!
//! Three shapes have to be understood, and only the first is conventional:
//!
//! 1. **The series sitemap is the search index.** Lnori has no usable search
//!    endpoint and 404s on a bare `/series/<id>` — the title slug is part of
//!    the path. `sitemap-series.xml` is 82KB, 884 entries, every one shaped
//!    `https://lnori.com/series/<id>/<english-title-slug>`, so the slug *is*
//!    the title in normalised form and matching is string work, not scraping.
//! 2. **A volume is one page.** `/book/<id>/<slug>-vol-<n>` carries the entire
//!    book inline (367KB for Spice and Wolf vol. 1), so a "chapter" is a slice
//!    of that page addressed by a `#pageNN` fragment, not a URL of its own.
//! 3. **A table-of-contents entry spans several sections**, which is the part
//!    the Python scraper got wrong — see `slice_section`.
//!
//! Everything is regex-scraped, like `reader::mangakatana`, so no HTML-parser
//! dependency is pulled in for two page shapes.

use std::sync::{Arc, Mutex};
use std::time::{Duration, Instant};

use regex_lite::Regex;

use super::syosetu::{NovelChapterContent, NovelChapterRef};

const BASE_URL: &str = "https://lnori.com";
const SERIES_SITEMAP: &str = "https://lnori.com/sitemap/sitemap-series.xml";
const REQUEST_TIMEOUT: Duration = Duration::from_secs(20);
const USER_AGENT: &str =
    "Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/131.0.0.0 Safari/537.36";

/// The sitemap is 82KB and gains a handful of entries a month. Refetching it
/// per lookup would spend more bytes on the index than on the book.
const SITEMAP_TTL: Duration = Duration::from_secs(6 * 3600);

/// One volume page is 367KB and holds every chapter of that volume, so reading
/// a volume straight through would otherwise refetch the whole book once per
/// chapter turn — a dozen times for a twelve-entry table of contents.
const PAGE_TTL: Duration = Duration::from_secs(15 * 60);

/// At 367KB a page, an unbounded map is how a long reading session ends up
/// holding a shelf of books resident. Two is a volume plus the one the reader
/// just came from; four leaves room for the series page in the same map.
const PAGES_KEPT: usize = 4;

/// Slug tails that mean the entry is companion material rather than the novel:
/// `konosuba-gods-blessing-on-this-wonderful-world-memorial-fan-book` and
/// `ascendance-of-a-bookworm-fanbook` both sit in the index next to their
/// parent series. Only a demotion, never an exclusion — see `rank_match`.
const COMPANION_MARKERS: &[&str] = &[
    "fanbook",
    "fan-book",
    "short-story-collection",
    "anthology",
    "artbook",
    "art-book",
    "memorial",
    "special-book",
    "drama-cd",
    "illustration",
    "character-book",
    "guidebook",
    "trpg",
];

#[derive(Debug, Clone, PartialEq)]
struct SeriesEntry {
    id: u32,
    slug: String,
    url: String,
}

pub struct LnoriClient {
    http: reqwest::Client,
    /// The parsed sitemap and when it was parsed. `Arc` so a lookup clones a
    /// pointer rather than 884 entries, and so the lock is never held across
    /// the fetch that fills it.
    sitemap: Mutex<Option<(Instant, Arc<Vec<SeriesEntry>>)>>,
    /// Recently fetched pages, newest last, capped at `PAGES_KEPT`.
    pages: Mutex<Vec<(String, Instant, Arc<String>)>>,
}

impl LnoriClient {
    pub fn new(http: reqwest::Client) -> Self {
        Self {
            http,
            sitemap: Mutex::new(None),
            pages: Mutex::new(Vec::new()),
        }
    }

    pub fn can_handle(url: &str) -> bool {
        let host = url.split("://").nth(1).and_then(|s| s.split('/').next()).unwrap_or("");
        host.contains("lnori.com") && (url.contains("/series/") || url.contains("/book/"))
    }

    async fn get(&self, url: &str) -> Result<String, String> {
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
            return Err(format!("lnori {} for {url}", resp.status()));
        }
        resp.text().await.map_err(|e| e.to_string())
    }

    /// The series index, fetched at most once per `SITEMAP_TTL`.
    async fn series_index(&self) -> Result<Arc<Vec<SeriesEntry>>, String> {
        // Scoped so the guard is dropped before the `.await` below. A
        // `std::sync::MutexGuard` held across a suspend point makes the
        // future `!Send`, which uniffi's async export will not accept.
        {
            let cached = self.sitemap.lock().unwrap();
            if let Some((stamp, entries)) = cached.as_ref() {
                if stamp.elapsed() < SITEMAP_TTL {
                    return Ok(entries.clone());
                }
            }
        }
        let xml = self.get(SERIES_SITEMAP).await?;
        let entries = Arc::new(parse_series_sitemap(&xml));
        if entries.is_empty() {
            return Err("lnori series sitemap parsed to no entries".to_string());
        }
        *self.sitemap.lock().unwrap() = Some((Instant::now(), entries.clone()));
        Ok(entries)
    }

    /// A page, reusing a recent copy when there is one. Any `#fragment` is cut
    /// off first: every section of a volume is the same document.
    async fn page(&self, url: &str) -> Result<Arc<String>, String> {
        let key = url.split('#').next().unwrap_or(url).to_string();
        {
            let cached = self.pages.lock().unwrap();
            if let Some((_, stamp, html)) = cached.iter().find(|(k, _, _)| *k == key) {
                if stamp.elapsed() < PAGE_TTL {
                    return Ok(html.clone());
                }
            }
        }
        let html = Arc::new(self.get(&key).await?);
        {
            let mut cached = self.pages.lock().unwrap();
            cached.retain(|(k, stamp, _)| *k != key && stamp.elapsed() < PAGE_TTL);
            cached.push((key, Instant::now(), html.clone()));
            while cached.len() > PAGES_KEPT {
                cached.remove(0);
            }
        }
        Ok(html)
    }

    /// Candidate titles, best first (English then romaji, plus sanitised
    /// forms). Returns the series URL, or `None` when nothing matches well
    /// enough — the caller then shows "not available", which is a far better
    /// outcome than opening somebody else's book.
    pub async fn find_series(&self, titles: &[String]) -> Result<Option<String>, String> {
        let entries = self.series_index().await?;
        Ok(best_series_match(&entries, titles).map(|e| e.url.clone()))
    }

    /// Volumes of a series, in reading order.
    pub async fn volumes(&self, series_url: &str) -> Result<Vec<NovelChapterRef>, String> {
        let html = self.page(series_url).await?;
        let volumes = parse_volume_links(&html);
        if volumes.is_empty() {
            return Err(format!("lnori listed no volumes for {series_url}"));
        }
        Ok(volumes)
    }

    /// The table of contents of one volume.
    pub async fn volume_chapters(&self, book_url: &str) -> Result<Vec<NovelChapterRef>, String> {
        let html = self.page(book_url).await?;
        let base = strip_fragment(book_url);
        let chapters = parse_toc(&html, base);
        if chapters.is_empty() {
            return Err(format!("lnori returned no table of contents for {book_url}"));
        }
        Ok(chapters)
    }

    /// The volume's cover, if the page carries one.
    ///
    /// It sits *before* the first `<section>`, so no chapter slice contains it
    /// and it is the one image `chapter_content` can never return -- which is
    /// exactly the image an e-reader's library grid shows.
    pub async fn volume_cover(&self, book_url: &str) -> Result<Option<String>, String> {
        let html = self.page(book_url).await?;
        Ok(cover_image(&html))
    }

    /// One section's text, sliced out of the volume page.
    pub async fn chapter_content(&self, book_url: &str, anchor: &str) -> Result<NovelChapterContent, String> {
        let html = self.page(book_url).await?;
        let base = strip_fragment(book_url);
        let anchor = anchor.trim_start_matches('#');
        let Some(slice) = slice_section(&html, anchor) else {
            return Err(format!("lnori has no section {anchor} in {base}"));
        };
        let title = parse_toc(&html, base)
            .into_iter()
            .find(|c| c.url.ends_with(&format!("#{anchor}")))
            .map(|c| c.title)
            .or_else(|| first_heading(slice))
            .or_else(|| book_title(&html))
            .unwrap_or_default();
        // An empty body is not an error: the first two entries of every volume
        // are Cover and Insert, which carry illustrations and no prose.
        let prose = html_to_prose(slice);
        let (text, dropped) = strip_repeated_title(&prose.text, &title);
        // The dedupe removes leading paragraphs, so every image positioned
        // after one of them has moved with it. Left unshifted, a chapter's
        // first illustration climbed two paragraphs up the page each time the
        // title block was stripped.
        let images = prose
            .images
            .into_iter()
            .map(|(after, url)| ((after - dropped).max(-1), url))
            .collect();
        Ok(NovelChapterContent { title, text, images })
    }
}

// --- pure helpers, unit-tested against captured markup shapes ---------------

fn strip_fragment(url: &str) -> &str {
    url.split('#').next().unwrap_or(url)
}

fn parse_series_sitemap(xml: &str) -> Vec<SeriesEntry> {
    let re = Regex::new(r#"/series/(\d+)/([^<\s"]+)"#).unwrap();
    let mut out = Vec::new();
    for cap in re.captures_iter(xml) {
        let Ok(id) = cap[1].parse::<u32>() else { continue };
        let slug = cap[2].trim_end_matches('/').to_lowercase();
        if slug.is_empty() {
            continue;
        }
        out.push(SeriesEntry { id, slug: slug.clone(), url: format!("{BASE_URL}/series/{id}/{slug}") });
    }
    out
}

/// A title in the same shape Lnori writes its slugs in: lowercase, apostrophes
/// dropped entirely rather than becoming separators (the site writes
/// `the-insipid-princes-furtive-grab-for-the-throne`, not `prince-s`), every
/// other run of non-alphanumerics collapsed to one hyphen.
fn slugify(title: &str) -> String {
    let lowered = title.to_lowercase().replace(['\'', '\u{2019}'], "");
    let mut out = String::with_capacity(lowered.len());
    let mut pending_sep = false;
    for ch in lowered.chars() {
        if ch.is_ascii_alphanumeric() {
            if pending_sep && !out.is_empty() {
                out.push('-');
            }
            pending_sep = false;
            out.push(ch);
        } else {
            pending_sep = true;
        }
    }
    out
}

/// Articles dropped from both sides at once, so the comparison stays an
/// equality rather than becoming a fuzzy match. Lnori keeps articles in its
/// slugs, so this only rescues a catalogue title that spells them differently.
fn without_articles(slug: &str) -> String {
    slug.split('-')
        .filter(|t| !matches!(*t, "the" | "a" | "an"))
        .collect::<Vec<_>>()
        .join("-")
}

fn token_count(slug: &str) -> usize {
    slug.split('-').filter(|t| !t.is_empty()).count()
}

fn contains_token_run(haystack: &str, needle: &str) -> bool {
    haystack == needle
        || haystack.starts_with(&format!("{needle}-"))
        || haystack.ends_with(&format!("-{needle}"))
        || haystack.contains(&format!("-{needle}-"))
}

/// How well one index entry answers one candidate title, lower being better:
/// match tier, then which of the caller's titles matched, then whether the
/// slug names companion material, then the series id.
type MatchKey = (u8, usize, u8, u32);

/// How well a sitemap slug answers one candidate title, lower being better,
/// or `None` for no match at all.
///
/// The ladder is what keeps a spinoff from outranking its parent. Both
/// `mushoku-tensei-jobless-reincarnation` and
/// `mushoku-tensei-jobless-reincarnation-recollections` are in the index, and
/// a first-hit-wins scan that reached the second one first would serve the
/// wrong book with no sign anything went wrong. Tiers are therefore compared
/// across the *whole* index before anything is returned: no prefix match can
/// beat an exact one, wherever the two sit in the file.
///
/// Tiers 2 and 3 are gated because a short slug matches half the index
/// otherwise: `another` is a real series (17062) and 40 other slugs contain
/// the word.
fn match_tier(site_slug: &str, candidate: &str) -> Option<u8> {
    if site_slug == candidate {
        return Some(0);
    }
    if without_articles(site_slug) == without_articles(candidate) {
        return Some(1);
    }
    let cand_tokens = token_count(candidate);
    if cand_tokens >= 2 && site_slug.starts_with(&format!("{candidate}-")) {
        return Some(2);
    }
    // Containment needs the candidate to be most of the slug it sits inside,
    // otherwise a two-word title is "found" in a fifteen-word one that merely
    // quotes it — `dungeon` appears in twenty of these.
    if cand_tokens >= 3 && candidate.len() * 5 >= site_slug.len() * 3 && contains_token_run(site_slug, candidate) {
        return Some(3);
    }
    None
}

/// 1 when the part of the slug beyond the title names companion material.
fn companion_penalty(site_slug: &str, candidate: &str) -> u8 {
    let tail = site_slug.strip_prefix(candidate).unwrap_or(site_slug);
    u8::from(COMPANION_MARKERS.iter().any(|m| tail.contains(m)))
}

/// The ranking key for one (entry, candidate) pair: tier first, then which
/// title in the caller's list matched (English before romaji), then whether
/// the slug tail names companion material, then the series id.
///
/// The series id is the tiebreak because Lnori's ids are RanobeDB's, handed
/// out in registration order, and a parent series is always registered before
/// its spinoffs. Checked against every family in the index that has any:
/// 3336 < 13305/14199/15087 (Mushoku Tensei), 3079 < 9233/10731/13337/17534
/// (KonoSuba), 1234 < 2508/4080/6210 (Sword Art Online), 4239 < 6581/8813/
/// 10159/16936 (Ascendance of a Bookworm), 2643 < 3311/6585/14048/14809
/// (DanMachi), 5304 < 7804/9816 (Goblin Slayer), 3343 < 4120 (Re:Zero),
/// 5180 < 11634 (So I'm a Spider), 10482 < 11984 (Spy Classroom).
///
/// It matters because the obvious tiebreak — the shortest slug — is wrong:
/// the shortest prefix match for "Ascendance of a Bookworm" is
/// `ascendance-of-a-bookworm-fanbook`, and the real series is the longest of
/// the five, `ascendance-of-a-bookworm-ill-do-anything-to-become-a-librarian`.
fn rank_match(entry: &SeriesEntry, candidate: &str, title_rank: usize) -> Option<MatchKey> {
    let tier = match_tier(&entry.slug, candidate)?;
    Some((tier, title_rank, companion_penalty(&entry.slug, candidate), entry.id))
}

/// The best entry in the index for a caller's candidate titles, or `None`.
///
/// A prefix match can still land on companion material when the parent series
/// is not carried at all — the index has `frieren-beyond-journeys-end-prelude`
/// and no Frieren parent, so that title resolves to the prelude. Nothing in
/// the slug distinguishes a prelude from a subtitle, so this is the residual
/// risk of having a prefix tier at all; it is kept because
/// `ascendance-of-a-bookworm-ill-do-anything-to-become-a-librarian` has no
/// bare-title entry either and would otherwise be unreachable.
fn best_series_match<'a>(entries: &'a [SeriesEntry], titles: &[String]) -> Option<&'a SeriesEntry> {
    let candidates: Vec<String> = {
        let mut seen: Vec<String> = Vec::new();
        for t in titles {
            let slug = slugify(t);
            if !slug.is_empty() && !seen.contains(&slug) {
                seen.push(slug);
            }
        }
        seen
    };

    let mut best: Option<(MatchKey, &SeriesEntry)> = None;
    for entry in entries {
        let entry_best = candidates
            .iter()
            .enumerate()
            .filter_map(|(rank, c)| rank_match(entry, c, rank))
            .min();
        let Some(key) = entry_best else { continue };
        if best.as_ref().is_none_or(|(current, _)| key < *current) {
            best = Some((key, entry));
        }
    }
    best.map(|(_, entry)| entry)
}

/// The volume number a book slug states, if it states one. Both spellings are
/// in the index: `spice-and-wolf-vol-1` and `invaders-of-the-rokujouma-volume-12`.
fn volume_number(slug: &str) -> Option<u32> {
    let re = Regex::new(r"-vol(?:ume)?-(\d+)").unwrap();
    re.captures(slug)?.get(1)?.as_str().parse::<u32>().ok()
}

/// A volume label is more useful the more it says, and a label carrying a
/// digit beats one that does not: the same volume is linked from its card
/// (`aria-label="Volume 1"`) and from a "Start Reading" button, and the
/// button's text names no volume at all.
fn label_rank(label: &str) -> (u8, usize) {
    (u8::from(label.chars().any(|c| c.is_ascii_digit())), label.len())
}

/// Every volume linked from a series page, in reading order.
///
/// Deduplication is the point: Spice and Wolf's page carries 73 `/book/`
/// occurrences — 49 root-relative hrefs and 24 absolute ones — for 24
/// volumes, because each is linked from its cover, its title and its read
/// button. Both href forms have to be accepted or a third of the links are
/// invisible.
fn parse_volume_links(html: &str) -> Vec<NovelChapterRef> {
    let anchor_re = Regex::new(r##"<a[^>]*href="(?:https?://[^"/]*)?/book/(\d+)/([^#"?]*)"[^>]*>"##).unwrap();
    let aria_re = Regex::new(r#"aria-label="([^"]+)""#).unwrap();

    let mut found: Vec<(u32, String, String)> = Vec::new();
    for cap in anchor_re.captures_iter(html) {
        let Ok(book_id) = cap[1].parse::<u32>() else { continue };
        let slug = cap[2].to_string();
        let open_tag = cap.get(0).unwrap();
        // The anchor's own text, when it has any before the first child tag.
        // The cover and read-button anchors open with an `<img>`/`<svg>`, so
        // this is empty for them and the `aria-label` is what names them.
        let text: String = html[open_tag.end()..]
            .chars()
            .take_while(|c| *c != '<')
            .collect();
        let label = aria_re
            .captures(open_tag.as_str())
            .map(|c| c[1].trim().to_string())
            .filter(|l| !l.is_empty())
            .unwrap_or_else(|| text.trim().to_string());

        match found.iter_mut().find(|(id, _, _)| *id == book_id) {
            Some(existing) => {
                if label_rank(&label) > label_rank(&existing.1) {
                    existing.1 = label;
                }
            }
            None => found.push((book_id, label, slug)),
        }
    }

    // Ordered by the volume number the slug states, with the book id as the
    // fallback for the slugs that state none (`ninja-slayer-volume-03-chapter-01`
    // and friends) and as the tiebreak. Document order is not an ordering: a
    // series page lists each volume three times, in card order for one of them
    // and in whatever order the popup markup happens to sit for the others.
    found.sort_by_key(|(id, _, slug)| (volume_number(slug).unwrap_or(u32::MAX), *id));

    found
        .into_iter()
        .enumerate()
        .map(|(i, (id, label, slug))| {
            let index = i as i32 + 1;
            let title = if label.is_empty() { format!("Volume {index}") } else { label };
            NovelChapterRef {
                index,
                title: title.clone(),
                url: format!("{BASE_URL}/book/{id}/{slug}"),
                volume_name: Some(title),
            }
        })
        .collect()
}

fn book_title(html: &str) -> Option<String> {
    let re = Regex::new(r#"<h1[^>]*id="book-title"[^>]*>([^<]+)</h1>"#).unwrap();
    re.captures(html).map(|c| decode_entities(c[1].trim()))
}

/// The `<nav id="toc-list">` block, or "" when the page has none.
///
/// Anchored on the nav rather than scanned document-wide for the reason
/// `mangakatana::chapter_table` exists: `href="#..."` is not unique to the
/// table of contents — skip links and the sidebar's own controls use it too,
/// and they would enter the chapter list as untitled entries pointing at
/// nothing readable.
fn toc_block(html: &str) -> &str {
    let Some(start) = html.find(r#"id="toc-list""#) else { return "" };
    let rest = &html[start..];
    match rest.find("</nav>") {
        Some(end) => &rest[..end],
        None => rest,
    }
}

/// The article that holds the book's text, or the whole document when the page
/// shape has changed. Bounding the last chapter at `</article>` is what keeps
/// the footer and the page's inline scripts out of the afterword.
fn content_body(html: &str) -> &str {
    let Some(start) = html.find(r#"<article class="content-body"#) else { return html };
    let rest = &html[start..];
    match rest.find("</article>") {
        Some(end) => &rest[..end],
        None => rest,
    }
}

/// Byte offsets of every `<section class="chapter" id="...">` in the article,
/// paired with its id.
///
/// The class is matched, not just `<section`, because the prose sections nest:
/// inside `<section class="chapter" id="page11">` sits
/// `<section class="body-rw Chapter-rw" ... id="chapter005">`, and a looser
/// pattern would end every slice a few hundred bytes in.
fn section_offsets(article: &str) -> Vec<(String, usize)> {
    let re = Regex::new(r#"<section class="chapter" id="([^"]+)""#).unwrap();
    re.captures_iter(article)
        .map(|c| (c[1].to_string(), c.get(0).unwrap().start()))
        .collect()
}

fn toc_anchors(html: &str) -> Vec<(String, String)> {
    let re = Regex::new(r##"<a[^>]*href="#([^"]+)"[^>]*>([^<]*)</a>"##).unwrap();
    let title_re = Regex::new(r#"title="([^"]*)""#).unwrap();
    let block = toc_block(html);

    let mut out: Vec<(String, String)> = Vec::new();
    for cap in re.captures_iter(block) {
        let anchor = cap[1].to_string();
        if anchor.is_empty() || out.iter().any(|(a, _)| *a == anchor) {
            continue;
        }
        let open_tag = cap.get(0).unwrap().as_str();
        let title = title_re
            .captures(open_tag)
            .map(|c| c[1].trim().to_string())
            .filter(|t| !t.is_empty())
            .unwrap_or_else(|| cap[2].trim().to_string());
        out.push((anchor, decode_entities(&title)));
    }
    out
}

/// One volume's chapter list, built from its in-page table of contents and
/// falling back to the sections themselves when the nav is missing.
fn parse_toc(html: &str, book_url: &str) -> Vec<NovelChapterRef> {
    let base = strip_fragment(book_url);
    let volume_name = book_title(html);

    let mut chapters: Vec<NovelChapterRef> = toc_anchors(html)
        .into_iter()
        .enumerate()
        .map(|(i, (anchor, title))| NovelChapterRef {
            index: i as i32 + 1,
            title: if title.is_empty() { format!("Section {}", i + 1) } else { title },
            url: format!("{base}#{anchor}"),
            volume_name: volume_name.clone(),
        })
        .collect();

    if chapters.is_empty() {
        let article = content_body(html);
        chapters = section_offsets(article)
            .into_iter()
            .enumerate()
            .map(|(i, (anchor, start))| {
                let title = first_heading(&article[start..]).unwrap_or_else(|| format!("Section {}", i + 1));
                NovelChapterRef {
                    index: i as i32 + 1,
                    title,
                    url: format!("{base}#{anchor}"),
                    volume_name: volume_name.clone(),
                }
            })
            .collect();
    }
    chapters
}

/// The markup of one table-of-contents entry: from its own section up to the
/// section the *next* entry names, not up to the next section.
///
/// This is the correction to the Python scraper, which took the single section
/// the fragment named. A chapter spans several of Lnori's sections because
/// they are the source EPUB's page files: in Spice and Wolf vol. 1, "Chapter
/// One" is `#page10` at 499 bytes — a heading and nothing else — while its
/// prose is in `page11` (27KB) and `page13` (30KB), and the next entry,
/// "Chapter Two", is `#page16`. Slicing one section returns a chapter title
/// and no chapter.
///
/// An anchor that is not a table-of-contents entry (the fallback list above
/// builds those) stops at the next section instead, which for that list is the
/// same thing.
fn slice_section<'a>(html: &'a str, anchor: &str) -> Option<&'a str> {
    let article = content_body(html);
    let sections = section_offsets(article);
    let here = sections.iter().position(|(id, _)| id == anchor)?;

    let toc: Vec<String> = toc_anchors(html).into_iter().map(|(a, _)| a).collect();
    let next_id = match toc.iter().position(|a| a == anchor) {
        Some(i) => toc.get(i + 1).cloned(),
        None => sections.get(here + 1).map(|(id, _)| id.clone()),
    };
    let end = next_id
        .and_then(|id| sections.iter().find(|(sid, _)| *sid == id))
        .map(|(_, start)| *start)
        .unwrap_or(article.len());

    let start = sections[here].1;
    if end <= start {
        return None;
    }
    Some(&article[start..end])
}

fn first_heading(html: &str) -> Option<String> {
    let re = Regex::new(r"(?s)<h[1-6][^>]*>(.*?)</h[1-6]>").unwrap();
    let text = re.captures(html).map(|c| strip_tags(&c[1]))?;
    let text = collapse_spaces(&text);
    if text.is_empty() {
        None
    } else {
        Some(text)
    }
}

/// Drops the leading paragraphs that only repeat the chapter's own title.
///
/// Every Lnori section opens with the title twice over: an `<h2
/// class="chapter-title">` and, right under it, the printed title block the
/// source EPUB typesets as bold prose with a `<br>` between the number and the
/// name. The reader already draws the title above the body, so left alone the
/// chapter began with three copies of its own name. Comparison is on letters
/// and digits alone because the two copies punctuate and break differently
/// ("Chapter 1: Is This Another World?" against "Chapter 1:\nIs This Another
/// World?").
/// Returns the trimmed text and how many paragraphs went, so anything
/// positioned by paragraph index can be moved with it.
fn strip_repeated_title(text: &str, title: &str) -> (String, i32) {
    let wanted = alphanumeric_key(title);
    if wanted.is_empty() {
        return (text.to_string(), 0);
    }
    let mut rest = text;
    let mut dropped = 0;
    while let Some((head, tail)) = rest.split_once("\n\n") {
        if alphanumeric_key(head) != wanted {
            break;
        }
        rest = tail;
        dropped += 1;
    }
    // A section that is nothing but its title keeps it, so an image-only
    // Color Inserts page does not read as a chapter that failed to load.
    if rest.is_empty() { (text.to_string(), 0) } else { (rest.to_string(), dropped) }
}

fn alphanumeric_key(s: &str) -> String {
    s.chars().filter(|c| c.is_alphanumeric()).flat_map(|c| c.to_lowercase()).collect()
}

/// The volume's cover.
///
/// Read from the page's JSON-LD `"image"`, which is the only place it is
/// stated as *the cover* rather than as one picture among others. It does
/// appear as an `<img>` too, inside a `page01` section that the table of
/// contents does not link -- so no chapter slice reaches it and looking for
/// the first `<img>` before the first `<section>` finds nothing at all.
fn cover_image(html: &str) -> Option<String> {
    let re = Regex::new(r#"(?i)"image"\s*:\s*"([^"]+)""#).unwrap();
    let url = re.captures(html)?[1].trim().to_string();
    if url.starts_with("http") { Some(url) } else { None }
}

fn strip_tags(html: &str) -> String {
    let tag_re = Regex::new(r"(?s)<[^>]*>").unwrap();
    decode_entities(&tag_re.replace_all(html, ""))
}

fn collapse_spaces(s: &str) -> String {
    s.split_whitespace().collect::<Vec<_>>().join(" ")
}

fn decode_entities(s: &str) -> String {
    s.replace("&nbsp;", " ")
        .replace("&#160;", " ")
        .replace("&mdash;", "\u{2014}")
        .replace("&ndash;", "\u{2013}")
        .replace("&hellip;", "\u{2026}")
        .replace("&rsquo;", "\u{2019}")
        .replace("&lsquo;", "\u{2018}")
        .replace("&rdquo;", "\u{201d}")
        .replace("&ldquo;", "\u{201c}")
        .replace("&quot;", "\"")
        .replace("&#39;", "'")
        .replace("&lt;", "<")
        .replace("&gt;", ">")
        // Last, or a literal `&amp;lt;` in the source decodes twice.
        .replace("&amp;", "&")
}

/// Readable prose out of a slice of the book.
///
/// Structure is turned into markers *before* the tags are stripped, because
/// the prose is one `<p>` per paragraph with inline `<em>` and
/// `<span class="small-caps">` inside it. Stripping first would run the whole
/// chapter into one line; splitting on every tag would break a word wherever a
/// small-caps span sits mid-sentence, which is every chapter heading and every
/// proper noun the typesetter styled.
///
/// The markers matter for a second reason: a paragraph is wrapped across
/// several source lines, so a plain newline inside one is not a line break the
/// book asked for and joining those back up is what keeps a paragraph a
/// paragraph. Only `<br>` and a closed block are breaks.
#[cfg(test)]
fn html_to_text(html: &str) -> String {
    html_to_prose(html).text
}

/// The text of a slice, and the illustrations in it with the paragraph each
/// one follows.
///
/// A position and not just a list: a volume's images are not all front matter.
/// Of the 21 in Mushoku Tensei volume 1, six are colour inserts and the rest
/// sit *inside* chapters, where an illustration belongs to the sentence before
/// it. Collected without positions they would all pile up at the end of the
/// chapter, which is worse than the blank front-matter pages this replaces.
///
/// `after_paragraph` is -1 for an image before any prose -- the whole of a
/// colour-inserts section.
pub struct Prose {
    pub text: String,
    pub images: Vec<(i32, String)>,
}

fn html_to_prose(html: &str) -> Prose {
    const LINE_BREAK: char = '\u{1}';
    const PARAGRAPH_BREAK: char = '\u{2}';
    // Around a URL, so an image survives tag stripping with its place in the
    // text intact. Control characters no prose contains.
    const IMAGE_OPEN: char = '\u{3}';
    const IMAGE_CLOSE: char = '\u{4}';

    let script_re = Regex::new(r"(?is)<(script|style)[^>]*>.*?</(script|style)>").unwrap();
    let br_re = Regex::new(r"(?i)<br\s*/?>").unwrap();
    // An empty inline element is a word boundary, and the only record of one
    // the source leaves. A drop cap is typeset as its own span, and where the
    // letter is a word by itself the volume writes
    // `<span>I</span><span></span><span>was ...` -- with no space anywhere,
    // because the gap on the page comes from the 3em glyph's side bearing.
    // Stripped naively that reads "Iwas". Where the drop cap does continue its
    // word ("W" then "hen") there is no empty span between them, so this
    // separates the two cases without having to guess at the words.
    // Spelled as an alternation rather than a backreference: regex-lite has
    // no backreferences, and an inline element closed by a different one is
    // not markup this has to be careful about.
    let empty_re =
        Regex::new(r"(?is)<(?:span|b|i|em|strong|a)[^>]*>\s*</(?:span|b|i|em|strong|a)>").unwrap();
    let block_re = Regex::new(r"(?i)</(?:p|h[1-6]|div|section|li|blockquote|figcaption)>").unwrap();

    let img_re =
        Regex::new(r#"(?is)<img[^>]*\bsrc\s*=\s*["']([^"']+)["'][^>]*>"#).unwrap();

    let cleaned = script_re.replace_all(html, "");
    // Before the empty-element pass: an `<img>` has no closing tag, but a
    // `<span><img ...></span>` would otherwise be seen as empty once the image
    // is gone.
    let marked = img_re.replace_all(&cleaned, |caps: &regex_lite::Captures| {
        format!("{PARAGRAPH_BREAK}{IMAGE_OPEN}{}{IMAGE_CLOSE}{PARAGRAPH_BREAK}", &caps[1])
    });
    let spaced = empty_re.replace_all(&marked, " ");
    let with_breaks = br_re.replace_all(&spaced, LINE_BREAK.to_string().as_str());
    let with_blocks = block_re.replace_all(&with_breaks, PARAGRAPH_BREAK.to_string().as_str());

    let mut paragraphs: Vec<String> = Vec::new();
    let mut images: Vec<(i32, String)> = Vec::new();

    for block in strip_tags(&with_blocks).split(PARAGRAPH_BREAK) {
        if let Some(url) = block
            .trim()
            .strip_prefix(IMAGE_OPEN)
            .and_then(|rest| rest.strip_suffix(IMAGE_CLOSE))
        {
            images.push((paragraphs.len() as i32 - 1, url.trim().to_string()));
            continue;
        }
        let paragraph = block
            .split(LINE_BREAK)
            .map(collapse_spaces)
            .filter(|line| !line.is_empty())
            .collect::<Vec<_>>()
            .join("\n");
        if !paragraph.is_empty() {
            paragraphs.push(paragraph);
        }
    }

    Prose { text: paragraphs.join("\n\n"), images }
}

#[cfg(test)]
mod tests;
