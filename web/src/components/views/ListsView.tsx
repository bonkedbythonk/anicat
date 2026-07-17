
import { useState } from "react";
import { Loader2 } from "lucide-react";
import { MediaCard } from "@/components/media/MediaCard";
import { InfiniteScroll } from "@/components/shared/InfiniteScroll";
import { MediaTypeToggle } from "@/components/shared/MediaTypeToggle";
import { usePaginatedList } from "@/lib/usePaginatedList";
import { mediaApi, type MediaItem } from "@/lib/api";
import { formatRelativeTimeFromUnix } from "@/lib/date";
import { useAppStore, type WatchStatus } from "@/stores/app";

const LIST_TABS: { key: WatchStatus; label: string }[] = [
  { key: "watching", label: "Watching" },
  { key: "repeating", label: "Rewatching" },
  { key: "completed", label: "Completed" },
  { key: "planning", label: "Planning" },
  { key: "paused", label: "Paused" },
  { key: "dropped", label: "Dropped" },
];

interface ListsViewProps {
  onSelect: (item: MediaItem) => void;
}

// Skeleton card grid shown during tab switches instead of a blinding spinner
function ListSkeletonGrid() {
  return (
    <div className="grid grid-cols-2 sm:grid-cols-3 md:grid-cols-4 lg:grid-cols-5 xl:grid-cols-6 gap-5 animate-pulse">
      {Array.from({ length: 12 }).map((_, i) => (
        <div key={i} className="space-y-2.5">
          <div className="aspect-[2/3] w-full rounded-lg bg-foreground/10" />
          <div className="h-4 w-3/4 rounded-md bg-foreground/10" />
          <div className="h-3 w-1/2 rounded-md bg-foreground/10" />
        </div>
      ))}
    </div>
  );
}

/** The Library: poster grid by default (choosing what to watch is a visual
 * decision), dense table as a toggle for sorting and scanning. */
