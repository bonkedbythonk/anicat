import { useState, useEffect } from "react";
import { useAppStore } from "@/stores/app";
import { Loader2, Globe, Monitor, Activity, Clock, Calendar } from "lucide-react";
import { LazyCard } from "@/components/media/LazyCard";
import { mediaApi, getUserLists, type MediaItem } from "@/lib/api";

interface ScheduleViewProps {
  onSelect: (item: MediaItem) => void;
}

export function ScheduleView({ onSelect }: ScheduleViewProps) {
  const [items, setItems] = useState<MediaItem[]>([]);
  const [loading, setLoading] = useState(true);
  const watchingOnly = useAppStore(s => s.scheduleWatchingOnly);
  const setWatchingOnly = useAppStore(s => s.setScheduleWatchingOnly);

  const parseAiringAt = (airingAt?: string) => {
    if (!airingAt) return 0;
    return new Date(airingAt.endsWith("Z") ? airingAt : `${airingAt}Z`).getTime();
  };


  useEffect(() => {
    async function load() {
      setLoading(true);
      try {
        let mediaIds: number[] | undefined = undefined;
        if (watchingOnly) {
          // Use getUserLists directly so we get ALL watching entries, not just
          // the first 50 that the paginated getUserList wrapper returns.
          const collection = await getUserLists(undefined, "CURRENT", "ANIME");
          const lists = collection?.MediaListCollection?.lists ?? [];
          const entries = lists.flatMap((l: { entries?: { media?: { id?: number } }[] }) => l.entries ?? []);
          mediaIds = entries
            .map((e: { media?: { id?: number } }) => e.media?.id)
            .filter((id): id is number => typeof id === "number");
          if (mediaIds.length === 0) {
            setItems([]);
            setLoading(false);
            return;
          }
        }
        
        const data = await mediaApi.getSchedule(1, 7, 1, 50, mediaIds);
        setItems((data.media || []) as MediaItem[]);
      } catch (err) {
        console.error("Failed to load schedule:", err);
      } finally {
        setLoading(false);
      }
    }
    load();
  }, [watchingOnly]);

  // Sort globally by nearest airing first, then group by day in that order.
  const sortedItems = items
    .filter((item) => item.next_airing?.airing_at)
    .sort(
      (a, b) =>
        parseAiringAt(a.next_airing?.airing_at) -
        parseAiringAt(b.next_airing?.airing_at)
    );

  const groups = new Map<string, MediaItem[]>();
  sortedItems.forEach((item) => {
    const date = new Date(
      item.next_airing?.airing_at?.endsWith("Z")
        ? item.next_airing.airing_at
        : `${item.next_airing?.airing_at}Z`
    );
    const dateStr = date.toLocaleDateString(undefined, {
      weekday: "long",
      month: "long",
      day: "numeric",
    });
    if (!groups.has(dateStr)) groups.set(dateStr, []);
    groups.get(dateStr)!.push(item);
  });

  const timeFormat = typeof window !== "undefined" ? localStorage.getItem("anicat_time_format") : "12h";
  const use24h = timeFormat === "24h";

  return (
    <div className="space-y-12 animate-fade-in pb-12">
      <div className="flex flex-col sm:flex-row sm:items-end justify-between gap-6">
        <div className="flex flex-col space-y-2">
          <h1 className="text-[28px] font-bold text-white tracking-tight">Airing Schedule</h1>
          <p className="text-gray-500 font-medium text-lg">Keep track of the latest releases and upcoming episodes</p>
        </div>
        
        <div className="flex bg-white/[0.04] p-1 rounded-xl border border-white/[0.06] w-fit h-fit self-start sm:self-auto">
          <button
            onClick={() => setWatchingOnly(false)}
            className={`flex items-center space-x-2 px-4 py-2 rounded-lg font-semibold text-sm transition-all ${
              !watchingOnly ? "bg-white/[0.1] text-white" : "text-gray-500 hover:text-white"
            }`}
          >
            <Globe size={16} />
            <span>Global</span>
          </button>
          <button
            onClick={() => setWatchingOnly(true)}
            className={`flex items-center space-x-2 px-4 py-2 rounded-lg font-semibold text-sm transition-all ${
              watchingOnly ? "bg-white/[0.1] text-white" : "text-gray-500 hover:text-white"
            }`}
          >
            <Monitor size={16} />
            <span>Watching Only</span>
          </button>
        </div>
      </div>

      <div className="relative">
        {loading && items.length > 0 && (
          <div className="absolute top-1/2 left-0 right-0 z-10 flex justify-center -translate-y-1/2 animate-fade-in">
            <div className="bg-black/80 px-6 py-3 rounded-2xl border border-white/10 flex items-center space-x-3 shadow-2xl">
              <Loader2 className="animate-spin text-accent" size={20} />
              <span className="text-xs font-bold text-white uppercase tracking-widest">Updating Schedule...</span>
            </div>
          </div>
        )}

        {loading && items.length === 0 ? (
          <div className="space-y-12 animate-pulse">
            <div className="space-y-6">
              <div className="h-8 bg-white/[0.04] rounded-xl w-48" />
              <div className="grid grid-cols-2 sm:grid-cols-3 md:grid-cols-4 lg:grid-cols-5 xl:grid-cols-6 gap-6">
                {Array.from({ length: 6 }).map((_, i) => (
                  <div key={i} className="space-y-3">
                    <div className="aspect-[2/3] w-full bg-white/[0.04] rounded-2xl border border-white/[0.03]" />
                    <div className="h-4 bg-white/[0.04] rounded-md w-3/4" />
                    <div className="h-3 bg-white/[0.02] rounded-md w-1/2" />
                  </div>
                ))}
              </div>
            </div>
          </div>
        ) : items.length === 0 ? (
          <div className="flex flex-col items-center justify-center py-20 text-center space-y-4">
            <div className="p-6 rounded-full bg-white/[0.02] border border-white/[0.04]">
              <Calendar size={48} className="text-gray-700" />
            </div>
            <div className="space-y-1">
              <h3 className="text-lg font-bold text-white">No episodes scheduled</h3>
              <p className="text-gray-500 max-w-xs">
                {watchingOnly 
                  ? "Make sure you have active shows in your Watching list." 
                  : "Check back later for updated airing times."}
              </p>
            </div>
          </div>
        ) : (
          <div className={`space-y-12 transition-opacity duration-200 ${loading ? "opacity-50 pointer-events-none" : "opacity-100"}`}>
            {Array.from(groups.entries()).map(([date, dayItems]) => (
              <div key={date} className="space-y-6">
                <div className="flex items-center space-x-4">
                  <h2 className="text-xl font-bold text-white px-4 py-2 bg-white/[0.03] border border-white/[0.06] rounded-xl inline-block">{date}</h2>
                  <div className="h-px flex-1 bg-gradient-to-r from-white/[0.06] to-transparent" />
                </div>
                <div className="grid grid-cols-2 sm:grid-cols-3 md:grid-cols-4 lg:grid-cols-5 xl:grid-cols-6 gap-6">
                  {dayItems.map(item => (
                    <div key={item.id} className="space-y-2">
                      <LazyCard item={item} onSelect={onSelect} />
                      <p className="text-sm font-bold text-white leading-tight line-clamp-2 px-0.5">
                        {item.title?.english || item.title?.romaji || item.title?.native || ""}
                      </p>
                      <div className="flex items-center justify-between px-1">
                        <div className="flex items-center space-x-1.5 text-accent">
                          <Activity size={12} className="animate-pulse" />
                          <span className="text-[11px] font-black uppercase tracking-wider">Ep {item.next_airing?.episode}</span>
                        </div>
                        <div className="flex items-center space-x-1.5 text-gray-500">
                          <Clock size={12} />
                          <span className="text-[11px] font-bold">
                            {new Date(
                              item.next_airing!.airing_at!.endsWith("Z")
                                ? item.next_airing!.airing_at!
                                : `${item.next_airing!.airing_at!}Z`
                            ).toLocaleTimeString(undefined, { hour: '2-digit', minute: '2-digit', hour12: !use24h })}
                          </span>
                        </div>
                      </div>
                    </div>
                  ))}
                </div>
              </div>
            ))}
          </div>
        )}
      </div>
    </div>
  );
}
