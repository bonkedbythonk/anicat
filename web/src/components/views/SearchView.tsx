import { useState, useEffect, useCallback, useMemo } from "react";
import { useAppStore } from "@/stores/app";
import { Search, Loader2, SlidersHorizontal, Activity } from "lucide-react";
import { useQuery, useQueryClient } from "@tanstack/react-query";
import { MediaCard } from "@/components/media/MediaCard";
import { InfiniteScroll } from "@/components/shared/InfiniteScroll";
import { MediaTypeToggle } from "@/components/shared/MediaTypeToggle";
import { usePaginatedList } from "@/lib/usePaginatedList";
import { mediaApi, type MediaItem, type SearchFilters } from "@/lib/api";
import type { MediaSearchType } from "@/lib/types";
import { FocusScope, useFocusable, useSpatialNavigation } from "@/focus";

interface SearchViewProps {
  onSelect: (item: MediaItem) => void;
}

function SuggestionButton({ item, onSelect }: { item: MediaItem; onSelect: (item: MediaItem) => void }) {
  const { ref, tabIndex } = useFocusable<HTMLButtonElement>();
  const title = item.title.english || item.title.romaji || "Media";
  return (
    <button
      ref={ref}
      tabIndex={tabIndex}
      onClick={() => onSelect(item)}
      className="flex w-full items-center gap-3 rounded-md border border-border p-2 text-left transition-colors hover:border-foreground/25 hover:bg-surface/70 cursor-pointer"
    >
      <img
        src={item.cover_image?.large}
        alt={title}
        className="h-14 w-10 shrink-0 rounded-lg object-cover"
      />
      <div className="min-w-0 flex-1">
        <p className="truncate text-[13px] font-medium text-foreground">{title}</p>
        <p className="meta-mono truncate text-muted-foreground mt-0.5">
          {item.season && item.seasonYear ? `${item.season.charAt(0) + item.season.slice(1).toLowerCase()} ${item.seasonYear}` : item.status || "Anime"}
        </p>
      </div>
    </button>
  );
}

function SuggestionItems({ suggestions, onSelect }: { suggestions: MediaItem[]; onSelect: (item: MediaItem) => void }) {
  useSpatialNavigation();
  return (
    <>
      {suggestions.map((item) => (
        // min-w-0: a grid item defaults to min-width:auto, so it refuses to
        // shrink below its content's intrinsic width. Without this a long
        // title pushes the card past its column and over its neighbour, and
        // the inner `truncate` never engages because no ancestor is allowed
        // to shrink.
        <div key={item.id} role="listitem" className="min-w-0">
          <SuggestionButton item={item} onSelect={onSelect} />
        </div>
      ))}
    </>
  );
}

function MediaGrid({ items, onSelect, className }: { items: MediaItem[]; onSelect: (item: MediaItem) => void; className?: string }) {
  useSpatialNavigation();
  return (
    <>
      {items.map((item) => (
        <div key={item.id} role="listitem" className={className}>
          <MediaCard item={item} onSelect={onSelect} />
        </div>
      ))}
    </>
  );
}

