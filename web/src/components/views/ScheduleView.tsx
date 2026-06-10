import { useQuery } from "@tanstack/react-query";
import { getSeasonal } from "@/lib/api";
import { useAppStore } from "@/stores/app";

function timeUntil(seconds: number): string {
  const days = Math.floor(seconds / 86400);
  const hours = Math.floor((seconds % 86400) / 3600);
  if (days > 0) return `${days}d ${hours}h`;
  return `${hours}h ${Math.floor((seconds % 3600) / 60)}m`;
}

export function ScheduleView() {
  const openDetail = useAppStore((s) => s.openDetail);

  const { data, isLoading } = useQuery({
    queryKey: ["schedule"],
    queryFn: () => getSeasonal(),
    staleTime: 300_000,
  });

  const items = data?.Page?.media || [];

  return (
    <div className="flex-1 overflow-y-auto p-6">
      <h1 className="text-2xl font-bold text-[var(--text-primary)] mb-6">Schedule</h1>
      {isLoading ? (
        <div className="flex justify-center py-12">
          <div className="animate-spin h-6 w-6 border-2 border-[var(--accent)] border-t-transparent rounded-full" />
        </div>
      ) : items.length === 0 ? (
        <p className="text-[var(--text-secondary)]">No airing schedule available.</p>
      ) : (
        <div className="grid grid-cols-2 sm:grid-cols-3 md:grid-cols-4 lg:grid-cols-5 gap-3">
          {items.map((item) => (
            <button
              key={item.id}
              onClick={() => openDetail(item)}
              className="group relative aspect-[2/3] rounded-lg overflow-hidden bg-[var(--bg-tertiary)] hover:ring-2 hover:ring-[var(--accent)] transition-all"
            >
              {item.coverImage?.large && (
                <img
                  src={item.coverImage.large}
                  alt={item.title.romaji || ""}
                  className="w-full h-full object-cover"
                  loading="lazy"
                />
              )}
              {item.nextAiringEpisode && (
                <div className="absolute top-2 right-2 bg-[var(--accent)] text-white text-[10px] font-bold px-2 py-0.5 rounded-full">
                  EP {item.nextAiringEpisode.episode}
                </div>
              )}
              <div className="absolute bottom-0 inset-x-0 bg-gradient-to-t from-black/80 to-transparent p-2">
                <p className="text-white text-xs font-medium line-clamp-1">
                  {item.title.romaji || item.title.english}
                </p>
                {item.nextAiringEpisode && (
                  <p className="text-[var(--accent)] text-[10px] mt-0.5">
                    {timeUntil(item.nextAiringEpisode.timeUntilAiring)}
                  </p>
                )}
              </div>
            </button>
          ))}
        </div>
      )}
    </div>
  );
}
