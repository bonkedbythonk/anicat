// @ts-nocheck

import { useMemo, useRef, useState, useCallback } from "react";
import { Loader2, Settings2, Clock, Heart, Zap, Ghost, Coffee, Smile, Sparkles, Flame, Eye, User } from "lucide-react";
import { Hero } from "@/components/media/Hero";
import { MediaRow } from "@/components/media/MediaRow";
import { mediaApi, type MediaItem } from "@/lib/api";
import { useQuery } from "@tanstack/react-query";
import { useAmbientColor } from "@/hooks/useAmbientColor";
import { useAppStore } from "@/stores/app";

interface HomeViewProps {
  onSelect: (item: MediaItem) => void;
}

// UX-22: Default row configuration
type RowId = "continue" | "airingToday" | "newForYou" | "smartPlaylist" | "trending" | "newlyReleasing" | "seasonal";

const DEFAULT_ROWS: { id: RowId; title: string; visible: boolean }[] = [
  { id: "airingToday", title: "Airing Today", visible: true },
  { id: "continue", title: "Continue Watching", visible: true },
  { id: "newForYou", title: "New for You", visible: true },
  { id: "smartPlaylist", title: "Smart Playlist", visible: true },
  { id: "trending", title: "Trending Now", visible: true },
  { id: "newlyReleasing", title: "Newly Releasing", visible: true },
  { id: "seasonal", title: "Seasonal Highlights", visible: true },
];

