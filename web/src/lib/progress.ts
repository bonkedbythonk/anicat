import type { MediaItem } from "@/lib/api";

/**
 * Returns true if the user has watched every currently-available episode of a
 * media item. "Available" means: the total episode count if the show has
 * finished, otherwise the latest aired episode derived from the next-airing
 * schedule. Items that are NOT caught up stay in Continue Watching.
 *
 * When AniList data is incomplete (no total and no next-airing slot — common in
 * the window right after an episode drops) we deliberately return false so the
 * show stays visible rather than vanishing.
 */
export function isCaughtUp(item: MediaItem): boolean {
  const progress = item.user_status?.progress ?? 0;
  const total = item.episodes;
  // Check both snake_case (snakify'd) and raw camelCase from the API.
  const nextAiringEp =
    (item as { nextAiringEpisode?: { episode?: number } }).nextAiringEpisode?.episode ??
    item.next_airing?.episode;

  if (total && total > 0) {
    if (progress >= total) return true;
    // Total known and progress < total — but the next episode may not have aired.
    if (nextAiringEp && nextAiringEp > 0 && progress >= nextAiringEp - 1) return true;
    return false;
  }
  // Airing show with a confirmed schedule: compare against the aired count.
  if (nextAiringEp && nextAiringEp > 0) {
    return progress >= nextAiringEp - 1;
  }
  // No total and no schedule — assume NOT caught up so it stays visible.
  return false;
}
