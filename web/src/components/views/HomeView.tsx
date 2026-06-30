
import { Fragment, useMemo, useRef, useState, useCallback, useEffect } from "react";
import { Loader2, Clock, User, LayoutDashboard, X, Eye, EyeOff } from "lucide-react";
import { Hero } from "@/components/media/Hero";
import { MediaRow } from "@/components/media/MediaRow";
import { mediaApi, type MediaItem } from "@/lib/api";
import { useQuery } from "@tanstack/react-query";
import { useAmbientColor } from "@/hooks/useAmbientColor";
import { useAppStore } from "@/stores/app";
import { isCaughtUp } from "@/lib/progress";

interface HomeViewProps {
  onSelect: (item: MediaItem, action?: "play", episode?: string | null) => void;
}

// UX-22: Default row configuration
type RowId = "continue" | "airingToday" | "newForYou" | "smartPlaylist" | "trending" | "newlyReleasing" | "seasonal" | "watching" | "planning";

const DEFAULT_ROWS: { id: RowId; title: string; visible: boolean }[] = [
  { id: "airingToday", title: "Airing Today", visible: true },
  { id: "continue", title: "Continue Watching", visible: true },
  { id: "watching", title: "Watching", visible: true },
  { id: "planning", title: "Planning", visible: true },
  { id: "newForYou", title: "New for You", visible: true },
  { id: "smartPlaylist", title: "Smart Picks", visible: true },
  { id: "trending", title: "Trending Now", visible: true },
  { id: "newlyReleasing", title: "Newly Releasing", visible: true },
  { id: "seasonal", title: "Seasonal Highlights", visible: true },
];

// Load saved row config, reconciled with DEFAULT_ROWS: keeps the saved order
// and visibility, drops rows that no longer exist, and appends any newly-added
// default rows at the end so a stale localStorage entry never hides a new row.
function loadRowConfig(): typeof DEFAULT_ROWS {
  if (typeof window === "undefined") return DEFAULT_ROWS;
  const saved = localStorage.getItem("anicat_home_rows");
  if (!saved) return DEFAULT_ROWS;
  try {
    const parsed = JSON.parse(saved) as typeof DEFAULT_ROWS;
    const byId = new Map(DEFAULT_ROWS.map(r => [r.id, r]));
    const merged = parsed
      .filter(r => byId.has(r.id))
      .map(r => ({ ...byId.get(r.id)!, visible: r.visible }));
    const seen = new Set(merged.map(r => r.id));
    for (const def of DEFAULT_ROWS) {
      if (!seen.has(def.id)) merged.push(def);
    }
    return merged;
  } catch {
    return DEFAULT_ROWS;
  }
}

function MediaRowSkeleton({ title }: { title: string }) {
  return (
    <div className="space-y-4 animate-pulse px-1">
      <div className="h-6 w-48 bg-white/10 rounded-md" />
      <div className="flex space-x-4 overflow-hidden">
        {[1, 2, 3, 4, 5, 6].map((i) => (
          <div key={i} className="w-[150px] md:w-[180px] flex-none space-y-3">
            {/* UX-24: Match exact card layout — aspect-[2/3] with rounded-lg */}
            <div className="aspect-[2/3] w-full bg-white/[0.06] rounded-lg border border-white/[0.04]" />
            <div className="h-4 w-3/4 bg-white/[0.06] rounded-md" />
            <div className="flex items-center space-x-2">
              <div className="h-3 w-8 bg-white/[0.04] rounded" />
              <div className="h-3 w-12 bg-white/[0.04] rounded" />
            </div>
          </div>
        ))}
      </div>
    </div>
  );
}

