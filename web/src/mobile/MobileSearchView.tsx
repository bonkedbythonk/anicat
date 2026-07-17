import { useState, useEffect, useMemo } from "react";
import { Search, Loader2, SlidersHorizontal } from "lucide-react";
import { useQuery } from "@tanstack/react-query";
import { InfiniteScroll } from "@/components/shared/InfiniteScroll";
import { MediaTypeToggle } from "@/components/shared/MediaTypeToggle";
import { usePaginatedList } from "@/lib/usePaginatedList";
import { mediaApi, type MediaItem, type SearchFilters } from "@/lib/api";
import { PosterCard } from "./PosterCard";

interface MobileSearchViewProps {
  onSelect: (item: MediaItem) => void;
}

const GENRES = ["Action", "Adventure", "Comedy", "Drama", "Fantasy", "Horror", "Mystery", "Romance", "Sci-Fi", "Slice of Life", "Sports", "Supernatural", "Thriller"];

function PosterGrid({ items, onSelect }: { items: MediaItem[]; onSelect: (item: MediaItem) => void }) {
  return (
    <div className="grid grid-cols-3 gap-x-3 gap-y-5">
      {items.map((item) => (
        <PosterCard key={item.id} item={item} onSelect={onSelect} width="100%" />
      ))}
    </div>
  );
}

/** Mobile search — a native-style search field (iOS-style pill, no desktop
 * chrome) over a poster grid. Reuses the same data hooks as desktop's
 * SearchView (usePaginatedList, the discovery/random queries) so search
 * behavior and caching are identical; only the presentation is new. */
export function MobileSearchView({ onSelect }: MobileSearchViewProps) {
  const [query, setQuery] = useState("");
  const [debouncedQuery, setDebouncedQuery] = useState("");
  const [type, setType] = useState<"ANIME" | "MANGA">("ANIME");
  const [showFilters, setShowFilters] = useState(false);
  const [filters, setFilters] = useState<SearchFilters>({});

  const { data: discoveryRaw, isLoading: loadingDiscovery } = useQuery({
    queryKey: ["search-discovery", type],
    queryFn: async () => {
      const [trending, seasonal, recent] = await Promise.all([
        mediaApi.getTrending(type),
        mediaApi.getSeasonal(type),
        mediaApi.getRecent(type),
      ]);
      return { trending: trending.media || [], seasonal: seasonal.media || [], recent: recent.media || [] };
    },
  });

  const discovery = useMemo(() => {
    if (!discoveryRaw) return [];
    const pool = [...discoveryRaw.trending, ...discoveryRaw.seasonal, ...discoveryRaw.recent];
    return pool.filter((item, i, arr) => arr.findIndex((o) => o.id === item.id) === i).slice(0, 24);
  }, [discoveryRaw]);

  const { items: results, loading: loadingResults, loadingMore, hasMore, loadMore } = usePaginatedList<MediaItem>({
    fetchFn: async (page) => {
      const data = await mediaApi.search(debouncedQuery, type, page, filters);
      return { items: data.media || [], hasNextPage: data.page_info?.hasNextPage || false };
    },
    queryKey: ["search", debouncedQuery, type, filters],
    enabled: Boolean(debouncedQuery) || Object.values(filters).some(Boolean),
  });

  useEffect(() => {
    const trimmed = query.trim();
    if (!trimmed) { setDebouncedQuery(""); return; }
    const timer = setTimeout(() => setDebouncedQuery(trimmed), 400);
    return () => clearTimeout(timer);
  }, [query]);

  const hasFilters = Object.values(filters).some(Boolean);
  const isSearching = Boolean(debouncedQuery) || hasFilters;
  const loading = Boolean(debouncedQuery) && loadingResults;

  return (
    <div className="space-y-5 pb-4">
      <div className="flex items-center gap-2">
        <div className="relative flex-1">
          <Search className="absolute left-3.5 top-1/2 -translate-y-1/2 text-muted-foreground" size={18} />
          <input
            type="text"
            value={query}
            onChange={(e) => setQuery(e.target.value)}
            placeholder={`Search ${type.toLowerCase()}`}
            className="w-full rounded-md border border-border bg-surface py-2.5 pl-10 pr-4 text-[15px] outline-none placeholder:text-muted-foreground"
          />
        </div>
        <button
          onClick={() => setShowFilters((v) => !v)}
          className={`flex h-10 w-10 shrink-0 items-center justify-center rounded-md border `}
        >
          <SlidersHorizontal size={17} />
        </button>
      </div>

      <MediaTypeToggle value={type} onChange={setType} />

      {showFilters && (
        <div className="grid grid-cols-2 gap-2.5 rounded-md border border-border bg-surface p-3">
          <select value={filters.genre || ""} onChange={(e) => setFilters((f) => ({ ...f, genre: e.target.value || undefined }))} className="rounded-[4px] border border-border bg-background p-2.5 text-sm">
            <option value="">Any Genre</option>
            {GENRES.map((g) => <option key={g} value={g}>{g}</option>)}
          </select>
          <select value={filters.status || ""} onChange={(e) => setFilters((f) => ({ ...f, status: e.target.value || undefined }))} className="rounded-[4px] border border-border bg-background p-2.5 text-sm">
            <option value="">Any Status</option>
            <option value="FINISHED">Finished</option>
            <option value="RELEASING">Releasing</option>
            <option value="NOT_YET_RELEASED">Not Yet Released</option>
          </select>
        </div>
      )}

      {!isSearching && (
        loadingDiscovery && discovery.length === 0 ? (
          <div className="flex justify-center py-20"><Loader2 className="animate-spin text-accent" size={32} /></div>
        ) : (
          <PosterGrid items={discovery} onSelect={onSelect} />
        )
      )}

      {isSearching && loading && results.length === 0 && (
        <div className="flex justify-center py-20"><Loader2 className="animate-spin text-accent" size={32} /></div>
      )}

      {isSearching && results.length > 0 && (
        <>
          <PosterGrid items={results} onSelect={onSelect} />
          <InfiniteScroll hasMore={hasMore} loading={loadingMore} onLoadMore={loadMore} />
        </>
      )}

      {isSearching && !loading && results.length === 0 && (
        <div className="py-20 text-center">
          <p className="font-mono text-[11px] uppercase tracking-[0.08em] text-muted-foreground">No {type.toLowerCase()} found</p>
        </div>
      )}
    </div>
  );
}
