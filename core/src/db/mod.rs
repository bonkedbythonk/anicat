//! SQLite registry, keyed by `(catalog, catalog_id)` rather than by a single
//! integer.
//!
//! The Tauri build stored one bare `media_id INTEGER` and shifted TMDB ids
//! into their own numeric bands (`media_id + 100_000_000`, with movies and TV
//! in separate bands because TMDB numbers them independently) so that AniList
//! and TMDB ids could not collide. That worked, but every read and every write
//! had to remember to encode and decode, a new catalog needed a new band
//! rather than a new value, and a raw `SELECT` against the file was
//! unreadable. The catalog is now a column, so the id is stored exactly as the
//! upstream API returns it.

pub mod schema;
pub mod service;

pub use schema::{migrate, Catalog};
pub use service::Registry;
