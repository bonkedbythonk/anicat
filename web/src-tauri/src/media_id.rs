//! Which catalog a `media_id` came from, encoded into the id itself.
//!
//! Every table in `registry` keys on a bare `media_id INTEGER` with no column
//! saying where the id originated — five tables' worth, two of them with the
//! id inside a uniqueness constraint. That was fine while AniList was the only
//! catalog. It stops being fine the moment TMDB ids arrive: both services hand
//! out small integers, so TMDB movie 550 (Fight Club) and AniList 550 (a real
//! anime) would share a row, and a movie's resume position would surface on an
//! unrelated anime.
//!
//! Rather than migrate five tables — live, against friends' watch history on
//! the Pi — each catalog gets its own band of the integer space. AniList ids
//! are stored exactly as they are, so every existing row keeps its meaning and
//! no migration runs at all. TMDB ids are shifted into their own band on the
//! way in and shifted back on the way out.
//!
//! TMDB numbers movies and TV shows in *separate* id spaces — movie 550 and TV
//! 550 are unrelated titles — so they get separate bands rather than sharing
//! one.
//!
//! The bands are far wider than either catalog needs (AniList is in the low
//! hundreds of thousands, TMDB in the low millions), which is the point: an
//! i64 has room to spare, and a band that can never fill is a band that can
//! never silently wrap into its neighbour.

/// Width of each catalog's slice of the id space.
const BAND: i64 = 100_000_000;

/// Where a `media_id` came from.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum MediaSource {
    /// Anime and manga. Stored unshifted, so pre-existing rows still resolve.
    AniList,
    /// TMDB movies.
    TmdbMovie,
    /// TMDB TV series.
    TmdbTv,
}

impl MediaSource {
    /// First id in this source's band.
    const fn base(self) -> i64 {
        match self {
            MediaSource::AniList => 0,
            MediaSource::TmdbMovie => BAND,
            MediaSource::TmdbTv => BAND * 2,
        }
    }

    /// The slug used in configs, logs and the provider mapping blob.
    pub const fn as_str(self) -> &'static str {
        match self {
            MediaSource::AniList => "anilist",
            MediaSource::TmdbMovie => "tmdb_movie",
            MediaSource::TmdbTv => "tmdb_tv",
        }
    }

    /// True for the catalogs that belong to cinema mode.
    pub const fn is_cinema(self) -> bool {
        matches!(self, MediaSource::TmdbMovie | MediaSource::TmdbTv)
    }
}

/// Shift a catalog's own id into the stored id space.
///
/// Returns `None` for a native id outside the band width, which would land in
/// a neighbouring catalog's range. No real id comes close, so this only fires
/// on corrupt input — and silently storing it under the wrong source is worse
/// than refusing it.
pub fn encode(source: MediaSource, native_id: i64) -> Option<i64> {
    if !(0..BAND).contains(&native_id) {
        return None;
    }
    Some(source.base() + native_id)
}

/// Recover the catalog and its own id from a stored `media_id`.
///
/// Ids above the last band are treated as AniList, matching how every id
/// behaved before bands existed; nothing in the database can produce one.
pub fn decode(media_id: i64) -> (MediaSource, i64) {
    if media_id >= MediaSource::TmdbTv.base() && media_id < MediaSource::TmdbTv.base() + BAND {
        (MediaSource::TmdbTv, media_id - MediaSource::TmdbTv.base())
    } else if media_id >= MediaSource::TmdbMovie.base()
        && media_id < MediaSource::TmdbMovie.base() + BAND
    {
        (MediaSource::TmdbMovie, media_id - MediaSource::TmdbMovie.base())
    } else {
        (MediaSource::AniList, media_id)
    }
}

/// Which catalog a stored id belongs to.
pub fn source_of(media_id: i64) -> MediaSource {
    decode(media_id).0
}

/// True when the id is AniList's, and so safe to send to the AniList API.
pub fn is_anilist(media_id: i64) -> bool {
    source_of(media_id) == MediaSource::AniList
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn an_anilist_id_is_stored_unchanged() {
        // The whole reason this scheme needs no migration: rows written before
        // cinema mode existed still decode to exactly what they always meant.
        for id in [1, 550, 21202, 201514, 99_999_999] {
            assert_eq!(encode(MediaSource::AniList, id), Some(id));
            assert_eq!(decode(id), (MediaSource::AniList, id));
        }
    }

    #[test]
    fn every_source_round_trips_across_its_whole_band() {
        for source in [MediaSource::AniList, MediaSource::TmdbMovie, MediaSource::TmdbTv] {
            for native in [0, 1, 550, 1_400_000, BAND - 1] {
                let stored = encode(source, native).expect("in-band id encodes");
                assert_eq!(decode(stored), (source, native), "{:?} {}", source, native);
            }
        }
    }

    #[test]
    fn the_same_number_in_two_catalogs_gets_two_rows() {
        // The collision this module exists to prevent: TMDB movie 550 is Fight
        // Club, AniList 550 is an anime, TMDB TV 550 is neither.
        let anilist = encode(MediaSource::AniList, 550).unwrap();
        let movie = encode(MediaSource::TmdbMovie, 550).unwrap();
        let tv = encode(MediaSource::TmdbTv, 550).unwrap();
        assert_ne!(anilist, movie);
        assert_ne!(anilist, tv);
        assert_ne!(movie, tv);
    }

    #[test]
    fn bands_do_not_overlap_at_their_edges() {
        let last_anilist = encode(MediaSource::AniList, BAND - 1).unwrap();
        let first_movie = encode(MediaSource::TmdbMovie, 0).unwrap();
        let last_movie = encode(MediaSource::TmdbMovie, BAND - 1).unwrap();
        let first_tv = encode(MediaSource::TmdbTv, 0).unwrap();
        assert_eq!(first_movie, last_anilist + 1);
        assert_eq!(first_tv, last_movie + 1);
        assert_eq!(source_of(last_anilist), MediaSource::AniList);
        assert_eq!(source_of(first_movie), MediaSource::TmdbMovie);
        assert_eq!(source_of(last_movie), MediaSource::TmdbMovie);
        assert_eq!(source_of(first_tv), MediaSource::TmdbTv);
    }

    #[test]
    fn an_out_of_band_native_id_is_refused_rather_than_misfiled() {
        assert_eq!(encode(MediaSource::TmdbMovie, BAND), None);
        assert_eq!(encode(MediaSource::TmdbMovie, -1), None);
    }

    #[test]
    fn only_anilist_ids_are_safe_to_send_to_anilist() {
        assert!(is_anilist(21202));
        assert!(!is_anilist(encode(MediaSource::TmdbMovie, 550).unwrap()));
        assert!(!is_anilist(encode(MediaSource::TmdbTv, 1396).unwrap()));
        assert!(MediaSource::TmdbMovie.is_cinema());
        assert!(MediaSource::TmdbTv.is_cinema());
        assert!(!MediaSource::AniList.is_cinema());
    }
}
