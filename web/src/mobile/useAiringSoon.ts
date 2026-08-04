import { useMemo } from "react";
import { useQuery } from "@tanstack/react-query";
import { mediaApi, type MediaItem } from "@/lib/api";
import { useAppStore } from "@/stores/app";
import { parseAiringTime } from "@/lib/date";

// `airing_at` is unix seconds when snakify copied AniList's raw airingAt
// over, or an ISO string when it came from the schedule mapping — accept
// both (same tolerance Hero.tsx needs).
function airingAtMs(item: MediaItem): number | null {
  const raw = item.next_airing?.airing_at;
  if (raw == null) return null;
  const ms = parseAiringTime(raw);
  return ms === 0 || isNaN(ms) ? null : ms;
}

export function airingLabel(ms: number): string {
  const diff = ms - Date.now();
  if (diff <= 0) return "aired";
  const hours = Math.floor(diff / 3_600_000);
  if (hours < 1) return `in ${Math.max(1, Math.floor(diff / 60_000))}m`;
  if (hours < 48) return `in ${hours}h`;
  return `in ${Math.floor(hours / 24)}d`;
}

/** Watching-list entries with a known upcoming episode, soonest first — the
 * phone equivalent of glancing at the Schedule tab for "anything I follow
 * airing today?". Pure so Home can run it over the watching list it already
 * holds instead of declaring a second query for the same rows. */
export function pickAiringSoon(watching: MediaItem[]): { item: MediaItem; at: number }[] {
  return watching
    .map((m) => ({ item: m, at: airingAtMs(m) }))
    .filter((e): e is { item: MediaItem; at: number } => e.at !== null && e.at > Date.now() - 6 * 3_600_000)
    .sort((a, b) => a.at - b.at)
    .slice(0, 10);
}

/** The same selection for callers outside Home that have no watching list of
 * their own — the shell, which owns the tab bar's something-new dot. Reads
 * Home's `home-watching` cache entry, so mounting it costs no extra request
 * once Home has loaded, and the dot can never disagree with the shelf. */
export function useAiringSoon(): { item: MediaItem; at: number }[] {
  const isAuthenticated = useAppStore((s) => s.apiAuthenticated);
  const { data } = useQuery({
    queryKey: ["home-watching"],
    queryFn: () => mediaApi.getUserList("watching", "ANIME"),
    enabled: isAuthenticated,
  });

  return useMemo(() => pickAiringSoon(data?.media || []), [data]);
}
