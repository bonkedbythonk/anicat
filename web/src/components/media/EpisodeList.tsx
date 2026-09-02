
import { useState, useEffect, useRef, useMemo, type ReactNode } from "react";
import { Play, Download, Loader2, Clock, AlertCircle, BookOpen, XCircle, RefreshCw, Video, Check, HardDriveDownload, Zap, Search, X, Copy, CheckCheck } from "lucide-react";
import { listen } from "@tauri-apps/api/event";
import { mediaApi, type Episode, type StreamServer } from "@/lib/api";
import { useSettingsStore, useAppStore } from "@/stores/app";
import { dispatchRefresh } from "@/lib/events";
import { formatTime, formatEpisodeAirDate } from "@/lib/date";
import { isCinemaId } from "@/lib/mediaId";
import { FocusScope, ScopeNav, useFocusable } from "@/focus";

/** How long a row has to hold the pointer or the keyboard focus before it is
 *  worth speculatively preloading. Each preload is a real indexer search plus
 *  a swarm handshake, and nyaa throttles hard: four concurrent queries answer
 *  200, eight return two 429s, twelve return six. A throttled query silently
 *  comes back with a smaller candidate pool, which degrades the pick for every
 *  later play — so without the delay a mouse sweeping down a 12-episode list
 *  fires twelve resolves and makes the app slower rather than faster. */
const SPECULATIVE_PRELOAD_DELAY_MS = 400;

/** How long an unanswered speculative preload keeps the single-flight latch
 *  shut. The latch is normally released by the backend's
 *  `stream_preload_status` event landing in the store, but Low Data Mode drops
 *  a torrent preload with an early `Ok` and emits nothing at all — with no
 *  expiry the first hover in that mode would wedge speculation off for the
 *  rest of the session. */
const SPECULATIVE_PRELOAD_MAX_WAIT_MS = 30_000;

