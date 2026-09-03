import { useMemo, useEffect } from "react";
import { Loader2, ArrowRight } from "lucide-react";
import { MediaRow } from "@/components/media/MediaRow";
import { UpNextQueue } from "@/components/media/UpNextQueue";
import { mediaApi } from "@/lib/api";
import type { MediaItem } from "@/lib/types";
import { useQuery } from "@tanstack/react-query";
import { useAppStore } from "@/stores/app";
import { FocusScope, ScopeNav, useFocusable } from "@/focus";

interface MangaViewProps {
  onSelect: (item: MediaItem, action?: "play", episode?: string | null) => void;
}

function BrowseMangaButton({ onClick }: { onClick: () => void }) {
  const { ref, isFocused, tabIndex } = useFocusable<HTMLButtonElement>();

  return (
    <button
      ref={ref}
      onClick={onClick}
      tabIndex={tabIndex}
      className={`flex items-center gap-1.5 rounded-md border px-3.5 py-1.5 text-[12px] font-medium transition-all cursor-pointer ${
        isFocused
          ? "border-accent bg-accent/10 text-foreground ring-1 ring-accent"
          : "border-border text-foreground/70 hover:text-foreground hover:border-foreground/25"
      }`}
    >
      <span>Browse all manga</span>
      <ArrowRight size={13} />
    </button>
  );
}

export function MangaView({ onSelect }: MangaViewProps) {
  const setActiveFocusScope = useAppStore((s) => s.setActiveFocusScope);
  const setCurrentView = useAppStore((s) => s.setCurrentView);
  const setSearchType = useAppStore((s) => s.setSearchType);
  const setSearchQuery = useAppStore((s) => s.setSearchQuery);

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

  const handleBrowseCatalog = () => {
    setSearchType("MANGA");
    setSearchQuery("");
    setCurrentView("search");
  };

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

  useEffect(() => {
    if (continueReading.length > 0) {
      setActiveFocusScope("manga-queue");
    } else if (data?.readingList?.length) {
      setActiveFocusScope("row-Reading");
    } else {
      setActiveFocusScope("row-Trending Manga");
    }
  }, [continueReading.length, data, setActiveFocusScope]);

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
            <h1 className="text-[19px] font-semibold tracking-tight text-foreground">Manga</h1>
            <p className="meta-mono mt-1 text-muted-foreground">
              {continueReading.length} in progress · {data.readingList.length} reading
            </p>
          </div>
          <FocusScope name="manga-header" orientation="horizontal">
            <ScopeNav />
            <BrowseMangaButton onClick={handleBrowseCatalog} />
          </FocusScope>
        </div>
        {continueReading.length > 0 ? (
          <UpNextQueue
            items={continueReading.slice(0, 8)}
            newEpisodeIds={new Set()}
            lastWatched={{}}
            onSelect={onSelect}
            unit="CH"
            focusScopeName="manga-queue"
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