// Returns true if the user has watched all available episodes for a media item.
function isCaughtUp(item: MediaItem): boolean {
  const total = item.episodes;
  const progress = item.user_status?.progress ?? 0;
  if (!total || total <= 0) return false;  // unknown/ongoing = never caught up
  return progress >= total;
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

// UX-15: Genre mood chips
const GENRE_MOODS = [
  { label: "Action", genre: "Action", icon: Zap },
  { label: "Romance", genre: "Romance", icon: Heart },
  { label: "Thriller", genre: "Thriller", icon: Eye },
  { label: "Comedy", genre: "Comedy", icon: Smile },
  { label: "Slice of Life", genre: "Slice of Life", icon: Coffee },
  { label: "Sci-Fi", genre: "Sci-Fi", icon: Sparkles },
  { label: "Fantasy", genre: "Fantasy", icon: Flame },
  { label: "Horror", genre: "Horror", icon: Ghost },
];

export function HomeView({ onSelect }: HomeViewProps) {
  const isAuthenticated = useAppStore((s) => s.apiAuthenticated);


  // 2. Playback Status — shared query key with NowPlaying component (deduped)
  useQuery({
    queryKey: ["playback-status"],
    queryFn: () => mediaApi.getPlaybackStatus().catch(() => null),
    refetchInterval: 1_800_000,  // 30 min
    staleTime: 900_000,          // 15 min
  });

  // 3. AniList Watching List — used for hero fallback and "New for You"
  const watchingQuery = useQuery({
    queryKey: ["home-watching"],
    queryFn: () => mediaApi.getUserList("watching", "ANIME"),
    refetchInterval: 1_800_000,  // 30 min
    staleTime: 900_000,          // 15 min
    enabled: isAuthenticated,
  });

  const trendingQuery = useQuery({
    queryKey: ["home-trending"],
    queryFn: () => mediaApi.getTrending("ANIME"),
    staleTime: 1_800_000,   // 30 min
    refetchInterval: 3_600_000,  // 60 min
  });

  const seasonalQuery = useQuery({
    queryKey: ["home-seasonal"],
    queryFn: () => mediaApi.getSeasonal("ANIME"),
    staleTime: 1_800_000,   // 30 min
    refetchInterval: 3_600_000,  // 60 min
  });

  const newlyReleasingQuery = useQuery({
    queryKey: ["home-newly-releasing"],
    queryFn: () => mediaApi.search('', 'ANIME', 1, { status: 'RELEASING' }),
    staleTime: 1_800_000,   // 30 min
    refetchInterval: 3_600_000,  // 60 min
  });

  // 5. Smart Playlist — personalized recommendations (cached, non-blocking)
  const smartPlaylistQuery = useQuery({
    queryKey: ["home-smart-playlist"],
    queryFn: () => mediaApi.getSmartPlaylist(),
    staleTime: 1_800_000,   // 30 min
    refetchInterval: 3_600_000,  // 60 min
    enabled: isAuthenticated,
  });

  // 6. "New for You" — based on AniList watching list + schedule
  const watchingMedia = watchingQuery.data?.media || [];
  const watchingIds = useMemo(() => watchingMedia.map((m) => m.id), [watchingMedia]);

  // UX-13: Airing Today — schedule for current day (must be after watchingIds)
  const airingTodayQuery = useQuery({
    queryKey: ["home-airing-today"],
      queryFn: () => mediaApi.getSchedule(0, 1, 1, 15, watchingIds),
    staleTime: 600_000,          // 10 min
    refetchInterval: 1_200_000,  // 20 min
    enabled: isAuthenticated && watchingIds.length > 0,
  });

  // UX-15: Genre mood filter state
  const [activeGenre, setActiveGenre] = useState<string | null>(null);

  // UX-22: Customizable row visibility
  const [rowConfig, setRowConfig] = useState(() => {
    if (typeof window !== "undefined") {
      const saved = localStorage.getItem("anicat_home_rows");
      if (saved) {
        try { return JSON.parse(saved) as typeof DEFAULT_ROWS; } catch {}
      }
    }
    return DEFAULT_ROWS;
  });
  const [showCustomizer, setShowCustomizer] = useState(false);
  const isRowVisible = (id: RowId) => rowConfig.find(r => r.id === id)?.visible ?? true;
  const toggleRow = (id: RowId) => {
    const next = rowConfig.map(r => r.id === id ? { ...r, visible: !r.visible } : r);
    setRowConfig(next);
    localStorage.setItem("anicat_home_rows", JSON.stringify(next));
  };
  const filterByGenre = useCallback((items: MediaItem[]) => {
    if (!activeGenre) return items;
    return items.filter(m => m.genres?.includes(activeGenre));
  }, [activeGenre]);

  // 6. Continue Watching = local watch history filtered to only shows
  //    currently on the user's AniList watching/repeating list, EXCLUDING
  //    items the user has caught up on. Also includes any other items in
  //    the user's watching list that haven't been started yet (are not in local history).
  const continueWatchingList = useMemo(() => {
    const watching = watchingQuery.data?.media || [];
    console.log("[HomeView] continueWatchingList: watchingQuery.data?.media?.length:", watching.length, "isAuthenticated:", isAuthenticated, "watchingQuery.status:", watchingQuery.status);
    const filtered = watching.filter((m) => !isCaughtUp(m));
    console.log("[HomeView] continueWatchingList: after isCaughtUp filter:", filtered.length);
    return filtered;
  }, [watchingQuery.data]);



  const recentReleasesQuery = useQuery({
    queryKey: ["home-recent-releases", watchingIds],
    staleTime: 600_000,          // 10 min
    refetchInterval: 1_200_000,  // 20 min
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
      return releases;
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

  console.log("[VIEW:HomeView] render: isAuthenticated:", isAuthenticated);

  console.log("  watchingQuery status:", watchingQuery.status, "isLoading:", watchingQuery.isLoading, "media count:", watchingQuery.data?.media?.length);
  console.log("  trendingQuery status:", trendingQuery.status, "isLoading:", trendingQuery.isLoading, "media count:", trendingQuery.data?.media?.length);
  console.log("  seasonalQuery status:", seasonalQuery.status, "isLoading:", seasonalQuery.isLoading, "media count:", seasonalQuery.data?.media?.length);
  console.log("  newlyReleasingQuery status:", newlyReleasingQuery.status, "isLoading:", newlyReleasingQuery.isLoading, "media count:", newlyReleasingQuery.data?.media?.length);
  console.log("  smartPlaylistQuery status:", smartPlaylistQuery.status, "isLoading:", smartPlaylistQuery.isLoading, "media count:", smartPlaylistQuery.data?.media?.length);
  console.log("  airingTodayQuery status:", airingTodayQuery.status, "isLoading:", airingTodayQuery.isLoading, "media count:", airingTodayQuery.data?.media?.length);

  // Global loading only until critical data is loaded
  if (trendingQuery.isLoading && seasonalQuery.isLoading) {
    return (
      <div className="flex items-center justify-center h-full min-h-[400px]">
        <Loader2 className="animate-spin text-accent" size={36} />
      </div>
    );
  }

  return (
    <div className="relative h-full space-y-12 pb-12">
      {/* Ambient background glow */}
      <div 
        className="absolute top-[-100px] right-[-60px] w-[500px] h-[500px] rounded-full opacity-[0.14] pointer-events-none -z-10"
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

      {/* UX-15: Genre mood chips */}
      <div className="flex items-center space-x-2 overflow-x-auto scrollbar-hide px-1 pt-6 lg:pt-8">
        {GENRE_MOODS.map(mood => {
          const Icon = mood.icon;
          const isActive = activeGenre === mood.genre;
          return (
            <button
              key={mood.genre}
              onClick={() => setActiveGenre(isActive ? null : mood.genre)}
              className={`shrink-0 flex items-center space-x-1.5 px-4 py-2 rounded-full text-xs font-bold transition-all cursor-pointer ${
                isActive
                  ? "bg-gradient-to-r from-accent to-accent-light text-white border-t border-white/10 shadow-lg shadow-accent/25"
                  : "bg-white/[0.03] border border-white/[0.04] text-gray-300 hover:text-white hover:bg-white/[0.07] hover:border-white/[0.08]"
              }`}
            >
              <Icon size={12} className={isActive ? "text-white animate-pulse" : "text-gray-400"} />
              <span>{mood.label}</span>
            </button>
          );
        })}
        {/* UX-22: Customize button */}
        <button
          onClick={() => setShowCustomizer(!showCustomizer)}
          className={`shrink-0 p-2 rounded-full transition-all ${
            showCustomizer ? "glass-button text-white" : "bg-white/5 text-gray-400 hover:text-white hover:bg-white/10"
          }`}
          title="Customize home layout"
        >
          <Settings2 size={14} />
        </button>
      </div>

      {/* UX-22: Row customizer panel */}
      {showCustomizer && (
        <div className="mx-1 p-4 glass-panel space-y-2">
          <h3 className="text-xs font-bold text-gray-500 uppercase tracking-wider mb-2">Visible Sections</h3>
          {rowConfig
            .filter(row => isAuthenticated || !["continue", "airingToday", "newForYou", "smartPlaylist"].includes(row.id))
            .map(row => (
            <label key={row.id} className="flex items-center space-x-3 cursor-pointer">
              <input
                type="checkbox"
                checked={row.visible}
                onChange={() => toggleRow(row.id)}
                className="accent-accent rounded"
              />
              <span className="text-sm font-medium text-gray-300">{row.title}</span>
            </label>
          ))}
        </div>
      )}

      {/* UX-13: Airing Today row with countdown badges */}
      {isAuthenticated && isRowVisible("airingToday") && (
        airingTodayQuery.isLoading ? (
          <MediaRowSkeleton title="Airing Today" />
        ) : (
          airingTodayQuery.data?.media && airingTodayQuery.data.media.length > 0 && (
            <MediaRow
              title="Airing Today"
              items={filterByGenre(airingTodayQuery.data.media)}
              onSelect={onSelect}
            />
          )
        )
      )}

      {(() => {
        const show = isAuthenticated && isRowVisible("continue") && continueWatchingList.length > 0;
        if (!show) console.log("[HomeView] Continue Watching NOT rendering: isAuthenticated:", isAuthenticated, "isRowVisible:", isRowVisible("continue"), "continueWatchingList.length:", continueWatchingList.length);
        return null;
      })()}
      {isAuthenticated && isRowVisible("continue") && continueWatchingList.length > 0 && (
        <MediaRow
          title="Continue Watching"
          items={continueWatchingList}
          secondaryItems={smartPlaylistQuery.data?.media ? filterByGenre(smartPlaylistQuery.data.media) : undefined}
          secondaryLabel="Smart Picks"
          onSelect={onSelect}
        />
      )}

      {isAuthenticated && isRowVisible("newForYou") && (
        recentReleasesQuery.isLoading ? (
          <MediaRowSkeleton title="New for You" />
        ) : (
          recentReleasesQuery.data && recentReleasesQuery.data.length > 0 && (
            <MediaRow title="New for You" items={filterByGenre(recentReleasesQuery.data)} onSelect={onSelect} />
          )
        )
      )}

      {isAuthenticated && isRowVisible("smartPlaylist") && smartPlaylistQuery.data?.media && smartPlaylistQuery.data.media.length > 0 && (
        <MediaRow title="Smart Playlist" items={filterByGenre(smartPlaylistQuery.data.media)} onSelect={onSelect} />
      )}

      {isRowVisible("trending") && (
        trendingQuery.isLoading ? (
          <MediaRowSkeleton title="Trending Now" />
        ) : (
          trendingQuery.data?.media && trendingQuery.data.media.length > 0 && (
            <MediaRow title="Trending Now" items={filterByGenre(trendingQuery.data.media)} onSelect={onSelect} />
          )
        )
      )}

      {isRowVisible("newlyReleasing") && (
        newlyReleasingQuery.isLoading ? (
          <MediaRowSkeleton title="Newly Releasing" />
        ) : (
          newlyReleasingQuery.data?.media && newlyReleasingQuery.data.media.length > 0 && (
            <MediaRow title="Newly Releasing" items={newlyReleasingQuery.data.media} onSelect={onSelect} />
          )
        )
      )}

      {isRowVisible("seasonal") && (
        seasonalQuery.isLoading ? (
          <MediaRowSkeleton title="Seasonal Highlights" />
        ) : (
          seasonalQuery.data?.media && seasonalQuery.data.media.length > 0 && (
            <MediaRow title="Seasonal Highlights" items={filterByGenre(seasonalQuery.data.media)} onSelect={onSelect} />
          )
        )
      )}
    </div>
  );
}
