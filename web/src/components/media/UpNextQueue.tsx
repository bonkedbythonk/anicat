import { useMemo } from "react";
import type { MediaItem } from "@/lib/api";
import { parseAiringTime } from "@/lib/date";

interface UpNextQueueProps {
  items: MediaItem[];
  newEpisodeIds: Set<number>;
  lastWatched: Record<string, string>;
  onSelect: (item: MediaItem, action?: "play", episode?: string | null) => void;
  /** "EP" for anime, "CH" for manga. */
  unit?: "EP" | "CH";
}

function relativeDay(iso: string | undefined): string | null {
  if (!iso) return null;
  const then = new Date(iso).getTime();
  if (!then) return null;
  const diff = Date.now() - then;
  const hours = Math.floor(diff / 3_600_000);
  if (hours < 1) return "just now";
  if (hours < 24) return `${hours}h ago`;
  const days = Math.floor(hours / 24);
  if (days === 1) return "yesterday";
  if (days < 7) return `${days}d ago`;
  const weeks = Math.floor(days / 7);
  return `${weeks}w ago`;
}

/** The front page: a dense resume queue. First row is the primary target
 * (solid Resume button); everything below is one click away. Poster art
 * carries the color; all metadata is mono. */
export function UpNextQueue({ items, newEpisodeIds, lastWatched, onSelect, unit = "EP" }: UpNextQueueProps) {
  if (!items.length) return null;

  return (
    <div className="rounded-lg border border-border overflow-hidden">
      {items.map((item, i) => {
        const name = item.title.english || item.title.romaji || "Media";
        const art = item.banner_image || item.cover_image?.large || item.cover_image?.medium;
        const progress = item.user_status?.progress || item.media_list_entry?.progress || 0;
        const total = (unit === "CH" ? item.chapters : item.episodes) || 0;
        const isRepeating =
          (item.user_status?.status || item.media_list_entry?.status || "").toUpperCase() === "REPEATING";
        // A rewatch whose progress still sits at the old total restarts at EP 1.
        const restarting = isRepeating && total > 0 && progress >= total;
        const nextEp = restarting ? 1 : progress + 1;
        const pct = restarting ? 0 : total > 0 ? Math.min(100, (progress / total) * 100) : 0;
        const hasNew = newEpisodeIds.has(item.id);
        const watched = relativeDay(lastWatched[item.id] || lastWatched[String(item.id)] || undefined);
        const first = i === 0;

        return (
          <div
            key={item.id}
            className={`flex items-center gap-4 px-4 py-3 cursor-pointer border-b border-border last:border-b-0 ${
              first ? "bg-surface" : "hover:bg-surface/60"
            }`}
            onClick={() => onSelect(item)}
          >
            <div className="relative w-[104px] h-[60px] shrink-0 rounded overflow-hidden bg-surface">
              {art && (
                <img src={art} alt="" loading="lazy" decoding="async" className="absolute inset-0 h-full w-full object-cover" />
              )}
            </div>
            <div className="flex-1 min-w-0">
              <p className={`truncate leading-tight text-foreground ${first ? "text-[15px] font-semibold" : "text-[13.5px] font-medium"}`}>
                {name}
              </p>
              <p className="meta-mono mt-1.5 text-muted-foreground flex items-center gap-4">
                <span>
                  {unit} {nextEp}{total > 0 ? ` / ${total}` : ""}
                </span>
                {isRepeating && <span>{unit === "CH" ? "Reread" : "Rewatch"}</span>}
                {hasNew ? (
                  <span className="text-accent">{unit === "CH" ? "New chapter out" : "New episode out"}</span>
                ) : watched ? (
                  <span>Watched {watched}</span>
                ) : null}
              </p>
              {total > 0 && (
                <div className="mt-2 h-[2px] max-w-[420px] rounded-full bg-foreground/10">
                  <div className="h-full rounded-full bg-accent" style={{ width: `${pct}%` }} />
                </div>
              )}
            </div>
            <button
              onClick={(e) => {
                e.stopPropagation();
                onSelect(item, "play");
              }}
              className={`shrink-0 rounded-md px-4 py-2 text-[12.5px] font-semibold cursor-pointer ${
                first
                  ? "bg-accent text-black hover:bg-accent-light"
                  : "border border-border text-foreground/70 hover:text-foreground hover:border-foreground/25"
              }`}
            >
              {first ? (unit === "CH" ? "Continue" : "Resume") : (unit === "CH" ? "Read" : "Play")}
            </button>
          </div>
        );
      })}
    </div>
  );
}

interface WeekStripProps {
  watching: MediaItem[];
  onSelect: (item: MediaItem) => void;
}



/** Seven-day strip built from the watching list's next_airing timestamps —
 * no extra query, answers "what airs this week" at a glance. */
export function WeekStrip({ watching, onSelect }: WeekStripProps) {
  const days = useMemo(() => {
    const out: { label: string; isToday: boolean; shows: { item: MediaItem; episode: number }[] }[] = [];
    const now = new Date();
    for (let d = 0; d < 7; d++) {
      const day = new Date(now.getFullYear(), now.getMonth(), now.getDate() + d);
      const dayEnd = new Date(day.getTime() + 86_400_000);
      const shows = watching
        .filter((m) => {
          const t = parseAiringTime(m.next_airing?.airing_at);
          return t >= day.getTime() && t < dayEnd.getTime();
        })
        .map((m) => ({ item: m, episode: m.next_airing?.episode ?? 0 }));
      out.push({
        label: day.toLocaleDateString(undefined, { weekday: "short" }),
        isToday: d === 0,
        shows,
      });
    }
    return out;
  }, [watching]);

  if (!watching.some((m) => m.next_airing?.airing_at)) return null;

  return (
    <div>
      <div className="flex items-baseline justify-between mb-3 px-1">
        <h2 className="text-[15px] font-semibold text-foreground tracking-tight">This week</h2>
      </div>
      <div className="flex gap-2">
        {days.map((day) => (
          <div
            key={day.label}
            className={`flex-1 min-w-0 rounded-md border px-2.5 py-2 ${
              day.isToday ? "border-accent" : "border-border"
            }`}
          >
            <div className={`meta-mono text-[9px] ${day.isToday ? "text-accent" : "text-muted-foreground"}`}>
              {day.label}
            </div>
            <div className="mt-1.5 space-y-1">
              {day.shows.length === 0 ? (
                <span className="text-[11px] text-muted-foreground/60 select-none">&mdash;</span>
              ) : (
                day.shows.slice(0, 3).map(({ item, episode }) => (
                  <button
                    key={item.id}
                    onClick={() => onSelect(item)}
                    className="block w-full truncate text-left text-[11.5px] leading-snug text-foreground/70 hover:text-foreground cursor-pointer"
                    title={item.title.english || item.title.romaji}
                  >
                    {(item.title.english || item.title.romaji || "").split(":")[0]}{" "}
                    <span className="meta-mono text-[8.5px] text-muted-foreground">EP {episode}</span>
                  </button>
                ))
              )}
            </div>
          </div>
        ))}
      </div>
    </div>
  );
}
