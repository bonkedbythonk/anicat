import { Loader2 } from "lucide-react";
import { InfiniteScroll } from "@/components/shared/InfiniteScroll";
import { MediaTypeToggle } from "@/components/shared/MediaTypeToggle";
import { usePaginatedList } from "@/lib/usePaginatedList";
import { mediaApi, type MediaItem } from "@/lib/api";
import { useAppStore, type WatchStatus } from "@/stores/app";
import { PosterCard } from "./PosterCard";

const LIST_TABS: { key: WatchStatus; label: string }[] = [
  { key: "watching", label: "Watching" },
  { key: "repeating", label: "Rewatching" },
  { key: "completed", label: "Completed" },
  { key: "planning", label: "Planning" },
  { key: "paused", label: "Paused" },
  { key: "dropped", label: "Dropped" },
];

interface MobileListsViewProps {
  onSelect: (item: MediaItem) => void;
}

/** Mobile My Lists — same underlying paginated query as desktop (shared
 * queryKey/cache), rebuilt as a native segmented-pill tab strip over a
 * poster grid instead of desktop's card grid. */
export function MobileListsView({ onSelect }: MobileListsViewProps) {
  const activeTab = useAppStore((s) => s.listsActiveTab);
  const setActiveTab = useAppStore((s) => s.setListsActiveTab);
  const type = useAppStore((s) => s.listsType);
  const setType = useAppStore((s) => s.setListsType);
  const isAuthenticated = useAppStore((s) => s.apiAuthenticated);

  const { items, loading, loadingMore, hasMore, loadMore } = usePaginatedList<MediaItem>({
    fetchFn: async (page) => {
      const data = await mediaApi.getUserList(activeTab, type, page);
      return { items: (data.media || []) as MediaItem[], hasNextPage: data.page_info?.has_next_page || false };
    },
    queryKey: ["lists", activeTab, type],
    enabled: isAuthenticated,
  });

  return (
    <div className="space-y-4 pb-4">
      <MediaTypeToggle value={type} onChange={setType} />

      <div className="-mx-6 flex gap-2 overflow-x-auto px-6 pb-1 scrollbar-hide">
        {LIST_TABS.map((tab) => {
          const active = activeTab === tab.key;
          const label = tab.key === "watching" ? (type === "MANGA" ? "Reading" : "Watching")
            : tab.key === "repeating" ? (type === "MANGA" ? "Rereading" : "Rewatching")
            : tab.label;
          return (
            <button
              key={tab.key}
              onClick={() => setActiveTab(tab.key)}
              className={`shrink-0 rounded-full border px-3.5 py-1.5 font-mono text-[10px] uppercase tracking-[0.08em] transition-colors ${
                active ? "border-transparent bg-foreground/10 text-foreground" : "border-border text-muted-foreground"
              }`}
            >
              {label}
            </button>
          );
        })}
      </div>

      {items.length > 0 ? (
        <div className="grid grid-cols-3 gap-x-3 gap-y-5">
          {items.map((item) => (
            <PosterCard key={item.id} item={item} onSelect={onSelect} width="100%" />
          ))}
        </div>
      ) : loading ? (
        <div className="flex justify-center py-20"><Loader2 className="animate-spin text-accent" size={32} /></div>
      ) : (
        <div className="py-20 text-center">
          <p className="font-mono text-[11px] uppercase tracking-[0.08em] text-muted-foreground">This list is empty</p>
        </div>
      )}

      <InfiniteScroll hasMore={hasMore} loading={loadingMore} onLoadMore={loadMore} />
    </div>
  );
}
