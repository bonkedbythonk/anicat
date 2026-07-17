import { useState, useEffect } from "react";
import { useAppStore } from "@/stores/app";
import { Loader2, Globe, Monitor, Activity, Clock, Calendar } from "lucide-react";
import { LazyCard } from "@/components/media/LazyCard";
import { mediaApi, getUserLists, type MediaItem } from "@/lib/api";
import { parseAiringTime } from "@/lib/date";
interface ScheduleViewProps {
  onSelect: (item: MediaItem) => void;
}

export function ScheduleView({ onSelect }: ScheduleViewProps) {
  const [items, setItems] = useState<MediaItem[]>([]);
  const [loading, setLoading] = useState(true);
  const watchingOnly = useAppStore(s => s.scheduleWatchingOnly);
  const setWatchingOnly = useAppStore(s => s.setScheduleWatchingOnly);




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
        parseAiringTime(a.next_airing?.airing_at) -
        parseAiringTime(b.next_airing?.airing_at)
    );

  const groups = new Map<string, MediaItem[]>();
  sortedItems.forEach((item) => {
    const date = new Date(parseAiringTime(item.next_airing?.airing_at));
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
          <h1 className="text-[28px] font-bold text-foreground tracking-tight">Airing Schedule</h1>
          <p className="text-muted-foreground font-medium text-lg">Keep track of the latest releases and upcoming episodes</p>
        </div>
        
        <div className="flex bg-foreground/[0.04] p-1 rounded-xl border border-border w-fit h-fit self-start sm:self-auto">
          <button
            onClick={() => setWatchingOnly(false)}
            className={`flex items-center space-x-2 px-4 py-2 rounded-lg font-semibold text-sm transition-all ${
              !watchingOnly ? "bg-foreground/[0.1] text-foreground" : "text-muted-foreground hover:text-foreground"
            }`}
          >
            <Globe size={16} />
            <span>Global</span>
          </button>
          <button
            onClick={() => setWatchingOnly(true)}
            className={`flex items-center space-x-2 px-4 py-2 rounded-lg font-semibold text-sm transition-all ${
              watchingOnly ? "bg-foreground/[0.1] text-foreground" : "text-muted-foreground hover:text-foreground"
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
            <div className="flex items-center space-x-3 bg-surface border border-border px-4 py-2 rounded-lg shadow-xl shadow-black/20">
              <Loader2 className="animate-spin text-accent" size={20} />
              <span className="text-xs font-bold text-foreground uppercase tracking-widest">Updating Schedule...</span>
            </div>
          </div>
        )}

        {loading && items.length === 0 ? (
          <div className="flex items-center justify-center py-20">
            <span className="meta-mono text-muted-foreground">LOADING SCHEDULE...</span>
          </div>
        ) : items.length === 0 ? (
          <div className="flex flex-col items-center justify-center py-20 text-center space-y-4">
            <div className="p-6 rounded-full bg-foreground/[0.02] border border-border">
              <Calendar size={48} className="text-muted-foreground/50" />
            </div>
            <div className="space-y-1">
              <h3 className="text-lg font-bold text-foreground">No episodes scheduled</h3>
              <p className="text-muted-foreground max-w-xs">
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
                  <h2 className="text-[15px] font-semibold tracking-tight text-foreground px-0 py-0 bg-transparent border-none">{date}</h2>
                  <div className="h-px flex-1 bg-border" />
                </div>
                <div className="grid grid-cols-2 sm:grid-cols-3 md:grid-cols-4 lg:grid-cols-5 xl:grid-cols-6 gap-6">
                  {dayItems.map(item => (
                    <div key={item.id} className="space-y-2">
                      <LazyCard item={item} onSelect={onSelect} />
                      <p className="text-sm font-bold text-foreground leading-tight line-clamp-2 px-0.5">
                        {item.title?.english || item.title?.romaji || item.title?.native || ""}
                      </p>
                      <div className="flex items-center justify-between px-1">
                        <div className="flex items-center space-x-1.5 text-accent">
                          <Activity size={12} />
                          <span className="meta-mono text-[10.5px]">Ep {item.next_airing?.episode}</span>
                        </div>
                        <div className="flex items-center space-x-1.5 text-muted-foreground">
                          <Clock size={12} />
                          <span className="meta-mono text-[10.5px]">
                            {new Date(parseAiringTime(item.next_airing!.airing_at)).toLocaleTimeString(undefined, { hour: '2-digit', minute: '2-digit', hour12: !use24h })}
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
