"use client";

import { useMemo } from "react";
import { Loader2 } from "lucide-react";
import Hero from "@/components/media/Hero";
import MediaRow from "@/components/media/MediaRow";
import { mediaApi, type MediaItem } from "@/lib/api";
import { useQuery } from "@tanstack/react-query";

interface HomeViewProps {
  onSelect: (item: MediaItem) => void;
}

export default function HomeView({ onSelect }: HomeViewProps) {
  const { data, isLoading } = useQuery({
    queryKey: ["home-data"],
    queryFn: async () => {
      const [watching, trending, seasonal, playbackStatus] = await Promise.all([
        mediaApi.getUserList("watching", "ANIME"),
        mediaApi.getTrending("ANIME"),
        mediaApi.getSeasonal("ANIME"),
        mediaApi.getPlaybackStatus().catch(() => null),
      ]);

      const watchingMedia = watching.media || [];
      
      // Calculate what's actually new based on user progress
      const missedEpisodes = watchingMedia.filter(item => {
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

      let recentReleases: MediaItem[] = missedEpisodes;

      if (watchingMedia.length > 0) {
        const watchingIds = watchingMedia.map((m) => m.id);
        const schedule = await mediaApi.getSchedule(3, 0, 1, 10, watchingIds);
        const scheduledMedia = schedule.media || [];
        
        // Merge and de-duplicate
        const seenIds = new Set(recentReleases.map(m => m.id));
        for (const m of scheduledMedia) {
          if (!seenIds.has(m.id)) {
            recentReleases.push(m);
            seenIds.add(m.id);
          }
        }
      }

      // Re-order watching list based on local playback status if available
      if (playbackStatus && watchingMedia.length > 0) {
        const lastPlayedId = playbackStatus.media_id;
        const lastPlayedIndex = watchingMedia.findIndex(m => m.id === lastPlayedId);
        if (lastPlayedIndex > 0) {
          const [lastPlayedItem] = watchingMedia.splice(lastPlayedIndex, 1);
          watchingMedia.unshift(lastPlayedItem);
        }
      }

      return {
        watchingList: watchingMedia,
        trendingList: trending.media || [],
        seasonalList: seasonal.media || [],
        recentReleases,
        playbackStatus,
      };
    },
  });

  const heroItem = useMemo(() => {
    if (!data) return null;
    const { watchingList, trendingList } = data;

    if (watchingList.length > 0) {
      const availableToWatch = watchingList.filter((item) => {
        const progress = item.user_status?.progress || 0;
        const total = item.episodes || 0;
        if (item.next_airing) {
          return progress < item.next_airing.episode - 1;
        }
        return total > 0 ? progress < total : true;
      });

      const pool = availableToWatch.length > 0 ? availableToWatch : watchingList;
      // Instead of random, use the first one (which we've ensured is the last played)
      return pool[0];
    } else if (trendingList.length > 0) {
      return trendingList[0];
    }
    return null;
  }, [data]);

  if (isLoading) {
    return (
      <div className="flex items-center justify-center h-full min-h-[400px]">
        <Loader2 className="animate-spin text-accent" size={36} />
      </div>
    );
  }

  if (!data) return null;

  return (
    <div className="space-y-12 pb-12">
      {heroItem && <Hero item={heroItem} onSelect={onSelect} />}
      
      {data.watchingList.length > 0 && (
        <MediaRow title="Continue Watching" items={data.watchingList} onSelect={onSelect} />
      )}
      
      {data.recentReleases.length > 0 && (
        <MediaRow title="New for You" items={data.recentReleases} onSelect={onSelect} />
      )}
      
      <MediaRow title="Trending Now" items={data.trendingList} onSelect={onSelect} />
      
      <MediaRow title="Seasonal Highlights" items={data.seasonalList} onSelect={onSelect} />
    </div>
  );
}
