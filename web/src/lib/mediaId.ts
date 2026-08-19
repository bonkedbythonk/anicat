/** Which catalog a media id came from, encoded into the id itself.
 *
 *  The mirror of `src-tauri/src/media_id.rs` — see that file for why the
 *  scheme exists. The short version: every registry table keys on a bare
 *  integer with no source column, AniList and TMDB both hand out small
 *  integers, and giving each catalog its own band of the integer space avoids
 *  migrating five tables against friends' live watch history.
 *
 *  Keep the band width in step with the Rust side. Nothing enforces that
 *  across the language boundary, and a mismatch would file ids under the
 *  wrong catalog rather than fail loudly. */

/** Width of each catalog's slice of the id space. Must match `BAND` in
 *  `media_id.rs`. */
const BAND = 100_000_000;

export type MediaSource = "anilist" | "tmdb_movie" | "tmdb_tv";

const BASE: Record<MediaSource, number> = {
  anilist: 0,
  tmdb_movie: BAND,
  tmdb_tv: BAND * 2,
};

/** Shift a catalog's own id into the stored id space. Returns null for a
 *  native id wide enough to land in a neighbouring catalog's band. */
export function encodeMediaId(source: MediaSource, nativeId: number): number | null {
  if (!Number.isInteger(nativeId) || nativeId < 0 || nativeId >= BAND) return null;
  return BASE[source] + nativeId;
}

/** Recover the catalog and its own id from a stored media id. Ids past the
 *  last band read as AniList, which is how every id behaved before bands. */
export function decodeMediaId(mediaId: number): { source: MediaSource; nativeId: number } {
  if (mediaId >= BASE.tmdb_tv && mediaId < BASE.tmdb_tv + BAND) {
    return { source: "tmdb_tv", nativeId: mediaId - BASE.tmdb_tv };
  }
  if (mediaId >= BASE.tmdb_movie && mediaId < BASE.tmdb_movie + BAND) {
    return { source: "tmdb_movie", nativeId: mediaId - BASE.tmdb_movie };
  }
  return { source: "anilist", nativeId: mediaId };
}

/** Which catalog a stored id belongs to. */
export function mediaSourceOf(mediaId: number): MediaSource {
  return decodeMediaId(mediaId).source;
}

/** True when the id is AniList's, and so safe to send to the AniList API. */
export function isAnilistId(mediaId: number): boolean {
  return mediaSourceOf(mediaId) === "anilist";
}

/** True for the catalogs that belong to cinema mode. */
export function isCinemaId(mediaId: number): boolean {
  return !isAnilistId(mediaId);
}
