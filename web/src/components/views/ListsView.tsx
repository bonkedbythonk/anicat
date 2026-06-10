import { useQuery } from "@tanstack/react-query";
import { getUserLists } from "@/lib/api";
import { useAppStore } from "@/stores/app";

export function ListsView() {
  const openDetail = useAppStore((s) => s.openDetail);

  const { data, isLoading } = useQuery({
    queryKey: ["lists", "all"],
    queryFn: () => getUserLists(),
    staleTime: 120_000,
  });

  const lists = data?.MediaListCollection?.lists || [];

  return (
    <div className="flex-1 overflow-y-auto p-6">
      <h1 className="text-2xl font-bold text-[var(--text-primary)] mb-6">Lists</h1>
      {isLoading ? (
        <div className="flex justify-center py-12">
          <div className="animate-spin h-6 w-6 border-2 border-[var(--accent)] border-t-transparent rounded-full" />
        </div>
      ) : lists.length === 0 ? (
        <p className="text-[var(--text-secondary)]">No lists found.</p>
      ) : (
        lists.map((list) => (
          <section key={list.name} className="mb-6">
            <h2 className="text-lg font-semibold text-[var(--text-primary)] mb-3">
              {list.status || list.name}
            </h2>
            <div className="grid grid-cols-2 sm:grid-cols-3 md:grid-cols-4 lg:grid-cols-5 gap-3">
              {list.entries.map((entry) => (
                <button
                  key={entry.media.id}
                  onClick={() => openDetail(entry.media)}
                  className="aspect-[2/3] rounded-lg overflow-hidden bg-[var(--bg-tertiary)] hover:ring-2 hover:ring-[var(--accent)] transition-all"
                >
                  {entry.media.coverImage?.large && (
                    <img
                      src={entry.media.coverImage.large}
                      alt={entry.media.title.romaji || ""}
                      className="w-full h-full object-cover"
                      loading="lazy"
                    />
                  )}
                </button>
              ))}
            </div>
          </section>
        ))
      )}
    </div>
  );
}
