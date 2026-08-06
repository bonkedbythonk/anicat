import { proxyImage } from "@/lib/proxy";
import type { MediaItem } from "@/lib/types";

interface UpNextCardProps {
  item: MediaItem;
  onSelect: (item: MediaItem, action?: "play", episode?: string | null) => void;
}

/** The single dominant Up Next card — the Ink & Index replacement for the
 * hero carousel. One resume target, not a billboard: banner art with the
 * title over its bottom edge, then a solid card body with the mono
 * EP-count line, a progress tick, and one Resume button. Carousels
 * recreate the indecision the front page exists to kill. */
export function UpNextCard({ item, onSelect }: UpNextCardProps) {
  const title = item.title?.english || item.title?.romaji || "Unknown";
  const art = item.banner_image || item.cover_image?.large || item.cover_image?.medium;
  const progress = item.user_status?.progress || 0;
  const total = item.episodes || item.chapters || 0;
  const nextEp = progress + 1;
  const pct = total > 0 ? Math.min(100, (progress / total) * 100) : 0;
  const isManga = item.type === "MANGA";

  return (
    <div className="overflow-hidden rounded-lg border border-border">
      <button onClick={() => onSelect(item)} className="relative block h-[190px] w-full text-left">
        <img src={proxyImage(art)} alt="" className="absolute inset-0 h-full w-full object-cover" />
        <div className="absolute inset-0 bg-gradient-to-t from-black/85 via-black/20 to-transparent" />
        <h2 className="absolute bottom-2.5 left-3.5 right-3.5 line-clamp-2 text-[20px] font-bold leading-tight text-white">
          {title}
        </h2>
      </button>
      <div className="flex items-center gap-3.5 bg-surface px-3.5 py-3">
        <div className="min-w-0 flex-1">
          <div className="flex gap-3.5 font-mono text-[10px] uppercase tracking-[0.08em] text-muted-foreground tabular-nums">
            <span>{isManga ? "CH" : "EP"} {nextEp}{total > 0 ? ` / ${total}` : ""}</span>
            {progress > 0 && <span>{progress} watched</span>}
          </div>
          {total > 0 && (
            <div className="mt-2 h-[2px] rounded-[1px] bg-foreground/10">
              <div className="h-full rounded-[1px] bg-accent" style={{ width: `${pct}%` }} />
            </div>
          )}
        </div>
        <button
          onClick={() => onSelect(item, "play", String(nextEp))}
          className="shrink-0 rounded-sm bg-accent px-5 py-3 text-[12.5px] font-semibold text-background active:scale-[0.97] transition-transform"
        >
          {isManga ? "Read" : progress > 0 ? "Resume" : "Play"}
        </button>
      </div>
    </div>
  );
}
