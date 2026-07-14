import { Play } from "lucide-react";
import type { MediaItem } from "@/lib/api";

interface EpisodeRowProps {
  title: string;
  items: MediaItem[];
  onSelect?: (item: MediaItem, action?: "play", episode?: string | null) => void;
}

/** Continue-Watching shelf in the Crunchyroll/Apple TV idiom: 16:9 landscape
 * art with next-episode context and a progress bar, because this shelf's job
 * is resuming, not browsing — the poster-grid MediaRow stays for every other
 * shelf. Clicking the art plays the next episode directly; the title text
 * opens the detail page. */
export function EpisodeRow({ title, items, onSelect }: EpisodeRowProps) {
  if (!items.length) return null;

  return (
    <div className="space-y-4">
      <h2 className="text-lg font-bold text-white tracking-tight px-1">{title}</h2>
      <div className="flex space-x-4 overflow-x-auto scrollbar-hide scroll-smooth pb-2 snap-x snap-proximity">
        {items.map((item) => {
          const name = item.title.english || item.title.romaji || "Media";
          const art =
            item.banner_image || item.cover_image?.large || item.cover_image?.medium;
          const progress = item.user_status?.progress || item.media_list_entry?.progress || 0;
          const total = item.episodes || 0;
          const nextEp = progress + 1;
          const pct = total > 0 ? Math.min(100, (progress / total) * 100) : 0;
          return (
            <div key={item.id} className="group w-[240px] flex-none snap-start">
              <button
                onClick={() => onSelect?.(item, "play")}
                className="relative block aspect-video w-full overflow-hidden rounded-lg bg-surface border border-white/[0.06] card-glow cursor-pointer"
                aria-label={`Play ${name} episode ${nextEp}`}
              >
                <img
                  src={art}
                  alt=""
                  loading="lazy"
                  decoding="async"
                  className="absolute inset-0 h-full w-full object-cover transition-transform duration-300 group-hover:scale-[1.03]"
                />
                <div className="absolute inset-0 flex items-center justify-center bg-black/45 opacity-0 transition-opacity duration-200 group-hover:opacity-100">
                  <span className="glass-button flex h-11 w-11 items-center justify-center rounded-full">
                    <Play size={18} fill="currentColor" />
                  </span>
                </div>
                {total > 0 && (
                  <div className="absolute inset-x-0 bottom-0 h-[3px] bg-white/15">
                    <div className="h-full bg-accent" style={{ width: `${pct}%` }} />
                  </div>
                )}
              </button>
              <button onClick={() => onSelect?.(item)} className="mt-2 block w-full cursor-pointer text-left">
                <p className="line-clamp-1 text-sm font-semibold leading-tight text-white">{name}</p>
                <p className="text-[11px] tabular-nums text-gray-500">
                  Episode {nextEp}
                  {total > 0 ? ` of ${total}` : ""}
                </p>
              </button>
            </div>
          );
        })}
      </div>
    </div>
  );
}
