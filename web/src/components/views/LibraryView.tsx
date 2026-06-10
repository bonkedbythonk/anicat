import { useQuery, useMutation, useQueryClient } from "@tanstack/react-query";
import { getUserLists, updateProgress, removeMediaEntry } from "@/lib/api";
import { useAppStore } from "@/stores/app";
import type { MediaItem } from "@/lib/types";

export function LibraryView() {
  const queryClient = useQueryClient();
  const openDetail = useAppStore((s) => s.openDetail);

  const watching = useQuery({
    queryKey: ["library", "watching"],
    queryFn: () => getUserLists(undefined, "CURRENT"),
    staleTime: 60_000,
  });

  const planning = useQuery({
    queryKey: ["library", "planning"],
    queryFn: () => getUserLists(undefined, "PLANNING"),
    staleTime: 60_000,
  });

  const completed = useQuery({
    queryKey: ["library", "completed"],
    queryFn: () => getUserLists(undefined, "COMPLETED"),
    staleTime: 60_000,
  });

  const removeMutation = useMutation({
    mutationFn: (entryId: number) => removeMediaEntry(entryId),
    onSuccess: () => {
      queryClient.invalidateQueries({ queryKey: ["library"] });
    },
  });

  const watchingEntries =
    watching.data?.data?.MediaListCollection?.lists?.[0]?.entries || [];

  if (watching.isLoading) {
    return (
      <div className="flex-1 overflow-y-auto p-6 flex items-center justify-center">
        <div className="animate-spin h-6 w-6 border-2 border-[var(--accent)] border-t-transparent rounded-full" />
      </div>
    );
  }

  return (
    <div className="flex-1 overflow-y-auto p-6">
      <h1 className="text-2xl font-bold text-[var(--text-primary)] mb-6">Library</h1>

      {watchingEntries.length === 0 ? (
        <p className="text-[var(--text-secondary)]">
          No entries in your library. Search for anime to add to your list.
        </p>
      ) : (
        <div className="grid grid-cols-2 sm:grid-cols-3 md:grid-cols-4 lg:grid-cols-5 gap-3">
          {watchingEntries.map((entry) => (
            <LibraryCard
              key={entry.media.id}
              entry={entry}
              onOpen={() => openDetail(entry.media)}
              onRemove={() => removeMutation.mutate(entry.id)}
            />
          ))}
        </div>
      )}
    </div>
  );
}

function LibraryCard({
  entry,
  onOpen,
  onRemove,
}: {
  entry: { media: MediaItem; progress: number; status: string; id: number; score: number };
  onOpen: () => void;
  onRemove: () => void;
}) {
  const title = entry.media.title.romaji || entry.media.title.english || "Unknown";
  const progress = entry.progress || 0;
  const total = entry.media.episodes || 1;
  const pct = Math.min(100, Math.round((progress / total) * 100));

  return (
    <div className="group relative rounded-lg overflow-hidden bg-[var(--bg-tertiary)]">
      <button onClick={onOpen} className="w-full aspect-[2/3]">
        {entry.media.coverImage?.large && (
          <img
            src={entry.media.coverImage.large}
            alt={title}
            className="w-full h-full object-cover"
            loading="lazy"
          />
        )}
      </button>
      <div className="p-2">
        <p className="text-xs text-[var(--text-primary)] truncate font-medium">{title}</p>
        <div className="flex items-center justify-between mt-1">
          <div className="flex-1 h-1 bg-[var(--border)] rounded-full overflow-hidden mr-2">
            <div
              className="h-full bg-[var(--accent)] rounded-full transition-all"
              style={{ width: `${pct}%` }}
            />
          </div>
          <span className="text-[10px] text-[var(--text-muted)]">
            {progress}/{total}
          </span>
        </div>
        {entry.score > 0 && (
          <p className="text-[10px] text-[var(--text-muted)] mt-0.5">
            Score: {entry.score}
          </p>
        )}
      </div>
    </div>
  );
}
