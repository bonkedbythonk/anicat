import { useState } from "react";
import { Play, Loader2, MoreVertical, Check, XCircle, RefreshCw, Video } from "lucide-react";
import { mediaApi, type Episode, type StreamServer } from "@/lib/api";
import { dispatchRefresh } from "@/lib/events";
import { BottomSheet, SheetRow } from "./BottomSheet";

interface MobileEpisodeListProps {
  mediaId: number;
  episodes: Episode[];
  loading: boolean;
  progress?: number;
  isManga?: boolean;
  onRead?: (chapterNum: string) => void;
  onUnwatch?: (epNum: string) => void;
  onWatch?: (epNum: string) => void;
  nextAiringEpisode?: number;
  nextAiringTime?: number | string;
  onRetry?: () => void;
  selectedProvider?: string;
  mediaTitle?: string;
  coverImage?: string;
  episodeTitleMap?: Record<number, string>;
  fillerEpisodes?: number[] | Set<number>;
}

/** Native episode/chapter list. The shared desktop `EpisodeList` hides its
 * per-row actions (download, mark watched, choose server) behind `:hover` —
 * which never fires on touch, so those actions are simply unreachable on a
 * phone. Rebuilt here so tapping a row plays it directly (the Crunchyroll/
 * Netflix convention) and secondary actions live in a bottom sheet.
 * Download/queue is intentionally omitted (out of scope for mobile). */
