//! Which backend a media request actually goes to.
//!
//! The configured provider name is one `String` spanning two unrelated worlds:
//! torrent-backed sources (anime through nyaa, plus cinema's films and series)
//! and scraper-backed ones (manga, light novels). Nothing in the string says
//! which, so every caller re-derived it — `provider == "nyaa"` here, a separate
//! `is_cinema()` check there — and the two disagreed. `general.provider`
//! describes the anime world only, so a film played with a scraper provider
//! configured answered "not a torrent" to every guard written against the name
//! while running the torrent path anyway: Low Data Mode stopped applying to
//! exactly the downloads it exists to stop.
//!
//! Resolve a `StreamSource` once, where a request enters, and branch on it.
//!
//! The provider string is still what gets *stored* — `config.toml`, the
//! registry's per-media slug rows, `CurrentPlayback.provider`,
//! `PreloadedStream.provider` and the preload claim keys all key on it, and a
//! film's stored provider is whatever `general.provider` said, untouched. This
//! type answers "which code path", never "what to persist"; mapping it back to
//! a name would rewrite those records.

use crate::media_id::{source_of, MediaSource};

/// What a torrent-backed request is looking for. The three arms search the
/// same indexes but agree on nothing else: an anime release is matched by
/// episode number and a sub/dub preference, a film by year with no episode
/// number to demand, a series by the season-and-episode pair its filenames
/// spell rather than the absolute number the app stores.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum TorrentIndex {
    Anime,
    Movie,
    Series,
}

/// Where one media request's stream comes from.
#[derive(Debug, Clone, PartialEq, Eq)]
pub enum StreamSource {
    Torrent(TorrentIndex),
    /// The Python sidecar, which takes the provider name verbatim as a
    /// required parameter — hence a `String` rather than a closed enum.
    Scraper(String),
}

impl StreamSource {
    /// The single string-to-source decision in the crate.
    ///
    /// The id band is consulted before the provider name because it is the
    /// stronger signal: a TMDB id is a film or a series whatever the anime
    /// provider happens to say, and no scraper provider has ever heard of one.
    pub fn resolve(media_id: i64, provider: &str) -> Self {
        match source_of(media_id) {
            MediaSource::TmdbMovie => StreamSource::Torrent(TorrentIndex::Movie),
            MediaSource::TmdbTv => StreamSource::Torrent(TorrentIndex::Series),
            MediaSource::AniList => StreamSource::for_anime_provider(provider),
        }
    }

    /// The anime-world half of `resolve`, for the catalog search, which asks a
    /// provider about a *title* and so has no media id to consult.
    pub fn for_anime_provider(provider: &str) -> Self {
        if provider == "nyaa" {
            StreamSource::Torrent(TorrentIndex::Anime)
        } else {
            StreamSource::Scraper(provider.to_string())
        }
    }

    /// Whether the request goes through the embedded torrent session rather
    /// than the scraper sidecar.
    pub fn is_torrent(&self) -> bool {
        matches!(self, StreamSource::Torrent(_))
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::media_id::{encode, MediaSource};

    #[test]
    fn a_cinema_id_is_torrent_backed_whatever_the_anime_provider_is() {
        let film = encode(MediaSource::TmdbMovie, 693134).unwrap();
        let series = encode(MediaSource::TmdbTv, 94997).unwrap();

        // The guards this feeds (Low Data Mode, on both the detail-page
        // preload and the auto-next preload) used to ask only whether the
        // provider was nyaa. `general.provider` describes the anime world, so
        // with anineko configured a film would start a real torrent download
        // with Low Data Mode on -- the exact thing the guard exists to stop.
        assert_eq!(
            StreamSource::resolve(film, "anineko"),
            StreamSource::Torrent(TorrentIndex::Movie)
        );
        assert_eq!(
            StreamSource::resolve(series, "anineko"),
            StreamSource::Torrent(TorrentIndex::Series)
        );
        assert_eq!(
            StreamSource::resolve(film, "nyaa"),
            StreamSource::Torrent(TorrentIndex::Movie)
        );
    }

    #[test]
    fn an_anilist_id_is_decided_by_the_provider_alone() {
        assert_eq!(StreamSource::resolve(21202, "nyaa"), StreamSource::Torrent(TorrentIndex::Anime));
        assert_eq!(
            StreamSource::resolve(21202, "anineko"),
            StreamSource::Scraper("anineko".into())
        );
        assert_eq!(
            StreamSource::resolve(21202, "mangakatana"),
            StreamSource::Scraper("mangakatana".into())
        );
        assert!(!StreamSource::resolve(21202, "mangakatana").is_torrent());
    }

    /// A film and a series are separate arms because they search on different
    /// criteria. Collapsing them into one "cinema" arm is how the series path
    /// once searched with the absolute episode number that no release name
    /// carries.
    #[test]
    fn a_film_and_a_series_do_not_share_an_arm() {
        let film = encode(MediaSource::TmdbMovie, 693134).unwrap();
        let series = encode(MediaSource::TmdbTv, 94997).unwrap();
        assert_ne!(StreamSource::resolve(film, "nyaa"), StreamSource::resolve(series, "nyaa"));
    }
}
