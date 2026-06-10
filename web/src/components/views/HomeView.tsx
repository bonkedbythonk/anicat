import { useQuery } from "@tanstack/react-query";
import { getTrending, getSeasonal, getSmartPlaylist, getUpcoming } from "@/lib/api";
import { useAppStore } from "@/stores/app";
import type { MediaItem } from "@/lib/types";
import { Play } from "lucide-react";

function MediaGrid({ items, title }: { items: MediaItem[]; title: string }) {
  const openDetail = useAppStore((s) => s.openDetail);

  if (!items.length) return null;

  return (
    <section className="mb-8">
      <h2 className="text-lg font-semibold text-[var(--text-primary)] mb-3">{title}</h2>
      <div className="grid grid-cols-2 sm:grid-cols-3 md:grid-cols-4 lg:grid-cols-5 xl:grid-cols-6 gap-3">
        {items.map((item) => (
          <button
            key={item.id}
            onClick={() => openDetail(item)}
            onMouseEnter={() => {
              document.documentElement.style.setProperty(
                "--ambient-color",
                "rgba(139, 92, 246, 0.12)"
              );
            }}
            onMouseLeave={() => {
              document.documentElement.style.setProperty(
                "--ambient-color",
                "rgba(139, 92, 246, 0.08)"
              );
            }}
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
        ))}
      </div>
    </section>
  );
}

export function HomeView() {
  const trending = useQuery({
    queryKey: ["home-trending"],
    queryFn: () => getTrending(),
    staleTime: 300_000,
  });

  const seasonal = useQuery({
    queryKey: ["home-seasonal"],
    queryFn: () => getSeasonal(),
    staleTime: 300_000,
  });

  const upcoming = useQuery({
    queryKey: ["home-upcoming"],
    queryFn: () => getUpcoming(),
    staleTime: 300_000,
  });

  const smart = useQuery({
    queryKey: ["home-smart"],
    queryFn: () => getSmartPlaylist(),
    staleTime: 300_000,
  });

  const trendingItems = trending.data?.Page?.media || [];
  const seasonalItems = seasonal.data?.Page?.media || [];
  const upcomingItems = upcoming.data?.Page?.media || [];
  const smartItems = smart.data?.Page?.media || [];

  const isLoading =
    trending.isLoading || seasonal.isLoading || upcoming.isLoading || smart.isLoading;

  return (
    <div className="flex-1 overflow-y-auto p-6">
      {isLoading && !trendingItems.length ? (
        <div className="flex items-center justify-center h-32">
          <div className="animate-spin h-6 w-6 border-2 border-[var(--accent)] border-t-transparent rounded-full" />
        </div>
      ) : (
        <>
          <MediaGrid items={trendingItems.slice(0, 12)} title="Trending Now" />
          <MediaGrid items={smartItems} title="Recommended For You" />
          <MediaGrid items={seasonalItems.slice(0, 12)} title="Current Season" />
          <MediaGrid items={upcomingItems.slice(0, 6)} title="Upcoming" />
        </>
      )}
    </div>
  );
}
