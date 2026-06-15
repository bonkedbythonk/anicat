// @ts-nocheck

import { useEffect, useState, useRef, useMemo } from "react";
import { useQuery, useQueryClient } from "@tanstack/react-query";
import { motion, AnimatePresence } from "framer-motion";
import { X, Play, Loader2, Star, Users, Calendar, Clock, Building2, Monitor, CheckCircle2, Bookmark, Pause, XCircle, Download, BookOpen, RotateCcw, ChevronDown, ChevronUp, MoreHorizontal, Trash2, Edit2, Check, SkipForward, Sparkles } from "lucide-react";
import { mediaApi, type MediaItem, type Episode, type Character, type Review, API_BASE_ORIGIN } from "@/lib/api";
import { sanitizeHtml } from "@/lib/sanitize";
import { proxyImage } from "@/lib/proxy";
import { dispatchRefresh, updateProgressInQueries, removeMediaFromQueries } from "@/lib/events";
import { formatTime, formatRelativeTime, formatRelativeTimeFromUnix } from "@/lib/date";
import { useAmbientColor } from "@/hooks/useAmbientColor";
import { useProgressEditor } from "@/lib/useProgressEditor";
import { useAppStore, useSettingsStore } from "@/stores/app";
import { EpisodeList } from "./EpisodeList";
import MangaReader from "./MangaReader";

interface MediaDetailProps {
  item: MediaItem;
  onClose: () => void;
  initialAction?: "play";
  onRead?: (chapter: string) => void;
  onPlayEpisode?: (episodeNum: string, provider?: string, server?: string) => void;
}

type DetailConfig = {
  general?: {
    provider?: string;
  };
  stream?: {
    player_type?: "embedded" | "external";
  };
};

