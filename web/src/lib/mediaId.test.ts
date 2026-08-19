import { describe, it, expect } from "vitest";
import { readFileSync } from "node:fs";
import { resolve } from "node:path";
import { decodeMediaId, encodeMediaId, isAnilistId, isCinemaId, mediaSourceOf } from "./mediaId";

describe("media id bands", () => {
  it("keeps AniList ids exactly as they were stored", () => {
    // No migration ran, so every row written before cinema mode existed has to
    // still decode to what it always meant.
    for (const id of [1, 550, 21202, 201514]) {
      expect(encodeMediaId("anilist", id)).toBe(id);
      expect(decodeMediaId(id)).toEqual({ source: "anilist", nativeId: id });
    }
  });

  it("round-trips every source across its whole band", () => {
    for (const source of ["anilist", "tmdb_movie", "tmdb_tv"] as const) {
      for (const native of [0, 1, 550, 1_400_000, 99_999_999]) {
        const stored = encodeMediaId(source, native);
        expect(stored).not.toBeNull();
        expect(decodeMediaId(stored!)).toEqual({ source, nativeId: native });
      }
    }
  });

  it("gives the same number in two catalogs two different ids", () => {
    const anilist = encodeMediaId("anilist", 550)!;
    const movie = encodeMediaId("tmdb_movie", 550)!;
    const tv = encodeMediaId("tmdb_tv", 550)!;
    expect(new Set([anilist, movie, tv]).size).toBe(3);
    expect(mediaSourceOf(anilist)).toBe("anilist");
    expect(mediaSourceOf(movie)).toBe("tmdb_movie");
    expect(mediaSourceOf(tv)).toBe("tmdb_tv");
    expect(isAnilistId(anilist)).toBe(true);
    expect(isCinemaId(movie)).toBe(true);
    expect(isCinemaId(tv)).toBe(true);
  });

  it("refuses a native id wide enough to land in the next band", () => {
    expect(encodeMediaId("tmdb_movie", 100_000_000)).toBeNull();
    expect(encodeMediaId("tmdb_movie", -1)).toBeNull();
  });

  it("uses the same band width as the Rust side", () => {
    // The two implementations are hand-mirrored. A mismatch would not throw —
    // it would quietly file ids under the wrong catalog — so pin it here.
    // Vitest runs with `web/` as its root.
    const rust = readFileSync(resolve(process.cwd(), "src-tauri/src/media_id.rs"), "utf8");
    const band = rust.match(/const BAND: i64 = ([\d_]+);/);
    expect(band, "BAND constant not found in media_id.rs").not.toBeNull();
    expect(Number(band![1].replace(/_/g, ""))).toBe(100_000_000);
  });
});
