import { useState } from "react";
import { useQuery } from "@tanstack/react-query";
import { searchAnime } from "@/lib/api";
import { useAppStore } from "@/stores/app";
import type { MediaItem } from "@/lib/types";
import { Search } from "lucide-react";

export function SearchView() {
  const [query, setQuery] = useState("");
  const [debouncedQuery, setDebouncedQuery] = useState("");
  const openDetail = useAppStore((s) => s.openDetail);

  const { data, isLoading } = useQuery({
    queryKey: ["search", debouncedQuery],
    queryFn: () => searchAnime(debouncedQuery),
    enabled: debouncedQuery.length >= 2,
    staleTime: 120_000,
  });

  const items: MediaItem[] = data?.Page?.media || [];

  const handleChange = (value: string) => {
    setQuery(value);
    const timer = setTimeout(() => setDebouncedQuery(value), 300);
    return () => clearTimeout(timer);
  };

  return (
    <div className="flex-1 overflow-y-auto p-6">
      <div className="max-w-2xl mx-auto mb-6">
        <div className="relative">
          <Search
            size={18}
            className="absolute left-3 top-1/2 -translate-y-1/2 text-[var(--text-muted)]"
          />
          <input
            type="text"
            value={query}
            onChange={(e) => handleChange(e.target.value)}
            placeholder="Search anime..."
            className="w-full bg-[var(--bg-tertiary)] text-[var(--text-primary)] rounded-xl pl-10 pr-4 py-3 outline-none ring-1 ring-[var(--border)] focus:ring-[var(--accent)] transition-all"
            autoFocus
          />
        </div>
      </div>

      <div className="grid grid-cols-2 sm:grid-cols-3 md:grid-cols-4 lg:grid-cols-5 gap-3">
        {isLoading ? (
          <div className="col-span-full flex items-center justify-center h-32">
            <div className="animate-spin h-6 w-6 border-2 border-[var(--accent)] border-t-transparent rounded-full" />
          </div>
        ) : items.length > 0 ? (
          items.map((item) => (
            <button
              key={item.id}
              onClick={() => openDetail(item)}
              className="group relative aspect-[2/3] rounded-lg overflow-hidden bg-[var(--bg-tertiary)] hover:ring-2 hover:ring-[var(--accent)] hover:shadow-[0_0_20px_rgba(139,92,246,0.3)] transition-all"
            >
              {item.coverImage?.large && (
                <img
                  src={item.coverImage.large}
                  alt={item.title.romaji || item.title.english || ""}
                  className="w-full h-full object-cover"
                  loading="lazy"
                />
              )}
              <div className="absolute inset-0 bg-gradient-to-t from-black/80 via-transparent to-transparent opacity-0 group-hover:opacity-100 transition-opacity flex items-end p-2">
                <p className="text-white text-xs font-medium line-clamp-2">
                  {item.title.romaji || item.title.english}
                </p>
              </div>
            </button>
          ))
        ) : debouncedQuery.length >= 2 ? (
          <p className="col-span-full text-center text-[var(--text-secondary)] py-12">
            No results found for &quot;{debouncedQuery}&quot;
          </p>
        ) : null}
      </div>
    </div>
  );
}
