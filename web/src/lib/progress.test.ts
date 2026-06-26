import { describe, it, expect } from "vitest";
import { isCaughtUp } from "./progress";
import type { MediaItem } from "@/lib/api";

// Build a minimal MediaItem with just the fields isCaughtUp reads.
function item(fields: Partial<MediaItem> & Record<string, unknown>): MediaItem {
  return fields as MediaItem;
}

describe("isCaughtUp", () => {
  it("finished show: caught up only when progress reaches the total", () => {
    expect(isCaughtUp(item({ episodes: 12, user_status: { progress: 12 } }))).toBe(true);
    expect(isCaughtUp(item({ episodes: 12, user_status: { progress: 13 } }))).toBe(true);
    expect(isCaughtUp(item({ episodes: 12, user_status: { progress: 11 } }))).toBe(false);
    expect(isCaughtUp(item({ episodes: 12, user_status: { progress: 0 } }))).toBe(false);
  });

  it("airing show: caught up relative to the latest aired episode", () => {
    // next episode is 6, so episodes 1-5 have aired.
    expect(isCaughtUp(item({ next_airing: { episode: 6 }, user_status: { progress: 5 } }))).toBe(true);
    expect(isCaughtUp(item({ next_airing: { episode: 6 }, user_status: { progress: 4 } }))).toBe(false);
  });

  it("reads the raw camelCase nextAiringEpisode shape too", () => {
    expect(isCaughtUp(item({ nextAiringEpisode: { episode: 3 }, user_status: { progress: 2 } }))).toBe(true);
    expect(isCaughtUp(item({ nextAiringEpisode: { episode: 3 }, user_status: { progress: 1 } }))).toBe(false);
  });

  it("incomplete AniList data stays visible (not caught up)", () => {
    // No total, no schedule — must not vanish from Continue Watching.
    expect(isCaughtUp(item({ user_status: { progress: 4 } }))).toBe(false);
    expect(isCaughtUp(item({}))).toBe(false);
  });

  it("missing progress is treated as zero", () => {
    expect(isCaughtUp(item({ episodes: 12 }))).toBe(false);
  });
});
