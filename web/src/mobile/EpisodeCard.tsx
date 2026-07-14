import { Play } from "lucide-react";
import { proxyImage } from "@/lib/proxy";
import type { MediaItem } from "@/lib/types";

interface EpisodeCardProps {
  item: MediaItem;
  onSelect: (item: MediaItem, action?: "play") => void;
}

/** Continue-Watching card in the Crunchyroll idiom: 16:9 landscape art,
 * next-episode context, a progress bar, and a one-tap play affordance —
 * resuming is the whole point of this shelf, so the card leads with "what
 * happens when I tap" rather than cover art. */
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
        onClick={() => onSelect(item, "play")}
        className="relative block aspect-video w-full overflow-hidden rounded-xl bg-surface shadow-lg shadow-black/40 active:scale-[0.98] transition-transform"
        aria-label={`Play ${title} episode ${nextEp}`}
      >
        <img src={proxyImage(art)} alt="" className="h-full w-full object-cover" loading="lazy" />
        <div className="absolute inset-0 bg-gradient-to-t from-black/55 via-transparent to-transparent" />
        <div className="absolute bottom-2 left-2 flex h-7 w-7 items-center justify-center rounded-full bg-black/60 text-white backdrop-blur">
          <Play size={12} fill="currentColor" className="ml-0.5" />
        </div>
        {total > 0 && (
          <div className="absolute inset-x-0 bottom-0 h-[3px] bg-black/50">
            <div className="h-full bg-accent" style={{ width: `${pct}%` }} />
          </div>
        )}
      </button>
      <button onClick={() => onSelect(item)} className="mt-1.5 block w-full text-left">
        <p className="line-clamp-1 text-[12.5px] font-semibold leading-tight text-foreground">{title}</p>
        <p className="text-[11px] tabular-nums text-muted-foreground">
          Episode {nextEp}
          {total > 0 ? ` of ${total}` : ""}
        </p>
      </button>
    </div>
  );
}
