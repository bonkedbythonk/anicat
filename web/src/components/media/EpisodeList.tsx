
import { useState, useEffect, useRef } from "react";
import { Play, Download, Loader2, CheckCircle2, Clock, AlertCircle, BookOpen, XCircle, RefreshCw, Video, Check } from "lucide-react";
import { listen } from "@tauri-apps/api/event";
import { mediaApi, type Episode, type StreamServer } from "@/lib/api";
import { useSettingsStore } from "@/stores/app";
import { dispatchRefresh } from "@/lib/events";

interface EpisodeListProps {
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

export function EpisodeList({
  mediaId,
  episodes,
  loading,
  progress = 0,
  isManga = false,
  onRead,
  onUnwatch,
  onWatch,
  nextAiringEpisode,
  nextAiringTime,
  onRetry,
  selectedProvider,
  mediaTitle,
  coverImage,
  episodeTitleMap,
  fillerEpisodes,
}: EpisodeListProps) {
  const translationType = useSettingsStore((s) => s.translationType);
  const [playingEp, setPlayingEp] = useState<string | null>(null);
  const [queueingEp, setQueueingEp] = useState<string | null>(null);
  const [localDownloadStatus, setLocalDownloadStatus] = useState<Record<string, string>>({});
  const [retrying, setRetrying] = useState(false);

  const [expandedEpStreams, setExpandedEpStreams] = useState<string | null>(null);
  const [loadingStreamsEp, setLoadingStreamsEp] = useState<string | null>(null);
  const [resolvedStreams, setResolvedStreams] = useState<any[]>([]);
  const [streamsError, setStreamsError] = useState<string | null>(null);
  const [streamFilter, setStreamFilter] = useState<"hard_sub" | "soft_sub" | "dub" | null>(
    translationType === "dub" ? "dub" : null
  );
  const [loadingServer, setLoadingServer] = useState<string | null>(null);

  useEffect(() => {
    setStreamFilter(translationType === "dub" ? "dub" : null);
  }, [translationType]);

  // Removed automatic scrolling entirely to ensure UI stability.
  // The list will always start at the top (Episode 1).
  useEffect(() => {
    // Manual scroll only
  }, [mediaId]);

  useEffect(() => {
    // Sync initial episodes statuses with localDownloadStatus when episodes change
    const initialStatus: Record<string, string> = {};
    episodes.forEach(ep => {
      if (ep.download_status) {
        initialStatus[String(ep.number)] = ep.download_status;
      }
    });
    setLocalDownloadStatus(initialStatus);
  }, [episodes]);

  useEffect(() => {
    const unlistenStatus = listen<{ media_id: number; episode_number: number; status: string }>(
      "download_status_change",
      (event) => {
        const { media_id, episode_number, status } = event.payload;
        if (media_id === mediaId) {
          setLocalDownloadStatus((prev) => {
            const next = { ...prev };
            if (status === "removed") {
              delete next[String(episode_number)];
            } else {
              next[String(episode_number)] = status;
            }
            return next;
          });
        }
      }
    );

    const unlistenProgress = listen<{ media_id: number; episode_number: number; progress: number }>(
      "download_progress",
      (event) => {
        const { media_id, episode_number, progress } = event.payload;
        if (media_id === mediaId) {
          setLocalDownloadStatus((prev) => ({
            ...prev,
            [String(episode_number)]: progress >= 100 ? "completed" : "downloading",
          }));
        }
      }
    );

    return () => {
      unlistenStatus.then((fn) => fn());
      unlistenProgress.then((fn) => fn());
    };
  }, [mediaId]);

  const getStreamGroup = (name: string) => {
    const lower = (name || "").toLowerCase();
    if (lower.includes("dub")) return "dub";
    if (lower.includes("soft")) return "soft_sub";
    if (lower.includes("hard")) return "hard_sub";
    if (lower.includes("sub")) return "soft_sub";
    return "default";
  };

  const getStreamGroupFromServer = (s: StreamServer) => {
    if (s.group) {
      if (s.group === "sub") return "hard_sub";
      return s.group;
    }
    const n = (s.name || "").toLowerCase();
    if (n.includes("dub")) return "dub";
    if (n.includes("sub")) return "hard_sub";
    return "default";
  };

  const statusIcon = (status: string | null | undefined) => {
    if (status === "completed") return <CheckCircle2 size={16} className="text-green-400 shrink-0" />;
    if (status === "downloading") return <Loader2 size={16} className="animate-spin text-accent shrink-0" />;
    if (status === "queued") return <Clock size={16} className="text-yellow-400 shrink-0" />;
    if (status === "failed") return <AlertCircle size={16} className="text-red-400 shrink-0" />;
    return null;
  };

  const serverSpeedRank = (server: StreamServer) => {
    const url = (server.url || "").toLowerCase();
    if (url.includes("tools.fast4speed.rsvp")) return 0;
    if (url.includes("wixstatic.com") || url.includes("wixmp.com")) return 1;
    if (url.includes("sharepoint") || url.includes("fast4speed")) return 2;
    if (url.includes("mp4upload") || url.includes("youtu-chan")) return 3;
    return 4;
  };

  const getSortedStreams = (streams: StreamServer[]) => {
    if (!streams) return [];
    
    let filtered = [...streams];
    
    if (streamFilter) {
      filtered = filtered.filter(s => getStreamGroupFromServer(s) === streamFilter);
    }
    
    const getGroupWeight = (group: string) => {
      switch (group) {
        case "hard_sub": return 1;
        case "dub": return 2;
        case "soft_sub": return 3;
        default: return 4;
      }
    };

    return filtered.sort((a, b) => {
      const aGroup = getStreamGroupFromServer(a);
      const bGroup = getStreamGroupFromServer(b);
      
      const aWeight = getGroupWeight(aGroup);
      const bWeight = getGroupWeight(bGroup);
      if (aWeight !== bWeight) {
        return aWeight - bWeight;
      }

      const aSpeed = serverSpeedRank(a);
      const bSpeed = serverSpeedRank(b);
      return aSpeed - bSpeed;
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

    setPlayingEp(epNum);
    try {
      const ep = episodes.find((e) => String(e.number) === epNum);
      const epTitle = episodeTitleMap?.[parseInt(epNum)] || ep?.title;
      await mediaApi.play(mediaId, parseInt(epNum, 10), selectedProvider, undefined, mediaTitle, epTitle, coverImage, episodes.length);
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
      const data = await mediaApi.getStreams(mediaId, parseInt(epNum, 10), selectedProvider) as { streams?: StreamServer[] };
      setResolvedStreams(data.streams || []);
    } catch (err: unknown) {
      console.error("Failed to load stream servers:", err);
      setStreamsError((err as Error)?.message || "Failed to load stream servers.");
    } finally {
      setLoadingStreamsEp(null);
    }
  };

  const handlePlaySpecificStream = async (epNum: string, serverName: string) => {
    const serverKey = `${epNum}-${serverName}`;
    setLoadingServer(serverKey);

    setPlayingEp(epNum);
    try {
      const ep = episodes.find((e) => String(e.number) === epNum);
      const epTitle = episodeTitleMap?.[parseInt(epNum)] || ep?.title;
      await mediaApi.play(mediaId, parseInt(epNum, 10), selectedProvider, serverName, mediaTitle, epTitle, coverImage, episodes.length);
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
      await mediaApi.addToQueue(mediaId, [parseInt(epNum, 10)], mediaTitle, coverImage);
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
          {episodes.map((ep, idx) => {
            const epNum = String(ep.number);
            const isWatched = Number(ep.number) <= progress;
            const isNext = Number(ep.number) === progress + 1;
            const nextAiringSecs = typeof nextAiringTime === "string" 
              ? new Date(nextAiringTime).getTime() / 1000 
              : Number(nextAiringTime);
            const hasAired = !isNaN(nextAiringSecs) && (Date.now() / 1000) > nextAiringSecs;
            const isUnaired = !isManga && nextAiringEpisode !== undefined && Number(ep.number) >= nextAiringEpisode && !hasAired;
            
            return (
              <div key={`${epNum}-${idx}`} className="space-y-1.5">
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
                      {ep.title && !/^(episode|watch episode|chapter)\s+\d+$/i.test(ep.title) ? ep.title : episodeTitleMap?.[Number(ep.number)] || (isManga ? `Chapter ${epNum}` : `Episode ${epNum}`)}
                      {((fillerEpisodes && (
                        Array.isArray(fillerEpisodes)
                          ? fillerEpisodes.includes(Number(ep.number))
                          : typeof fillerEpisodes.has === "function"
                          ? fillerEpisodes.has(Number(ep.number))
                          : false
                      ))) && (
                        <span className="ml-2 px-1.5 py-0.5 rounded text-[9px] font-bold bg-yellow-500/15 text-yellow-400 border border-yellow-500/20">Filler</span>
                      )}
                    </span>
                  </div>
                  {statusIcon(localDownloadStatus[epNum] || ep.download_status)}
                </div>

                {!isUnaired ? (
                  <div className="flex items-center space-x-1.5 shrink-0">
                    {/* Always visible (not hover-gated like the actions below) —
                        this is the only way to reach the multi-source picker, and
                        it being hidden behind hover made it easy to never notice
                        a provider had more than one stream to choose from. */}
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
                            : "bg-foreground/[0.04] text-muted-foreground hover:bg-accent/15 hover:text-accent"
                        }`}
                      >
                        {loadingStreamsEp === epNum ? (
                          <Loader2 size={16} className="animate-spin text-accent" />
                        ) : (
                          <Video size={16} />
                        )}
                      </button>
                    )}
                    <div className="flex items-center space-x-1.5 opacity-0 group-hover:opacity-100 transition-opacity">
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
                     {isWatched ? (
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
                     ) : (
                       <button
                         onClick={(e) => {
                           e.stopPropagation();
                           if (onWatch) onWatch(epNum);
                         }}
                         title={isManga ? "Mark as read" : "Mark as watched"}
                         className="flex items-center justify-center w-9 h-9 bg-foreground/[0.04] text-muted-foreground rounded-xl hover:bg-green-500/20 hover:text-green-400 transition-all active:scale-90"
                       >
                         <Check size={16} />
                       </button>
                     )}
                    </div>
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
                      {(["hard_sub", "soft_sub", "dub"] as const)
                        .filter(mode => resolvedStreams.length === 0 || resolvedStreams.some(s => getStreamGroupFromServer(s) === mode))
                        .map((mode) => (
                        <button
                          key={mode}
                          onClick={(e) => {
                            e.stopPropagation();
                            setStreamFilter(streamFilter === mode ? null : mode);
                          }}
                          className={`px-2 py-1 rounded transition-all capitalize ${
                            streamFilter === mode
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
                  ) : getSortedStreams(resolvedStreams).length === 0 ? (
                    <div className="text-muted-foreground py-1 text-[11px]">
                      No {streamFilter ? streamFilter.replace("_", " ") + " " : ""}streams found.
                    </div>
                  ) : (
                    <div className="grid grid-cols-1 sm:grid-cols-2 gap-2">
                      {getSortedStreams(resolvedStreams).map((s, idx) => {
                        const isCurrentLoading = loadingServer === `${epNum}-${s.name}`;
                        const isAnyLoading = loadingServer !== null || playingEp !== null;
                        
                        return (
                          <button
                            key={`${s.name}-${idx}`}
                            disabled={isAnyLoading}
                            onClick={() => handlePlaySpecificStream(epNum, s.name)}
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
                                {(s.name || "").trim()}
                              </div>
                              <div className="text-[9px] text-gray-500 mt-0.5">
                                {getStreamGroupFromServer(s).replace(/_/g, " ")} &bull; {s.quality || "HD"}
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
