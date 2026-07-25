
import { useMemo } from "react";
import { useQuery, useQueries } from "@tanstack/react-query";
import { Loader2, User } from "lucide-react";
import { mediaApi, type UserProfile, type MediaItem, type WatchActivityEntry } from "@/lib/api";
import { proxyImage } from "@/lib/proxy";
import { useAppStore } from "@/stores/app";
import { LazyCard } from "@/components/media/LazyCard";
import { parseWatchedAt } from "@/lib/date";

interface ProfileViewProps {
  onSelect?: (item: MediaItem) => void;
}

function dayKey(d: Date): string {
  return `${d.getFullYear()}-${String(d.getMonth() + 1).padStart(2, "0")}-${String(d.getDate()).padStart(2, "0")}`;
}

/** History: what the registry has been quietly recording all along —
 * per-day activity heatmap, a plain log, and the AniList lifetime stats. */
export function ProfileView({ onSelect }: ProfileViewProps) {
  const favType = useAppStore((s) => s.profileFavType);
  const setFavType = useAppStore((s) => s.setProfileFavType);
  const isAuthenticated = useAppStore((s) => s.apiAuthenticated);

  const { data: profile, isLoading: loading } = useQuery<UserProfile | null>({
    queryKey: ["profile"],
    queryFn: () => mediaApi.getProfile(),
    enabled: isAuthenticated,
  });

  // Tolerant of older backends (headless Pi before redeploy): no history
  // endpoint just means an empty heatmap, never a broken page.
  const { data: activity = [] } = useQuery<WatchActivityEntry[]>({
    queryKey: ["watch-activity"],
    queryFn: () => mediaApi.getWatchActivity().catch(() => []),
  });

  // Last 30 days as labeled bars — legible at a glance, no decoding needed.
  const { bars, thisWeek, thisMonth, maxCount } = useMemo(() => {
    const counts = new Map<string, number>();
    for (const e of activity) {
      const d = parseWatchedAt(e.watched_at);
      if (Number.isNaN(d.getTime())) continue;
      counts.set(dayKey(d), (counts.get(dayKey(d)) || 0) + 1);
    }
    const today = new Date();
    const bars: { key: string; label: string; weekday: string; count: number; isToday: boolean }[] = [];
    let thisWeek = 0;
    let thisMonth = 0;
    let maxCount = 0;
    for (let i = 29; i >= 0; i--) {
      const d = new Date(today.getFullYear(), today.getMonth(), today.getDate() - i);
      const count = counts.get(dayKey(d)) || 0;
      if (i < 7) thisWeek += count;
      thisMonth += count;
      maxCount = Math.max(maxCount, count);
      bars.push({
        key: dayKey(d),
        label: String(d.getDate()),
        weekday: d.toLocaleDateString(undefined, { weekday: "narrow" }),
        count,
        isToday: i === 0,
      });
    }
    return { bars, thisWeek, thisMonth, maxCount };
  }, [activity]);

  const logEntries = activity.slice(0, 14);

  // Resolve titles for the log. Most ids are already cached from list
  // queries; the rest are one cached GraphQL detail call each.
  const uniqueLogIds = useMemo(
    () => Array.from(new Set(logEntries.map((e) => e.media_id))),
    [logEntries]
  );
  const detailQueries = useQueries({
    queries: uniqueLogIds.map((id) => ({
      queryKey: ["media-detail", id],
      queryFn: () => mediaApi.getDetails(id),
      staleTime: 24 * 60 * 60 * 1000,
    })),
  });
  const titleById = useMemo(() => {
    const map = new Map<number, MediaItem>();
    detailQueries.forEach((q, i) => {
      if (q.data) map.set(uniqueLogIds[i], q.data as MediaItem);
    });
    return map;
  }, [detailQueries, uniqueLogIds]);

  if (loading) {
    return (
      <div className="flex items-center justify-center h-full">
        <Loader2 className="animate-spin text-accent" size={36} />
      </div>
    );
  }

  if (!profile) {
    return (
      <div className="flex flex-col items-center justify-center h-[50vh] space-y-4">
        <User size={40} className="text-muted-foreground" />
        <p className="text-foreground/60 font-medium">Connect AniList in Settings to see your history.</p>
      </div>
    );
  }

  const days = Math.floor((profile.minutes_watched || 0) / 1440);
  const hours = Math.floor(((profile.minutes_watched || 0) % 1440) / 60);
  const favorites = favType === "ANIME" ? profile.favorite_anime || [] : profile.favorite_manga || [];

  return (
    <div className="animate-fade-in max-w-[1100px] space-y-10 pb-12">
      <div className="flex items-center gap-4">
        {profile.avatar_url ? (
          <img src={proxyImage(profile.avatar_url)} alt="" className="w-14 h-14 rounded-lg object-cover" />
        ) : (
          <div className="w-14 h-14 rounded-lg bg-surface border border-border grid place-items-center">
            <User size={22} className="text-muted-foreground" />
          </div>
        )}
        <div>
          <h1 className="text-[19px] font-semibold tracking-tight text-foreground">{profile.name}</h1>
          <p className="meta-mono mt-1 text-muted-foreground">
            {days}d {hours}h watched · {profile.episodes_watched?.toLocaleString() || 0} episodes ·{" "}
            {profile.chapters_read?.toLocaleString() || 0} chapters · {profile.anime_count || 0} anime ·{" "}
            {profile.manga_count || 0} manga
          </p>
        </div>
      </div>

      <div>
        <div className="flex items-baseline justify-between mb-3 px-1">
          <h2 className="text-[15px] font-semibold text-foreground tracking-tight">Last 30 days</h2>
          <span className="meta-mono text-muted-foreground">
            {thisWeek} this week · {thisMonth} this month
          </span>
        </div>
        <div className="rounded-lg border border-border px-4 pt-5 pb-2">
          <div className="flex items-end gap-[5px] h-[88px]">
            {bars.map((bar) => (
              <div
                key={bar.key}
                title={`${bar.key}: ${bar.count} episode${bar.count === 1 ? "" : "s"}`}
                className="flex-1 flex flex-col items-center justify-end h-full gap-1.5"
              >
                {bar.count > 0 && maxCount > 0 && (
                  <span className="meta-mono text-[8px] text-muted-foreground leading-none">{bar.count}</span>
                )}
                <div
                  className={`w-full rounded-t-[3px] ${bar.isToday ? "bg-accent" : bar.count > 0 ? "bg-accent/55" : "bg-foreground/[0.07]"}`}
                  style={{ height: maxCount > 0 ? `${Math.max(bar.count > 0 ? 8 : 2, (bar.count / maxCount) * 64)}px` : "2px" }}
                />
              </div>
            ))}
          </div>
          <div className="flex gap-[5px] mt-1.5">
            {bars.map((bar) => (
              <span
                key={bar.key}
                className={`flex-1 text-center meta-mono text-[7.5px] leading-none ${bar.isToday ? "text-accent" : "text-muted-foreground/60"}`}
              >
                {bar.isToday ? "now" : Number(bar.label) === 1 || bars.indexOf(bar) % 5 === 0 ? bar.label : ""}
              </span>
            ))}
          </div>
        </div>
      </div>

      {logEntries.length > 0 && (
        <div>
          <h2 className="text-[15px] font-semibold text-foreground tracking-tight mb-2 px-1">Recent</h2>
          <div className="rounded-lg border border-border overflow-hidden">
            {logEntries.map((e, i) => {
              const media = titleById.get(e.media_id);
              const name = media?.title?.english || media?.title?.romaji;
              const when = parseWatchedAt(e.watched_at);
              return (
                <button
                  key={`${e.media_id}-${e.episode_number}-${i}`}
                  onClick={() => media && onSelect?.(media)}
                  disabled={!media}
                  className="w-full flex items-center justify-between gap-4 px-4 py-2.5 border-b border-border last:border-b-0 text-left hover:bg-surface/70 cursor-pointer disabled:cursor-default"
                >
                  <span className="text-[13px] text-foreground/80 truncate">
                    <span className="font-medium text-foreground">{name || `#${e.media_id}`}</span>
                    {" — "}
                    {media?.type === "MANGA" ? "CH" : "EP"} {e.episode_number}
                  </span>
                  <span className="meta-mono text-muted-foreground shrink-0">
                    {when.toLocaleDateString(undefined, { weekday: "short" })}{" "}
                    {when.toLocaleTimeString(undefined, { hour: "2-digit", minute: "2-digit" })}
                  </span>
                </button>
              );
            })}
          </div>
        </div>
      )}

      <div>
        <div className="flex items-center justify-between mb-3 px-1">
          <h2 className="text-[15px] font-semibold text-foreground tracking-tight">Favorites</h2>
          <div className="flex rounded-md border border-border overflow-hidden">
            {(["ANIME", "MANGA"] as const).map((t) => (
              <button
                key={t}
                onClick={() => setFavType(t)}
                className={`px-3 py-1.5 text-[12px] font-medium cursor-pointer ${
                  favType === t ? "bg-accent/15 text-accent" : "text-foreground/50 hover:text-foreground"
                }`}
              >
                {t === "ANIME" ? "Anime" : "Manga"}
              </button>
            ))}
          </div>
        </div>
        {favorites.length > 0 ? (
          <div className="grid grid-cols-2 sm:grid-cols-3 md:grid-cols-4 lg:grid-cols-5 xl:grid-cols-6 gap-5">
            {favorites.map((item) => (
              <LazyCard key={item.id} item={item} onSelect={onSelect ?? (() => {})} />
            ))}
          </div>
        ) : (
          <p className="meta-mono px-1 py-8 text-muted-foreground">No favorite {favType.toLowerCase()} yet</p>
        )}
      </div>
    </div>
  );
}