export function HomeView({ onSelect }: HomeViewProps) {
  const isAuthenticated = useAppStore((s) => s.apiAuthenticated);


  // 2. Playback Status — shared query key with NowPlaying component (deduped)
  useQuery({
    queryKey: ["playback-status"],
    queryFn: () => mediaApi.getPlaybackStatus().catch(() => null),
  });

  // 3. AniList Watching List — used for hero fallback and "New for You"
  const watchingQuery = useQuery({
    queryKey: ["home-watching"],
    queryFn: () => mediaApi.getUserList("watching", "ANIME"),
    enabled: isAuthenticated,
  });

  const repeatingQuery = useQuery({
    queryKey: ["home-repeating"],
    queryFn: () => mediaApi.getUserList("repeating", "ANIME"),
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

  const newlyReleasingQuery = useQuery({
    queryKey: ["home-newly-releasing"],
    queryFn: () => mediaApi.search('', 'ANIME', 1, { status: 'RELEASING' }),
  });

  // 5. Smart Playlist — kept for cache compatibility, replaced by smartPicks below
  const smartPlaylistQuery = useQuery({
    queryKey: ["home-smart-playlist"],
    queryFn: () => mediaApi.getSmartPlaylist(),
    enabled: false,
  });

  // 6. Planning List — user's plan-to-watch
  const planningQuery = useQuery({
    queryKey: ["home-planning"],
    queryFn: () => mediaApi.getUserList("planning", "ANIME"),
    enabled: isAuthenticated,
  });

  const lastWatchedQuery = useQuery({
    queryKey: ["home-last-watched"],
    queryFn: () => mediaApi.getAllLastWatched(),
  });

  // Smart Picks: blend planning list items (shuffled) with trending items
  const smartPicks = useMemo(() => {
    const planning = planningQuery.data?.media || [];
    const trending = trendingQuery.data?.media || [];
    const shuffled = [...planning].sort(() => Math.random() - 0.5);
    const planningIds = new Set(planning.map((m: MediaItem) => m.id));
    const fill = trending.filter((m: MediaItem) => !planningIds.has(m.id));
    return [...shuffled, ...fill].slice(0, 20);
  }, [planningQuery.data, trendingQuery.data]);

  // 6. "New for You" — based on AniList watching list + schedule
  const watchingMedia = useMemo(() => {
    const watching = watchingQuery.data?.media || [];
    const repeating = repeatingQuery.data?.media || [];
    return [...watching, ...repeating];
  }, [watchingQuery.data, repeatingQuery.data]);
  const watchingIds = useMemo(() => watchingMedia.map((m) => m.id), [watchingMedia]);

  // UX-13: Airing Today — schedule for current day (must be after watchingIds)
  const airingTodayQuery = useQuery({
    queryKey: ["home-airing-today"],
    queryFn: () => mediaApi.getSchedule(0, 1, 1, 15, watchingIds),
    enabled: isAuthenticated && watchingIds.length > 0,
    staleTime: 30_000,
    refetchInterval: 60_000,
  });

  // UX-22: Customizable row visibility + order
  const [rowConfig, setRowConfig] = useState(() => loadRowConfig());

  const persistRows = (next: typeof DEFAULT_ROWS) => {
    setRowConfig(next);
    localStorage.setItem("anicat_home_rows", JSON.stringify(next));
  };
  const toggleRow = (id: RowId) => {
    persistRows(rowConfig.map(r => r.id === id ? { ...r, visible: !r.visible } : r));
  };

  useEffect(() => {
    const handler = () => setRowConfig(loadRowConfig());
    window.addEventListener("anicat_home_rows_changed", handler);
    return () => window.removeEventListener("anicat_home_rows_changed", handler);
  }, []);

  // 6. Continue Watching = items from the user's AniList watching list
  //    that have unwatched episodes, sorted by local last watched time first,
  //    falling back to AniList update time.
  const continueWatchingList = useMemo(() => {
    const lastWatchedMap = (lastWatchedQuery.data || {}) as Record<string, string>;
    return watchingMedia.filter((m) => !isCaughtUp(m)).sort((a, b) => {
      const aLocal = lastWatchedMap[a.id] || lastWatchedMap[String(a.id)];
      const bLocal = lastWatchedMap[b.id] || lastWatchedMap[String(b.id)];
      if (aLocal || bLocal) {
        const aVal = aLocal ? new Date(aLocal).getTime() : 0;
        const bVal = bLocal ? new Date(bLocal).getTime() : 0;
        if (aVal !== bVal) {
          return bVal - aVal;
        }
      }
      const aTime = Number(a.user_status?.updated_at) || Number(a.media_list_entry?.updated_at) || 0;
      const bTime = Number(b.user_status?.updated_at) || Number(b.media_list_entry?.updated_at) || 0;
      return bTime - aTime;
    });
  }, [watchingMedia, lastWatchedQuery.data]);



  const recentReleasesQuery = useQuery({
    queryKey: ["home-recent-releases", watchingIds],
    staleTime: 30_000,
    refetchInterval: 60_000,
    queryFn: async () => {
      const missedEpisodes = watchingMedia.filter((item) => {
        const progress = item.user_status?.progress || 0;
        const nextEp = item.next_airing?.episode;
        let currentReleased = 0;
        if (nextEp) {
          currentReleased = nextEp - 1;
        } else if (item.episodes) {
          currentReleased = item.episodes;
        }
        const isFinished = item.status === 'FINISHED';
        return item.status === 'RELEASING' && !isFinished && progress < currentReleased;
      });

      const releases = [...missedEpisodes];
      if (watchingMedia.length > 0) {
        const schedule = await mediaApi.getSchedule(3, 0, 1, 10, watchingIds);
        const scheduledMedia = schedule.media || [];
        // Build a progress lookup from the watching list so we can check
        // whether the user is caught up on schedule items.
        const progressMap = new Map(
          watchingMedia.map((m) => [m.id, m.user_status?.progress || 0])
        );
        const seenIds = new Set(releases.map((m) => m.id));
        for (const m of scheduledMedia) {
          if (!seenIds.has(m.id)) {
            // Skip if the user has caught up on this show
            const userProgress = progressMap.get(m.id) || 0;
            const latestReleased = m.next_airing?.episode
              ? m.next_airing.episode - 1
              : m.episodes || 0;
            if (userProgress > 0 && userProgress >= latestReleased) {
              continue;
            }
            releases.push(m);
            seenIds.add(m.id);
          }
        }
      }

      // Filter out any releases where the user is already caught up or completed
      return releases.filter((item) => {
        const progress = item.user_status?.progress || 0;
        const total = item.episodes || 0;

        // 1. Exclude if completely finished/completed
        if (total > 0 && progress >= total) {
          return false;
        }

        // 2. Exclude if caught up to the latest released episode
        const nextEp = item.next_airing?.episode;
        const latestReleased = nextEp ? nextEp - 1 : total;
        if (latestReleased > 0 && progress >= latestReleased) {
          return false;
        }

        return true;
      });
    },
  });

  // Compute candidate hero item — prefer recently watched (in-progress), then watching list, then trending
  const candidateHeroItem = useMemo(() => {
    // First: pick the most recently watched item that is still in progress
    if (continueWatchingList.length > 0) {
      return continueWatchingList[0];
    }

    // Second: fall back to AniList watching list (first in-progress item)
    if (watchingMedia.length > 0) {
      const availableToWatch = watchingMedia.filter((item) => !isCaughtUp(item));
      if (availableToWatch.length > 0) return availableToWatch[0];
    }

    // Third: trending
    if (trendingQuery.data?.media && trendingQuery.data.media.length > 0) {
      return trendingQuery.data.media[0];
    }
    return null;
  }, [continueWatchingList, watchingMedia, trendingQuery.data]);

  const [activeHeroItem, setActiveHeroItem] = useState<MediaItem | null>(null);
  const ambientColor = useAmbientColor(activeHeroItem?.banner_image || activeHeroItem?.cover_image?.large);

  const [showLayoutEditor, setShowLayoutEditor] = useState(false);


  // Render a single home row by id. Returning null means the row has nothing to
  // show (not authenticated, still loading with no data, or empty result).
  const renderRow = (id: RowId) => {
    switch (id) {
      case "airingToday":
        if (!isAuthenticated) return null;
        if (airingTodayQuery.isLoading) return <MediaRowSkeleton title="Airing Today" />;
        if (!airingTodayQuery.data?.media?.length) return null;
        return <MediaRow title="Airing Today" items={airingTodayQuery.data.media} onSelect={onSelect} />;
      case "continue":
        if (!isAuthenticated || continueWatchingList.length === 0) return null;
        return (
          <MediaRow
            title="Continue Watching"
            items={continueWatchingList}
            secondaryItems={smartPicks.length > 0 ? smartPicks : undefined}
            secondaryLabel="Smart Picks"
            onSelect={onSelect}
          />
        );
      case "newForYou":
        if (!isAuthenticated) return null;
        if (recentReleasesQuery.isLoading) return <MediaRowSkeleton title="New for You" />;
        if (!recentReleasesQuery.data?.length) return null;
        return <MediaRow title="New for You" items={recentReleasesQuery.data} onSelect={onSelect} />;
      case "watching":
        if (!isAuthenticated || watchingMedia.length === 0) return null;
        return <MediaRow title="Currently Watching" items={watchingMedia} onSelect={onSelect} />;
      case "planning":
        if (!isAuthenticated || !planningQuery.data?.media?.length) return null;
        return <MediaRow title="Planning" items={planningQuery.data.media} onSelect={onSelect} />;
      case "smartPlaylist":
        if (!isAuthenticated || smartPicks.length === 0) return null;
        return <MediaRow title="Smart Picks" items={smartPicks} onSelect={onSelect} />;
      case "trending":
        if (trendingQuery.isLoading) return <MediaRowSkeleton title="Trending Now" />;
        if (!trendingQuery.data?.media?.length) return null;
        return <MediaRow title="Trending Now" items={trendingQuery.data.media} onSelect={onSelect} />;
      case "newlyReleasing":
        if (newlyReleasingQuery.isLoading) return <MediaRowSkeleton title="Newly Releasing" />;
        if (!newlyReleasingQuery.data?.media?.length) return null;
        return <MediaRow title="Newly Releasing" items={newlyReleasingQuery.data.media} onSelect={onSelect} />;
      case "seasonal":
        if (seasonalQuery.isLoading) return <MediaRowSkeleton title="Seasonal Highlights" />;
        if (!seasonalQuery.data?.media?.length) return null;
        return <MediaRow title="Seasonal Highlights" items={seasonalQuery.data.media} onSelect={onSelect} />;
      default:
        return null;
    }
  };

  // Global loading only until critical data is loaded
  if (trendingQuery.isLoading && seasonalQuery.isLoading) {
    return (
      <div className="flex items-center justify-center h-full min-h-[400px]">
        <Loader2 className="animate-spin text-accent" size={36} />
      </div>
    );
  }

  return (
    <div className="relative h-full space-y-12 pb-12 overflow-x-hidden">
      {/* Ambient background glow */}
      <div 
        className="absolute top-[-100px] right-0 w-[500px] h-[500px] rounded-full opacity-[0.14] pointer-events-none -z-10"
        style={{ 
          background: `radial-gradient(circle, ${ambientColor} 0%, transparent 70%)`
        }}
      />
      <Hero 
        onSelect={onSelect}
        continueList={continueWatchingList}
        recentReleases={recentReleasesQuery.data || []}
        airingToday={airingTodayQuery.data?.media || []}
        fallbackList={trendingQuery.data?.media || []}
        onFocusChange={setActiveHeroItem}
      />
      {!isAuthenticated && (
        <div className="flex items-center justify-between px-5 py-3.5 rounded-2xl bg-accent/[0.07] border border-accent/[0.12] mt-6">
          <div className="flex items-center gap-3">
            <div className="w-8 h-8 rounded-full bg-accent/15 flex items-center justify-center shrink-0">
              <User size={15} className="text-accent" />
            </div>
            <div>
              <p className="text-sm font-semibold text-foreground">Connect AniList to personalize your homepage</p>
              <p className="text-xs text-muted-foreground mt-0.5">See your watch list, get recommendations, and track progress</p>
            </div>
          </div>
          <button
            onClick={() => {
              useAppStore.getState().setSettingsDefaultTab("account");
              useAppStore.getState().setCurrentView("settings");
            }}
            className="shrink-0 px-4 py-1.5 rounded-xl bg-accent text-white text-xs font-bold hover:bg-accent/90 transition-all"
          >
            Connect
          </button>
        </div>
      )}

      {/* Rows render in the user's saved order; hidden rows are skipped. */}
      {rowConfig.filter(r => r.visible).map(r => (
        <Fragment key={r.id}>{renderRow(r.id)}</Fragment>
      ))}

      {/* Layout editor */}
      <div className="flex flex-col items-center gap-4 pt-4">
        <button
          onClick={() => setShowLayoutEditor(true)}
          className="flex items-center gap-2 px-4 py-2 rounded-xl text-xs font-semibold text-muted-foreground hover:text-foreground hover:bg-white/[0.05] border border-white/[0.06] transition-all"
        >
          <LayoutDashboard size={13} />
          Customize home
        </button>

        {showLayoutEditor && (
          <div
            className="fixed inset-0 z-[100] flex items-center justify-center bg-black/60 backdrop-blur-sm p-4"
            onClick={() => setShowLayoutEditor(false)}
          >
            <div
              className="w-full max-w-md rounded-2xl bg-[#111114] border border-white/[0.1] shadow-2xl p-6 max-h-[85vh] overflow-y-auto"
              onClick={(e) => e.stopPropagation()}
            >
              <div className="flex items-center justify-between mb-5">
                <div className="flex items-center gap-2">
                  <LayoutDashboard size={18} className="text-accent" />
                  <h2 className="text-base font-bold text-foreground">Customize home</h2>
                </div>
                <button
                  onClick={() => setShowLayoutEditor(false)}
                  aria-label="Close"
                  className="p-1.5 rounded-lg hover:bg-white/[0.08] transition-colors text-muted-foreground"
                >
                  <X size={16} />
                </button>
              </div>
              <p className="text-[11px] text-muted-foreground/70 mb-3">Tap the eye to show or hide.</p>
              <div className="space-y-1">
                {rowConfig.map((row) => (
                  <div
                    key={row.id}
                    className="flex items-center gap-2 px-2 py-2 rounded-xl border border-transparent hover:bg-white/[0.05] transition-all"
                  >
                    <span className={`flex-1 text-sm font-medium select-none transition-colors ${row.visible ? "text-foreground" : "text-muted-foreground/60"}`}>
                      {row.title}
                    </span>
                    <button
                      onClick={() => toggleRow(row.id)}
                      aria-label={row.visible ? `Hide ${row.title}` : `Show ${row.title}`}
                      className="p-1.5 rounded-lg hover:bg-white/[0.08] transition-colors shrink-0"
                    >
                      {row.visible ? (
                        <Eye size={15} className="text-accent" />
                      ) : (
                        <EyeOff size={15} className="text-muted-foreground/50" />
                      )}
                    </button>
                  </div>
                ))}
              </div>
            </div>
          </div>
        )}
      </div>
    </div>
  );
}
