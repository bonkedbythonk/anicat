import { useQuery } from "@tanstack/react-query";
import { Loader2, Play, BookOpen } from "lucide-react";
import { mediaApi } from "@/lib/api";
import type { MediaItem } from "@/lib/types";
import { proxyImage } from "@/lib/proxy";
import { PosterRow } from "./PosterRow";

interface MobileMangaViewProps {
  onSelect: (item: MediaItem, action?: "play" | null) => void;
}

function titleOf(item: MediaItem): string {
  return item.title?.english || item.title?.romaji || "Unknown";
}

function coverOf(item: MediaItem): string | undefined {
  return item.cover_image?.large || item.cover_image?.medium || item.coverImage?.large || item.coverImage?.medium;
}

/** Purpose-built manga tab, replacing the reused desktop MangaView. No hero
 * banner — Continue Reading leads as list cells with chapter progress and a
 * one-tap resume button (passing initialAction "play", which MobileMediaDetail
 * already turns into "open the reader at the next unread chapter"). */
export function MobileMangaView({ onSelect }: MobileMangaViewProps) {
  const { data, isLoading } = useQuery({
    queryKey: ["mobile-manga"],
    queryFn: async () => {
      const [trending, reading] = await Promise.all([
        mediaApi.getTrending("MANGA"),
        mediaApi.getUserList("reading", "MANGA"),
      ]);
      let planning: { media: MediaItem[] } = { media: [] };
      try {
        planning = await mediaApi.getUserList("planning", "MANGA");
      } catch {
        // Planning list is optional — an empty AniList list can 404.
      }
      return {
        trending: trending.media || [],
        reading: reading.media || [],
        planning: planning.media || [],
      };
    },
  });

  if (isLoading) {
    return (
      <div className="flex items-center justify-center py-32">
        <Loader2 className="animate-spin text-accent" size={36} />
      </div>
    );
  }

  const reading = data?.reading ?? [];
  const planning = data?.planning ?? [];
  const trending = data?.trending ?? [];

  return (
    <div className="animate-fade-in space-y-7 pb-4">
      {reading.length > 0 && (
        <section>
          <h2 className="mb-2.5 text-[17px] font-bold text-foreground">Continue Reading</h2>
          <div className="rounded-xl bg-white/[0.04] border border-white/[0.05] overflow-hidden">
            {reading.map((item, i) => {
              const progress = item.user_status?.progress || 0;
              const total = item.chapters || 0;
              const pct = total > 0 ? Math.min(100, (progress / total) * 100) : 0;
              return (
                <div
                  key={item.id}
                  className={`flex items-center gap-3 px-3 py-2.5 ${i > 0 ? "border-t border-white/[0.05]" : ""}`}
                >
                  <button onClick={() => onSelect(item)} className="flex min-w-0 flex-1 items-center gap-3 text-left">
                    <div className="h-16 w-11 shrink-0 overflow-hidden rounded-md bg-surface">
                      <img src={proxyImage(coverOf(item))} alt="" className="h-full w-full object-cover" loading="lazy" />
                    </div>
                    <div className="min-w-0 flex-1">
                      <p className="line-clamp-2 text-[13.5px] font-semibold leading-snug text-foreground">{titleOf(item)}</p>
                      <p className="mt-0.5 text-[11.5px] tabular-nums text-muted-foreground">
                        Ch {progress}{total > 0 ? ` of ${total}` : ""}
                      </p>
                      {total > 0 && (
                        <div className="mt-1.5 h-[3px] rounded-full bg-white/[0.1]">
                          <div className="h-full rounded-full bg-accent" style={{ width: `${pct}%` }} />
                        </div>
                      )}
                    </div>
                  </button>
                  <button
                    onClick={() => onSelect(item, "play")}
                    aria-label={`Continue reading ${titleOf(item)}`}
                    className="flex h-9 w-9 shrink-0 items-center justify-center rounded-full bg-accent/15 text-accent active:scale-90 transition-transform"
                  >
                    <Play size={15} fill="currentColor" />
                  </button>
                </div>
              );
            })}
          </div>
        </section>
      )}

      {planning.length > 0 && <PosterRow title="Plan to Read" items={planning} onSelect={onSelect} />}

      <PosterRow title="Trending Manga" items={trending} onSelect={onSelect} />

      {reading.length === 0 && planning.length === 0 && trending.length === 0 && (
        <div className="flex flex-col items-center gap-3 py-24 text-muted-foreground">
          <BookOpen size={32} />
          <p className="text-sm font-medium">Nothing here yet — search for a manga to start reading.</p>
        </div>
      )}
    </div>
  );
}