export function MobileEpisodeList({
  mediaId, episodes, loading, progress = 0, isManga = false, onRead, onUnwatch, onWatch,
  nextAiringEpisode, nextAiringTime, onRetry, selectedProvider, mediaTitle, coverImage,
  episodeTitleMap, fillerEpisodes,
}: MobileEpisodeListProps) {
  const [playingEp, setPlayingEp] = useState<string | null>(null);
  const [retrying, setRetrying] = useState(false);
  const [sheetEp, setSheetEp] = useState<string | null>(null);
  const [serverPicker, setServerPicker] = useState<{ epNum: string; streams: StreamServer[]; loading: boolean; error: string | null } | null>(null);

  const isFiller = (num: number) =>
    !!fillerEpisodes && (Array.isArray(fillerEpisodes) ? fillerEpisodes.includes(num) : fillerEpisodes.has(num));

  const handlePlay = async (epNum: string, serverName?: string) => {
    if (isManga && onRead) { onRead(epNum); return; }
    setPlayingEp(epNum);
    try {
      const ep = episodes.find((e) => String(e.number) === epNum);
      const epTitle = episodeTitleMap?.[parseInt(epNum)] || ep?.title;
      await mediaApi.play(mediaId, parseInt(epNum, 10), selectedProvider, serverName, mediaTitle, epTitle, coverImage, episodes.length);
      dispatchRefresh();
    } catch (error) {
      console.error("Failed to play:", error);
    } finally {
      setPlayingEp(null);
      setServerPicker(null);
    }
  };

  const openServerPicker = async (epNum: string) => {
    setSheetEp(null);
    setServerPicker({ epNum, streams: [], loading: true, error: null });
    try {
      const data = (await mediaApi.getStreams(mediaId, parseInt(epNum, 10), selectedProvider)) as { streams?: StreamServer[] };
      setServerPicker({ epNum, streams: data.streams || [], loading: false, error: null });
    } catch (err) {
      setServerPicker({ epNum, streams: [], loading: false, error: err instanceof Error ? err.message : "Failed to load servers." });
    }
  };

  const handleRetry = async () => {
    if (!onRetry || retrying) return;
    setRetrying(true);
    try { await onRetry(); } finally { setRetrying(false); }
  };

  if (loading) {
    return (
      <div className="flex items-center justify-center py-16 gap-3 text-muted-foreground">
        <Loader2 className="animate-spin text-accent" size={24} />
        <span className="text-sm font-medium">Fetching {isManga ? "chapters" : "episodes"}...</span>
      </div>
    );
  }

  if (!Array.isArray(episodes) || episodes.length === 0) {
    return (
      <div className="space-y-3 py-12 text-center text-sm text-muted-foreground">
        <p>No {isManga ? "chapters" : "episodes"} found from this provider.</p>
        {onRetry && (
          <button
            onClick={handleRetry}
            disabled={retrying}
            className="inline-flex items-center gap-2 rounded-xl border border-accent/20 bg-accent/10 px-4 py-2 text-xs font-bold text-accent active:scale-95 disabled:opacity-50"
          >
            <RefreshCw size={14} className={retrying ? "animate-spin" : ""} />
            {retrying ? "Retrying..." : "Retry Search"}
          </button>
        )}
      </div>
    );
  }

  const sheetEpisode = episodes.find((e) => String(e.number) === sheetEp);
  const sheetIsWatched = sheetEpisode ? Number(sheetEpisode.number) <= progress : false;

  return (
    <div className="space-y-1">
      {episodes.map((ep, idx) => {
        const epNum = String(ep.number);
        const isWatched = Number(ep.number) <= progress;
        const isNext = Number(ep.number) === progress + 1;
        const nextAiringSecs = typeof nextAiringTime === "string" ? new Date(nextAiringTime).getTime() / 1000 : Number(nextAiringTime);
        const hasAired = !isNaN(nextAiringSecs) && Date.now() / 1000 > nextAiringSecs;
        const isUnaired = !isManga && nextAiringEpisode !== undefined && Number(ep.number) >= nextAiringEpisode && !hasAired;
        const displayTitle = ep.title && !/^(episode|watch episode|chapter)\s+\d+$/i.test(ep.title)
          ? ep.title
          : episodeTitleMap?.[Number(ep.number)] || (isManga ? `Chapter ${epNum}` : `Episode ${epNum}`);

        return (
          <div
            key={`${epNum}-${idx}`}
            onClick={() => !isUnaired && handlePlay(epNum)}
            className={`flex items-center gap-3 rounded-xl px-3 py-2.5 active:bg-white/[0.05] ${isWatched ? "opacity-50" : ""}`}
          >
            <div className={`flex h-10 w-10 shrink-0 items-center justify-center rounded-xl text-sm font-bold ${
              isNext && !isUnaired ? "bg-accent text-white" : "bg-white/[0.06] text-foreground"
            }`}>
              {playingEp === epNum ? <Loader2 size={15} className="animate-spin" /> : epNum}
            </div>
            <div className="min-w-0 flex-1">
              <p className="truncate text-[14px] font-semibold text-foreground">{displayTitle}</p>
              {isFiller(Number(ep.number)) && (
                <span className="mt-0.5 inline-block rounded bg-yellow-500/15 px-1.5 py-0.5 text-[9px] font-bold text-yellow-400">Filler</span>
              )}
            </div>
            {isUnaired ? (
              <span className="shrink-0 rounded-lg bg-white/[0.06] px-2.5 py-1 text-[10px] font-bold uppercase text-muted-foreground">Soon</span>
            ) : (
              <button
                onClick={(e) => { e.stopPropagation(); setSheetEp(epNum); }}
                className="shrink-0 p-2 text-muted-foreground active:opacity-50"
              >
                <MoreVertical size={18} />
              </button>
            )}
          </div>
        );
      })}

      <BottomSheet open={!!sheetEp} onClose={() => setSheetEp(null)} title={sheetEp ? `Episode ${sheetEp}` : undefined}>
        <SheetRow onClick={() => sheetEp && handlePlay(sheetEp)}>
          <Play size={18} fill="currentColor" /> Play
        </SheetRow>
        {!isManga && (
          <SheetRow onClick={() => sheetEp && openServerPicker(sheetEp)}>
            <Video size={18} /> Choose Server
          </SheetRow>
        )}
        <SheetRow
          onClick={() => {
            if (!sheetEp) return;
            if (sheetIsWatched) onUnwatch?.(sheetEp); else onWatch?.(sheetEp);
            setSheetEp(null);
          }}
        >
          {sheetIsWatched ? <XCircle size={18} /> : <Check size={18} />}
          {sheetIsWatched ? (isManga ? "Mark as unread" : "Mark as unwatched") : (isManga ? "Mark as read" : "Mark as watched")}
        </SheetRow>
      </BottomSheet>

      <BottomSheet open={!!serverPicker} onClose={() => setServerPicker(null)} title="Stream Servers">
        {serverPicker?.loading ? (
          <div className="flex items-center gap-2 px-4 py-6 text-sm text-muted-foreground">
            <Loader2 size={16} className="animate-spin" /> Loading servers...
          </div>
        ) : serverPicker?.error ? (
          <p className="px-4 py-6 text-sm text-red-400">{serverPicker.error}</p>
        ) : serverPicker && serverPicker.streams.length === 0 ? (
          <p className="px-4 py-6 text-sm text-muted-foreground">No servers found.</p>
        ) : (
          serverPicker?.streams.map((s, i) => (
            <SheetRow key={`${s.name}-${i}`} onClick={() => handlePlay(serverPicker.epNum, s.name)}>
              <Play size={16} fill="currentColor" />
              <span className="flex-1 truncate">{s.name}</span>
              <span className="text-xs font-normal text-muted-foreground">{s.quality || "HD"}</span>
            </SheetRow>
          ))
        )}
      </BottomSheet>
    </div>
  );
}