function FocusableButton({ disabled, children, ...props }: React.ButtonHTMLAttributes<HTMLButtonElement>) {
  const { ref, tabIndex } = useFocusable<HTMLButtonElement>({ disabled });
  return <button ref={ref} tabIndex={disabled ? -1 : tabIndex} disabled={disabled} {...props}>{children}</button>;
}

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
  episodeThumbMap?: Record<number, string>;
  episodeOverviewMap?: Record<number, string>;
  episodeAirDateMap?: Record<number, string>;
  episodeRuntimeMap?: Record<number, number>;
  resumeSeconds?: number;
  fillerEpisodes?: number[] | Set<number>;
  translationType?: "sub" | "dub";
  viewMode?: "cards" | "compact";
  onViewModeChange?: (mode: "cards" | "compact") => void;
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
  episodeThumbMap,
  episodeOverviewMap,
  episodeAirDateMap,
  episodeRuntimeMap,
  resumeSeconds,
  fillerEpisodes,
  translationType: propTranslationType,
  viewMode: propViewMode,
  onViewModeChange,
}: EpisodeListProps) {
  const globalTranslationType = useSettingsStore((s) => s.translationType);
  const translationType = propTranslationType || globalTranslationType;
  const dataSaver = useSettingsStore((s) => s.dataSaver);
  const preloadStatus = useAppStore((s) => s.preloadStatus);

  const [internalViewMode, setInternalViewMode] = useState<"cards" | "compact">(() => {
    if (typeof window === "undefined") return "cards";
    return (localStorage.getItem("anicat_episode_view_mode") as "cards" | "compact") || "cards";
  });
  const viewMode = propViewMode || internalViewMode;
  const handleSetViewMode = (mode: "cards" | "compact") => {
    if (onViewModeChange) {
      onViewModeChange(mode);
    } else {
      setInternalViewMode(mode);
      localStorage.setItem("anicat_episode_view_mode", mode);
    }
  };

  const CHUNK_SIZE = 50;
  const showChunks = episodes.length > 35;

  const chunks = useMemo(() => {
    if (!showChunks) return [];
    const list: { start: number; end: number; label: string }[] = [];
    const maxEp = Math.max(...episodes.map((e) => Number(e.number) || 0), episodes.length);
    for (let i = 1; i <= maxEp; i += CHUNK_SIZE) {
      const end = Math.min(i + CHUNK_SIZE - 1, maxEp);
      list.push({ start: i, end, label: `${i}–${end}` });
    }
    return list;
  }, [episodes, showChunks]);

  const defaultChunkIndex = useMemo(() => {
    if (!showChunks || chunks.length === 0) return 0;
    const target = progress + 1;
    const idx = chunks.findIndex((c) => target >= c.start && target <= c.end);
    return idx >= 0 ? idx : 0;
  }, [chunks, progress, showChunks]);

  const [selectedChunkIndex, setSelectedChunkIndex] = useState<number>(defaultChunkIndex);
  const [searchQuery, setSearchQuery] = useState<string>("");
  const [isSearchOpen, setIsSearchOpen] = useState<boolean>(false);

  useEffect(() => {
    setSelectedChunkIndex(defaultChunkIndex);
  }, [defaultChunkIndex]);

  const displayedEpisodes = useMemo(() => {
    const q = searchQuery.trim().toLowerCase();
    if (q) {
      return episodes.filter((ep) => {
        const num = String(ep.number);
        const title = (ep.title || episodeTitleMap?.[Number(ep.number)] || "").toLowerCase();
        return num === q || num.includes(q) || title.includes(q);
      });
    }
    if (!showChunks || chunks.length === 0) return episodes;
    const currentChunk = chunks[selectedChunkIndex] || chunks[0];
    return episodes.filter((ep) => {
      const num = Number(ep.number);
      return num >= currentChunk.start && num <= currentChunk.end;
    });
  }, [episodes, searchQuery, showChunks, chunks, selectedChunkIndex, episodeTitleMap]);

  const [playingEp, setPlayingEp] = useState<string | null>(null);
  const [queueingEp, setQueueingEp] = useState<string | null>(null);
  const [localDownloadStatus, setLocalDownloadStatus] = useState<Record<string, string>>({});
  const [retrying, setRetrying] = useState(false);
  // Stale TVDB/Crunchyroll URLs fall back to the plain number badge.
  const [brokenThumbs, setBrokenThumbs] = useState<Set<number>>(new Set());

  const [expandedEpStreams, setExpandedEpStreams] = useState<string | null>(null);
  const [loadingStreamsEp, setLoadingStreamsEp] = useState<string | null>(null);
  const [resolvedStreams, setResolvedStreams] = useState<any[]>([]);
  const [streamsError, setStreamsError] = useState<string | null>(null);
  const [streamFilter, setStreamFilter] = useState<"hard_sub" | "soft_sub" | "dub" | null>(
    translationType === "dub" ? "dub" : null
  );
  const [loadingServer, setLoadingServer] = useState<string | null>(null);

  const [contextMenu, setContextMenu] = useState<{
    x: number;
    y: number;
    epNum: string;
    isWatched: boolean;
    isUnaired: boolean;
    epTitle: string;
  } | null>(null);

  useEffect(() => {
    if (!contextMenu) return;
    const handleClose = () => setContextMenu(null);
    const handleKeyDown = (e: KeyboardEvent) => {
      if (e.key === "Escape") setContextMenu(null);
    };
    window.addEventListener("click", handleClose);
    window.addEventListener("contextmenu", handleClose);
    window.addEventListener("keydown", handleKeyDown);
    return () => {
      window.removeEventListener("click", handleClose);
      window.removeEventListener("contextmenu", handleClose);
      window.removeEventListener("keydown", handleKeyDown);
    };
  }, [contextMenu]);

  useEffect(() => {
    setStreamFilter(translationType === "dub" ? "dub" : null);
  }, [translationType]);

  useEffect(() => {
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

  // Re-fetch expanded stream servers immediately when selectedProvider changes
  useEffect(() => {
    if (!expandedEpStreams) return;

    let isMounted = true;
    const currentEp = expandedEpStreams;

    const refreshStreams = async () => {
      setLoadingStreamsEp(currentEp);
      setStreamsError(null);
      setResolvedStreams([]);

      try {
        const data = await mediaApi.getStreams(mediaId, parseInt(currentEp, 10), selectedProvider) as { streams?: StreamServer[] };
        if (isMounted) {
          setResolvedStreams(data.streams || []);
        }
      } catch (err: unknown) {
        if (isMounted) {
          console.error("Failed to load stream servers:", err);
          setStreamsError((err as Error)?.message || "Couldn't load stream servers. Try another provider.");
        }
      } finally {
        if (isMounted) {
          setLoadingStreamsEp(null);
        }
      }
    };

    refreshStreams();

    return () => {
      isMounted = false;
    };
  }, [selectedProvider, expandedEpStreams, mediaId]);

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
    if (status === "completed") return <HardDriveDownload size={16} className="text-accent shrink-0" />;
    if (status === "downloading") return <Loader2 size={16} className="animate-spin text-accent shrink-0" />;
    if (status === "queued") return <Clock size={16} className="text-warning-light shrink-0" />;
    if (status === "failed") return <AlertCircle size={16} className="text-danger-light shrink-0" />;
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
    
    // Filter by stream group (sub vs dub)
    if (streamFilter) {
      filtered = filtered.filter(s => getStreamGroupFromServer(s) === streamFilter);
    } else if (translationType !== "dub" && streams.some(s => getStreamGroupFromServer(s) !== "dub")) {
      // If user prefers Sub, filter out Dub streams when Sub streams exist
      filtered = filtered.filter(s => getStreamGroupFromServer(s) !== "dub");
    }

    // Filter by resolution preference (1080p vs 720p)
    if (!dataSaver && filtered.some(s => (s.quality || "").includes("1080"))) {
      // Non Low Data Mode: if 1080p exists, hide 720p, 480p, 360p
      filtered = filtered.filter(s => !(s.quality || "").includes("720") && !(s.quality || "").includes("480") && !(s.quality || "").includes("360"));
    } else if (dataSaver && filtered.some(s => (s.quality || "").includes("720"))) {
      // Low Data Mode: if 720p exists, hide 1080p
      filtered = filtered.filter(s => !(s.quality || "").includes("1080"));
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

  // MediaDetail already preloads the Continue episode when the page opens.
  // This covers the other half: picking any *other* row, which is otherwise a
  // fully cold resolve at click time. Intent is read from hover and from
  // keyboard focus — spatial navigation moves by calling `.focus()` on the
  // target (`useSpatialNavigation`), so a focusin listener on the row catches
  // both without the row having to reach into the focus scope.
  const preloadTimer = useRef<ReturnType<typeof setTimeout> | null>(null);
  const speculativePreload = useRef<{ key: string; at: number } | null>(null);

  const cancelSpeculativePreload = () => {
    if (preloadTimer.current !== null) {
      clearTimeout(preloadTimer.current);
      preloadTimer.current = null;
    }
  };

  // A pending timer closes over the mediaId it was armed with, and the detail
  // page swaps entries in place when a related title is opened. Without this,
  // a hover that was still settling when the user jumped to a sequel fires a
  // resolve against the show they just left.
  useEffect(() => cancelSpeculativePreload, [mediaId]);

  const scheduleSpeculativePreload = (epNum: string) => {
    // Manga reads through its own path and never resolves a stream. Cinema ids
    // must not reach this at all: a torrent resolve aimed at a film starts real
    // provider work for a title the anime indexes will never have (see the
    // header comment on CinemaDetail). Cinema renders its own episode list
    // today, so this is a belt on top of that separation, not the only one.
    if (isManga || !selectedProvider || isCinemaId(mediaId)) return;

    const episodeNumber = parseInt(epNum, 10);
    if (!Number.isFinite(episodeNumber)) return;

    cancelSpeculativePreload();
    preloadTimer.current = setTimeout(() => {
      preloadTimer.current = null;

      const statuses = useAppStore.getState().preloadStatus;
      const key = `${mediaId}-${episodeNumber}`;
      if (statuses[key] === "fetching" || statuses[key] === "ready") return;

      // One speculative resolve outstanding at a time, so a walk down the list
      // cannot stack queries against the throttle. `undefined` counts as still
      // outstanding rather than as finished: the backend answers through the
      // `stream_preload_status` event, which has not arrived yet in the moment
      // right after the request goes out.
      const outstanding = speculativePreload.current;
      if (
        outstanding &&
        Date.now() - outstanding.at < SPECULATIVE_PRELOAD_MAX_WAIT_MS &&
        statuses[outstanding.key] !== "ready" &&
        statuses[outstanding.key] !== "idle"
      ) {
        return;
      }

      speculativePreload.current = { key, at: Date.now() };
      // Flagged speculative: the backend holds one preloaded stream, and a
      // hover must not take it from the Continue episode the detail page
      // warmed on open. A refused one still leaves the show warm -- the
      // torrent manager caches the resolution either way -- and the refusal
      // comes back as an `idle` event, which is what releases the latch above.
      mediaApi
        .preloadEpisode(mediaId, episodeNumber, selectedProvider, mediaTitle, true)
        .catch(() => {
          speculativePreload.current = null;
        });
    }, SPECULATIVE_PRELOAD_DELAY_MS);
  };

  const handlePlay = async (epNum: string) => {
    if (isManga && onRead) {
      onRead(epNum);
      return;
    }

    const ep = episodes.find((e) => String(e.number) === epNum);
    const epTitle = episodeTitleMap?.[parseInt(epNum)] || ep?.title;
    const playerType = useSettingsStore.getState().playerType;

    if (playerType === "builtin") {
      useAppStore.getState().openPlayer({
        mediaId,
        episodeNumber: parseInt(epNum, 10),
        provider: selectedProvider,
        title: mediaTitle,
        episodeTitle: epTitle,
        coverImage,
        totalEpisodes: episodes.length,
      });
      return;
    }

    setPlayingEp(epNum);

    useAppStore.getState().setPlaybackLoading({
      isLoading: true,
      mediaId: mediaId,
      episodeNumber: parseInt(epNum, 10),
      title: mediaTitle,
      coverImage: coverImage,
      statusText: "Starting...",
      step: selectedProvider === "nyaa" ? 2 : 1,
    });

    try {
      await mediaApi.play(mediaId, parseInt(epNum, 10), selectedProvider, undefined, mediaTitle, epTitle, coverImage, episodes.length);
      dispatchRefresh();
    } catch (error) {
      console.error("Failed to play:", error);
      useAppStore.getState().setPlaybackLoading({
        isLoading: true,
        statusText: typeof error === "string" ? error : "Couldn't start playback.",
        step: 0,
      });
    } finally {
      setPlayingEp(null);
    }
  };

  const toggleStreams = (epNum: string) => {
    // Fetching is handled by the effect above, which reacts to
    // expandedEpStreams changing. Fetching here too used to fire a second,
    // concurrent request on every open — the two responses could land in
    // either order and briefly render duplicated/flickering server rows.
    setExpandedEpStreams(expandedEpStreams === epNum ? null : epNum);
  };

  const handlePlaySpecificStream = async (epNum: string, serverName: string) => {
    const ep = episodes.find((e) => String(e.number) === epNum);
    const epTitle = episodeTitleMap?.[parseInt(epNum)] || ep?.title;
    const playerType = useSettingsStore.getState().playerType;

    if (playerType === "builtin") {
      useAppStore.getState().openPlayer({
        mediaId,
        episodeNumber: parseInt(epNum, 10),
        provider: selectedProvider,
        server: serverName,
        title: mediaTitle,
        episodeTitle: epTitle,
        coverImage,
        totalEpisodes: episodes.length,
      });
      return;
    }

    const serverKey = `${epNum}-${serverName}`;
    setLoadingServer(serverKey);
    setPlayingEp(epNum);

    useAppStore.getState().setPlaybackLoading({
      isLoading: true,
      mediaId: mediaId,
      episodeNumber: parseInt(epNum, 10),
      title: mediaTitle,
      coverImage: coverImage,
      statusText: "Starting...",
      step: selectedProvider === "nyaa" ? 2 : 1,
    });

    try {
      await mediaApi.play(mediaId, parseInt(epNum, 10), selectedProvider, serverName, mediaTitle, epTitle, coverImage, episodes.length);
      dispatchRefresh();
    } catch (error: any) {
      console.error("Failed to play stream:", error);
      useAppStore.getState().setPlaybackLoading({
        isLoading: true,
        statusText: typeof error === "string" ? error : "Couldn't start playback.",
        step: 0,
      });
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
    <div className="space-y-3">
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
        <div className="space-y-3">
          {/* Range chunk selector & Quick collapsible episode jump/search (only for 35+ episode shows) */}
          {showChunks && (
            <div className="flex items-center justify-between gap-2 pb-1.5">
              <div className="flex items-center gap-1.5 overflow-x-auto scrollbar-hide py-0.5 max-w-full">
                {chunks.map((chunk, idx) => {
                  const isSelected = selectedChunkIndex === idx && !searchQuery.trim();
                  const hasNext = (progress + 1) >= chunk.start && (progress + 1) <= chunk.end;
                  return (
                    <button
                      key={chunk.label}
                      onClick={() => {
                        setSelectedChunkIndex(idx);
                        setSearchQuery("");
                        setIsSearchOpen(false);
                      }}
                      className={`font-mono text-[11px] font-semibold px-2.5 py-1 rounded-md border transition-all shrink-0 cursor-pointer ${
                        isSelected
                          ? "bg-accent text-background border-accent shadow-xs"
                          : "bg-surface border-border text-muted-foreground hover:text-foreground hover:border-foreground/20"
                      }`}
                    >
                      <span>{chunk.label}</span>
                      {hasNext && !isSelected && (
                        <span className="inline-block w-1.5 h-1.5 rounded-full bg-accent ml-1.5 mb-0.5" />
                      )}
                    </button>
                  );
                })}
              </div>

              <div className="shrink-0">
                {isSearchOpen || searchQuery ? (
                  <div className="relative flex items-center w-36 sm:w-44 animate-fade-in">
                    <Search size={12} className="absolute left-2.5 text-muted-foreground pointer-events-none" />
                    <input
                      type="text"
                      autoFocus
                      value={searchQuery}
                      onChange={(e) => setSearchQuery(e.target.value)}
                      placeholder={isManga ? "Jump to ch..." : "Jump to ep..."}
                      className="w-full pl-7 pr-6 py-1 rounded-md bg-surface border border-border text-xs text-foreground placeholder:text-muted-foreground/60 outline-none focus:border-accent/60 transition-colors"
                      onKeyDown={(e) => {
                        if (e.key === "Escape") {
                          setSearchQuery("");
                          setIsSearchOpen(false);
                        }
                      }}
                    />
                    <button
                      onClick={() => {
                        setSearchQuery("");
                        setIsSearchOpen(false);
                      }}
                      className="absolute right-1 text-muted-foreground hover:text-foreground p-0.5 cursor-pointer"
                      title="Close search"
                    >
                      <X size={12} />
                    </button>
                  </div>
                ) : (
                  <button
                    onClick={() => setIsSearchOpen(true)}
                    title={isManga ? "Jump to chapter" : "Jump to episode"}
                    className="px-2 py-1 rounded-md border border-border bg-surface text-muted-foreground hover:text-foreground hover:border-foreground/20 transition-all flex items-center gap-1.5 text-[11px] font-medium cursor-pointer"
                  >
                    <Search size={11} />
                    <span className="font-mono text-[10.5px]">Jump</span>
                  </button>
                )}
              </div>
            </div>
          )}

          {/* When searching and no matches found */}
          {searchQuery.trim() && displayedEpisodes.length === 0 ? (
            <div className="py-16 text-center text-sm text-muted-foreground space-y-2">
              <p>No {isManga ? "chapters" : "episodes"} matching &ldquo;{searchQuery}&rdquo;.</p>
              <button
                onClick={() => {
                  setSearchQuery("");
                  setIsSearchOpen(false);
                }}
                className="text-xs text-accent font-semibold hover:underline"
              >
                Clear search
              </button>
            </div>
          ) : (
            <div className="space-y-2">
              {displayedEpisodes.map((ep, idx) => {
            const epNum = ep.number.toString();
            const isWatched = Number(ep.number) <= progress;
            const isNext = epNum === (progress + 1).toString();
            const isUnaired = !isManga && nextAiringEpisode !== undefined && Number(ep.number) >= nextAiringEpisode;
            const epTitle = isManga
              ? (ep.title && !/^(episode|chapter)\s+\d+$/i.test(ep.title) ? ep.title : `Chapter ${epNum}`)
              : (episodeTitleMap?.[Number(ep.number)] || ep.title || `Episode ${epNum}`);
            const airDate = isManga ? undefined : episodeAirDateMap?.[Number(ep.number)];
            const overview = isManga ? undefined : episodeOverviewMap?.[Number(ep.number)];
            const runtimeMin = isManga ? 0 : (episodeRuntimeMap?.[Number(ep.number)] || 24);

            return (
              <div key={`${epNum}-${idx}`} className="space-y-1.5">
                <FocusScope
                  name={`ep-${epNum}`}
                  orientation="horizontal"
                  className="space-y-1.5"
                >
                <ScopeNav />
                <div
                  onMouseEnter={() => { if (!isUnaired) scheduleSpeculativePreload(epNum); }}
                  onMouseLeave={cancelSpeculativePreload}
                  onFocus={() => { if (!isUnaired) scheduleSpeculativePreload(epNum); }}
                  onBlur={cancelSpeculativePreload}
                  onContextMenu={(e) => {
                    e.preventDefault();
                    setContextMenu({
                      x: Math.min(e.clientX, window.innerWidth - 220),
                      y: Math.min(e.clientY, window.innerHeight - 260),
                      epNum,
                      isWatched,
                      isUnaired: Boolean(isUnaired),
                      epTitle,
                    });
                  }}
                  className={`flex items-center justify-between transition-all group episode-row-item ${
                    isManga ? "p-2.5 rounded-lg" : viewMode === "cards" ? "p-3 rounded-xl" : "p-2 rounded-lg"
                  } ${
                    isNext && !isUnaired
                      ? 'bg-accent/10 border border-accent/40 shadow-md'
                      : isWatched
                      ? 'opacity-55 hover:opacity-90 hover:bg-foreground/[0.04] border border-border/40'
                      : 'bg-foreground/[0.02] border border-border hover:bg-foreground/[0.06] hover:border-border/60'
                  }`}
                >
                <FocusableButton
                  disabled={isUnaired}
                  onClick={() => handlePlay(epNum)}
                  className={`flex items-center gap-3.5 min-w-0 flex-1 text-left ${!isUnaired ? 'cursor-pointer' : ''}`}
                >
                  {isManga ? (
                    <>
                      <span className={`w-8 h-8 rounded-md font-mono text-[11px] flex items-center justify-center font-bold shrink-0 transition-colors ${
                        isNext ? "bg-accent text-background shadow-xs" :
                        isWatched ? "bg-accent/15 text-accent" :
                        "bg-foreground/[0.07] text-muted-foreground group-hover:bg-accent group-hover:text-background"
                      }`}>
                        {playingEp === epNum ? <Loader2 size={13} className="animate-spin" /> : epNum}
                      </span>
                      <div className="flex-1 min-w-0">
                        <div className="flex items-center gap-2">
                          <span className={`text-[13px] font-semibold truncate ${
                            isNext ? "text-foreground font-bold" :
                            isWatched ? "text-muted-foreground/60" : "text-foreground/90 group-hover:text-foreground"
                          }`}>
                            {epTitle}
                          </span>
                          {isNext && (
                            <span className="font-mono text-[9px] uppercase tracking-wider text-accent font-semibold px-1.5 py-0.5 rounded bg-accent/10 shrink-0">
                              Up Next
                            </span>
                          )}
                        </div>
                      </div>
                    </>
                  ) : viewMode === "compact" ? (
                    <>
                      <span className={`w-7 h-7 rounded font-mono text-[11px] flex items-center justify-center font-bold shrink-0 ${
                        isNext && !isUnaired ? "bg-accent text-background shadow-xs" :
                        isWatched ? "bg-foreground/5 text-muted-foreground/50" :
                        "bg-foreground/[0.07] text-muted-foreground group-hover:bg-accent group-hover:text-background transition-colors"
                      }`}>
                        {playingEp === epNum ? <Loader2 size={12} className="animate-spin" /> : epNum}
                      </span>
                      <span className={`text-[12.5px] font-medium truncate flex-1 ${
                        isNext && !isUnaired ? "text-foreground font-semibold" :
                        isWatched ? "text-muted-foreground/60" : "text-foreground/90 group-hover:text-foreground"
                      }`}>
                        {epTitle}
                      </span>
                      {isNext && resumeSeconds && resumeSeconds > 0 ? (
                        <span className="font-mono text-[10px] text-accent shrink-0 font-medium">
                          Resume {formatTime(resumeSeconds)}
                        </span>
                      ) : null}
                      {runtimeMin > 0 && (
                        <span className="font-mono text-[10px] text-muted-foreground/60 shrink-0">
                          {runtimeMin}m
                        </span>
                      )}
                    </>
                  ) : (
                    <>
                      <div className="relative w-28 sm:w-32 aspect-video shrink-0 rounded-lg overflow-hidden bg-foreground/5 transition-all border border-border/40">
                        {!isManga && !dataSaver && episodeThumbMap?.[Number(ep.number)] && !brokenThumbs.has(Number(ep.number)) ? (
                          <img
                            src={episodeThumbMap[Number(ep.number)]}
                            alt=""
                            loading="lazy"
                            onError={() => setBrokenThumbs((prev) => new Set(prev).add(Number(ep.number)))}
                            className={`w-full h-full object-cover group-hover:scale-105 transition-transform duration-300 ${
                              isWatched ? "opacity-50 group-hover:opacity-75" : ""
                            }`}
                          />
                        ) : (
                          <div className="w-full h-full flex items-center justify-center font-mono text-xs font-bold text-muted-foreground/40">
                            {epNum}
                          </div>
                        )}
                        <div className="absolute inset-0 bg-black/40 opacity-0 group-hover:opacity-100 transition-opacity flex items-center justify-center">
                          {playingEp === epNum ? (
                            <Loader2 size={16} className="animate-spin text-white" />
                          ) : (
                            <div className="w-7 h-7 rounded-full bg-accent flex items-center justify-center pl-0.5 text-background font-bold shadow-md">
                              <Play size={10} fill="currentColor" />
                            </div>
                          )}
                        </div>
                        {isWatched && (
                          <span className="absolute top-1 left-1 w-4 h-4 rounded-full bg-accent flex items-center justify-center text-background font-bold text-[9px] shadow-xs">
                            ✓
                          </span>
                        )}
                        {runtimeMin > 0 && (
                          <span className="absolute bottom-1 right-1 px-1 rounded bg-black/80 font-mono text-[9px] text-[#ccc]">
                            {runtimeMin}m
                          </span>
                        )}
                        {isWatched ? (
                          <div className="absolute bottom-0 left-0 right-0 h-[2.5px] bg-accent" />
                        ) : isNext && resumeSeconds && resumeSeconds > 0 ? (
                          <div className="absolute bottom-0 left-0 right-0 h-[2.5px] bg-foreground/20">
                            <div className="h-full bg-accent" style={{ width: `${Math.min(100, Math.max(10, (resumeSeconds / (runtimeMin * 60)) * 100))}%` }} />
                          </div>
                        ) : null}
                      </div>

                      <div className="flex flex-col min-w-0 pr-4 flex-1">
                        <div className="flex items-center gap-1.5 font-mono text-[10px] uppercase tracking-wider text-muted-foreground">
                          <span className={isNext && !isUnaired ? "text-accent font-bold" : "text-accent font-semibold"}>
                            {isManga ? `CH ${epNum}` : `EP ${epNum}`}
                          </span>
                          {airDate && (
                            <>
                              <span className="text-muted-foreground/40">·</span>
                              <span>{formatEpisodeAirDate(airDate)}</span>
                            </>
                          )}
                          {isNext && resumeSeconds && resumeSeconds > 0 ? (
                            <>
                              <span className="text-muted-foreground/40">·</span>
                              <span className="text-accent font-medium">Resume {formatTime(resumeSeconds)}</span>
                            </>
                          ) : null}
                        </div>

                        <h4 className={`text-[13.5px] font-semibold truncate transition-colors mt-0.5 ${
                          isWatched ? "text-muted-foreground" :
                          isNext ? "text-foreground group-hover:text-accent font-bold" :
                          "text-foreground/90 group-hover:text-foreground"
                        }`}>
                          {epTitle}
                        </h4>

                        {overview && (
                          <p className="text-[11.5px] text-muted-foreground/70 line-clamp-1 mt-0.5 font-normal leading-relaxed">
                            {overview}
                          </p>
                        )}
                      </div>
                    </>
                  )}
                  {!isManga && statusIcon(localDownloadStatus[epNum] || ep.download_status)}
                </FocusableButton>
                
                {!isUnaired ? (
                  <div className="flex items-center gap-0.5 shrink-0 opacity-0 group-hover:opacity-100 group-focus-within:opacity-100 transition-opacity">
                    {!isManga && (
                      <FocusableButton
                        onClick={(e) => {
                          e.stopPropagation();
                          toggleStreams(epNum);
                        }}
                        title="Stream Servers"
                        className={`p-2 rounded-lg transition-all active:scale-90 cursor-pointer ${
                          expandedEpStreams === epNum
                            ? "bg-accent/20 text-accent"
                            : "text-muted-foreground/50 hover:text-foreground hover:bg-foreground/[0.06]"
                        }`}
                      >
                        {loadingStreamsEp === epNum ? (
                          <Loader2 size={15} className="animate-spin text-accent" />
                        ) : (
                          <Video size={15} />
                        )}
                      </FocusableButton>
                    )}
                    <FocusableButton
                      onClick={(e) => {
                        e.stopPropagation();
                        handleQueue(epNum);
                      }}
                      disabled={queueingEp === epNum || (localDownloadStatus[epNum] || ep.download_status) === "completed"}
                      title="Download Episode"
                      className="p-2 rounded-lg text-muted-foreground/50 hover:text-foreground hover:bg-foreground/[0.06] transition-all disabled:opacity-30 active:scale-90 cursor-pointer"
                    >
                      {queueingEp === epNum ? (
                        <Loader2 size={15} className="animate-spin text-accent" />
                      ) : (
                        <Download size={15} />
                      )}
                    </FocusableButton>
                    <FocusableButton
                      onClick={(e) => {
                        e.stopPropagation();
                        if (isWatched) {
                          if (onUnwatch) onUnwatch(epNum);
                        } else {
                          if (onWatch) onWatch(epNum);
                        }
                      }}
                      title={isWatched ? (isManga ? "Mark as unread" : "Mark as unwatched") : (isManga ? "Mark as read" : "Mark as watched")}
                      className={`p-2 rounded-lg transition-all active:scale-90 cursor-pointer ${
                        isWatched
                          ? "text-muted-foreground/50 hover:text-danger hover:bg-danger/10"
                          : "text-muted-foreground/50 hover:text-accent hover:bg-accent/10"
                      }`}
                    >
                      {isWatched ? <XCircle size={15} /> : <Check size={15} />}
                    </FocusableButton>
                  </div>
                ) : (
                  <span className="text-[10px] font-mono uppercase tracking-wider text-muted-foreground/60 px-2.5 py-1 bg-foreground/[0.03] border border-border/40 rounded-md shrink-0">
                    Airing Soon
                  </span>
                )}
                </div>
              </FocusScope>

              {expandedEpStreams === epNum && (
                <div className="ml-15 p-4 rounded-2xl bg-foreground/[0.02] border border-border space-y-3 animate-fade-in text-xs" onClick={(e) => e.stopPropagation()}>
                  <div className="flex flex-col sm:flex-row sm:items-center sm:justify-between border-b border-border/10 pb-2 mb-2 gap-2">
                    <div className="text-[10px] font-black text-accent uppercase tracking-[0.2em]">Available Stream Servers</div>
                    <div className="flex items-center space-x-1 bg-foreground/[0.03] p-0.5 rounded-lg border border-border/40 text-[9px] font-bold self-start sm:self-auto">
                      {(["hard_sub", "soft_sub", "dub"] as const)
                        .filter(mode => resolvedStreams.length === 0 || resolvedStreams.some(s => getStreamGroupFromServer(s) === mode))
                        .map((mode) => (
                        <FocusableButton
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
                        </FocusableButton>
                      ))}
                    </div>
                  </div>
                  {loadingStreamsEp === epNum ? (
                    <div className="flex items-center space-x-2 py-3 text-muted-foreground text-[11px]">
                      <Loader2 size={12} className="animate-spin text-accent" />
                      <span>Fetching stream servers...</span>
                    </div>
                  ) : streamsError ? (
                    <div className="text-danger-light py-1 text-[11px] font-medium">{streamsError}</div>
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
                          <FocusableButton
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
                              {/* Torrent release names are long and differ only near the
                                  end (source/codec/CRC) — a single-line truncate clipped
                                  exactly that part, making genuinely different releases
                                  look like duplicates. Wrap instead so the whole name (and
                                  what actually distinguishes it) stays visible. */}
                              <div className={`font-bold text-[11px] line-clamp-2 break-words ${
                                isCurrentLoading ? "text-accent" : "text-gray-200 group-hover/btn:text-white"
                              }`}>
                                {(s.name || "").trim()}
                              </div>
                              <div className="text-[9px] text-gray-500 mt-0.5">
                                {getStreamGroupFromServer(s).replace(/_/g, " ")} &bull; {s.quality || "HD"}
                                {typeof s.seeders === "number" && <> &bull; {s.seeders} seeders</>}
                              </div>
                            </div>
                            {isCurrentLoading ? (
                              <Loader2 size={12} className="animate-spin text-accent shrink-0" />
                            ) : (
                              <Play size={12} className="text-muted-foreground group-hover/btn:text-accent group-hover/btn:scale-110 transition-all shrink-0" fill="currentColor" />
                            )}
                          </FocusableButton>
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
  )}

  {/* Episode Right-Click Context Menu */}
  {contextMenu && (
    <div
      style={{ top: `${contextMenu.y}px`, left: `${contextMenu.x}px` }}
      className="fixed z-[999] min-w-[210px] bg-surface/95 backdrop-blur-md rounded-xl border border-border shadow-2xl p-1.5 animate-scale-in text-xs font-medium space-y-0.5"
      onClick={(e) => e.stopPropagation()}
    >
      <div className="px-2.5 py-1 text-[10px] font-mono text-muted-foreground font-semibold border-b border-border/50 pb-1 mb-1 truncate">
        {isManga ? `Chapter ${contextMenu.epNum}` : `Episode ${contextMenu.epNum}`}
      </div>

      {!contextMenu.isUnaired && (
        <button
          onClick={() => {
            handlePlay(contextMenu.epNum);
            setContextMenu(null);
          }}
          className="w-full flex items-center gap-2.5 px-2.5 py-1.5 rounded-lg text-foreground hover:bg-accent hover:text-background transition-colors text-left cursor-pointer"
        >
          <Play size={13} fill="currentColor" />
          <span>{isManga ? "Read Chapter" : "Play Episode"}</span>
        </button>
      )}

      {!isManga && !contextMenu.isUnaired && (
        <button
          onClick={() => {
            toggleStreams(contextMenu.epNum);
            setContextMenu(null);
          }}
          className="w-full flex items-center gap-2.5 px-2.5 py-1.5 rounded-lg text-foreground hover:bg-foreground/10 transition-colors text-left cursor-pointer"
        >
          <Video size={13} />
          <span>Choose Server / Quality</span>
        </button>
      )}

      {!contextMenu.isUnaired && (
        <button
          onClick={() => {
            (contextMenu.isWatched ? onUnwatch : onWatch)?.(contextMenu.epNum);
            setContextMenu(null);
          }}
          className="w-full flex items-center gap-2.5 px-2.5 py-1.5 rounded-lg text-foreground hover:bg-foreground/10 transition-colors text-left cursor-pointer"
        >
          <Check size={13} />
          <span>{contextMenu.isWatched ? "Mark as Unwatched" : "Mark as Watched"}</span>
        </button>
      )}

      {Number(contextMenu.epNum) > 1 && !contextMenu.isUnaired && (
        <button
          onClick={() => {
            onWatch?.(contextMenu.epNum);
            setContextMenu(null);
          }}
          className="w-full flex items-center gap-2.5 px-2.5 py-1.5 rounded-lg text-foreground hover:bg-foreground/10 transition-colors text-left cursor-pointer"
        >
          <CheckCheck size={13} />
          <span>Mark all previous watched</span>
        </button>
      )}

      {!isManga && !contextMenu.isUnaired && (
        <button
          onClick={() => {
            handleQueue(contextMenu.epNum);
            setContextMenu(null);
          }}
          className="w-full flex items-center gap-2.5 px-2.5 py-1.5 rounded-lg text-foreground hover:bg-foreground/10 transition-colors text-left cursor-pointer"
        >
          <Download size={13} />
          <span>Download Episode</span>
        </button>
      )}

      <button
        onClick={() => {
          navigator.clipboard.writeText(contextMenu.epTitle || `Episode ${contextMenu.epNum}`);
          setContextMenu(null);
        }}
        className="w-full flex items-center gap-2.5 px-2.5 py-1.5 rounded-lg text-muted-foreground hover:text-foreground hover:bg-foreground/10 transition-colors text-left cursor-pointer border-t border-border/40 mt-1 pt-1.5"
      >
        <Copy size={13} />
        <span>Copy Title</span>
      </button>
    </div>
  )}
</div>
);
}