export function ListsView({ onSelect }: ListsViewProps) {
  const activeTab = useAppStore((s) => s.listsActiveTab);
  const setActiveTab = useAppStore((s) => s.setListsActiveTab);
  const type = useAppStore((s) => s.listsType);
  const setType = useAppStore((s) => s.setListsType);
  const isAuthenticated = useAppStore((s) => s.apiAuthenticated);
  const [layout, setLayout] = useState<"grid" | "table">(
    () => (localStorage.getItem("anicat_library_layout") === "table" ? "table" : "grid")
  );

  const switchLayout = (next: "grid" | "table") => {
    setLayout(next);
    localStorage.setItem("anicat_library_layout", next);
  };

  const { items, loading, loadingMore, hasMore, loadMore } =
    usePaginatedList<MediaItem>({
      fetchFn: async (page) => {
        const data = await mediaApi.getUserList(activeTab, type, page);
        return {
          items: (data.media || []) as MediaItem[],
          hasNextPage: data.page_info?.has_next_page || false,
        };
      },
      queryKey: ["lists", activeTab, type],
      enabled: isAuthenticated,
    });

  const tabLabel = (tab: { key: WatchStatus; label: string }) =>
    tab.key === "watching"
      ? type === "MANGA" ? "Reading" : "Watching"
      : tab.key === "repeating"
        ? type === "MANGA" ? "Rereading" : "Rewatching"
        : tab.label;

  return (
    <div className="space-y-5 animate-fade-in max-w-[1200px]">
      <div className="flex items-end justify-between gap-4 flex-wrap">
        <div>
          <h1 className="text-[19px] font-semibold tracking-tight text-foreground">Library</h1>
          <p className="meta-mono mt-1 text-muted-foreground">
            {items.length}{hasMore ? "+" : ""} {type === "MANGA" ? "manga" : "anime"} · {layout}
          </p>
        </div>
        <div className="flex items-center gap-3">
          <MediaTypeToggle value={type} onChange={setType} />
          <div className="flex rounded-md border border-border overflow-hidden">
            {(["grid", "table"] as const).map((l) => (
              <button
                key={l}
                onClick={() => switchLayout(l)}
                className={`px-3 py-1.5 text-[12px] font-medium cursor-pointer ${
                  layout === l ? "bg-accent/15 text-accent" : "text-foreground/50 hover:text-foreground"
                }`}
              >
                {l === "grid" ? "Grid" : "Table"}
              </button>
            ))}
          </div>
        </div>
      </div>

      {/* Status filter: plain words, active in indigo. */}
      <div className="flex gap-1 flex-wrap">
        {LIST_TABS.map((tab) => (
          <button
            key={tab.key}
            onClick={() => setActiveTab(tab.key)}
            className={`px-3 py-1.5 rounded-md text-[12.5px] font-medium whitespace-nowrap cursor-pointer ${
              activeTab === tab.key
                ? "bg-accent/15 text-accent"
                : "text-foreground/50 hover:text-foreground/80"
            }`}
          >
            {tabLabel(tab)}
          </button>
        ))}
      </div>

      <div className="relative">
        {loading && items.length > 0 && (
          <div className="absolute top-0 left-0 right-0 z-10 flex justify-center mt-12 animate-fade-in">
            <div className="bg-surface px-5 py-2.5 rounded-lg border border-border flex items-center space-x-3 shadow-xl">
              <Loader2 className="animate-spin text-accent" size={16} />
              <span className="meta-mono text-foreground">Updating</span>
            </div>
          </div>
        )}

        {items.length > 0 ? (
          layout === "grid" ? (
            <div className={`grid grid-cols-2 sm:grid-cols-3 md:grid-cols-4 lg:grid-cols-5 xl:grid-cols-6 gap-5 animate-fade-in transition-opacity duration-200 ${loading ? "opacity-50 pointer-events-none" : "opacity-100"}`}>
              {items.map((item) => (
                <MediaCard key={item.id} item={item} onSelect={onSelect} />
              ))}
            </div>
          ) : (
            <div className={`overflow-x-auto rounded-lg border border-border animate-fade-in transition-opacity duration-200 ${loading ? "opacity-50 pointer-events-none" : "opacity-100"}`}>
              <table className="w-full text-[13px] border-collapse">
                <thead>
                  <tr>
                    {["Title", "Progress", "Score", "Updated"].map((h) => (
                      <th key={h} className="meta-mono text-left font-medium text-muted-foreground px-4 py-2.5 border-b border-border">
                        {h}
                      </th>
                    ))}
                  </tr>
                </thead>
                <tbody>
                  {items.map((item) => {
                    const progress = item.user_status?.progress ?? item.media_list_entry?.progress ?? 0;
                    const total = (type === "MANGA" ? item.chapters : item.episodes) || 0;
                    const pct = total > 0 ? Math.min(100, (progress / total) * 100) : 0;
                    const score = item.user_status?.score ?? item.media_list_entry?.score ?? 0;
                    const updated = item.user_status?.updated_at || item.media_list_entry?.updated_at;
                    return (
                      <tr
                        key={item.id}
                        onClick={() => onSelect(item)}
                        className="cursor-pointer hover:bg-surface/70 border-b border-border last:border-b-0"
                      >
                        <td className="px-4 py-2.5 font-medium text-foreground max-w-[380px] truncate">
                          {item.title.english || item.title.romaji}
                        </td>
                        <td className="px-4 py-2.5 whitespace-nowrap">
                          <span className="inline-block align-middle w-16 h-[2px] rounded-full bg-foreground/10 mr-3">
                            <span className="block h-full rounded-full bg-accent" style={{ width: `${pct}%` }} />
                          </span>
                          <span className="meta-mono text-muted-foreground">
                            {progress}{total ? ` / ${total}` : ""}
                          </span>
                        </td>
                        <td className="meta-mono px-4 py-2.5 text-muted-foreground">
                          {score > 0 ? score : "—"}
                        </td>
                        <td className="meta-mono px-4 py-2.5 text-muted-foreground whitespace-nowrap">
                          {updated ? formatRelativeTimeFromUnix(updated) : "—"}
                        </td>
                      </tr>
                    );
                  })}
                </tbody>
              </table>
            </div>
          )
        ) : loading ? (
          <ListSkeletonGrid />
        ) : (
          <div className="py-24 text-center rounded-lg border border-dashed border-border">
            <p className="meta-mono text-muted-foreground">This list is empty</p>
            <p className="text-sm text-foreground/50 mt-2">Search for {type.toLowerCase()} and add them to your list.</p>
          </div>
        )}
      </div>

      <InfiniteScroll hasMore={hasMore} loading={loadingMore} onLoadMore={loadMore} />
    </div>
  );
}
