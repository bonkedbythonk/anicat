import type { MediaItem } from "@/lib/types";

interface EpisodeListProps {
  mediaId: number;
  media?: MediaItem;
}

export function EpisodeList({ mediaId }: EpisodeListProps) {
  return (
    <div className="space-y-2">
      <p className="text-sm text-[var(--text-muted)]">
        Episodes will be loaded from the provider.
      </p>
    </div>
  );
}
