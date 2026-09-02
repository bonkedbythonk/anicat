import { useMemo, useEffect } from "react";
import { Loader2, ArrowRight } from "lucide-react";
import { MediaRow } from "@/components/media/MediaRow";
import { UpNextQueue } from "@/components/media/UpNextQueue";
import { mediaApi } from "@/lib/api";
import type { MediaItem } from "@/lib/types";
import { useQuery } from "@tanstack/react-query";
import { useAppStore } from "@/stores/app";

interface NovelsViewProps {
  onSelect: (item: MediaItem, action?: "play", episode?: string | null) => void;
}

export function NovelsView({ onSelect }: NovelsViewProps) {
  const setActiveFocusScope = useAppStore((s) => s.setActiveFocusScope);
  const setCurrentView = useAppStore((s) => s.setCurrentView);
  const setSearchType = useAppStore((s) => s.setSearchType);
  const setSearchQuery = useAppStore((s) => s.setSearchQuery);

  useEffect(() => {
    setActiveFocusScope("novels-default");
  }, [setActiveFocusScope]);

  const { data, isLoading } = useQuery({
    queryKey: ["novels-data"],
    queryFn: async () => {
      const [trendingNovels, reading, planning] = await Promise.all([
        mediaApi.search("", "NOVEL", 1, { sort: "TRENDING_DESC" }),
        mediaApi.getUserList("reading", "MANGA"),
        mediaApi.getUserList("planning", "MANGA").catch(() => ({ media: [] })),
      ]);

      const filterNovels = (items: MediaItem[]) =>
        (items || []).filter(
          (m) =>
            m.format === "NOVEL" ||
            (m.tags && m.tags.some((t) => t.name.toLowerCase().includes("light novel")))
        );

      const readingNovels = filterNovels(reading.media || []);
      const planningNovels = filterNovels(planning.media || []);

      return {
        trendingList: trendingNovels.media || [],
        readingList: readingNovels,
        planningList: planningNovels,
      };
    },
  });

  const handleBrowseCatalog = () => {
    setSearchType("NOVEL");
    setSearchQuery("");
    setCurrentView("search");
  };

  // Continue-reading queue: reading entries with unread chapters/volumes, most
  // recently updated first — the novel equivalent of Up Next.
  const continueReading = useMemo(() => {
    const reading = data?.readingList || [];
    return reading
      .filter((item) => {
        const progress = item.user_status?.progress || 0;
        const total = item.chapters || item.volumes || 0;
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
        <div className="flex items-end justify-between mb-4 px-1">
          <div>
            <h1 className="text-[19px] font-semibold tracking-tight text-foreground">Light Novels</h1>
            <p className="meta-mono mt-1 text-muted-foreground">
              {continueReading.length} in progress · {data.readingList.length} reading
            </p>
          </div>
          <button
            onClick={handleBrowseCatalog}
            className="flex items-center gap-1.5 rounded-md border border-border px-3.5 py-1.5 text-[12px] font-medium text-foreground/70 hover:text-foreground hover:border-foreground/25 cursor-pointer"
          >
            <span>Browse all light novels</span>
            <ArrowRight size={13} />
          </button>
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

      <MediaRow title="Trending Light Novels" items={data.trendingList} onSelect={onSelect} />
    </div>
  );
}
