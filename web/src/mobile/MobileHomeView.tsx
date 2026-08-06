import { useMemo } from "react";
import { useQuery } from "@tanstack/react-query";
import { Loader2 } from "lucide-react";
import { mediaApi, type MediaItem } from "@/lib/api";
import { useAppStore } from "@/stores/app";
import { isCaughtUp } from "@/lib/progress";
import { proxyImage } from "@/lib/proxy";
import { parseWatchedAt } from "@/lib/date";
import { pickAiringSoon, airingLabel } from "./useAiringSoon";
import { UpNextCard } from "./UpNextCard";
import { PosterRow } from "./PosterRow";
import { BrowseRow } from "./BrowseRow";
import { PosterCard } from "./PosterCard";
import { EpisodeCard } from "./EpisodeCard";

// Home's Watching grid is a summary, not the exhaustive list — the Library
// tab (backed by real server-side pagination via MobileListsView) is where
// "all of it" lives. Capping here keeps this count honest instead of
// silently dropping anything past `getUserList`'s client-side page-1 slice.
const WATCHING_GRID_LIMIT = 9;

interface MobileHomeViewProps {
  onSelect: (item: MediaItem, action?: "play", episode?: string | null) => void;
  onSeeAllWatching: () => void;
  onOpenSchedule: () => void;
}

/** Shared style for the small right-hand action in a section header. The
 * padding is negative-margined back out so the label keeps its baseline while
 * the tap target reaches ~44px. */
const SECTION_ACTION =
  "-my-3.5 -mr-2 px-2 py-3.5 font-mono text-[10px] uppercase tracking-[0.08em] text-muted-foreground tabular-nums active:opacity-60";

/** Ink & Index mobile home: resume is the product. One dominant Up Next
 * card (the most recently watched in-progress show), the rest of the
 * watching queue as a horizontal shelf, then a Watching grid and quiet
 * poster rows. The hero carousel is deleted, not restyled — billboards
 * sell, archives resume. Reuses the same queries/cache keys as desktop's
 * HomeView so both surfaces share warm cache. */
export function MobileHomeView({ onSelect, onSeeAllWatching, onOpenSchedule }: MobileHomeViewProps) {
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
        return (bLocal ? parseWatchedAt(bLocal).getTime() : 0) - (aLocal ? parseWatchedAt(aLocal).getTime() : 0);
      });
  }, [watchingQuery.data, lastWatchedQuery.data]);

  const watching = watchingQuery.data?.media || [];
  const trending = trendingQuery.data?.media || [];
  const seasonal = seasonalQuery.data?.media || [];
  const planning = planningQuery.data?.media || [];

  const airingSoon = useMemo(() => pickAiringSoon(watching), [watching]);

  const upNext = continueWatching[0];
  const queueRest = continueWatching.slice(1);

  const isLoading = trendingQuery.isLoading || (isAuthenticated && watchingQuery.isLoading);
  if (isLoading && !upNext && trending.length === 0) {
    return (
      <div className="flex items-center justify-center py-32">
        <Loader2 className="animate-spin text-accent" size={36} />
      </div>
    );
  }

  return (
    <div className="space-y-7 pb-6">
      {upNext && <UpNextCard item={upNext} onSelect={onSelect} />}

      {queueRest.length > 0 && (
        <div className="space-y-2.5">
          <div className="flex items-baseline justify-between">
            <h2 className="text-[15px] font-semibold tracking-tight text-foreground">Continue</h2>
            <span className="font-mono text-[10px] uppercase tracking-[0.08em] text-muted-foreground tabular-nums">{queueRest.length}</span>
          </div>
          <div className="-mx-6 flex gap-3 overflow-x-auto px-6 pb-1 scrollbar-hide">
            {queueRest.map((item) => (
              <EpisodeCard key={item.id} item={item} onSelect={onSelect} />
            ))}
          </div>
        </div>
      )}

      {airingSoon.length > 0 && (
        <div className="space-y-2.5">
          <div className="flex items-baseline justify-between">
            <h2 className="text-[15px] font-semibold tracking-tight text-foreground">Airing soon</h2>
            {/* Was a plain span styled exactly like the tappable "See all"
                below it — it looked like an action and did nothing. */}
            <button onClick={onOpenSchedule} className={SECTION_ACTION}>
              Schedule
            </button>
          </div>
          <div className="-mx-6 flex gap-3 overflow-x-auto px-6 pb-1 scrollbar-hide">
            {airingSoon.map(({ item, at }) => {
              const cover = item.cover_image?.large || item.cover_image?.medium || item.coverImage?.large || item.coverImage?.medium;
              return (
                <button key={item.id} onClick={() => onSelect(item)} className="w-[112px] shrink-0 text-left">
                  <div className="relative aspect-[2/3] w-full overflow-hidden rounded-[5px] bg-surface">
                    <img src={proxyImage(cover)} alt="" className="h-full w-full object-cover" loading="lazy" />
                  </div>
                  <p className="mt-1.5 line-clamp-1 text-[12px] font-medium leading-[1.3] text-foreground">
                    {item.title?.english || item.title?.romaji}
                  </p>
                  <p className="mt-0.5 font-mono text-[10px] uppercase tracking-[0.07em] text-accent tabular-nums">
                    EP {item.next_airing?.episode ?? "?"} {airingLabel(at)}
                  </p>
                </button>
              );
            })}
          </div>
        </div>
      )}

      {watching.length > 0 && (
        <div className="space-y-2.5">
          <div className="flex items-baseline justify-between">
            <h2 className="text-[15px] font-semibold tracking-tight text-foreground">Watching</h2>
            {/* Always says what it does; the count is the label beside it, not
                the button text ("8 shows" read as a stat, not a control). */}
            <button onClick={onSeeAllWatching} className={SECTION_ACTION}>
              See all
              <span className="ml-1.5 text-muted-foreground/70">{watching.length}</span>
            </button>
          </div>
          <div className="grid grid-cols-3 gap-x-3 gap-y-4">
            {watching.slice(0, WATCHING_GRID_LIMIT).map((item) => (
              <PosterCard key={item.id} item={item} onSelect={onSelect} width="100%" />
            ))}
          </div>
        </div>
      )}

      <PosterRow title="Planning" items={planning} onSelect={onSelect} />
      <BrowseRow title="Trending now" items={trending} onSelect={onSelect} />
      <BrowseRow title="This season" items={seasonal} onSelect={onSelect} />
    </div>
  );
}