export function MediaDetail({ item, onClose, initialAction, onRead, onPlayEpisode }: MediaDetailProps) {
  const [isExpanded, setIsExpanded] = useState(false);
  const [isPlayingNext, setIsPlayingNext] = useState(false);
  const [activeTab, setActiveTab] = useState<"episodes" | "characters" | "more">("episodes");
  // Two-step delete confirm (replaces window.confirm which is broken in Tauri WebView)
  const [deleteConfirmPending, setDeleteConfirmPending] = useState(false);
  const [activeChapter, setActiveChapter] = useState<string | null>(null);
  const [selectedCharacter, setSelectedCharacter] = useState<any>(null);
  const initialPlayEpisode = useAppStore((s) => s.initialPlayEpisode);

  const { data: config = null } = useQuery<DetailConfig | null>({
    queryKey: ["media-config", item.id],
    queryFn: async () => {
      const userConfig = await mediaApi.getConfig();
      return userConfig;
    },
  });

  const [selectedProvider, setSelectedProvider] = useState<string>("allanime");

  // Debug overlay state (DEV only)


  useEffect(() => {
    if (config?.general?.provider) {
      setSelectedProvider(config.general.provider as string);
    }
  }, [config]);

  // Derived values (computed from state/props, must precede hooks that consume them)
  const isManga = item.type === "MANGA" || !!(item.format && ["MANGA", "ONE_SHOT", "NOVEL"].includes(item.format));

  // Initial detail load via React Query
  const {
    data: fullItem = item,
    isLoading: loading,
  } = useQuery({
    queryKey: ["media-detail", item.id],
    queryFn: async () => {
      const details = await mediaApi.getDetails(item.id, isManga ? "MANGA" : "ANIME");
      return details;
    },
  });

  const banner = fullItem?.banner_image || fullItem?.cover_image?.large || item?.banner_image || item?.cover_image?.large;

  // Extracted hooks
  const ambientColor = useAmbientColor(banner);
  const progressEditor = useProgressEditor();

  // Tab data loaded via React Query — cached, deduped, refetched on tab switch.
  // Secondary tabs (characters, reviews, recommendations) are lazy-loaded
  // only when the user switches to them, avoiding 4 simultaneous GraphQL
  // requests on mount that can trigger AniList rate limits.
  const {
    data: episodesRaw,
    isLoading: loadingEps,
  } = useQuery({
    queryKey: ["media-episodes", item.id, isManga ? "mangakatana" : selectedProvider],
    queryFn: () => mediaApi.getEpisodes(item.id, isManga ? "mangakatana" : selectedProvider, item.title?.english || item.title?.romaji || item.title?.native || null),
    enabled: !!selectedProvider || isManga,
  });
  const episodes: Episode[] = Array.isArray(episodesRaw) ? episodesRaw : [];

  // Fallback chain: prefer raw AniList media_list_entry over derived user_status alias
  const actualProgress =
    fullItem?.media_list_entry?.progress ??
    fullItem?.user_status?.progress ??
    0;
  const actualScore =
    fullItem?.media_list_entry?.score ??
    fullItem?.user_status?.score ??
    null;
  const actualProgressVolumes =
    fullItem?.media_list_entry?.progress_volumes ??
    fullItem?.user_status?.progress_volumes ??
    null;

  // Relations + Recommendations — from MEDIA_DETAIL_QUERY (item prop)
  const relations = useMemo(() =>
    (fullItem as any)?.relations?.edges || (item as any).relations?.edges || [],
  [fullItem, item]);
  const recommendations = useMemo(() =>
    (fullItem as any)?.recommendations?.nodes || (item as any).recommendations?.nodes || [],
  [fullItem, item]);
  const { data: anizipTitles = {} } = useQuery({
    queryKey: ["anizip-titles", item.id],
    queryFn: () => mediaApi.fetchAniZipTitles(item.id),
    staleTime: 24 * 60 * 60 * 1000,
  });

  const { data: fillerEpisodes = [] } = useQuery({
    queryKey: ["jikan-filler", (fullItem as any)?.id_mal],
    queryFn: () => mediaApi.fetchJikanFiller((fullItem as any)?.id_mal),
    enabled: !!((fullItem as any)?.id_mal),
    staleTime: 24 * 60 * 60 * 1000,
  });

  const episodeTitleMap = useMemo(() => {
    const map: Record<number, string> = {};
    const eps = (fullItem as any)?.streaming_episodes;
    if (Array.isArray(eps)) {
      eps.forEach((ep: any, idx: number) => {
        if (!ep?.title) return;
        const epNumMatch = ep.title.match(/^Episode\s+(\d+)/i);
        if (epNumMatch && parseInt(epNumMatch[1]) !== idx + 1) return;
        if (ep.title === `Episode ${idx + 1}`) return;
        map[idx + 1] = ep.title;
      });
    }
    // AniZip titles override (more complete data)
    for (const [num, title] of Object.entries(anizipTitles)) {
      map[Number(num)] = title;
    }
    return map;
  }, [fullItem, anizipTitles]);

  const {
    data: characters = [],
    isLoading: loadingChars,
  } = useQuery({
    queryKey: ["media-characters", item.id],
    queryFn: async () => {
      const res = await mediaApi.getCharacters(item.id);
      const r = res as any;
      const edges = r?.Media?.characters?.edges
          || r?.media?.characters?.edges
          || r?.characters?.edges
          || r?.edges
          || [];
      // Flatten: each edge {role, node: {id, name, image}, voiceActors} -> {id, name, image, role, voiceActors}
      return edges.map((edge: any) => ({
        id: edge.node?.id ?? edge.id,
        name: edge.node?.name ?? edge.name,
        image: edge.node?.image ?? edge.image,
        role: edge.role ?? "",
        voiceActors: edge.voiceActors ?? [],
      }));
    },
    enabled: activeTab === "characters",
  });

  const [hasTriggeredInitial, setHasTriggeredInitial] = useState(false);

  // Handle initial action (e.g. from Hero "Play Now" button)
  useEffect(() => {
    if (initialAction === "play" && !loading && config && !hasTriggeredInitial) {
      setHasTriggeredInitial(true);
      handlePlayNext();
    }
  }, [initialAction, loading, config, hasTriggeredInitial]);

  const isProcessingAction = useRef(false);

  const handlePlayNext = async () => {
    if (isPlayingNext || isProcessingAction.current) return;
    
    isProcessingAction.current = true;
    setIsPlayingNext(true);
    try {
      if (isManga) {
        const nextChapter = initialPlayEpisode ? Number(initialPlayEpisode) : (actualProgress + 1);
        if (onPlayEpisode) {
          onPlayEpisode(String(nextChapter));
        } else {
          setActiveChapter(String(nextChapter));
        }
      } else {
        if (!initialPlayEpisode && (!fullItem.status || fullItem.status === "FINISHED" || fullItem.status === "CANCELLED")) {
          if (fullItem.episodes && actualProgress >= fullItem.episodes) {
            // Already watched all episodes — nothing to play
            return;
          }
        }
        const nextEpisode = initialPlayEpisode ? Number(initialPlayEpisode) : (actualProgress + 1);
        if (onPlayEpisode) {
          onPlayEpisode(nextEpisode.toString(), selectedProvider);
          onClose();
        } else {
          const coverImg = fullItem?.banner_image || fullItem?.cover_image?.large || item?.banner_image || item?.cover_image?.large || "";
          const nextEpNum = nextEpisode;
          const nextEpTitle = episodeTitleMap?.[nextEpNum] || "";
          const totalEps = fullItem?.episodes || episodes?.length || 0;
          await mediaApi.play(item.id, nextEpNum, selectedProvider, undefined, title, nextEpTitle, coverImg, totalEps);
          dispatchRefresh();
        }
      }
    } catch (error) {
      console.error("Failed to play next:", error);
    } finally {
      setIsPlayingNext(false);
      // Keep locked for a short moment to prevent accidental double-clicks 
      // even after the request finished
      setTimeout(() => {
        isProcessingAction.current = false;
      }, 500);
    }
  };

  const autoskip = useSettingsStore((s) => s.autoskip);
  const setAutoskip = useSettingsStore((s) => s.setAutoskip);
  const shaderProfile = useSettingsStore((s) => s.shaderProfile);
  const setShaderProfile = useSettingsStore((s) => s.setShaderProfile);

  const handleToggleAutoskip = async () => {
    const newVal = !autoskip;
    setAutoskip(newVal);
    try {
      await mediaApi.updateConfig({ general: { autoskip: newVal } });
    } catch (err) {
      console.error("Failed to update config on backend:", err);
    }
  };

  const handleChangeShaderProfile = async (newVal: string) => {
    setShaderProfile(newVal);
    try {
      await mediaApi.updateConfig({ stream: { shader_profile: newVal } });
    } catch (err) {
      console.error("Failed to update config on backend:", err);
    }
  };

  const handleToggleUpscaling = async () => {
    const newVal = shaderProfile === "off" ? "balanced" : "off";
    setShaderProfile(newVal);
    try {
      await mediaApi.updateConfig({ stream: { shader_profile: newVal } });
    } catch (err) {
      console.error("Failed to update config on backend:", err);
    }
  };

  const handleUpdateProgress = async (newProgress: number) => {
    try {
      const updates: Record<string, unknown> = { progress: newProgress };
      if (newProgress > 0) {
        const currentStatus = fullItem?.media_list_entry?.status ?? fullItem?.user_status?.status;
        if (!currentStatus || currentStatus === "PLANNING") {
          updates.status = isManga ? "CURRENT" : "CURRENT";
        }
      }
      await mediaApi.saveMediaListEntry(item.id, updates);
      updateProgressInQueries(queryClient, item.id, newProgress);
      queryClient.invalidateQueries({ queryKey: ["media-detail", item.id], refetchType: 'all' });
      queryClient.invalidateQueries({ queryKey: ["lists"] });
      queryClient.invalidateQueries({ queryKey: ["home-watching"], refetchType: 'all' });
      queryClient.invalidateQueries({ queryKey: ["home-repeating"], refetchType: 'all' });
      queryClient.invalidateQueries({ queryKey: ["manga-data"], refetchType: 'all' });
      dispatchRefresh();
      progressEditor.cancelEditing();
    } catch (err) {
      console.error("Failed to update progress:", err);
    }
  };

  const handleRemoveFromList = async (bypassConfirm: boolean | React.MouseEvent = false) => {
    const shouldBypass = bypassConfirm === true;
    if (!shouldBypass && !deleteConfirmPending) {
      // First click: ask for confirmation inline
      setDeleteConfirmPending(true);
      // Auto-reset after 3s if user does nothing
      setTimeout(() => setDeleteConfirmPending(false), 3000);
      return;
    }
    // Second click: confirmed — fire immediately
    setDeleteConfirmPending(false);
    onClose();

    // Optimistic: remove from all list caches immediately
    const qc = queryClient;
    const listQueryKeys = [
      ["lists"],
      ["home-recently-watched"],
      ["home-watching"],
      ["home-repeating"],
    ];
    // Snapshot each list cache for rollback
    interface ListPage { media?: MediaItem[]; page_info?: unknown; }
    const snapshots: Map<string, ListPage | undefined> = new Map();
    for (const key of listQueryKeys) {
      snapshots.set(JSON.stringify(key), qc.getQueryData<ListPage>(key as unknown[]));
      qc.setQueryData(key as unknown[], (old: ListPage | undefined) => {
        if (!old?.media) return old;
        return { ...old, media: old.media.filter((m: MediaItem) => m.id !== item.id) };
      });
    }
    // Mark the media-detail cache as stale so it refetches fresh data
    // if the user re-opens the detail (don't removeQueries — the component
    // may still be mounted during exit animation and would crash on null data).
    qc.invalidateQueries({ queryKey: ["media-detail", item.id] });

    mediaApi.deleteFromList(fullItem?.user_status?.id || fullItem?.media_list_entry?.id || 0)
      .then(() => {
        removeMediaFromQueries(qc, item.id);
        // Invalidate to ensure consistency with server
        for (const key of listQueryKeys) {
          qc.invalidateQueries({ queryKey: key as unknown[] });
        }
        qc.invalidateQueries({ queryKey: ["playback-status"] });
        dispatchRefresh();
      })
      .catch((error) => {
        console.error("Failed to remove from list:", error);
        // Rollback: restore snapshots
        for (const [keyStr, snapshot] of snapshots) {
          qc.setQueryData(JSON.parse(keyStr) as unknown[], snapshot);
        }
      });
  };

  const [isUpdatingStatus, setIsUpdatingStatus] = useState(false);
  const queryClient = useQueryClient();
  const selectItem = useAppStore((s) => s.openDetail);


  const title = fullItem?.title?.english || fullItem?.title?.romaji || item?.title?.english || item?.title?.romaji || '';

  return (
    <div className="fixed inset-0 z-[150] flex justify-end overflow-hidden">
      {/* Backdrop */}
      <motion.div 
        initial={{ opacity: 0 }}
        animate={{ opacity: 1 }}
        exit={{ opacity: 0 }}
        onClick={onClose} 
        className="absolute inset-0 bg-background/60 backdrop-blur-sm will-change-opacity transform-gpu" 
      />
      
      {/* Sidebar Drawer */}
      <motion.div 
        initial={{ x: "100%" }}
        animate={{ x: 0 }}
        exit={{ x: "100%" }}
        transition={{ duration: 0.3, ease: [0.32, 0.72, 0, 1] }}
        style={{ willChange: "transform" }}
        className="relative w-full max-w-2xl h-full bg-[#050505]/95 border-l border-border shadow-[-20px_0_50px_rgba(0,0,0,0.15)] dark:shadow-[-20px_0_50px_rgba(0,0,0,0.5)] flex flex-col transform-gpu overflow-hidden media-detail-drawer"
      >
        {/* Ambient Glow Backdrop Lighting */}
        <div className="absolute inset-0 overflow-hidden pointer-events-none z-0">
          <div 
            className="absolute -top-32 -left-32 w-[480px] h-[480px] rounded-full blur-[130px] transition-all duration-[1.5s] ease-out animate-pulse" 
            style={{ 
              backgroundColor: ambientColor,
              animationDuration: '9s',
              transition: 'background-color 1.2s ease-in-out, transform 1.2s ease-out'
            }} 
          />
          <div 
            className="absolute top-96 -right-32 w-[380px] h-[380px] rounded-full blur-[110px] transition-all duration-[1.5s] ease-out animate-pulse" 
            style={{ 
              backgroundColor: ambientColor.replace("0.18", "0.08"),
              animationDuration: '13s',
              transition: 'background-color 1.2s ease-in-out, transform 1.2s ease-out'
            }} 
          />
        </div>

        {/* Close Button */}
        <button 
          onClick={onClose} 
          className="absolute top-6 right-6 z-50 p-2 bg-foreground/10 hover:bg-foreground/20 text-foreground/70 hover:text-foreground rounded-full backdrop-blur-sm transition-all border border-border active:scale-90"
        >
          <X size={20} />
        </button>

        {/* Content Area */}
        <div className="flex-1 overflow-y-auto scrollbar-hide z-10 relative bg-transparent transform-gpu translate-z-0 will-change-scroll">
          {/* Header Banner */}
          <div className="relative h-72 w-full flex-shrink-0 forced-dark-container">
             <div className="absolute inset-0 z-[1] detail-banner-gradient" />
             <img
                src={proxyImage(banner)}
               alt={title}
               className="w-full h-full object-cover transition-opacity duration-1000 opacity-100"
             />
             
             <div className="absolute bottom-6 left-8 right-8 z-[2] space-y-3">
                <div className="flex items-center space-x-2">
                  <div className="px-2 py-1 bg-accent rounded text-[10px] font-black uppercase tracking-widest text-white shadow-lg shadow-accent/20">
                    {fullItem.format || (isManga ? "MANGA" : "ANIME")}
                  </div>
                  {fullItem.average_score && (
                    <div className="flex items-center space-x-1 px-2 py-1 bg-background/65 rounded text-[10px] font-bold text-amber-600 dark:text-yellow-400 border border-border">
                      <Star size={10} fill="currentColor" />
                      <span>{fullItem.average_score}%</span>
                    </div>
                  )}
                </div>
                <h2 className="text-3xl lg:text-4xl font-extrabold text-white leading-tight drop-shadow-[0_2px_8px_rgba(0,0,0,0.8)]">{title}</h2>
             </div>
          </div>

          <div className="p-8 lg:p-10 space-y-8">
            {/* Quick Actions & Meta */}
            <div className="flex flex-col space-y-4">
              <div className="flex items-center space-x-3">
                {(() => {
                  const currentProgress = actualProgress;
                  const total = fullItem.episodes || fullItem.chapters || 0;
                  const nextAiringEp = fullItem.next_airing?.episode;
                  const filteredEps = episodes
                    .filter(e => !nextAiringEp || Number(e.number) < nextAiringEp)
                    .map(e => Number(e.number));
                  const latestAvailable = episodes.length > 0 && filteredEps.length > 0
                    ? Math.max(...filteredEps)
                    : total;
                  const nextEpisode = actualProgress + 1;
                  const isFinished = total > 0 && currentProgress >= total;
                  const isCaughtUp = !isFinished && latestAvailable > 0 && currentProgress >= latestAvailable;

                  return (
                    <button
                      onClick={handlePlayNext}
                      disabled={isPlayingNext || isCaughtUp}
                      className="flex-1 flex items-center justify-center space-x-3 py-3.5 bg-accent hover:bg-accent-light text-white font-extrabold text-sm rounded-2xl transition-all shadow-xl shadow-accent/20 active:scale-95 disabled:opacity-50 disabled:bg-foreground/[0.05] disabled:text-muted-foreground disabled:shadow-none"
                    >
                      {isPlayingNext ? (
                        <Loader2 className="animate-spin" size={18} />
                      ) : (
                        <>
                          {isManga ? <BookOpen size={18} /> : <Play size={18} fill="currentColor" />}
                          <span>
                            {isFinished ? "Completed" : isCaughtUp ? "Caught Up" : `${isManga ? 'Read' : 'Continue'} ${isManga ? 'Chapter' : 'Episode'} ${nextEpisode}`}
                          </span>
                        </>
                      )}
                    </button>
                  );
                })()}
                
                <div className="relative w-44">
                  <select
                    value={
                      (() => {
                        const s = fullItem.user_status?.status?.toLowerCase();
                        return s === "current" ? "watching" : (s || "none");
                      })()
                    }
                    onChange={(e) => {
                      const newStatus = e.target.value;
                      if (newStatus === "none") {
                        handleRemoveFromList(true);
                      } else {
                        setIsUpdatingStatus(true);
                        // Fire-and-forget: don't block the UI on the network call
                        mediaApi.updateStatus(item.id, newStatus)
                          .then(() => {
                            updateProgressInQueries(queryClient, item.id, actualProgress, newStatus);
                            queryClient.invalidateQueries({ queryKey: ["media-detail", item.id], refetchType: 'all' });
                            queryClient.invalidateQueries({ queryKey: ["lists"] });
                            queryClient.invalidateQueries({ queryKey: ["home-watching"], refetchType: 'all' });
                            queryClient.invalidateQueries({ queryKey: ["home-repeating"], refetchType: 'all' });
                            dispatchRefresh();
                          })
                          .catch((err) => console.error("Failed to update status:", err))
                          .finally(() => setIsUpdatingStatus(false));
                      }
                    }}
                    disabled={isUpdatingStatus}
                    className="w-full bg-foreground/5 border border-border text-foreground hover:bg-foreground/10 rounded-2xl pl-4 pr-10 py-3.5 text-sm font-bold focus:outline-none focus:border-accent active:scale-95 transition-all cursor-pointer appearance-none"
                  >
                    <option value="none" className="text-muted-foreground">-- Add to List --</option>
                    <option value="planning" className="text-foreground">Planning</option>
                    <option value="watching" className="text-foreground">{isManga ? "Reading" : "Watching"}</option>
                    <option value="repeating" className="text-foreground">{isManga ? "Rereading" : "Rewatching"}</option>
                    <option value="completed" className="text-foreground">Completed</option>
                    <option value="paused" className="text-foreground">Paused</option>
                    <option value="dropped" className="text-foreground">Dropped</option>
                  </select>
                  <div className="absolute right-4 top-1/2 -translate-y-1/2 pointer-events-none text-muted-foreground">
                    <ChevronDown size={16} />
                  </div>
                </div>

                <button 
                  onClick={handleRemoveFromList}
                  title={deleteConfirmPending ? "Click again to confirm removal" : "Remove from List"}
                  className={`p-3.5 rounded-2xl transition-all border active:scale-95 ${
                    deleteConfirmPending
                      ? "bg-red-500/80 text-white border-red-500 scale-105 animate-pulse"
                      : "bg-red-500/10 hover:bg-red-500/20 text-red-500/70 hover:text-red-500 border-red-500/20"
                  }`}
                >
                  <Trash2 size={22} />
                </button>
              </div>


              <div className="flex items-center justify-between px-2">
                <div className="flex items-center space-x-6">
                  <div>
                    <div className="text-[10px] font-bold text-muted-foreground uppercase tracking-[0.2em] mb-1">Progress</div>
                    {progressEditor.isEditing ? (
                      <div className="flex items-center space-x-2">
                        <input 
                          autoFocus
                          type="number" 
                          value={progressEditor.editValue}
                          onChange={(e) => progressEditor.setEditValue(e.target.value)}
                          onKeyDown={(e) => {
                            if (e.key === 'Enter') handleUpdateProgress(parseInt(progressEditor.editValue) || 0);
                            if (e.key === 'Escape') progressEditor.cancelEditing();
                          }}
                          className="w-16 bg-foreground/5 border border-border rounded-lg px-2 py-1 text-sm font-bold text-foreground focus:outline-none focus:border-accent"
                        />
                        <button 
                          onClick={() => handleUpdateProgress(parseInt(progressEditor.editValue) || 0)}
                          className="p-1.5 bg-accent text-white rounded-lg hover:bg-accent-light transition-colors"
                        >
                          <Check size={14} />
                        </button>
                        <button 
                          onClick={() => progressEditor.cancelEditing()}
                          className="p-1.5 bg-foreground/5 text-muted-foreground rounded-lg hover:bg-foreground/10 transition-colors"
                        >
                          <X size={14} />
                        </button>
                      </div>
                    ) : (
                      <div className="flex items-center space-x-3 group/progress">
                        <div>
                          <p className="text-xl font-black text-foreground tabular-nums">
                            {actualProgress}
                            <span className="text-muted-foreground/45 mx-1.5 font-medium">/</span>
                            <span className="text-muted-foreground">{isManga ? (fullItem.chapters || "?") : (fullItem.episodes || "?")}</span>
                          </p>
                          {isManga && actualProgressVolumes != null && actualProgressVolumes > 0 && (
                            <p className="text-[11px] text-muted-foreground/60 tabular-nums mt-0.5">
                              Vol. {actualProgressVolumes}{fullItem.volumes ? <><span className="text-muted-foreground/45 mx-1 font-medium">/</span>{fullItem.volumes}</> : ""}
                            </p>
                          )}
                        </div>
                        <button 
                          onClick={() => progressEditor.startEditing(actualProgress)}
                          className="p-1.5 bg-foreground/5 text-muted-foreground hover:text-foreground hover:bg-foreground/10 rounded-lg transition-all opacity-0 group-hover/progress:opacity-100"
                        >
                          <Edit2 size={12} />
                        </button>
                      </div>
                    )}
                  </div>
                  <div className="h-8 w-px bg-border" />
                  <div className="flex flex-col">
                    <span className="text-[10px] font-black text-muted-foreground uppercase tracking-widest">
                      {actualScore != null && actualScore > 0 ? "Your Score" : "Avg Score"}
                    </span>
                    <span className="text-base font-bold text-foreground tabular-nums">
                      {actualScore != null && actualScore > 0 ? (
                        <>{actualScore} <span className="text-muted-foreground/45 font-medium">/ 100</span></>
                      ) : (
                        <>{fullItem.average_score ? `${fullItem.average_score}%` : '-'}</>
                      )}
                    </span>
                  </div>
                </div>
                
                <div className="flex items-center space-x-2">
                   <div className={`w-2 h-2 rounded-full ${fullItem.status === 'RELEASING' ? 'bg-green-500 animate-pulse' : 'bg-gray-600'}`} />
                   <span className="text-[10px] font-black text-muted-foreground uppercase tracking-widest">{fullItem.status?.replace('_', ' ')}</span>
                </div>
              </div>
            </div>

            {/* Genres */}
            {fullItem.genres && (
              <div className="flex flex-wrap gap-2">
                {fullItem.genres.map(g => (
                  <span key={g} className="px-3 py-1 bg-foreground/5 border border-border rounded-lg text-[11px] font-bold text-muted-foreground genre-chip">{g}</span>
                ))}
              </div>
            )}



            {/* Synopsis with smooth expand */}
            {fullItem.description && (
              <div className="space-y-3 p-6 rounded-2xl bg-foreground/[0.02] border border-border synopsis-container">
                <h3 className="text-[10px] font-black text-accent uppercase tracking-[0.2em]">Synopsis</h3>
                <motion.div
                  className="relative overflow-hidden"
                  animate={{ maxHeight: isExpanded ? 2000 : 96 }}
                  initial={false}
                  transition={{ duration: 0.4, ease: [0.25, 0.46, 0.45, 0.94] }}
                >
                  <p 
                    className="text-sm text-muted-foreground leading-relaxed"
                    dangerouslySetInnerHTML={{ __html: sanitizeHtml(fullItem.description) }} 
                  />
                  {!isExpanded && fullItem.description.length > 200 && (
                    <div className="absolute bottom-0 left-0 right-0 h-12 pointer-events-none"
                      style={{ background: 'linear-gradient(to bottom, transparent, rgba(5,5,5,0.95))' }} />
                  )}
                </motion.div>
                {fullItem.description.length > 200 && (
                  <button 
                    onClick={() => setIsExpanded(!isExpanded)}
                    className="flex items-center space-x-1.5 text-[11px] font-bold text-foreground/50 hover:text-foreground transition-colors group"
                  >
                    <span>{isExpanded ? "Show Less" : "Read Full Synopsis"}</span>
                    {isExpanded ? <ChevronUp size={14} /> : <ChevronDown size={14} className="group-hover:translate-y-0.5 transition-transform" />}
                  </button>
                )}
              </div>
            )}

            {/* Next Episode Banner */}
            {!isManga && fullItem.next_airing && (
              <div className="bg-accent/5 border border-accent/10 rounded-2xl p-5 flex items-center space-x-4 next-episode-banner">
                <div className="p-3 bg-accent/10 rounded-xl text-accent shadow-inner"><Calendar size={20} /></div>
                <div>
                  <div className="text-[10px] font-bold text-accent uppercase tracking-widest">Next Episode</div>
                  <div className="text-base text-foreground font-bold">
                    Episode {fullItem.next_airing.episode} <span className="text-muted-foreground font-medium text-sm">airing {formatRelativeTimeFromUnix(fullItem.next_airing.airing_at)}</span>
                  </div>
                </div>
              </div>
            )}


            {/* Tabs */}
            <div className="space-y-6">
              <div className="flex border-b border-white/[0.06] pb-0 relative">
                {([
                  "episodes",
                  "characters", 
                  "seasons",
                  "more"
                ] as const).map((tab) => (
                  <button
                    key={tab}
                    onClick={() => setActiveTab(tab as any)}
                    className={`px-4 py-2.5 text-sm font-semibold relative transition-colors ${
                      activeTab === tab ? "text-white" : "text-gray-400 hover:text-white"
                    }`}
                  >
                    {tab === "episodes" ? (isManga ? "Chapters" : "Episodes") : tab === "seasons" ? "Related" : tab.charAt(0).toUpperCase() + tab.slice(1)}
                    {activeTab === tab && (
                      <motion.div layoutId="tab-indicator"
                        className="absolute bottom-0 left-0 right-0 h-[2px] bg-accent rounded-full" />
                    )}
                  </button>
                ))}
              </div>

              <div className="min-h-[300px]">
                <AnimatePresence mode="wait">
                  {activeTab === "episodes" && (
                    <motion.div
                      key="episodes"
                      initial={{ opacity: 0, y: 6 }}
                      animate={{ opacity: 1, y: 0 }}
                      exit={{ opacity: 0, y: -6 }}
                      transition={{ duration: 0.18 }}
                    >
                      {!isManga && (
                        <div className="flex flex-wrap gap-4 items-center p-3.5 bg-foreground/[0.02] border border-border/50 rounded-2xl mb-4">
                          <button
                            onClick={handleToggleAutoskip}
                            className={`flex items-center space-x-2 px-3 py-1.5 rounded-xl text-xs font-bold transition-all ${
                              autoskip 
                                ? "bg-accent/15 text-accent border border-accent/30 shadow-sm shadow-accent/5" 
                                : "bg-background/40 text-muted-foreground border border-border/50 hover:bg-background/60"
                            }`}
                          >
                            <SkipForward size={14} fill={autoskip ? "currentColor" : "none"} />
                            <span>Auto Skip Intro</span>
                          </button>

                          <button
                            onClick={handleToggleUpscaling}
                            className={`flex items-center space-x-2 px-3 py-1.5 rounded-xl text-xs font-bold transition-all ${
                              shaderProfile !== "off" 
                                ? "bg-accent/15 text-accent border border-accent/30 shadow-sm shadow-accent/5" 
                                : "bg-background/40 text-muted-foreground border border-border/50 hover:bg-background/60"
                            }`}
                          >
                            <Sparkles size={14} className={shaderProfile !== "off" ? "text-accent" : ""} />
                            <span>Upscaling</span>
                          </button>
                        </div>
                      )}

                      {!isManga && (
                        <div className="flex items-center justify-between mb-3">
                          <p className="text-xs text-muted-foreground">Streaming source</p>
                          <div className="flex items-center gap-2">
                          <select
                            value={selectedProvider}
                            onChange={(e) => setSelectedProvider(e.target.value)}
                            className="text-xs bg-white/[0.04] border border-white/[0.06] rounded-lg px-3 py-1.5 text-foreground outline-none"
                          >
                            <option value="allanime">AllAnime</option>
                            <option value="anineko">AniNeko</option>
                          </select>
                           <button
                             onClick={async () => {
                               await mediaApi.clearProviderCache(item.id).catch(() => {});
                               queryClient.invalidateQueries({
                                 queryKey: ["media-episodes", item.id],
                               });
                               queryClient.invalidateQueries({
                                 queryKey: ["media-detail", item.id],
                               });
                             }}
                             className="p-1.5 rounded-lg bg-white/[0.04] border border-white/[0.06] hover:bg-white/[0.08] text-muted-foreground hover:text-foreground transition-all active:scale-95"
                             title="Re-match source"
                           >
                             <RotateCcw size={14} />
                           </button>
                          </div>
                        </div>
                      )}
                      <EpisodeList 
                        mediaId={item.id} 
                        episodes={episodes} 
                        loading={loadingEps} 
                        progress={actualProgress}
                        isManga={isManga} 
                        onRead={(chNum) => setActiveChapter(chNum)} 
                        onPlayEpisode={(epNum, prov, serv) => {
                          if (onPlayEpisode) onPlayEpisode(epNum, prov || selectedProvider, serv);
                          onClose();
                        }}
                        playerType={config?.stream?.player_type}
                        selectedProvider={selectedProvider}
                        mediaTitle={fullItem.title?.english || fullItem.title?.romaji || title}
                        coverImage={fullItem?.banner_image || fullItem?.cover_image?.large || item?.banner_image || item?.cover_image?.large || ""}
                        episodeTitleMap={episodeTitleMap}
                        fillerEpisodes={fillerEpisodes}
                        onUnwatch={(num) => handleUpdateProgress(Number(num) - 1)} 
                        onWatch={(num) => handleUpdateProgress(Number(num))} 
                        nextAiringEpisode={fullItem.next_airing?.episode}
                        nextAiringTime={fullItem.next_airing?.airing_at}
                        onRetry={async () => {
                          await mediaApi.clearProviderCache(item.id).catch(() => {});
                          queryClient.invalidateQueries({
                            queryKey: ["media-episodes", item.id],
                            refetchType: "all",
                          });
                          queryClient.invalidateQueries({
                            queryKey: ["media-detail", item.id],
                            refetchType: "all",
                          });
                        }}
                      />
                    </motion.div>
                  )}
                  {activeTab === "characters" && (
                    <motion.div
                      key="characters"
                      initial={{ opacity: 0, y: 6 }}
                      animate={{ opacity: 1, y: 0 }}
                      exit={{ opacity: 0, y: -6 }}
                      transition={{ duration: 0.18 }}
                    >
                      <div className="grid grid-cols-2 gap-4">
                        {loadingChars ? (
                          <div className="col-span-2 py-20 flex justify-center">
                            <Loader2 className="animate-spin text-accent" size={24} />
                          </div>
                        ) : characters.length > 0 ? (
                          characters.map(char => (
                            <button key={char.id || char.name.full} onClick={() => setSelectedCharacter(char)} className="flex items-center space-x-3 p-3 bg-foreground/[0.02] border border-border rounded-2xl hover:bg-foreground/[0.04] transition-colors group character-card text-left">
                              {char.image?.large && <img src={char.image.large} alt={char.name.full} className="w-14 h-14 rounded-xl object-cover shadow-lg" />}
                              <div className="min-w-0">
                                <div className="text-[13px] font-bold text-foreground group-hover:text-accent transition-colors truncate">{char.name.full}</div>
                                <div className="text-[10px] text-muted-foreground">{char.role?.replace(/_/g, " ")?.toLowerCase()}</div>
                              </div>
                            </button>
                          ))
                        ) : (
                          <div className="col-span-2 py-20 text-center text-muted-foreground text-xs font-bold">No character data available.</div>
                        )}
                      </div>
                    </motion.div>
                  )}

                  {activeTab === "seasons" && (
                    <motion.div
                      key="seasons"
                      initial={{ opacity: 0, y: 6 }}
                      animate={{ opacity: 1, y: 0 }}
                      exit={{ opacity: 0, y: -6 }}
                      transition={{ duration: 0.18 }}
                    >
                      {(() => {
                        const seasonRels = relations.filter(
                          (r: any) => r.relationType === "PREQUEL" || r.relationType === "SEQUEL" || r.relationType === "PARENT" || r.relationType === "SIDE_STORY" || r.relationType === "SUMMARY" || r.relationType === "ADAPTATION"
                        );
                        const otherRels = relations.filter(
                          (r: any) => !(r.relationType === "PREQUEL" || r.relationType === "SEQUEL" || r.relationType === "PARENT" || r.relationType === "SIDE_STORY" || r.relationType === "SUMMARY" || r.relationType === "ADAPTATION")
                        );
                        const hasContent = seasonRels.length > 0 || otherRels.length > 0;
                        if (!hasContent) {
                          return <div className="py-20 text-center text-muted-foreground text-xs font-bold">No related content.</div>;
                        }
                        return (
                          <div className="space-y-6">
                            {seasonRels.length > 0 && (
                              <div className="space-y-3">
                                <p className="text-xs font-semibold text-foreground">Seasons & Adaptations</p>
                                <div className="grid grid-cols-2 gap-4">
                                  {seasonRels.map((rel: any) => {
                                    const m = rel.node;
                                    if (!m) return null;
                                    return (
                                      <button key={m.id} onClick={() => selectItem(m)} className="flex items-start gap-3 group text-left relative">
                                        {(m as any).cover_image?.large || m.coverImage?.large ? (
                                          <img src={proxyImage((m as any).cover_image?.large || m.coverImage?.large)} className="w-12 h-16 rounded-lg object-cover shrink-0" />
                                        ) : null}
                                        <div className="min-w-0">
                                          <div className="text-xs font-semibold text-foreground group-hover:text-accent transition-colors">{m.title?.english || m.title?.romaji}</div>
                                          {rel.relationType && (
                                            <div className="text-[9px] font-bold text-accent/80 mt-0.5">{rel.relationType.replace(/_/g, " ")}</div>
                                          )}
                                          {m.format && <div className="text-[10px] text-muted-foreground mt-0.5">{m.format}</div>}
                                        </div>
                                      </button>
                                    );
                                  })}
                                </div>
                              </div>
                            )}
                            {otherRels.length > 0 && (
                              <div className="space-y-3">
                                <p className="text-xs font-semibold text-foreground">Other Relations</p>
                                <div className="grid grid-cols-2 gap-4">
                                  {otherRels.map((rel: any) => {
                                    const m = rel.node;
                                    if (!m) return null;
                                    return (
                                      <button key={m.id} onClick={() => selectItem(m)} className="flex items-start gap-3 group text-left relative">
                                        {(m as any).cover_image?.large || m.coverImage?.large ? (
                                          <img src={proxyImage((m as any).cover_image?.large || m.coverImage?.large)} className="w-12 h-16 rounded-lg object-cover shrink-0" />
                                        ) : null}
                                        <div className="min-w-0">
                                          <div className="text-xs font-semibold text-foreground group-hover:text-accent transition-colors">{m.title?.english || m.title?.romaji}</div>
                                          {rel.relationType && (
                                            <div className="text-[9px] font-bold text-accent/80 mt-0.5">{rel.relationType.replace(/_/g, " ")}</div>
                                          )}
                                          {m.format && <div className="text-[10px] text-muted-foreground mt-0.5">{m.format}</div>}
                                        </div>
                                      </button>
                                    );
                                  })}
                                </div>
                              </div>
                            )}
                          </div>
                        );
                      })()}
                    </motion.div>
                  )}
                  {activeTab === "more" && (
                    <motion.div
                      key="more"
                      initial={{ opacity: 0, y: 6 }}
                      animate={{ opacity: 1, y: 0 }}
                      exit={{ opacity: 0, y: -6 }}
                      transition={{ duration: 0.18 }}
                    >
                      {recommendations.length > 0 ? (
                        <div className="space-y-4">
                          <p className="text-xs font-semibold text-foreground">Recommendations</p>
                          <div className="grid grid-cols-2 sm:grid-cols-3 gap-4">
                            {recommendations.map((rec: any) => {
                              const m = rec.mediaRecommendation;
                              if (!m) return null;
                              return (
                                <button key={m.id} onClick={() => selectItem(m)} className="group space-y-2 text-left relative">
                                  <div className="aspect-[2/3] rounded-xl overflow-hidden border border-border shadow-lg">
                                    <img src={proxyImage((rec as any).cover_image?.large || m.coverImage?.large)} className="w-full h-full object-cover transition-transform duration-500 group-hover:scale-110" />
                                  </div>
                                  {rec.rating > 0 && (
                                    <span className="absolute top-2 right-2 px-1.5 py-0.5 rounded bg-accent text-white text-[9px] font-bold">{rec.rating}%</span>
                                  )}
                                  <div className="text-[11px] font-bold text-muted-foreground line-clamp-1 group-hover:text-foreground transition-colors">{m.title?.english || m.title?.romaji}</div>
                                </button>
                              );
                            })}
                          </div>
                        </div>
                      ) : (
                        <div className="py-20 text-center text-muted-foreground text-xs font-bold">No additional content.</div>
                      )}
                    </motion.div>
                  )}
                </AnimatePresence>
              </div>
            </div>
          </div>
        </div>
      </motion.div>
        {selectedCharacter && (
          <div className="fixed inset-0 z-[200] flex items-center justify-center" onClick={() => setSelectedCharacter(null)}>
            <div className="absolute inset-0 bg-black/60" />
            <div className="relative max-w-md w-[90%] bg-background border border-border rounded-2xl p-6 shadow-2xl" onClick={(e: any) => e.stopPropagation()}>
              <button onClick={() => setSelectedCharacter(null)} className="absolute top-3 right-3 text-muted-foreground hover:text-foreground transition-colors">
                <X size={16} />
              </button>
              <div className="flex items-start space-x-4">
                {selectedCharacter.image?.large && (
                  <img src={selectedCharacter.image.large} alt={selectedCharacter.name?.full} className="w-20 h-20 rounded-xl object-cover shadow-lg shrink-0" />
                )}
                <div className="min-w-0 space-y-1">
                  <div className="text-base font-bold text-foreground">{selectedCharacter.name?.full}</div>
                  <div className="text-[11px] text-muted-foreground capitalize">{selectedCharacter.role?.replace(/_/g, " ")?.toLowerCase()}</div>
                  {selectedCharacter.voiceActors?.length > 0 && (
                    <div className="pt-2 space-y-1.5">
                      <div className="text-[10px] font-bold text-muted-foreground uppercase tracking-wider">Voice Actors</div>
                      {selectedCharacter.voiceActors.map((va: any) => (
                        <div key={va.id} className="flex items-center space-x-2">
                          {va.image?.large && <img src={va.image.large} alt={va.name?.full} className="w-6 h-6 rounded-full object-cover" />}
                          <span className="text-xs text-foreground">{va.name?.full}</span>
                          <span className="text-[10px] text-muted-foreground">{va.language}</span>
                        </div>
                      ))}
                    </div>
                  )}
                </div>
              </div>
            </div>
          </div>
        )}
        {activeChapter && (
          <MangaReader
            mediaId={item.id}
            chapterNumber={activeChapter}
            onClose={() => setActiveChapter(null)}
            onProgressUpdate={async (chapterNum) => {
              const num = parseInt(chapterNum) || 0;
              if (num > actualProgress) {
                await handleUpdateProgress(num);
              }
            }}
            onNavigateChapter={(direction) => {
              const idx = episodes.findIndex((ep) => String(ep.number) === activeChapter);
              if (direction === "prev" && idx > 0) {
                setActiveChapter(String(episodes[idx - 1].number));
              } else if (direction === "next" && idx < episodes.length - 1) {
                setActiveChapter(String(episodes[idx + 1].number));
              }
            }}
            hasPrevChapter={episodes.findIndex((ep) => String(ep.number) === activeChapter) > 0}
            hasNextChapter={episodes.findIndex((ep) => String(ep.number) === activeChapter) < episodes.length - 1}
          />
        )}
      </div>
    );
  }
