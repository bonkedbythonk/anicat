"use client";

import { useMemo } from "react";
import { Loader2 } from "lucide-react";
import { MediaRow } from "@/components/media/MediaRow";
import { UpNextQueue } from "@/components/media/UpNextQueue";
import { mediaApi } from "@/lib/api";
import type { MediaItem } from "@/lib/types";
import { useQuery } from "@tanstack/react-query";

interface MangaViewProps {
  onSelect: (item: MediaItem, action?: "play", episode?: string | null) => void;
}

export function MangaView({ onSelect }: MangaViewProps) {
  const { data, isLoading } = useQuery({
    queryKey: ["manga-data"],
    queryFn: async () => {
      const [trending, reading] = await Promise.all([
        mediaApi.getTrending("MANGA"),
        mediaApi.getUserList("reading", "MANGA"),
      ]);

      let planning: { media: MediaItem[] } = { media: [] };
      try {
        const result = await mediaApi.getUserList("planning", "MANGA");
        planning = result;
      } catch {}

      return {
        trendingList: trending.media || [],
        readingList: reading.media || [],
        planningList: planning.media || [],
      };
    },
  });

  // Continue-reading queue: reading entries with unread chapters, most
  // recently updated first — the manga equivalent of Up Next.
  const continueReading = useMemo(() => {
    const reading = data?.readingList || [];
    return reading
      .filter((item) => {
        const progress = item.user_status?.progress || 0;
        const total = item.chapters || 0;
        return total > 0 ? progress < total : true;
      })
      .sort((a, b) => {
        const aTime = Number(a.user_status?.updated_at) || 0;
        const bTime = Number(b.user_status?.updated_at) || 0;
        return bTime - aTime;
      });
  }, [data]);

  if (isLoading) {
    return (
      <div className="flex items-center justify-center py-32">
        <Loader2 className="animate-spin text-accent" size={32} />
      </div>
    );
  }

  if (!data) return null;

  return (
    <div className="space-y-10 pb-20 max-w-[1100px]">
      <div>
        <div className="mb-4 px-1">
          <h1 className="text-[19px] font-semibold tracking-tight text-foreground">Manga</h1>
          <p className="meta-mono mt-1 text-muted-foreground">
            {continueReading.length} in progress · {data.readingList.length} reading
          </p>
        </div>
        {continueReading.length > 0 ? (
          <UpNextQueue
            items={continueReading.slice(0, 8)}
            newEpisodeIds={new Set()}
            lastWatched={{}}
            onSelect={onSelect}
            unit="CH"
          />
        ) : (
          <p className="meta-mono px-1 text-muted-foreground">Nothing in progress. Pick something below.</p>
        )}
      </div>

      {data.readingList.length > 0 && (
        <MediaRow title="Reading" items={data.readingList} onSelect={onSelect} />
      )}

      {data?.planningList?.length > 0 && (
        <MediaRow title="Want to Read" items={data.planningList} onSelect={onSelect} />
      )}

      <MediaRow title="Trending Manga" items={data.trendingList} onSelect={onSelect} />
    </div>
  );
}
