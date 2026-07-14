import { useMemo } from "react";
import { useQuery } from "@tanstack/react-query";
import { Loader2 } from "lucide-react";
import { mediaApi, type MediaItem } from "@/lib/api";
import { useAppStore } from "@/stores/app";
import { isCaughtUp } from "@/lib/progress";
import { proxyImage } from "@/lib/proxy";
import { MobileHero } from "./MobileHero";
import { PosterRow } from "./PosterRow";
import { EpisodeCard } from "./EpisodeCard";

// `airing_at` is unix seconds when snakify copied AniList's raw airingAt
// over, or an ISO string when it came from the schedule mapping — accept
// both (same tolerance Hero.tsx needs).
function airingAtMs(item: MediaItem): number | null {
  const raw = item.next_airing?.airing_at;
  if (raw == null) return null;
  if (typeof raw === "number") return raw * 1000;
  if (/^\d+$/.test(raw)) return Number(raw) * 1000;
  const ms = new Date(raw.endsWith("Z") ? raw : `${raw}Z`).getTime();
  return isNaN(ms) ? null : ms;
}

function airingLabel(ms: number): string {
  const diff = ms - Date.now();
  if (diff <= 0) return "aired";
  const hours = Math.floor(diff / 3_600_000);
  if (hours < 1) return `in ${Math.max(1, Math.floor(diff / 60_000))}m`;
  if (hours < 48) return `in ${hours}h`;
  return `in ${Math.floor(hours / 24)}d`;
}

interface MobileHomeViewProps {
  onSelect: (item: MediaItem, action?: "play", episode?: string | null) => void;
}

/** Purpose-built mobile home screen — poster rows + an immersive hero
 * carousel, matching the shape of a real streaming app (Crunchyroll/
 * Netflix) rather than a shrunk version of the desktop dashboard. Reuses
 * the same underlying queries/cache keys as desktop's HomeView so both
 * surfaces share warm cache, but the presentation is entirely new. */
export function MobileHomeView({ onSelect }: MobileHomeViewProps) {
  const isAuthenticated = useAppStore((s) => s.apiAuthenticated);

  const watchingQuery = useQuery({
    queryKey: ["home-watching"],
    queryFn: () => mediaApi.getUserList("watching", "ANIME"),
    enabled: isAuthenticated,
  });
  const planningQuery = useQuery({
    queryKey: ["home-planning"],
    queryFn: () => mediaApi.getUserList("planning", "ANIME"),
    enabled: isAuthenticated,
  });
  const trendingQuery = useQuery({
    queryKey: ["home-trending"],
    queryFn: () => mediaApi.getTrending("ANIME"),
  });
  const seasonalQuery = useQuery({
    queryKey: ["home-seasonal"],
    queryFn: () => mediaApi.getSeasonal("ANIME"),
  });
  const lastWatchedQuery = useQuery({
    queryKey: ["home-last-watched"],
    queryFn: () => mediaApi.getAllLastWatched(),
    enabled: isAuthenticated,
  });

  const continueWatching = useMemo(() => {
    const watching = watchingQuery.data?.media || [];
    const lastWatchedMap = (lastWatchedQuery.data || {}) as Record<string, string>;
    return watching
      .filter((m) => !isCaughtUp(m))
      .sort((a, b) => {
        const aLocal = lastWatchedMap[a.id] || lastWatchedMap[String(a.id)];
        const bLocal = lastWatchedMap[b.id] || lastWatchedMap[String(b.id)];
        return (bLocal ? new Date(bLocal).getTime() : 0) - (aLocal ? new Date(aLocal).getTime() : 0);
      });
  }, [watchingQuery.data, lastWatchedQuery.data]);

  const trending = trendingQuery.data?.media || [];
  const seasonal = seasonalQuery.data?.media || [];
  const planning = planningQuery.data?.media || [];

  // Watching-list entries with a known upcoming episode, soonest first —
  // the phone equivalent of glancing at the Schedule tab for "anything
  // I follow airing today?".
  const airingSoon = useMemo(() => {
    const watching = watchingQuery.data?.media || [];
    return watching
      .map((m) => ({ item: m, at: airingAtMs(m) }))
      .filter((e): e is { item: MediaItem; at: number } => e.at !== null && e.at > Date.now() - 6 * 3_600_000)
      .sort((a, b) => a.at - b.at)
      .slice(0, 10);
  }, [watchingQuery.data]);

  const heroPool = (continueWatching.length > 0 ? continueWatching : trending).slice(0, 5);

  const isLoading = trendingQuery.isLoading || (isAuthenticated && watchingQuery.isLoading);
  if (isLoading && heroPool.length === 0) {
    return (
      <div className="flex items-center justify-center py-32">
        <Loader2 className="animate-spin text-accent" size={36} />
      </div>
    );
  }

  return (
    <div className="space-y-7 pb-6">
      <MobileHero items={heroPool} onSelect={onSelect} />
      <div className="space-y-7 px-0">
        {continueWatching.length > 0 && (
          <div className="space-y-2.5">
            <h2 className="text-[17px] font-bold text-foreground">Continue Watching</h2>
            <div className="-mx-6 flex gap-3 overflow-x-auto px-6 pb-1 scrollbar-hide">
              {continueWatching.map((item) => (
                <EpisodeCard key={item.id} item={item} onSelect={onSelect} />
              ))}
            </div>
          </div>
        )}
        {airingSoon.length > 0 && (
          <div className="space-y-2.5">
            <h2 className="text-[17px] font-bold text-foreground">Airing Soon</h2>
            <div className="-mx-6 flex gap-2.5 overflow-x-auto px-6 pb-1 scrollbar-hide">
              {airingSoon.map(({ item, at }) => {
                const cover = item.cover_image?.large || item.cover_image?.medium || item.coverImage?.large || item.coverImage?.medium;
                return (
                  <button key={item.id} onClick={() => onSelect(item)} className="w-[112px] shrink-0 text-left">
                    <div className="relative aspect-[2/3] w-full overflow-hidden rounded-xl bg-surface shadow-lg shadow-black/40">
                      <img src={proxyImage(cover)} alt="" className="h-full w-full object-cover" loading="lazy" />
                    </div>
                    <p className="mt-1.5 line-clamp-1 text-[12.5px] font-semibold leading-tight text-foreground">
                      {item.title?.english || item.title?.romaji}
                    </p>
                    <p className="text-[11px] tabular-nums text-muted-foreground">
                      Ep {item.next_airing?.episode ?? "?"} {airingLabel(at)}
                    </p>
                  </button>
                );
              })}
            </div>
          </div>
        )}
        <PosterRow title="Planning" items={planning} onSelect={onSelect} />
        <PosterRow title="Trending Now" items={trending} onSelect={onSelect} />
        <PosterRow title="This Season" items={seasonal} onSelect={onSelect} />
      </div>
    </div>
  );
}
