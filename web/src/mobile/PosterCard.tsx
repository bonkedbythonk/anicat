import { proxyImage } from "@/lib/proxy";
import type { MediaItem } from "@/lib/types";

interface PosterCardProps {
  item: MediaItem;
  onSelect: (item: MediaItem) => void;
  width?: number | string;
}

/** Ink & Index poster card — art carries the color, chrome stays quiet: no
 * drop shadow, small radius, progress as a thin bottom tick, and the count
 * as a mono line under the name (the card-catalog signature). Distinct from
 * the shared desktop `MediaCard`; purpose-built for phone grids/shelves. */
export function PosterCard({ item, onSelect, width = 112 }: PosterCardProps) {
  const title = item.title?.english || item.title?.romaji || "Unknown";
  // snakify() (lib/api.ts) only adds the cover_image alias on the top-level
  // media object it's called on — nested items inside `recommendations` /
  // `relations` are never touched, so they only ever have AniList's raw
  // camelCase `coverImage`. Desktop's inline JSX already falls back to it;
  // this needs the same fallback or those grids render blank poster boxes.
  const cover = item.cover_image?.large || item.cover_image?.medium || item.coverImage?.large || item.coverImage?.medium;
  const progress = item.user_status?.progress || 0;
  const total = item.episodes || item.chapters || 0;
  const progressPct = total > 0 ? Math.min(100, (progress / total) * 100) : 0;

  return (
    <button onClick={() => onSelect(item)} className="shrink-0 text-left" style={{ width }}>
      <div className="relative aspect-[2/3] w-full overflow-hidden rounded-[5px] bg-surface">
        <img src={proxyImage(cover)} alt={title} className="h-full w-full object-cover" loading="lazy" />
        {progressPct > 0 && (
          <div className="absolute bottom-0 left-0 right-0 h-[3px] bg-black/45">
            <div className="h-full bg-accent" style={{ width: `${progressPct}%` }} />
          </div>
        )}
      </div>
      <p className="mt-1.5 line-clamp-2 text-[12px] font-medium leading-[1.3] text-foreground">{title}</p>
      {progress > 0 && (
        <p className="mt-0.5 font-mono text-[10px] tracking-[0.07em] text-muted-foreground tabular-nums">
          {progress}/{total || "?"}
        </p>
      )}
    </button>
  );
}
