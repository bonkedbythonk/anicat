//! Manga sourcing. MangaDex is the primary source, reached over its public
//! REST API — no Python sidecar, no `uv`, no PyInstaller freeze. MangaKatana
//! is a plain-HTML fallback (regex-scraped, no HTML-parser dependency) for
//! titles MangaDex has confirmed but has nothing readable under, such as a
//! publisher takedown.

pub mod mangadex;
pub mod mangakatana;
