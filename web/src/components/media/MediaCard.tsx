
import { useCallback, useRef, memo, useState } from "react";
import { Play, BookOpen, Star } from "lucide-react";
import { useQueryClient } from "@tanstack/react-query";
import { type MediaItem, mediaApi } from "@/lib/api";
import { useFocusable } from "@/focus";
import { useAppStore, useSettingsStore } from "@/stores/app";

interface MediaCardProps {
  item: MediaItem;
  onSelect?: (item: MediaItem, action?: "play", episode?: string | null) => void;
}

const MediaCard = memo(function MediaCard({ item, onSelect }: MediaCardProps) {
  const queryClient = useQueryClient();
  const { ref, tabIndex } = useFocusable<HTMLButtonElement>();

  // Smart pre-fetch: when user hovers or focuses for 300ms+, pre-load the detail
  const prefetchTimerRef = useRef<ReturnType<typeof setTimeout> | null>(null);

  const handlePrefetchStart = useCallback(() => {
    // Low Data Mode: while the mpv window is open, hover prefetches compete
    // with the running stream — skip them; details load on actual open.
    if (useSettingsStore.getState().dataSaver && useAppStore.getState().playerActive) return;
    prefetchTimerRef.current = setTimeout(() => {
      // Prefetch only the AniList detail — it's a single cached GraphQL call
      // and makes opening the card feel instant. Do NOT prefetch episodes
      // here: that spins up the Python scraper and hits the streaming
      // provider for every card the user hovers, which wastes the provider's
      // (and AniList's) rate budget on titles that are never opened. Episodes
      // resolve when the detail page actually mounts.
      queryClient.prefetchQuery({
        queryKey: ["media-detail", item.id],
        queryFn: () => mediaApi.getDetails(item.id),
      });
    }, 300);
  }, [item.id, queryClient]);

  const handlePrefetchEnd = useCallback(() => {
    if (prefetchTimerRef.current) {
      clearTimeout(prefetchTimerRef.current);
      prefetchTimerRef.current = null;
    }
  }, []);

  const title = item.title.english || item.title.romaji || "Media";
  const isManga = item.type === 'MANGA';
  const entry = item.user_status || item.media_list_entry || item.mediaListEntry;
  const progress = entry?.progress || 0;
  const rawStatus = entry?.status;
  const status = rawStatus?.toLowerCase();
  const totalCount = item.episodes || item.chapters || 0;
  const nextEp = item.next_airing?.episode;

  let currentReleased = 0;
  if (nextEp) {
    currentReleased = nextEp - 1;
  } else if (totalCount > 0) {
    currentReleased = totalCount;
  }

  const isFinished = item.status === 'FINISHED' || (item.end_date && new Date(item.end_date + "T00:00:00Z") < new Date());

  const hasNewEpisodes =
    (status === 'watching' || status === 'current') &&
    item.status === 'RELEASING' &&
    !isFinished &&
    progress < currentReleased &&
    (totalCount === 0 || progress < totalCount);

  const [imageLoaded, setImageLoaded] = useState(false);

  return (
    <button
      ref={ref}
      tabIndex={tabIndex}
      onClick={() => onSelect?.(item)}
      onMouseEnter={handlePrefetchStart}
      onMouseLeave={handlePrefetchEnd}
      onFocus={handlePrefetchStart}
      onBlur={handlePrefetchEnd}
      aria-label={title}
      className="group cursor-pointer flex flex-col space-y-2.5 w-full text-left relative"
    >
      <div className={`relative aspect-[2/3] w-full overflow-hidden rounded-md bg-surface border border-border card-glow ${tabIndex === 0 ? "focus-active" : ""}`}>
        <img
          src={item.cover_image?.large || item.cover_image?.medium}
          alt={title}
          loading="lazy"
          decoding="async"
          onLoad={() => setImageLoaded(true)}
          className={`absolute inset-0 w-full h-full object-cover transition-all duration-300 group-hover:scale-[1.03] ${
            imageLoaded ? "opacity-100" : "opacity-0"
          }`}
        />

        {/* Play overlay — visual affordance only; the card opens detail on activation */}
        <div className="absolute inset-0 bg-black/50 opacity-0 group-hover:opacity-100 group-focus-visible:opacity-100 transition-opacity duration-[400ms] flex items-center justify-center z-10" aria-hidden="true">
          <span className="glass-button p-3.5 rounded-full">
            {isManga ? (
              <BookOpen size={20} />
            ) : (
              <Play size={20} fill="currentColor" />
            )}
          </span>
        </div>

        {/* Progress tick — thin bar over a dark scrim, the skin's poster language */}
        {entry && totalCount > 0 && (
          <div className="poster-tick z-10">
            <i style={{ width: `${(progress / totalCount) * 100}%` }} />
          </div>
        )}
      </div>

      {/* Card info — one quiet metadata line instead of badge chips; the
          art carries the card, richer metadata lives on the detail page. */}
      <div className="space-y-1 px-0.5">
        <h3 className="text-sm font-semibold text-white leading-tight line-clamp-2">
          {title}
        </h3>
        <p className="meta-mono flex items-center gap-1.5 text-gray-500">
          {item.average_score ? (
            <span className="inline-flex items-center gap-0.5">
              <Star size={9} fill="currentColor" className="text-gray-500" />
              {item.average_score}%
            </span>
          ) : null}
          {entry && (
            <span className={hasNewEpisodes ? "text-accent font-semibold" : ""}>
              {hasNewEpisodes ? `Ep ${progress + 1} out` : `${progress}/${totalCount || "?"}`}
            </span>
          )}
          {!entry && item.playlist_reason && <span className="truncate">{item.playlist_reason}</span>}
        </p>
      </div>
    </button>
  );
});
export { MediaCard };
