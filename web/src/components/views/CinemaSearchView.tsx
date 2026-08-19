import { useEffect, useState } from "react";
import { Loader2, Search } from "lucide-react";
import { useQuery } from "@tanstack/react-query";
import { MediaCard } from "@/components/media/MediaCard";
import { mediaApi, type MediaItem } from "@/lib/api";
import { useAppStore } from "@/stores/app";
import { useFocusable, useSpatialNavigation } from "@/focus";

interface CinemaSearchViewProps {
  onSelect: (item: MediaItem) => void;
}

function ResultGrid({ items, onSelect }: { items: MediaItem[]; onSelect: (item: MediaItem) => void }) {
  useSpatialNavigation();
  return (
    <div
      role="list"
      className="grid grid-cols-2 gap-5 sm:grid-cols-3 md:grid-cols-4 lg:grid-cols-5 xl:grid-cols-6"
    >
      {items.map((item) => (
        <div key={item.id} role="listitem">
          <MediaCard item={item} onSelect={onSelect} />
        </div>
      ))}
    </div>
  );
}

export function CinemaSearchView({ onSelect }: CinemaSearchViewProps) {
  // Reuses the store's search query so the text survives opening a detail page
  // and coming back, exactly as the anime search does.
  const query = useAppStore((s) => s.searchQuery);
  const setQuery = useAppStore((s) => s.setSearchQuery);
  const setActiveFocusScope = useAppStore((s) => s.setActiveFocusScope);
  const { ref, tabIndex } = useFocusable<HTMLInputElement>();

  useEffect(() => {
    setActiveFocusScope("search-default");
  }, [setActiveFocusScope]);

  const [debounced, setDebounced] = useState(() => (query.trim().length >= 2 ? query.trim() : ""));
  useEffect(() => {
    const t = setTimeout(() => setDebounced(query.trim().length >= 2 ? query.trim() : ""), 400);
    return () => clearTimeout(t);
  }, [query]);

  const results = useQuery({
    queryKey: ["cinema-search", debounced],
    queryFn: () => mediaApi.cinemaSearch(debounced),
    enabled: debounced.length >= 2,
    staleTime: 60_000,
  });

  // With no query yet, show something rather than an empty page. Trending
  // films are the closest cinema equivalent to the anime search's discovery
  // rows, and the row is already cached by the home view.
  const discovery = useQuery({
    queryKey: ["cinema-row", "trending_movies"],
    queryFn: () => mediaApi.cinemaRow("trending_movies"),
    enabled: debounced.length < 2,
  });

  const showing = debounced.length >= 2 ? results : discovery;
  const items = showing.data?.media ?? [];

  return (
    <div className="space-y-8 px-8 py-8">
      <div className="relative max-w-[520px]">
        <Search
          size={16}
          aria-hidden="true"
          className="pointer-events-none absolute left-4 top-1/2 -translate-y-1/2 text-muted-foreground"
        />
        <input
          ref={ref}
          tabIndex={tabIndex}
          type="text"
          aria-label="Search movies and series"
          value={query}
          onChange={(e) => setQuery(e.target.value)}
          placeholder="Search movies and series"
          className="w-full rounded-md border border-border bg-transparent py-3 pl-11 pr-4 text-sm outline-none transition-all focus:border-accent"
        />
      </div>

      <div>
        <h2 className="meta-mono mb-4 text-muted-foreground">
          {debounced.length >= 2 ? `Results for "${debounced}"` : "Trending Films"}
        </h2>

        {showing.isLoading ? (
          <div className="flex justify-center py-16">
            <Loader2 className="animate-spin text-accent" size={28} />
          </div>
        ) : showing.isError ? (
          <p className="py-16 text-center text-[13px] text-muted-foreground">
            Could not reach TMDB. Check the token in Settings.
          </p>
        ) : items.length === 0 ? (
          <p className="py-16 text-center text-[13px] text-muted-foreground">
            {debounced.length >= 2 ? "Nothing matched that." : "Nothing to show yet."}
          </p>
        ) : (
          <ResultGrid items={items} onSelect={onSelect} />
        )}
      </div>
    </div>
  );
}
