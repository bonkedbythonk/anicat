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
            className="inline-flex items-center gap-2 rounded-md border border-border bg-accent/10 px-4 py-2 text-xs font-semibold text-accent active:scale-95 disabled:opacity-50"
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
          // Row carries its own "more" button, so it can't be a <button>
          // itself — role + key handling gives it the same semantics without
          // nesting interactive elements.
          <div
            key={`${epNum}-${idx}`}
            role="button"
            tabIndex={isUnaired ? -1 : 0}
            aria-disabled={isUnaired || undefined}
            aria-label={`${displayTitle}${isWatched ? ", watched" : ""}`}
            onClick={() => !isUnaired && handlePlay(epNum)}
            onKeyDown={(e) => {
              if (isUnaired) return;
              if (e.key === "Enter" || e.key === " ") {
                e.preventDefault();
                handlePlay(epNum);
              }
            }}
            className={`flex items-center gap-3 rounded-md px-3 py-2.5 active:bg-foreground/[0.05] ${isWatched ? "opacity-50" : ""}`}
          >
            <div className={`flex h-9 w-9 shrink-0 items-center justify-center rounded-[4px] border font-mono text-[11px] tabular-nums ${
              isNext && !isUnaired ? "border-accent text-foreground" : isWatched ? "border-transparent bg-accent/15 text-accent" : "border-border text-muted-foreground"
            }`}>
              {playingEp === epNum ? <Loader2 size={15} className="animate-spin" /> : epNum}
            </div>
            <div className="min-w-0 flex-1">
              <p className="truncate text-[13.5px] font-medium text-foreground">{displayTitle}</p>
              {isFiller(Number(ep.number)) && (
                <span className="mt-0.5 inline-block font-mono text-[9px] uppercase tracking-[0.08em] text-[#c07a5b]">Filler</span>
              )}
            </div>
            {isUnaired ? (
              <span className="shrink-0 rounded-[4px] border border-border px-2.5 py-1 font-mono text-[9px] uppercase tracking-[0.08em] text-muted-foreground">Soon</span>
            ) : (
              <button
                onClick={(e) => { e.stopPropagation(); setSheetEp(epNum); }}
                aria-label={`More options for ${isManga ? "chapter" : "episode"} ${epNum}`}
                className="shrink-0 p-3 text-muted-foreground active:opacity-50"
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
              {/* Torrent releases differ only near the end (source/codec/CRC) —
                  single-line truncate clipped exactly that, making different
                  releases look identical. Wrap instead. */}
              <span className="flex-1 line-clamp-2 break-words">{s.name}</span>
              <span className="text-xs font-normal text-muted-foreground shrink-0">{s.quality || "HD"}</span>
            </SheetRow>
          ))
        )}
      </BottomSheet>
    </div>
  );
}
