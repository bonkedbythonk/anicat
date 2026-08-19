import { Play } from "lucide-react";
import { proxyImage } from "@/lib/proxy";
import type { MediaItem } from "@/lib/types";

interface EpisodeCardProps {
  item: MediaItem;
  onSelect: (item: MediaItem, action?: "play", episode?: string | null) => void;
}

/** Continue-watching card: 16:9 landscape art, next-episode context, a thin
 * progress tick, one-tap play. Ink & Index restyle — no drop shadow, small
 * radius, mono metadata line. */
export function EpisodeCard({ item, onSelect }: EpisodeCardProps) {
  const title = item.title?.english || item.title?.romaji || "Unknown";
  const art =
    item.banner_image ||
    item.cover_image?.large ||
    item.cover_image?.medium ||
    item.coverImage?.large ||
    item.coverImage?.medium;
  const progress = item.user_status?.progress || 0;
  const total = item.episodes || 0;
  const nextEp = progress + 1;
  const pct = total > 0 ? Math.min(100, (progress / total) * 100) : 0;

  return (
    <div className="w-[188px] shrink-0">
      <button
        onClick={() => onSelect(item, "play", String(nextEp))}
        className="relative block aspect-video w-full overflow-hidden rounded-[5px] bg-surface active:scale-[0.98] transition-transform"
        aria-label={`Play ${title} episode ${nextEp}`}
      >
        <img src={proxyImage(art)} alt="" className="h-full w-full object-cover" loading="lazy" />
        <div className="absolute inset-0 bg-gradient-to-t from-black/55 via-transparent to-transparent" />
        <div className="absolute bottom-2 left-2 flex h-7 w-7 items-center justify-center rounded-full bg-black/60 text-white">
          <Play size={12} fill="currentColor" className="ml-0.5" />
        </div>
        {total > 0 && (
          <div className="absolute inset-x-0 bottom-0 h-[3px] bg-black/45">
            <div className="h-full bg-accent" style={{ width: `${pct}%` }} />
          </div>
        )}
      </button>
      {/* min-h keeps the caption a 44px tap target — it was 33px. */}
      <button onClick={() => onSelect(item)} className="mt-1.5 block min-h-11 w-full text-left">
        <p className="line-clamp-1 text-[12px] font-medium leading-[1.3] text-foreground">{title}</p>
        <p className="mt-0.5 font-mono text-[10px] uppercase tracking-[0.07em] text-muted-foreground tabular-nums">
          EP {nextEp}{total > 0 ? ` / ${total}` : ""}
        </p>
      </button>
    </div>
  );
}