export function SearchView({ onSelect }: SearchViewProps) {
  const query = useAppStore(s => s.searchQuery);
  const setQuery = useAppStore(s => s.setSearchQuery);
  const type = useAppStore(s => s.searchType);
  const setType = useAppStore(s => s.setSearchType);
  const filters = useAppStore(s => s.searchFilters);
  const setFilters = useAppStore(s => s.setSearchFilters);
  const setActiveFocusScope = useAppStore(s => s.setActiveFocusScope);
  const shuffleFocus = useFocusable<HTMLButtonElement>();
  const randomFocus = useFocusable<HTMLButtonElement>();

  useEffect(() => {
    setActiveFocusScope("search-default");
  }, [setActiveFocusScope]);

  // Discovery rows, random picks and the shuffle pool are inherently
  // per-type -- "Seasonal" has no manga meaning, and AniList's trending
  // endpoints take a concrete type. "ALL" only ever applies to an actual
  // query, so those surfaces fall back to anime.
  const discoveryType: "ANIME" | "MANGA" = type === "MANGA" ? "MANGA" : "ANIME";
  const combined = type === "ALL";

  const [debouncedQuery, setDebouncedQuery] = useState(() => query.trim().length >= 2 ? query.trim() : "");
  const [showFilters, setShowFilters] = useState(() => Object.keys(filters).length > 0);
  const queryClient = useQueryClient();

  // Cached discovery feed — refetches silently every 5 min, not on every mount
  const {
    data: discoveryRaw,
    isLoading: loadingDiscovery,
    isError: discoveryError,
  } = useQuery({
    queryKey: ["search-discovery", discoveryType],
    queryFn: async () => {
      const [trending, seasonal, recent] = await Promise.all([
        mediaApi.getTrending(discoveryType),
        mediaApi.getSeasonal(discoveryType),
        mediaApi.getRecent(discoveryType),
      ]);
      return { trending: trending.media || [], seasonal: seasonal.media || [], recent: recent.media || [] };
    },
  });

  // Random picks — cached per type, re-fetched with "New Random" button
  const {
    data: randomListRaw = [],
    isFetching: fetchingRandom,
    refetch: refetchRandom,
  } = useQuery({
    queryKey: ["search-random", discoveryType],
    queryFn: async () => {
      const randomPage = Math.floor(Math.random() * 100) + 1;
      const data = await mediaApi.search("", discoveryType, randomPage);
      return data.media || [];
    },
  });

  const randomList = useMemo(() => randomListRaw, [randomListRaw]);

  const [shuffledPools, setShuffledPools] = useState<Record<"ANIME" | "MANGA", MediaItem[]>>({
    ANIME: [],
    MANGA: [],
  });

  useEffect(() => {
    if (!discoveryRaw) return;
    setShuffledPools(prev => {
      if (prev[discoveryType].length > 0) return prev;
      
      const pool = [...discoveryRaw.trending, ...discoveryRaw.seasonal, ...discoveryRaw.recent];
      const unique = pool.filter((item, index, array) => array.findIndex(other => other.id === item.id) === index);
      const shuffled = unique.sort(() => Math.random() - 0.5).slice(0, 18);
      return {
        ...prev,
        [discoveryType]: shuffled,
      };
    });
  }, [discoveryRaw, discoveryType]);

  // Year maps to AniList's seasonYear, which manga essentially never carry --
  // leaving it set while switching to "All" would silently filter every manga
  // result back out, making the combined search look broken.
  const handleTypeChange = (next: MediaSearchType) => {
    setType(next);
    if (next === "ALL" && filters.year) {
      const { year: _year, ...rest } = filters;
      setFilters(rest);
    }
  };

  const handleShuffle = () => {
    if (!discoveryRaw) return;
    const pool = [...discoveryRaw.trending, ...discoveryRaw.seasonal, ...discoveryRaw.recent];
    const unique = pool.filter((item, index, array) => array.findIndex(other => other.id === item.id) === index);
    const shuffled = unique.sort(() => Math.random() - 0.5).slice(0, 18);
    setShuffledPools(prev => ({
      ...prev,
      [discoveryType]: shuffled,
    }));
  };

  // Paginated search results — active when query or filters are present
  const {
    items: results,
    loading: loadingResults,
    loadingMore,
    hasMore,
    loadMore,
  } = usePaginatedList<MediaItem>({
    fetchFn: async (page) => {
      const data = await mediaApi.search(debouncedQuery, type, page, filters);
      return {
        items: data.media || [],
        hasNextPage: data.page_info?.hasNextPage || false,
      };
    },
    queryKey: ["search", debouncedQuery, type, filters],
    enabled: Boolean(debouncedQuery) || Object.values(filters).some(Boolean),
  });

  // Debounce the search query (400ms) so usePaginatedList only fires after
  // settling. Also require 2+ chars: single-letter queries return thousands
  // of low-value matches and, more importantly, fire an AniList request for
  // every brief pause while the user is still typing the first character.
  useEffect(() => {
    const trimmed = query.trim();
    if (trimmed.length < 2) {
      setDebouncedQuery("");
      return;
    }
    const timer = setTimeout(() => {
      setDebouncedQuery(trimmed);
    }, 400);
    return () => clearTimeout(timer);
  }, [query]);

  const loading = Boolean(debouncedQuery) && loadingResults;

  // Suggestions reuse the same paginated search results instead of firing a
  // second, independently-debounced AniList query — the two were issuing
  // duplicate requests per keystroke and tripping AniList's rate limiter.
  const suggestions = useMemo(() => results.slice(0, 6), [results]);
  const loadingSuggestions = loadingResults;

  return (
    <div className="space-y-8 animate-fade-in">
      {/* Search header */}
      <div className="space-y-6">
        <div className="flex flex-col sm:flex-row sm:items-end justify-between gap-4">
          <h1 className="text-[19px] font-semibold tracking-tight text-foreground">Search</h1>
          <MediaTypeToggle value={type} onChange={handleTypeChange} options={["ALL", "ANIME", "MANGA"] as const} />
        </div>

        <div className="relative group">
          <Search className="absolute left-4 top-1/2 -translate-y-1/2 text-muted-foreground group-focus-within:text-accent transition-colors" size={17} />
          <input
            autoFocus
            type="text"
            value={query}
            onChange={(e) => setQuery(e.target.value)}
            placeholder={combined ? "Search anime and manga..." : `Search for ${type.toLowerCase()}...`}
            className="w-full bg-transparent border border-border rounded-lg py-3 pl-12 pr-6 text-[15px] focus:outline-none transition-colors placeholder:text-muted-foreground/60"
          />
          {loading && (
            <Loader2 className="absolute right-5 top-1/2 -translate-y-1/2 text-accent animate-spin" size={22} />
          )}
        </div>

        {debouncedQuery.trim().length >= 2 && suggestions.length > 0 && (
          <div className="space-y-3 rounded-lg border border-border p-4">
            <div className="flex items-center justify-between gap-3">
              <p className="meta-mono text-muted-foreground">Suggestions</p>
              {loadingSuggestions && <Loader2 className="animate-spin text-accent" size={14} />}
            </div>
            <FocusScope name="search-suggestions" orientation="vertical" role="list" className="grid gap-2 sm:grid-cols-2 xl:grid-cols-3">
              <SuggestionItems suggestions={suggestions} onSelect={onSelect} />
            </FocusScope>
          </div>
        )}

        {/* Filter toggle */}
        <button
          onClick={() => setShowFilters(!showFilters)}
          className={`flex items-center space-x-2 px-3.5 py-1.5 rounded-md text-[12.5px] font-medium transition-colors border cursor-pointer ${
            showFilters || Object.values(filters).some(Boolean)
              ? "bg-accent/15 text-accent border-transparent"
              : "text-foreground/50 border-border hover:text-foreground"
          }`}
        >
          <SlidersHorizontal size={14} />
          <span>Filters{Object.values(filters).filter(Boolean).length > 0 ? ` (${Object.values(filters).filter(Boolean).length})` : ""}</span>
        </button>

        {/* Filter panel */}
        {showFilters && (
          <div className="grid grid-cols-2 lg:grid-cols-4 gap-3 p-4 border border-border rounded-lg animate-fade-in">
            <div className="space-y-1.5">
              <label className="meta-mono text-muted-foreground">Genre</label>
              <select
                value={filters.genre || ""}
                onChange={(e) => setFilters({ ...filters, genre: e.target.value || undefined })}
                className="w-full bg-transparent border border-border rounded-md p-2.5 text-xs focus:border-accent outline-none transition-colors appearance-none cursor-pointer"
              >
                <option value="">Any Genre</option>
                {["Action","Adventure","Comedy","Drama","Fantasy","Horror","Mystery","Romance","Sci-Fi","Slice of Life","Sports","Supernatural","Thriller"].map(g => (
                  <option key={g} value={g}>{g}</option>
                ))}
              </select>
            </div>
            {!combined && (
            <div className="space-y-1.5">
              <label className="meta-mono text-muted-foreground">Year</label>
              <select
                value={filters.year || ""}
                onChange={(e) => setFilters({ ...filters, year: e.target.value ? Number(e.target.value) : undefined })}
                className="w-full bg-transparent border border-border rounded-md p-2.5 text-xs focus:border-accent outline-none transition-colors appearance-none cursor-pointer"
              >
                <option value="">Any Year</option>
                {Array.from({ length: 27 }, (_, i) => 2026 - i).map(y => (
                  <option key={y} value={y}>{y}</option>
                ))}
              </select>
            </div>
            )}
            <div className="space-y-1.5">
              <label className="meta-mono text-muted-foreground">Min Score</label>
              <select
                value={filters.minScore || ""}
                onChange={(e) => setFilters({ ...filters, minScore: e.target.value ? Number(e.target.value) : undefined })}
                className="w-full bg-transparent border border-border rounded-md p-2.5 text-xs focus:border-accent outline-none transition-colors appearance-none cursor-pointer"
              >
                <option value="">Any Score</option>
                {[90, 80, 70, 60, 50].map(s => (
                  <option key={s} value={s}>{s}%+</option>
                ))}
              </select>
            </div>
            <div className="space-y-1.5">
              <label className="meta-mono text-muted-foreground">Status</label>
              <select
                value={filters.status || ""}
                onChange={(e) => setFilters({ ...filters, status: e.target.value || undefined })}
                className="w-full bg-transparent border border-border rounded-md p-2.5 text-xs focus:border-accent outline-none transition-colors appearance-none cursor-pointer"
              >
                <option value="">Any Status</option>
                <option value="FINISHED">Finished</option>
                <option value="RELEASING">Releasing</option>
                <option value="NOT_YET_RELEASED">Not Yet Released</option>
              </select>
            </div>
          </div>
        )}
      </div>

      {/* Results */}
      {(() => {
        const hasFilters = Object.values(filters).some(Boolean);
        
        if (query.trim().length === 0 && !hasFilters) {
          const discovery = shuffledPools[discoveryType];
          const hasDiscovery = discovery.length > 0;
          const showSkeleton = loadingDiscovery && !hasDiscovery;

          return (
            <div className="space-y-12 relative">
              {loadingDiscovery && hasDiscovery && (
                <div className="absolute top-1/2 left-0 right-0 z-10 flex justify-center -translate-y-1/2 animate-fade-in">
                  <div className="bg-surface px-5 py-2.5 rounded-lg border border-border flex items-center space-x-3 shadow-xl">
                    <Loader2 className="animate-spin text-accent" size={16} />
                    <span className="meta-mono text-foreground">Loading {discoveryType.toLowerCase()}</span>
                  </div>
                </div>
              )}

              {showSkeleton ? (
                <div className="space-y-4">
                  <div className="space-y-2">
                    <div className="h-7 bg-white/[0.04] rounded-md w-48 animate-pulse" />
                    <div className="h-4 bg-white/[0.02] rounded-md w-64 animate-pulse" />
                  </div>
                  <div className="grid grid-cols-2 gap-5 sm:grid-cols-3 md:grid-cols-4 lg:grid-cols-5 xl:grid-cols-6">
                    {Array.from({ length: 12 }).map((_, i) => (
                      <div key={i} className="space-y-3 animate-pulse">
                        <div className="aspect-[2/3] w-full bg-white/[0.04] rounded-md border border-border" />
                        <div className="h-4 bg-white/[0.04] rounded-md w-3/4" />
                        <div className="h-3 bg-white/[0.02] rounded-md w-1/2" />
                      </div>
                    ))}
                  </div>
                </div>
              ) : (
                <>
                  {hasDiscovery && (
                    <div className={`space-y-4 transition-opacity duration-200 ${loadingDiscovery ? "opacity-50 pointer-events-none" : "opacity-100"}`}>
                      <div className="flex items-center justify-between gap-3">
                        <div>
                          <h2 className="text-[15px] font-semibold tracking-tight text-foreground">{combined ? "Discover" : discoveryType === "ANIME" ? "Discover Anime" : "Discover Manga"}</h2>
                          <p className="meta-mono mt-1 text-muted-foreground">Trending · seasonal · recent</p>
                        </div>
                        <button
                          ref={shuffleFocus.ref}
                          tabIndex={shuffleFocus.tabIndex}
                          onClick={handleShuffle}
                          className="rounded-md border border-border px-3.5 py-1.5 text-[12px] font-medium text-foreground/70 transition-colors hover:border-foreground/25 hover:text-foreground cursor-pointer"
                        >
                          Shuffle
                        </button>
                      </div>
                      <FocusScope name="search-discovery" orientation="grid" columns={6} role="list" className="grid grid-cols-2 gap-5 sm:grid-cols-3 md:grid-cols-4 lg:grid-cols-5 xl:grid-cols-6">
                        <MediaGrid items={discovery} onSelect={onSelect} />
                      </FocusScope>
                    </div>
                  )}

                  {randomList.length > 0 && (
                    <div className={`space-y-4 pt-12 border-t border-border transition-opacity duration-200 ${loadingDiscovery ? "opacity-50 pointer-events-none" : "opacity-100"}`}>
                      <div className="flex items-center justify-between gap-3">
                        <div>
                          <h2 className="text-[15px] font-semibold tracking-tight text-foreground">Random Picks</h2>
                          <p className="meta-mono mt-1 text-muted-foreground">From across the whole database</p>
                        </div>
                        <button
                          ref={randomFocus.ref}
                          tabIndex={randomFocus.tabIndex}
                          onClick={() => { refetchRandom(); }}
                          disabled={fetchingRandom}
                          className="rounded-md border border-border px-3.5 py-1.5 text-[12px] font-medium text-foreground/70 transition-colors hover:border-foreground/25 hover:text-foreground disabled:opacity-50 cursor-pointer"
                        >
                          {fetchingRandom ? "Loading..." : "New Random"}
                        </button>
                      </div>
                      <FocusScope name="search-random" orientation="grid" columns={6} role="list" className="grid grid-cols-2 gap-5 sm:grid-cols-3 md:grid-cols-4 lg:grid-cols-5 xl:grid-cols-6">
                        <MediaGrid items={randomList} onSelect={onSelect} />
                      </FocusScope>
                    </div>
                  )}

                  {!loadingDiscovery && !hasDiscovery && randomList.length === 0 && (
                    <div className="text-center py-24 rounded-lg border border-dashed border-border">
                      <Activity size={40} className="mx-auto text-gray-800 mb-4" />
                      <p className="text-gray-500 font-semibold">Unable to load discovery feed.</p>
                      <button 
                        onClick={() => { queryClient.invalidateQueries({ queryKey: ["search-discovery"] }); }}
                        className="mt-4 text-accent text-sm font-bold hover:underline"
                      >
                        Try Refreshing
                      </button>
                    </div>
                  )}
                </>
              )}
            </div>
          );
        }

        if (results.length > 0) {
          // Flat-merging the two types lets the more popular medium dominate
          // the ordering, burying a title's manga entry under its anime. Split
          // sections keep both findable; a section is omitted when empty, so a
          // query that only matches one type still reads as a plain list.
          if (combined) {
            const anime = results.filter(r => r.type !== "MANGA");
            const manga = results.filter(r => r.type === "MANGA");
            return (
              <div className="space-y-10">
                {[
                  { key: "ANIME", label: "Anime", items: anime },
                  { key: "MANGA", label: "Manga", items: manga },
                ].filter(g => g.items.length > 0).map(group => (
                  <div key={group.key} className="space-y-4">
                    <div className="flex items-baseline gap-3">
                      <h2 className="text-[15px] font-semibold tracking-tight text-foreground">{group.label}</h2>
                      <span className="meta-mono text-muted-foreground">{group.items.length}</span>
                    </div>
                    <FocusScope name={`search-results-${group.key.toLowerCase()}`} orientation="grid" columns={6} role="list" className="grid grid-cols-2 sm:grid-cols-3 md:grid-cols-4 lg:grid-cols-5 xl:grid-cols-6 gap-5">
                      <MediaGrid items={group.items} onSelect={onSelect} />
                    </FocusScope>
                  </div>
                ))}
              </div>
            );
          }
          return (
            <FocusScope name="search-results" orientation="grid" columns={6} role="list" className="grid grid-cols-2 sm:grid-cols-3 md:grid-cols-4 lg:grid-cols-5 xl:grid-cols-6 gap-5">
              <MediaGrid items={results} onSelect={onSelect} />
            </FocusScope>
          );
        }

        if (query.trim().length > 0 && !loading) {
          return (
            <div className="text-center py-24">
              <Search size={40} className="mx-auto text-gray-800 mb-4" />
              <p className="text-gray-600 font-semibold">No {combined ? "results" : type.toLowerCase()} found for &quot;{query}&quot;</p>
            </div>
          );
        }

        if (hasFilters && !loading) {
          return (
            <div className="text-center py-24">
              <SlidersHorizontal size={40} className="mx-auto text-gray-800 mb-4" />
              <p className="text-gray-600 font-semibold">No {combined ? "results" : type.toLowerCase()} found matching these filters.</p>
            </div>
          );
        }

        return null;
      })()}

      {debouncedQuery && (
        <InfiniteScroll hasMore={hasMore} loading={loadingMore} onLoadMore={loadMore} />
      )}
    </div>
  );
}
