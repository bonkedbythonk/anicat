"use client";

import { useMemo } from "react";
import { Loader2 } from "lucide-react";
import Hero from "@/components/media/Hero";
import MediaRow from "@/components/media/MediaRow";
import { mediaApi, type MediaItem } from "@/lib/api";
import { useQuery } from "@tanstack/react-query";

interface MangaViewProps {
  onSelect: (item: MediaItem) => void;
}

export default function MangaView({ onSelect }: MangaViewProps) {
  const { data, isLoading } = useQuery({
    queryKey: ["manga-data"],
    queryFn: async () => {
      const [trending, popular, reading] = await Promise.all([
        mediaApi.getTrending("MANGA"),
        mediaApi.search("", "MANGA", 1, { min_score: 70 }),
        mediaApi.getUserList("watching", "MANGA"),
      ]);

      return {
        trendingList: trending.media || [],
        popularList: popular.media || [],
        readingList: reading.media || [],
      };
    },
  });

  const heroManga = useMemo(() => {
    if (!data) return null;
    const { readingList, trendingList } = data;

    const availableToRead = readingList.filter((item) => {
      const progress = item.user_status?.progress || 0;
      const total = item.chapters || 0;
      return total > 0 ? progress < total : true;
    });

    const pool = availableToRead.length > 0
      ? availableToRead.slice(0, 5)
      : (readingList.length ? readingList.slice(0, 5) : trendingList.slice(0, 5));

    if (pool?.length) {
      return pool[Math.floor(Math.random() * pool.length)];
    }
    return null;
  }, [data]);

  if (isLoading) {
    return (
      <div className="flex items-center justify-center py-32">
        <Loader2 className="animate-spin text-accent" size={40} />
      </div>
    );
  }

  if (!data) return null;

  return (
    <div className="space-y-12 pb-20">
      {heroManga && <Hero item={heroManga} onSelect={onSelect} />}

      {data.readingList.length > 0 && (
        <MediaRow title="Continue Reading" items={data.readingList} onSelect={onSelect} />
      )}
      
      <MediaRow title="Trending Manga" items={data.trendingList} onSelect={onSelect} />
      
      <MediaRow title="Highly Rated Manga" items={data.popularList} onSelect={onSelect} />
    </div>
  );
}
