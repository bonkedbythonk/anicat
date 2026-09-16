//! TMDB: cinema mode's catalog, the counterpart to `anilist` for movies and
//! series. Metadata only — where the files come from is the torrent layer's
//! problem, exactly as it is for anime.

pub mod client;
pub mod types;

pub use client::TmdbClient;
