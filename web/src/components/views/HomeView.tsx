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
      const [watching, trending, seasonal] = await Promise.all([
        mediaApi.getUserList("watching", "ANIME"),
        mediaApi.getTrending("ANIME"),
        mediaApi.getSeasonal("ANIME"),
      ]);

      const watchingMedia = watching.media || [];
      let recentReleases: MediaItem[] = [];

      if (watchingMedia.length > 0) {
        const watchingIds = watchingMedia.map((m) => m.id);
        const schedule = await mediaApi.getSchedule(2, 0, 1, 10, watchingIds);
        recentReleases = schedule.media || [];
      }

      return {
        watchingList: watchingMedia,
        trendingList: trending.media || [],
        seasonalList: seasonal.media || [],
        recentReleases,
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
      const randomIndex = Math.floor(Math.random() * Math.min(pool.length, 10));
      return pool[randomIndex];
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
