import { useQuery } from "@tanstack/react-query";
import { getSeasonal } from "@/lib/api";
import { useAppStore } from "@/stores/app";

export function ScheduleView() {
  const openDetail = useAppStore((s) => s.openDetail);

  const { data, isLoading } = useQuery({
    queryKey: ["schedule"],
    queryFn: () => getSeasonal(),
    staleTime: 300_000,
  });

  const items = data?.data?.Page?.media || [];

  return (
    <div className="flex-1 overflow-y-auto p-6">
      <h1 className="text-2xl font-bold text-[var(--text-primary)] mb-6">Schedule</h1>
      {isLoading ? (
        <div className="flex justify-center py-12"><div className="animate-spin h-6 w-6 border-2 border-[var(--accent)] border-t-transparent rounded-full" /></div>
      ) : items.length === 0 ? (
        <p className="text-[var(--text-secondary)]">No airing schedule available.</p>
      ) : (
        <div className="grid grid-cols-2 sm:grid-cols-3 md:grid-cols-4 lg:grid-cols-5 gap-3">
          {items.map((item) => (
            <button key={item.id} onClick={() => openDetail(item)} className="aspect-[2/3] rounded-lg overflow-hidden bg-[var(--bg-tertiary)] hover:ring-2 hover:ring-[var(--accent)] transition-all">
              {item.coverImage?.large && <img src={item.coverImage.large} alt={item.title.romaji || ""} className="w-full h-full object-cover" loading="lazy" />}
            </button>
          ))}
        </div>
      )}
    </div>
  );
}
