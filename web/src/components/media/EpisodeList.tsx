// @ts-nocheck

import { useState, useEffect, useRef } from "react";
import { Play, Download, Loader2, CheckCircle2, Clock, AlertCircle, BookOpen, XCircle, RefreshCw, Video } from "lucide-react";
import { mediaApi, type Episode } from "@/lib/api";
import type { MediaItem } from "@/lib/types";
import { setPlayback } from "@/stores/app";
import { dispatchRefresh } from "@/lib/events";

interface EpisodeListProps {
  mediaId: number;
  episodes: Episode[];
  loading: boolean;
  progress?: number;
  isManga?: boolean;
  item?: MediaItem;
  onRead?: (chapterNum: string) => void;
  onPlayEpisode?: (epNum: string, provider?: string, server?: string) => void;
  playerType?: "embedded" | "external";
  onUnwatch?: (epNum: string) => void;
  nextAiringEpisode?: number;
  onRetry?: () => void;
  selectedProvider?: string;
}

export function EpisodeList({
  mediaId,
  episodes,
  loading,
  progress = 0,
  isManga = false,
  item,
  onRead,
  onPlayEpisode,
  playerType = "external",
  onUnwatch,
  nextAiringEpisode,
  onRetry,
  selectedProvider,
}: EpisodeListProps) {
  const [playingEp, setPlayingEp] = useState<string | null>(null);
  const [queueingEp, setQueueingEp] = useState<string | null>(null);
  const [batchStart, setBatchStart] = useState("");
  const [batchEnd, setBatchEnd] = useState("");
  const [batchQueuing, setBatchQueuing] = useState(false);
  const [retrying, setRetrying] = useState(false);
  // Local overrides for download status so the icon updates immediately
  // after queuing, without waiting for a full episode-list refetch.
  const [localDownloadStatus, setLocalDownloadStatus] = useState<Record<string, string>>({});

  const [expandedEpStreams, setExpandedEpStreams] = useState<string | null>(null);
  const [loadingStreamsEp, setLoadingStreamsEp] = useState<string | null>(null);
  const [resolvedStreams, setResolvedStreams] = useState<any[]>([]);
  const [streamsError, setStreamsError] = useState<string | null>(null);
  const [streamSortOrder, setStreamSortOrder] = useState<"default" | "hard_sub" | "soft_sub" | "dub">("default");
  const [loadingServer, setLoadingServer] = useState<string | null>(null);

  // Removed automatic scrolling entirely to ensure UI stability.
  // The list will always start at the top (Episode 1).
  useEffect(() => {
    // Manual scroll only
  }, [mediaId]);

  const getSortedStreams = (streams: any[]) => {
    if (!streams) return [];
    
    const sorted = [...streams];
    if (streamSortOrder === "default") {
      return sorted;
    }
    
    return sorted.sort((a, b) => {
      const aServer = (a.server || "").toLowerCase();
      const bServer = (b.server || "").toLowerCase();
      
      const aHasSubtitles = Array.isArray(a.subtitles) && a.subtitles.length > 0;
      const bHasSubtitles = Array.isArray(b.subtitles) && b.subtitles.length > 0;

      const aIsHard = aServer.includes("hard sub") || (!aHasSubtitles && !aServer.includes("dub"));
      const bIsHard = bServer.includes("hard sub") || (!bHasSubtitles && !bServer.includes("dub"));
      
      const aIsSoft = aServer.includes("sort sub") || aHasSubtitles;
      const bIsSoft = bServer.includes("sort sub") || bHasSubtitles;
      
      const aIsDub = aServer.includes("dub");
      const bIsDub = bServer.includes("dub");

      if (streamSortOrder === "hard_sub") {
        if (aIsHard && !bIsHard) return -1;
        if (!aIsHard && bIsHard) return 1;
      } else if (streamSortOrder === "soft_sub") {
        if (aIsSoft && !bIsSoft) return -1;
        if (!aIsSoft && bIsSoft) return 1;
      } else if (streamSortOrder === "dub") {
        if (aIsDub && !bIsDub) return -1;
        if (!aIsDub && bIsDub) return 1;
      }
      
      return aServer.localeCompare(bServer);
    });
  };

  const handleRetry = async () => {
    if (!onRetry || retrying) return;
    setRetrying(true);
    try {
      await onRetry();
    } catch (error) {
      console.error("Failed to retry search:", error);
    } finally {
      setRetrying(false);
    }
  };

  const handlePlay = async (epNum: string) => {
    if (isManga && onRead) {
      onRead(epNum);
      return;
    }
    
    if (playerType === "embedded" && onPlayEpisode) {
      onPlayEpisode(epNum, selectedProvider);
      return;
    }
    
    setPlayingEp(epNum);
    try {
      const result = await mediaApi.play(mediaId, epNum, selectedProvider);
      if (result?.stream_url && item) {
        const episode = episodes.find((e) => String(e.number) === epNum);
        if (episode) {
          setPlayback(item, episode, selectedProvider || "anineko", result.stream_url);
        }
      }
      dispatchRefresh();
    } catch (error) {
      console.error("Failed to play:", error);
    } finally {
      setPlayingEp(null);
    }
  };

  const toggleStreams = async (epNum: string) => {
    if (expandedEpStreams === epNum) {
      setExpandedEpStreams(null);
      return;
    }

    setExpandedEpStreams(epNum);
    setLoadingStreamsEp(epNum);
    setStreamsError(null);
    setResolvedStreams([]);

    try {
      const data = await mediaApi.getStreams(mediaId, epNum, selectedProvider);
      setResolvedStreams(data.streams || []);
    } catch (err: any) {
      console.error("Failed to load stream servers:", err);
      setStreamsError(err?.message || "Failed to load stream servers.");
    } finally {
      setLoadingStreamsEp(null);
    }
  };

  const handlePlaySpecificStream = async (epNum: string, serverName: string) => {
    const serverKey = `${epNum}-${serverName}`;
    setLoadingServer(serverKey);

    if (playerType === "embedded" && onPlayEpisode) {
      try {
        onPlayEpisode(epNum, selectedProvider, serverName);
      } catch (error) {
        console.error("Failed to play stream:", error);
      } finally {
        setTimeout(() => setLoadingServer(null), 1500);
      }
      return;
    }

    setPlayingEp(epNum);
    try {
      const result = await mediaApi.play(mediaId, epNum, selectedProvider, serverName);
      if (result?.stream_url && item) {
        const episode = episodes.find((e) => String(e.number) === epNum);
        if (episode) {
          setPlayback(item, episode, selectedProvider || "anineko", result.stream_url);
        }
      }
      dispatchRefresh();
    } catch (error) {
      console.error("Failed to play stream:", error);
    } finally {
      setPlayingEp(null);
      setLoadingServer(null);
    }
  };

  const handleQueue = async (epNum: string) => {
    setQueueingEp(epNum);
    try {
      await mediaApi.addToQueue(mediaId, [epNum]);
      // Update local status immediately so the icon changes to "queued"
      setLocalDownloadStatus(prev => ({ ...prev, [epNum]: "queued" }));
      dispatchRefresh();
    } catch (error) {
      console.error("Failed to queue:", error);
      // Clear local override on failure so we don't show stale state
      setLocalDownloadStatus(prev => {
        const next = { ...prev };
        delete next[epNum];
        return next;
      });
    } finally {
      setQueueingEp(null);
    }
  };

  const handleBatchQueue = async () => {
    const start = parseInt(batchStart);
    const end = parseInt(batchEnd);
    if (isNaN(start) || isNaN(end) || start > end) return;
    
    setBatchQueuing(true);
    const eps = [];
    for (let i = start; i <= end; i++) {
      eps.push(String(i));
    }
    try {
      await mediaApi.addToQueue(mediaId, eps);
      setBatchStart("");
      setBatchEnd("");
      dispatchRefresh();
    } catch (error) {
      console.error("Failed to batch queue:", error);
    } finally {
      setBatchQueuing(false);
    }
  };

  const statusIcon = (status: string) => {
    switch (status) {
      case "completed": return <CheckCircle2 size={14} className="text-green-400" />;
      case "downloading": return <Loader2 size={14} className="text-accent animate-spin" />;
      case "queued": return <Clock size={14} className="text-yellow-400" />;
      case "failed": return <AlertCircle size={14} className="text-red-400" />;
      default: return null;
    }
  };

  if (loading) {
    return (
      <div className="flex items-center justify-center py-16">
        <Loader2 className="animate-spin text-accent" size={28} />
        <span className="ml-3 text-gray-500 text-sm font-medium">Fetching {isManga ? "chapters" : "episodes"} from provider...</span>
      </div>
    );
  }

  return (
    <div className="space-y-4">
      {/* Episode list */}
      {!Array.isArray(episodes) || episodes.length === 0 ? (
        <div className="text-center py-12 text-gray-600 text-sm space-y-3">
          <p>No {isManga ? "chapters" : "episodes"} found from this provider.</p>
          {onRetry && (
            <button
              onClick={handleRetry}
              disabled={retrying}
              className="inline-flex items-center space-x-2 px-4 py-2 bg-accent/10 hover:bg-accent/20 border border-accent/20 text-accent rounded-xl text-xs font-bold transition-all active:scale-95 disabled:opacity-50 disabled:pointer-events-none"
            >
              <RefreshCw size={14} className={retrying ? "animate-spin" : ""} />
              <span>{retrying ? "Retrying..." : "Retry Search"}</span>
            </button>
          )}
        </div>
      ) : (
        <div className="space-y-1 max-h-[50vh] overflow-y-auto scrollbar-hide pr-1">
          {episodes.map((ep) => {
            const epNum = String(ep.number);
            const isWatched = Number(ep.number) <= progress;
            const isNext = Number(ep.number) === progress + 1;
            const isUnaired = !isManga && nextAiringEpisode !== undefined && Number(ep.number) >= nextAiringEpisode;
            
            return (
              <div key={epNum} className="space-y-1.5">
                <div
                  onClick={() => !isUnaired && handlePlay(epNum)}
                  className={`flex items-center justify-between px-4 py-2.5 rounded-lg transition-all group episode-row-item ${!isUnaired ? 'cursor-pointer' : ''} ${
                    isNext && !isUnaired ? 'bg-accent/10 border border-accent/20 shadow-lg shadow-accent/5' : 
                    isWatched ? 'opacity-50 hover:bg-foreground/[0.04] border border-transparent' : 
                    'bg-foreground/[0.02] border border-border hover:bg-foreground/[0.06] hover:border-border/60'
                  }`}
                >
                <div className="flex items-center space-x-4 min-w-0">
                  {/* Clean Episode Badge */}
                  <div className={`w-11 h-11 shrink-0 flex items-center justify-center rounded-[14px] font-bold text-sm transition-all episode-badge-box ${
                    isWatched ? "bg-foreground/5 text-gray-500" :
                    isUnaired ? "bg-foreground/5 text-gray-700" :
                    isNext ? "bg-accent text-white shadow-md shadow-accent/20" :
                    "bg-foreground/[0.06] text-foreground group-hover:bg-accent group-hover:text-white"
                  }`}>
                    {playingEp === epNum ? (
                      <Loader2 size={16} className="animate-spin" />
                    ) : (
                      <div className="relative flex items-center justify-center w-full h-full">
                        <span className="group-hover:opacity-0 transition-opacity absolute">{epNum}</span>
                        <Play size={16} fill="currentColor" className="opacity-0 group-hover:opacity-100 transition-opacity absolute" />
                      </div>
                    )}
                  </div>
                  
                  <div className="flex flex-col min-w-0">
                    <span className={`text-sm font-medium truncate transition-colors ${
                      isWatched ? "text-gray-500" : 
                      isUnaired ? "text-gray-600" : 
                      "text-gray-200 group-hover:text-white"
                    }`}>
                      {ep.title.toLowerCase() === `episode ${epNum}` ? `Episode ${epNum}` : ep.title || `Episode ${epNum}`}
                    </span>
                  </div>
                  {statusIcon(localDownloadStatus[epNum] || ep.download_status)}
                </div>

                {!isUnaired ? (
                  <div className="flex items-center space-x-1.5 opacity-0 group-hover:opacity-100 transition-opacity shrink-0">
                    {!isManga && (
                      <button
                        onClick={(e) => {
                          e.stopPropagation();
                          toggleStreams(epNum);
                        }}
                        title="Choose Stream Server"
                        className={`flex items-center justify-center w-9 h-9 rounded-xl transition-all active:scale-90 ${
                          expandedEpStreams === epNum
                            ? "bg-accent/25 text-accent border border-accent/30"
                            : "bg-foreground/[0.04] text-muted-foreground hover:bg-foreground/10 hover:text-foreground"
                        }`}
                      >
                        {loadingStreamsEp === epNum ? (
                          <Loader2 size={16} className="animate-spin text-accent" />
                        ) : (
                          <Video size={16} />
                        )}
                      </button>
                    )}
                    <button
                      onClick={(e) => {
                        e.stopPropagation();
                        handleQueue(epNum);
                      }}
                      disabled={queueingEp === epNum || (localDownloadStatus[epNum] || ep.download_status) === "completed"}
                      title="Download"
                      className="flex items-center justify-center w-9 h-9 bg-foreground/[0.04] text-muted-foreground rounded-xl hover:bg-foreground/10 hover:text-foreground transition-all disabled:opacity-30 active:scale-90"
                    >
                      {queueingEp === epNum ? (
                        <Loader2 size={16} className="animate-spin" />
                      ) : (
                        <Download size={16} />
                      )}
                    </button>
                    {isWatched && (
                      <button
                        onClick={(e) => {
                          e.stopPropagation();
                          if (onUnwatch) onUnwatch(epNum);
                        }}
                        title={isManga ? "Backtrack to before this chapter" : "Mark as unwatched"}
                        className="flex items-center justify-center w-9 h-9 bg-foreground/[0.04] text-muted-foreground rounded-xl hover:bg-red-500/20 hover:text-red-400 transition-all active:scale-90"
                      >
                        <XCircle size={16} />
                      </button>
                    )}
                  </div>
                ) : (
                  <span className="text-[10px] font-black uppercase tracking-wider text-muted-foreground px-3 py-1.5 bg-foreground/[0.04] border border-border rounded-[10px] shrink-0">
                    Airing Soon
                  </span>
                )}
              </div>

              {expandedEpStreams === epNum && (
                <div className="ml-15 p-4 rounded-2xl bg-foreground/[0.02] border border-border space-y-3 animate-fade-in text-xs" onClick={(e) => e.stopPropagation()}>
                  <div className="flex flex-col sm:flex-row sm:items-center sm:justify-between border-b border-border/10 pb-2 mb-2 gap-2">
                    <div className="text-[10px] font-black text-accent uppercase tracking-[0.2em]">Available Stream Servers</div>
                    <div className="flex items-center space-x-1 bg-foreground/[0.03] p-0.5 rounded-lg border border-border/40 text-[9px] font-bold self-start sm:self-auto">
                      {(["default", "hard_sub", "soft_sub", "dub"] as const).map((mode) => (
                        <button
                          key={mode}
                          onClick={(e) => {
                            e.stopPropagation();
                            setStreamSortOrder(mode);
                          }}
                          className={`px-2 py-1 rounded transition-all capitalize ${
                            streamSortOrder === mode
                              ? "bg-accent text-white shadow-sm"
                              : "text-muted-foreground hover:text-foreground hover:bg-foreground/5"
                          }`}
                        >
                          {mode.replace("_", " ")}
                        </button>
                      ))}
                    </div>
                  </div>
                  {loadingStreamsEp === epNum ? (
                    <div className="flex items-center space-x-2 py-3 text-muted-foreground text-[11px]">
                      <Loader2 size={12} className="animate-spin text-accent" />
                      <span>Fetching stream servers...</span>
                    </div>
                  ) : streamsError ? (
                    <div className="text-red-400 py-1 text-[11px] font-medium">{streamsError}</div>
                  ) : resolvedStreams.length === 0 ? (
                    <div className="text-muted-foreground py-1 text-[11px]">No alternative streams found.</div>
                  ) : (
                    <div className="grid grid-cols-1 sm:grid-cols-2 gap-2">
                      {getSortedStreams(resolvedStreams).map((s, idx) => {
                        const isCurrentLoading = loadingServer === `${epNum}-${s.server}`;
                        const isAnyLoading = loadingServer !== null || playingEp !== null;
                        
                        return (
                          <button
                            key={idx}
                            disabled={isAnyLoading}
                            onClick={() => handlePlaySpecificStream(epNum, s.server)}
                            className={`flex items-center justify-between p-3 rounded-xl text-left transition-all active:scale-95 group/btn ${
                              isCurrentLoading
                                ? "bg-accent/15 border-accent text-accent"
                                : "bg-foreground/[0.03] border-border/40 hover:bg-accent/15 hover:border-accent hover:text-accent"
                            } border ${
                              isAnyLoading && !isCurrentLoading ? "opacity-40 cursor-not-allowed" : "cursor-pointer"
                            }`}
                          >
                            <div className="min-w-0 flex-1 pr-2">
                              <div className={`font-bold text-[11px] truncate ${
                                isCurrentLoading ? "text-accent" : "text-gray-200 group-hover/btn:text-white"
                              }`}>
                                {s.server}
                              </div>
                              <div className="text-[9px] text-gray-500 mt-0.5">
                                {s.links.length} link{s.links.length > 1 ? 's' : ''} • {s.subtitles && s.subtitles.length > 0 ? `${s.subtitles.length} Subtitles` : 'Hard Sub'}
                              </div>
                            </div>
                            {isCurrentLoading ? (
                              <Loader2 size={12} className="animate-spin text-accent shrink-0" />
                            ) : (
                              <Play size={12} className="text-muted-foreground group-hover/btn:text-accent group-hover/btn:scale-110 transition-all shrink-0" fill="currentColor" />
                            )}
                          </button>
                        );
                      })}
                    </div>
                  )}
                </div>
              )}
            </div>
          );
        })}
        </div>
      )}
    </div>
  );
}
