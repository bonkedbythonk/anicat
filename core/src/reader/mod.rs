//! Manga sourcing. MangaDex is the primary source, reached over its public
//! REST API — no Python sidecar, no `uv`, no PyInstaller freeze. MangaKatana
//! is a plain-HTML fallback (regex-scraped, no HTML-parser dependency) for
//! titles MangaDex has confirmed but has nothing readable under, such as a
//! publisher takedown, and the fill for titles it has too little under: a
//! licensed title keeps only its newest simulpub chapters on MangaDex, and
//! `mangadex::detail` merges MangaKatana's run into such a feed. A chapter
//! id names its source (UUID or page URL), which is how one list can hold
//! both and the page fetch still reaches the right site.
//!
//! `senmanga` is the Japanese-language (raw) source, over its JSON API.
//!
//! Light novels sit alongside. `syosetu` reads Japanese web novels from a URL
//! the viewer pastes; `lnori` is the first light-novel source that can be
//! reached from a catalogue entry, matching AniList's title strings against
//! lnori.com's series sitemap and slicing chapters out of whole-volume pages.

pub mod offline;
pub mod mangadex;
pub mod mangakatana;
pub mod senmanga;
pub mod syosetu;
pub mod lnori;
pub mod epub;
pub mod novel_offline;
pub mod zip;

use regex_lite::Regex;

pub(crate) fn strip_tags(html: &str) -> String {
    let tag_re = Regex::new(r"(?s)<[^>]*>").unwrap();
    decode_entities(&tag_re.replace_all(html, ""))
}

pub(crate) fn decode_entities(s: &str) -> String {
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
        // "A Returner&#039;s Magic Should Be Special" came through as-is from
        // MangaKatana, and no title comparison could match it.
        .replace("&#039;", "'")
        .replace("&lt;", "<")
        .replace("&gt;", ">")
        // Last, or a literal `&amp;lt;` in the source decodes twice.
        .replace("&amp;", "&")
}

#[cfg(test)]
mod tests {
    #[test]
    fn an_escaped_entity_decodes_once() {
        assert_eq!(super::decode_entities("&amp;lt;"), "&lt;");
        assert_eq!(super::decode_entities("Rock &amp; Roll &#039;n&quot;"), "Rock & Roll 'n\"");
    }
}
