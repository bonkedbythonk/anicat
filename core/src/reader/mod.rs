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
//! Light novels sit alongside. `syosetu` reads Japanese web novels from a URL
//! the viewer pastes; `lnori` is the first light-novel source that can be
//! reached from a catalogue entry, matching AniList's title strings against
//! lnori.com's series sitemap and slicing chapters out of whole-volume pages.

pub mod offline;
pub mod mangadex;
pub mod mangakatana;
pub mod syosetu;
pub mod lnori;
