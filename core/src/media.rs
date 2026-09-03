//! How a title is identified across the whole engine.
//!
//! The Tauri build carried one bare `i64` and shifted TMDB ids into their own
//! numeric bands so an AniList id and a TMDB id could not collide in a schema
//! that had only one id column. That worked but leaked: every table, cache key
//! and IPC argument had to remember to encode on the way in and decode on the
//! way out, and a new catalog needed a new band rather than a new value.
//!
//! `MediaKey` is that pair made explicit. It is `Copy` and `Hash` so it drops
//! straight into the resolve and candidate caches where the banded integer
//! used to sit.

use crate::db::Catalog;

#[derive(Debug, Clone, Copy, PartialEq, Eq, Hash)]
pub struct MediaKey {
    pub catalog: Catalog,
    pub id: i64,
}

impl MediaKey {
    pub fn new(catalog: Catalog, id: i64) -> Self {
        Self { catalog, id }
    }

    pub fn anilist(id: i64) -> Self {
        Self::new(Catalog::Anilist, id)
    }

    pub fn tmdb_movie(id: i64) -> Self {
        Self::new(Catalog::TmdbMovie, id)
    }

    pub fn tmdb_tv(id: i64) -> Self {
        Self::new(Catalog::TmdbTv, id)
    }

    /// The AniList id, when this key is an AniList one.
    ///
    /// SeaDex and AniSkip are both keyed by AniList id and have no notion of a
    /// TMDB title, so they ask for this rather than for `id` — handing them a
    /// TMDB id would look up a completely unrelated anime.
    pub fn anilist_id(self) -> Option<i64> {
        (self.catalog == Catalog::Anilist).then_some(self.id)
    }
}

impl std::fmt::Display for MediaKey {
    fn fmt(&self, f: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
        write!(f, "{}:{}", self.catalog.as_str(), self.id)
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn the_same_integer_under_two_catalogs_is_two_keys() {
        assert_ne!(MediaKey::anilist(550), MediaKey::tmdb_movie(550));
        assert_ne!(MediaKey::tmdb_tv(550), MediaKey::tmdb_movie(550));
    }

    #[test]
    fn only_an_anilist_key_answers_anilist_id() {
        assert_eq!(MediaKey::anilist(21).anilist_id(), Some(21));
        assert_eq!(MediaKey::tmdb_tv(21).anilist_id(), None);
    }
}
