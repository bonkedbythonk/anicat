import { proxyImage } from "@/lib/proxy";
import type { MediaItem } from "@/lib/types";

interface PosterCardProps {
  item: MediaItem;
  onSelect: (item: MediaItem) => void;
  width?: number | string;
}

/** A Crunchyroll/Netflix-style poster card — image-forward, minimal text,
 * no inline genre/score clutter. Distinct from the shared desktop
 * `MediaCard` (which is a wider landscape-ish card with more metadata baked
 * in) — this is purpose-built for a phone-width horizontal shelf. */
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
      <div className="relative aspect-[2/3] w-full overflow-hidden rounded-xl bg-surface shadow-lg shadow-black/40">
        <img src={proxyImage(cover)} alt={title} className="h-full w-full object-cover" loading="lazy" />
        {progressPct > 0 && (
          <div className="absolute bottom-0 left-0 right-0 h-1 bg-black/50">
            <div className="h-full bg-accent" style={{ width: `${progressPct}%` }} />
          </div>
        )}
      </div>
      <p className="mt-1.5 line-clamp-2 text-[12.5px] font-semibold leading-tight text-foreground">{title}</p>
    </button>
  );
}
