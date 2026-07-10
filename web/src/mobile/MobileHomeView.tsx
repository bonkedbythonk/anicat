import { useMemo } from "react";
import { useQuery } from "@tanstack/react-query";
import { Loader2 } from "lucide-react";
import { mediaApi, type MediaItem } from "@/lib/api";
import { useAppStore } from "@/stores/app";
import { isCaughtUp } from "@/lib/progress";
import { MobileHero } from "./MobileHero";
import { PosterRow } from "./PosterRow";

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
        <PosterRow title="Continue Watching" items={continueWatching} onSelect={onSelect} />
        <PosterRow title="Planning" items={planning} onSelect={onSelect} />
        <PosterRow title="Trending Now" items={trending} onSelect={onSelect} />
        <PosterRow title="This Season" items={seasonal} onSelect={onSelect} />
      </div>
    </div>
  );
}
