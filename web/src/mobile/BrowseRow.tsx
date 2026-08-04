import { proxyImage } from "@/lib/proxy";
import type { MediaItem } from "@/lib/types";

interface BrowseRowProps {
  title: string;
  items: MediaItem[];
  onSelect: (item: MediaItem) => void;
}

/** The "browsing" shelf, as opposed to `PosterRow`'s "your list" shelf.
 * Discovery rows (Trending, This season) get bigger art, a scrim and the
 * title set over the poster; rows that are already yours (Planning, the
 * Watching grid) keep the small quiet card with the caption underneath.
 * The split is the point — two shelves that look alike read as one
 * undifferentiated wall of posters. No mono count chip here either: these
 * are section titles, not a data table. */
export function BrowseRow({ title, items, onSelect }: BrowseRowProps) {
  if (items.length === 0) return null;
  return (
    <div className="space-y-2.5">
      <h2 className="text-[16px] font-bold tracking-tight text-foreground">{title}</h2>
      <div className="-mx-6 flex gap-3 overflow-x-auto px-6 pb-1 scrollbar-hide">
        {items.map((item) => {
          const label = item.title?.english || item.title?.romaji || "Unknown";
          const cover =
            item.cover_image?.large || item.cover_image?.medium || item.coverImage?.large || item.coverImage?.medium;
          return (
            <button key={item.id} onClick={() => onSelect(item)} className="w-[150px] shrink-0 text-left">
              <div className="relative aspect-[3/4] w-full overflow-hidden rounded-lg bg-surface">
                <img src={proxyImage(cover)} alt={label} className="h-full w-full object-cover" loading="lazy" />
                <div
                  className="absolute inset-0"
                  style={{ background: "linear-gradient(to top, rgba(0,0,0,0.8), transparent 55%)" }}
                />
                <p className="absolute bottom-2.5 left-2.5 right-2.5 line-clamp-2 text-[14px] font-semibold leading-[1.25] text-white">
                  {label}
                </p>
              </div>
            </button>
          );
        })}
      </div>
    </div>
  );
}
