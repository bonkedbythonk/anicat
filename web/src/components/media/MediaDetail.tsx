
import { useEffect, useState, useRef, useMemo } from "react";
import { useQuery, useQueryClient } from "@tanstack/react-query";
import { motion, AnimatePresence } from "framer-motion";
import { X, Play, Loader2, Star, Users, Calendar, Clock, Building2, Monitor, CheckCircle2, Bookmark, Pause, XCircle, Download, BookOpen, RotateCcw, ChevronDown, ChevronUp, ChevronLeft, ChevronRight, MoreHorizontal, Trash2, Edit2, Check, SkipForward, Sparkles, PlayCircle, Film, Heart, Frown, Meh, Smile } from "lucide-react";
import { mediaApi, type MediaItem, type Episode, type Character, type Review } from "@/lib/api";
import { sanitizeHtml } from "@/lib/sanitize";
import { proxyImage } from "@/lib/proxy";
import { dispatchRefresh, updateProgressInQueries, removeMediaFromQueries } from "@/lib/events";
import { formatTime, formatRelativeTime, formatRelativeTimeFromUnix, parseAiringTime } from "@/lib/date";
import { useProgressEditor } from "@/lib/useProgressEditor";
import { useAppStore, useSettingsStore } from "@/stores/app";
import { EpisodeList } from "./EpisodeList";
import { WatchGrid } from "./WatchGrid";
import MangaReader from "./MangaReader";

// AniList airing timestamps are ISO strings without a zone suffix (UTC).
function airingCountdown(airingAt?: string | number): string | null {
  if (!airingAt) return null;
  const t = parseAiringTime(airingAt);
  if (!t) return null;
  const diff = t - Date.now();
  if (diff <= 0) return "out now";
  const days = Math.floor(diff / 86_400_000);
  const hours = Math.floor((diff % 86_400_000) / 3_600_000);
  if (days > 0) return `in ${days}d ${hours}h`;
  const mins = Math.floor((diff % 3_600_000) / 60_000);
  return hours > 0 ? `in ${hours}h ${mins}m` : `in ${mins}m`;
}

// AniList score formats — the raw score value lives on a different scale
// depending on which one the viewer's account uses.
const SCORE_FORMAT_MAX: Record<string, number> = {
  POINT_100: 100,
  POINT_10: 10,
  POINT_10_DECIMAL: 10,
  POINT_5: 5,
  POINT_3: 3,
};

interface MediaDetailProps {
  item: MediaItem;
  onClose: () => void;
  initialAction?: "play";
  onRead?: (chapter: string) => void;
}

type DetailConfig = {
  general?: {
    provider?: string;
  };
};

export function MediaDetail({ item, onClose, initialAction, onRead }: MediaDetailProps) {
  const [isExpanded, setIsExpanded] = useState(false);
  const [synopsisOverflows, setSynopsisOverflows] = useState(false);
  const synopsisRef = useRef<HTMLParagraphElement>(null);
  const [isPlayingNext, setIsPlayingNext] = useState(false);
  const [activeTab, setActiveTab] = useState<"episodes" | "characters" | "seasons" | "more">("episodes");
  // Two-step delete confirm (replaces window.confirm which is broken in Tauri WebView)
  const [deleteConfirmPending, setDeleteConfirmPending] = useState(false);
  const [activeChapter, setActiveChapter] = useState<string | null>(null);
  const [selectedCharacter, setSelectedCharacter] = useState<Character | null>(null);
  const [isResolvingTrailer, setIsResolvingTrailer] = useState(false);
  const initialPlayEpisode = useAppStore((s) => s.initialPlayEpisode);
  const setNotification = useAppStore((s) => s.setNotification);

  // Surface a failed action to the user instead of only logging it — an
  // optimistic UI update can otherwise silently diverge from AniList.
  const notifyError = (msg: string) => {
    setNotification({ message: msg, type: "error" });
    setTimeout(() => setNotification(null), 5000);
  };

  const { data: config = null } = useQuery({
    queryKey: ["media-config", item.id],
    queryFn: async () => {
      const userConfig = await mediaApi.getConfig();
      return userConfig;
    },
  });

  const [selectedProvider, setSelectedProvider] = useState<string>("mkissa");

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
    data: fullItemData,
    isLoading: loading,
  } = useQuery({
    queryKey: ["media-detail", item.id],
    queryFn: async () => {
      const details = await mediaApi.getDetails(item.id, isManga ? "MANGA" : "ANIME");
      return details;
    },
  });
  // Fall back to the always-present `item` prop so downstream code never
  // has to null-check the detail (the query data can be null).
  const fullItem = fullItemData ?? item;

  const banner = fullItem?.banner_image || fullItem?.cover_image?.large || item?.banner_image || item?.cover_image?.large;

  const trailer = fullItem?.trailer || item?.trailer;
  const hasTrailer = !!(trailer?.id && trailer.site?.toLowerCase() === "youtube");

  // Plays through mpv (via yt-dlp) instead of an embedded YouTube iframe —
  // no third-party UI/branding, consistent controls with the rest of the app.
  const handlePlayTrailer = async () => {
    if (!trailer?.id || isResolvingTrailer) return;
    setIsResolvingTrailer(true);
    try {
      await mediaApi.playTrailer(trailer.id);
    } catch (err) {
      setNotification({ message: err instanceof Error ? err.message : String(err), type: "error" });
      setTimeout(() => setNotification(null), 5000);
    } finally {
      setIsResolvingTrailer(false);
    }
  };

  // Extracted hooks
  const progressEditor = useProgressEditor();
  const scoreEditor = useProgressEditor();

  // Tab data loaded via React Query — cached, deduped, refetched on tab switch.
  // Secondary tabs (characters, reviews, recommendations) are lazy-loaded
  // only when the user switches to them, avoiding 4 simultaneous GraphQL
  // requests on mount that can trigger AniList rate limits.
  const {
    data: episodesRaw,
    isLoading: loadingEps,
  } = useQuery({
    queryKey: ["media-episodes", item.id, isManga ? "mangakatana" : selectedProvider],
    queryFn: () => mediaApi.getEpisodes(item.id, isManga ? "mangakatana" : selectedProvider, item.title?.english || item.title?.romaji || item.title?.native || undefined, fullItem?.episodes ?? item.episodes ?? undefined),
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
    fullItem?.relations?.edges || item.relations?.edges || [],
  [fullItem, item]);
  const recommendations = useMemo(() =>
    fullItem?.recommendations?.nodes || item.recommendations?.nodes || [],
  [fullItem, item]);

  // Surface the chronological chain (prequel/sequel) prominently so "what do I
  // watch before/after this" is answerable without opening the Related tab.
  // Prefer a TV-format entry so a side OVA/movie doesn't take the slot.
  const pickRel = (type: string) => {
    const matches = relations.filter((r: { relationType: string; node?: MediaItem }) => r.relationType === type && r.node);
    if (!matches.length) return null;
    return (matches.find((r: { relationType: string; node?: MediaItem }) => r.node?.format === 'TV') || matches[0]).node;
  };
  const prequel = useMemo(() => pickRel('PREQUEL'), [relations]);
  const sequel = useMemo(() => pickRel('SEQUEL'), [relations]);
  const { data: anizipTitles = {} } = useQuery({
    queryKey: ["anizip-titles", item.id],
    queryFn: () => mediaApi.fetchAniZipTitles(item.id),
    staleTime: 24 * 60 * 60 * 1000,
  });

  // AniList scores your account in whichever format you picked under Settings
  // > List > Scoring System — the raw `score` value on a list entry is in that
  // format, not always out of 100 (1-3 for smileys, 1-5 for stars, etc.), so
  // the editor and display below need to know it to not write garbage values.
  const { data: scoreFormat = "POINT_100" } = useQuery({
    queryKey: ["viewer-score-format"],
    queryFn: async () => {
      const res = await mediaApi.getUserProfile();
      return res?.Viewer?.mediaListOptions?.scoreFormat || "POINT_100";
    },
    staleTime: 60 * 60 * 1000,
  });

  const { data: fillerEpisodes = [] } = useQuery({
    queryKey: ["jikan-filler", fullItem?.id_mal],
    queryFn: () => mediaApi.fetchJikanFiller(fullItem.id_mal as number),
    enabled: !!fullItem?.id_mal,
    staleTime: 24 * 60 * 60 * 1000,
  });

  const episodeTitleMap = useMemo(() => {
    const map: Record<number, string> = {};
    const eps = fullItem?.streaming_episodes;
    if (Array.isArray(eps)) {
      eps.forEach((ep, idx: number) => {
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
      const r = res as { Media?: { characters?: { edges?: unknown[] } }; media?: { characters?: { edges?: unknown[] } }; characters?: { edges?: unknown[] }; edges?: unknown[] };
      const edges = r?.Media?.characters?.edges
          || r?.media?.characters?.edges
          || r?.characters?.edges
          || r?.edges
          || [];
      // Flatten: each edge {role, node: {id, name, image}, voiceActors} -> {id, name, image, role, voiceActors}
      type RawEdge = { role?: string; id?: number; name?: { full: string }; image?: { large?: string }; node?: { id?: number; name?: { full: string }; image?: { large?: string } }; voiceActors?: Character["voiceActors"] };
      return (edges as RawEdge[]).map((edge): Character => ({
        id: (edge.node?.id ?? edge.id) ?? 0,
        name: (edge.node?.name ?? edge.name) ?? { full: "" },
        image: edge.node?.image ?? edge.image,
        role: edge.role ?? "",
        voiceActors: edge.voiceActors ?? [],
      }));
    },
    enabled: activeTab === "characters",
  });

  const [hasTriggeredInitial, setHasTriggeredInitial] = useState(false);

  // Handle initial action (e.g. from Hero "Play Now" button) — the specific
  // episode requested by whatever quick-play button opened this page only
  // applies to this one automatic trigger, never to later manual clicks of
  // the Continue button (see handlePlayNext).
  useEffect(() => {
    if (initialAction === "play" && !loading && config && !hasTriggeredInitial) {
      setHasTriggeredInitial(true);
      handlePlayNext(initialPlayEpisode ? Number(initialPlayEpisode) : undefined, config?.general?.provider as string);
    }
  }, [initialAction, loading, config, hasTriggeredInitial]);

  // Measure whether synopsis actually overflows the collapsed height
  useEffect(() => {
    if (!synopsisRef.current) return;
    setSynopsisOverflows(synopsisRef.current.scrollHeight > 60);
  }, [fullItem.description]);

  // Resolve the Continue/Start episode's stream as soon as we know which one
  // it is, so by the time the user presses play, mpv has nothing left to wait
  // on — start_playback finds it already sitting in the preload slot.
  useEffect(() => {
    if (isManga || !selectedProvider) return;
    const continueEpisode = actualProgress + 1;
    mediaApi.preloadEpisode(
      item.id,
      continueEpisode,
      selectedProvider,
      item.title?.english || item.title?.romaji || item.title?.native || undefined,
    ).catch(() => {});
  }, [isManga, selectedProvider, actualProgress, item.id]);

  const isProcessingAction = useRef(false);
  const [queueingAll, setQueueingAll] = useState(false);

  const handleDownloadAll = async () => {
    if (isManga || queueingAll) return;
    setQueueingAll(true);
    try {
      const allEpNums = episodes.map(ep => parseInt(String(ep.number), 10));
      await mediaApi.addToQueue(item.id, allEpNums, fullItem?.title?.english || fullItem?.title?.romaji || item.title?.english || item.title?.romaji || '', fullItem?.banner_image || fullItem?.cover_image?.large || item?.banner_image || item?.cover_image?.large || '');
      dispatchRefresh();
    } catch (error) {
      console.error("Failed to queue all:", error);
    } finally {
      setQueueingAll(false);
    }
  };

  // `overrideEpisode` is only ever passed by the one-time initial-action
  // effect above (honoring whatever episode the Hero/quick-play button that
  // opened this page requested). Manual clicks of the Continue button always
  // omit it, so they fall through to the freshly computed `actualProgress +
  // 1` — otherwise a stale `initialPlayEpisode` left over from how this page
  // was originally opened would keep getting replayed on every later click,
  // even after watching further episodes from within the same open session.
  const handlePlayNext = async (overrideEpisode?: number, providerOverride?: string) => {
    if (isPlayingNext || isProcessingAction.current) return;

    isProcessingAction.current = true;
    setIsPlayingNext(true);
    try {
      if (isManga) {
        const nextChapter = overrideEpisode ?? (actualProgress + 1);
        setActiveChapter(String(nextChapter));
      } else {
        if (!overrideEpisode && (!fullItem.status || fullItem.status === "FINISHED" || fullItem.status === "CANCELLED")) {
          if (fullItem.episodes && actualProgress >= fullItem.episodes) {
            // Already watched all episodes — nothing to play
            return;
          }
        }
        const nextEpisode = overrideEpisode ?? (actualProgress + 1);
        const coverImg = fullItem?.banner_image || fullItem?.cover_image?.large || item?.banner_image || item?.cover_image?.large || "";
        const nextEpNum = nextEpisode;
        const nextEpTitle = episodeTitleMap?.[nextEpNum] || "";
        const totalEps = fullItem?.episodes || episodes?.length || 0;
        const activeProvider = providerOverride || selectedProvider;
        await mediaApi.play(item.id, nextEpNum, activeProvider, undefined, title, nextEpTitle, coverImg, totalEps);
        dispatchRefresh();
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
  const autoplay = useSettingsStore((s) => s.autoplay);
  const setAutoplay = useSettingsStore((s) => s.setAutoplay);
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

  const handleToggleAutoNext = async () => {
    const newVal = !autoplay;
    setAutoplay(newVal);
    try {
      await mediaApi.updateConfig({ general: { autoplay: newVal } });
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
    const updates: Record<string, unknown> = { progress: newProgress };
    if (newProgress > 0) {
      const currentStatus = fullItem?.media_list_entry?.status ?? fullItem?.user_status?.status;
      if (!currentStatus || currentStatus === "PLANNING") {
        updates.status = "CURRENT";
      }
    }
    // Optimistic update — reflect the change immediately in all cached views,
    // then fire the mutation in the background and trigger a background refetch.
    updateProgressInQueries(queryClient, item.id, newProgress);
    progressEditor.cancelEditing();
    mediaApi.saveMediaListEntry(item.id, updates)
      .then(() => {
        queryClient.invalidateQueries({ queryKey: ["media-detail", item.id], refetchType: 'all' });
        queryClient.invalidateQueries({ queryKey: ["lists"] });
        queryClient.invalidateQueries({ queryKey: ["home-watching"], refetchType: 'all' });
        queryClient.invalidateQueries({ queryKey: ["home-repeating"], refetchType: 'all' });
        queryClient.invalidateQueries({ queryKey: ["manga-data"], refetchType: 'all' });
        dispatchRefresh();
      })
      .catch((err) => { console.error("Failed to update progress:", err); notifyError("Couldn't update progress on AniList."); });
  };

  const handleUpdateScore = async (newScore: number) => {
    const clamped = Math.max(0, Math.min(SCORE_FORMAT_MAX[scoreFormat] ?? 100, newScore));
    scoreEditor.cancelEditing();
    // Optimistic patch so the new score shows immediately instead of waiting
    // on the refetch — same pattern as updateProgressInQueries, just scoped
    // to the one query that actually displays score (no home row shows it).
    queryClient.setQueryData(["media-detail", item.id], (old: MediaItem | undefined) => {
      if (!old) return old;
      return {
        ...old,
        media_list_entry: { ...(old.media_list_entry || {}), score: clamped },
      };
    });
    mediaApi.saveMediaListEntry(item.id, { score: clamped })
      .then(() => {
        queryClient.invalidateQueries({ queryKey: ["media-detail", item.id], refetchType: 'all' });
        queryClient.invalidateQueries({ queryKey: ["lists"] });
        dispatchRefresh();
      })
      .catch((err) => { console.error("Failed to update score:", err); notifyError("Couldn't update your score on AniList."); });
  };

  const [isTogglingFavourite, setIsTogglingFavourite] = useState(false);
  const handleToggleFavourite = async () => {
    if (isTogglingFavourite) return;
    setIsTogglingFavourite(true);
    const next = !fullItem?.is_favourite;
    queryClient.setQueryData(["media-detail", item.id], (old: MediaItem | undefined) => {
      if (!old) return old;
      return { ...old, is_favourite: next };
    });
    try {
      await mediaApi.toggleFavourite(item.id, isManga);
    } catch (err) {
      console.error("Failed to toggle favourite:", err);
      notifyError(next ? "Couldn't add to AniList favourites." : "Couldn't remove from AniList favourites.");
      // Roll back the optimistic flip on failure.
      queryClient.setQueryData(["media-detail", item.id], (old: MediaItem | undefined) => {
        if (!old) return old;
        return { ...old, is_favourite: !next };
      });
    } finally {
      setIsTogglingFavourite(false);
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
        notifyError("Couldn't remove this from your AniList list.");
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

  const primaryActionButton = (() => {
    const currentProgress = actualProgress;
    const total = fullItem.episodes || fullItem.chapters || 0;
    const nextAiringEp = fullItem.next_airing?.episode;
    const filteredEps = episodes
      .filter(e => !nextAiringEp || Number(e.number) < nextAiringEp)
      .map(e => Number(e.number));
    const latestAvailable = episodes.length > 0 && filteredEps.length > 0 ? Math.max(...filteredEps) : total;
    const nextEpisode = actualProgress + 1;
    const isFinished = total > 0 && currentProgress >= total && fullItem.status !== 'RELEASING';
    const isCaughtUp = !isFinished && latestAvailable > 0 && currentProgress >= latestAvailable;
    return (
      <button
        onClick={() => handlePlayNext()}
        disabled={isPlayingNext || isCaughtUp}
        className="flex items-center gap-2 px-5 py-3 bg-accent hover:bg-accent-light text-background font-medium text-sm rounded-md transition-all active:scale-95 disabled:opacity-50 disabled:bg-foreground/[0.05] disabled:text-muted-foreground"
      >
        {isPlayingNext ? (
          <Loader2 className="animate-spin" size={18} />
        ) : (
          <>
            {isManga ? <BookOpen size={18} /> : <Play size={18} fill="currentColor" />}
            <span>
              {isFinished ? 'Completed' : isCaughtUp ? 'Caught Up'
                : `${isManga ? 'Read' : actualProgress > 0 ? 'Continue' : 'Start'} ${isManga ? 'Chapter' : 'Episode'} ${nextEpisode}`}
            </span>
          </>
        )}
      </button>
    );
  })();

  return (
    <>
      <div className="relative min-h-full bg-background">
        {/* Banner */}
        <div className="relative h-56 sm:h-64 lg:h-72 overflow-hidden">
          {banner ? (
            <img src={banner} alt="" className="absolute inset-0 w-full h-full object-cover" />
          ) : (
            <div className="absolute inset-0 bg-surface" />
          )}
          <div className="absolute inset-0 hero-gradient" />
          <div className="absolute inset-x-0 top-0 z-20 px-4 sm:px-8 lg:px-14 pt-6">
            <div className="max-w-[1150px] mx-auto">
              <button
                onClick={onClose}
                className="flex items-center gap-1.5 text-[12.5px] font-medium text-foreground/70 hover:text-foreground cursor-pointer"
              >
                <ChevronLeft size={14} />
                Back
              </button>
            </div>
          </div>
        </div>

        {/* Main content — cover + info side by side */}
        <div className="relative z-10 px-4 sm:px-8 lg:px-14 -mt-24 sm:-mt-28 pb-16 max-w-[1150px] mx-auto">
          <div className="flex flex-col sm:flex-row gap-6 sm:gap-8">
            {/* Cover art — left column */}
            <div className="shrink-0 flex flex-col items-center sm:items-start gap-4">
              <img
                src={proxyImage(fullItem?.cover_image?.large || item?.cover_image?.large || '')}
                alt={title}
                className="w-36 h-52 sm:w-44 sm:h-64 lg:w-48 lg:h-[272px] rounded-lg object-cover border border-border shadow-2xl"
              />
              {/* Compact stats under cover */}
              <div className="w-36 sm:w-44 lg:w-48 space-y-3">
                <div className="group/progress">
                  <div className="meta-mono text-muted-foreground mb-1">Progress</div>
                  {progressEditor.isEditing ? (
                    <div className="flex items-center gap-1.5">
                      <input
                        autoFocus
                        type="number"
                        value={progressEditor.editValue}
                        onChange={(e) => progressEditor.setEditValue(e.target.value)}
                        onKeyDown={(e) => {
                          if (e.key === 'Enter') handleUpdateProgress(parseInt(progressEditor.editValue) || 0);
                          if (e.key === 'Escape') progressEditor.cancelEditing();
                        }}
                        className="w-14 bg-foreground/5 border border-border rounded-md px-2 py-1 text-sm font-bold text-foreground focus:outline-none focus:border-accent"
                      />
                      <button onClick={() => handleUpdateProgress(parseInt(progressEditor.editValue) || 0)} className="p-1 bg-accent text-background rounded-md hover:bg-accent-light transition-colors"><Check size={12} /></button>
                      <button onClick={() => progressEditor.cancelEditing()} className="p-1 bg-foreground/5 text-muted-foreground rounded-md hover:bg-foreground/10 transition-colors"><X size={12} /></button>
                    </div>
                  ) : (
                    <div className="flex items-center gap-2">
                      <p className="text-lg font-semibold text-foreground tabular-nums">
                        {actualProgress}
                        <span className="text-muted-foreground/45 mx-1 font-medium">/</span>
                        <span className="text-muted-foreground">{isManga ? (fullItem.chapters || '?') : (fullItem.episodes || '?')}</span>
                      </p>
                      <button onClick={() => progressEditor.startEditing(actualProgress)} className="p-1 bg-foreground/5 text-muted-foreground hover:text-foreground hover:bg-foreground/10 rounded-md transition-all opacity-0 group-hover/progress:opacity-100">
                        <Edit2 size={11} />
                      </button>
                    </div>
                  )}
                  {isManga && actualProgressVolumes != null && actualProgressVolumes > 0 && (
                    <p className="text-[11px] text-muted-foreground/60 tabular-nums mt-0.5">
                      Vol. {actualProgressVolumes}{fullItem.volumes ? <><span className="text-muted-foreground/45 mx-1 font-medium">/</span>{fullItem.volumes}</> : ''}
                    </p>
                  )}
                </div>

                <div className="h-px bg-border" />

                <div className="group/score">
                  <span className="meta-mono text-muted-foreground">Your Score</span>
                  {scoreFormat === 'POINT_5' || scoreFormat === 'POINT_3' ? (
                    <div className="flex items-center gap-0.5 mt-1">
                      {Array.from({ length: SCORE_FORMAT_MAX[scoreFormat] }, (_, i) => i + 1).map((n) => {
                        if (scoreFormat === 'POINT_5') {
                          const active = (actualScore || 0) >= n;
                          return (
                            <button key={n} onClick={() => handleUpdateScore(n)} aria-label={`Rate ${n} star${n > 1 ? 's' : ''}`} className="transition-transform hover:scale-110 active:scale-95">
                              <Star size={16} className={active ? 'text-accent' : 'text-muted-foreground/30'} fill={active ? 'currentColor' : 'none'} />
                            </button>
                          );
                        }
                        const Icon = n === 1 ? Frown : n === 2 ? Meh : Smile;
                        const selected = (actualScore || 0) === n;
                        return (
                          <button key={n} onClick={() => handleUpdateScore(n)} aria-label={n === 1 ? 'Rate sad' : n === 2 ? 'Rate neutral' : 'Rate happy'} className="transition-transform hover:scale-110 active:scale-95">
                            <Icon size={18} className={selected ? 'text-accent' : 'text-muted-foreground/30'} />
                          </button>
                        );
                      })}
                    </div>
                  ) : scoreEditor.isEditing ? (
                    <div className="flex items-center gap-1.5 mt-1">
                      <input
                        autoFocus
                        type="number"
                        min={0}
                        max={SCORE_FORMAT_MAX[scoreFormat] ?? 100}
                        step={scoreFormat === 'POINT_10_DECIMAL' ? 0.1 : 1}
                        value={scoreEditor.editValue}
                        onChange={(e) => scoreEditor.setEditValue(e.target.value)}
                        onKeyDown={(e) => {
                          if (e.key === 'Enter') handleUpdateScore(parseFloat(scoreEditor.editValue) || 0);
                          if (e.key === 'Escape') scoreEditor.cancelEditing();
                        }}
                        className="w-14 bg-foreground/5 border border-border rounded-md px-2 py-1 text-sm font-bold text-foreground focus:outline-none focus:border-accent"
                      />
                      <button onClick={() => handleUpdateScore(parseFloat(scoreEditor.editValue) || 0)} className="p-1 bg-accent text-background rounded-md hover:bg-accent-light transition-colors"><Check size={12} /></button>
                      <button onClick={() => scoreEditor.cancelEditing()} className="p-1 bg-foreground/5 text-muted-foreground rounded-md hover:bg-foreground/10 transition-colors"><X size={12} /></button>
                    </div>
                  ) : (
                    <div className="flex items-center gap-2 mt-0.5">
                      <span className="text-lg font-semibold text-foreground tabular-nums">
                        {actualScore != null && actualScore > 0
                          ? <>{actualScore} <span className="text-muted-foreground/45 font-medium text-xs">/ {SCORE_FORMAT_MAX[scoreFormat] ?? 100}</span></>
                          : <span className="text-muted-foreground/60">—</span>}
                      </span>
                      <button onClick={() => scoreEditor.startEditing(actualScore || 0)} className="p-1 bg-foreground/5 text-muted-foreground hover:text-foreground hover:bg-foreground/10 rounded-md transition-all opacity-0 group-hover/score:opacity-100">
                        <Edit2 size={11} />
                      </button>
                    </div>
                  )}
                </div>
              </div>
            </div>

            {/* Info — right column */}
            <div className="flex-1 min-w-0 pt-0 sm:pt-6 space-y-5">
              {/* Meta tags */}
              <div className="meta-mono flex items-center flex-wrap gap-x-3 gap-y-1 text-foreground/70">
                {fullItem.format && <span>{fullItem.format}</span>}
                {fullItem.status === 'RELEASING' && <span className="text-accent">Airing</span>}
                {fullItem.status === 'FINISHED' && <span>Finished</span>}
                {!isManga && fullItem.episodes ? <span>{fullItem.episodes} EP</span> : null}
                {isManga && fullItem.chapters ? <span>{fullItem.chapters} CH</span> : null}
                {(fullItem.season_year || fullItem.seasonYear || fullItem.startDate?.year) && (
                  <span>{fullItem.season_year || fullItem.seasonYear || fullItem.startDate?.year}</span>
                )}
                {fullItem.studios?.nodes?.[0]?.name && <span>{fullItem.studios.nodes[0].name}</span>}
                {fullItem.average_score ? <span>Score {fullItem.average_score}</span> : null}
                {!isManga && fullItem.next_airing?.episode && (
                  <span className="text-accent">
                    EP {fullItem.next_airing.episode} {airingCountdown(fullItem.next_airing.airing_at) || ""}
                  </span>
                )}
              </div>

              {/* Title */}
              <h1 className="text-2xl sm:text-3xl lg:text-4xl font-bold text-foreground leading-tight tracking-tight">{title}</h1>

              {/* Action bar */}
              <div className="flex items-center gap-3 flex-wrap">
                {primaryActionButton}

                {hasTrailer && (
                  <button
                    onClick={handlePlayTrailer}
                    disabled={isResolvingTrailer}
                    className="flex items-center gap-2 px-5 py-3 bg-surface border border-border text-foreground/80 hover:text-foreground hover:bg-foreground/[0.03] rounded-md text-sm font-medium transition-all active:scale-95 disabled:opacity-50"
                  >
                    {isResolvingTrailer ? <Loader2 size={18} className="animate-spin" /> : <Film size={18} />}
                    <span>Trailer</span>
                  </button>
                )}

                <button
                  onClick={handleToggleFavourite}
                  disabled={isTogglingFavourite}
                  title={fullItem?.is_favourite ? "Remove from AniList favourites" : "Add to AniList favourites"}
                  className={`p-3 rounded-md border transition-all active:scale-95 disabled:opacity-50 ${
                    fullItem?.is_favourite
                      ? "bg-pink-500/15 hover:bg-pink-500/25 text-pink-500 border-pink-500/25"
                      : "glass-button"
                  }`}
                >
                  <Heart size={18} fill={fullItem?.is_favourite ? "currentColor" : "none"} />
                </button>

                <div className="relative">
                  <select
                    value={(() => { const s = fullItem.user_status?.status?.toLowerCase(); return s === 'current' ? 'watching' : (s || 'none'); })()}
                    onChange={(e) => {
                      const newStatus = e.target.value;
                      if (newStatus === 'none') {
                        handleRemoveFromList(true);
                      } else {
                        setIsUpdatingStatus(true);
                        mediaApi.updateStatus(item.id, newStatus)
                          .then(() => {
                            updateProgressInQueries(queryClient, item.id, actualProgress, newStatus);
                            queryClient.invalidateQueries({ queryKey: ['media-detail', item.id], refetchType: 'all' });
                            queryClient.invalidateQueries({ queryKey: ['lists'] });
                            queryClient.invalidateQueries({ queryKey: ['home-watching'], refetchType: 'all' });
                            queryClient.invalidateQueries({ queryKey: ['home-repeating'], refetchType: 'all' });
                            dispatchRefresh();
                          })
                          .catch((err) => { console.error('Failed to update status:', err); notifyError("Couldn't update your list status on AniList."); })
                          .finally(() => setIsUpdatingStatus(false));
                      }
                    }}
                    disabled={isUpdatingStatus}
                    className="bg-surface border border-border text-foreground/80 hover:text-foreground rounded-md pl-4 pr-10 py-3 text-sm font-medium focus:outline-none focus:border-accent transition-all cursor-pointer appearance-none"
                  >
                    <option value="none" className="text-muted-foreground">-- Add to List --</option>
                    <option value="planning">Planning</option>
                    <option value="watching">{isManga ? 'Reading' : 'Watching'}</option>
                    <option value="repeating">{isManga ? 'Rereading' : 'Rewatching'}</option>
                    <option value="completed">Completed</option>
                    <option value="paused">Paused</option>
                    <option value="dropped">Dropped</option>
                  </select>
                  <div className="absolute right-3 top-1/2 -translate-y-1/2 pointer-events-none text-muted-foreground">
                    <ChevronDown size={16} />
                  </div>
                </div>

                <button
                  onClick={handleRemoveFromList}
                  title={deleteConfirmPending ? 'Click again to confirm removal' : 'Remove from List'}
                  className={`p-3 rounded-md transition-all border active:scale-95 ${
                    deleteConfirmPending
                      ? 'bg-red-500/80 text-background border-red-500 scale-105 animate-pulse'
                      : 'bg-red-500/10 hover:bg-red-500/20 text-red-500/70 hover:text-red-500 border-red-500/20'
                  }`}
                >
                  <Trash2 size={20} />
                </button>
              </div>

              {/* Synopsis */}
              {fullItem.description && (
                <div className="space-y-3">
                  <h3 className="meta-mono text-accent">Synopsis</h3>
                  <motion.div
                    className="relative overflow-hidden"
                    animate={{ maxHeight: isExpanded ? 2000 : 60 }}
                    initial={false}
                    transition={{ duration: 0.4, ease: [0.25, 0.46, 0.45, 0.94] }}
                  >
                    <p ref={synopsisRef} className="text-sm text-muted-foreground leading-relaxed" dangerouslySetInnerHTML={{ __html: sanitizeHtml(fullItem.description) }} />
                  </motion.div>
                  {synopsisOverflows && (
                    <button onClick={() => setIsExpanded(!isExpanded)} className="flex items-center space-x-1.5 text-[11px] font-bold text-foreground/50 hover:text-foreground transition-colors group">
                      <span>{isExpanded ? 'Show Less' : 'Read Full Synopsis'}</span>
                      {isExpanded ? <ChevronUp size={14} /> : <ChevronDown size={14} className="group-hover:translate-y-0.5 transition-transform" />}
                    </button>
                  )}
                </div>
              )}

              {/* Next Episode Banner */}
              {!isManga && fullItem.next_airing && (
                <div className="bg-accent/[0.06] border border-accent/10 rounded-md p-4 flex items-center gap-4 next-episode-banner">
                  <div className="p-2.5 bg-accent/10 rounded-xl text-accent"><Calendar size={18} /></div>
                  <div>
                    <div className="meta-mono text-accent mb-0.5">Next Episode</div>
                    <div className="text-sm text-foreground font-bold">
                      Episode {fullItem.next_airing.episode}{' '}
                      <span className="text-muted-foreground font-medium text-xs">airing {formatRelativeTimeFromUnix(fullItem.next_airing.airing_at ?? 0)}</span>
                    </div>
                  </div>
                </div>
              )}

              {/* Season chain: previous / next */}
              {(prequel || sequel) && (
                <div className="grid grid-cols-1 sm:grid-cols-2 gap-3">
                  {[
                    { rel: prequel, label: 'Previous', side: 'prev' as const },
                    { rel: sequel, label: 'Next', side: 'next' as const },
                  ].filter((s) => s.rel).map(({ rel, label, side }) => {
                    const cover = rel?.cover_image?.large || rel?.coverImage?.large;
                    return (
                      <button
                        key={side}
                        onClick={() => rel && selectItem(rel)}
                        className={`group flex items-center gap-3 p-2.5 border border-border rounded-md bg-foreground/[0.02] hover:bg-surface/70 hover:border-foreground/20 transition-all text-left ${side === 'next' ? 'sm:flex-row-reverse sm:text-right' : ''}`}
                      >
                        {side === 'prev'
                          ? <ChevronLeft size={18} className="shrink-0 text-muted-foreground group-hover:text-accent transition-colors" />
                          : <ChevronRight size={18} className="shrink-0 text-muted-foreground group-hover:text-accent transition-colors" />}
                        {cover && <img src={proxyImage(cover)} className="w-10 h-14 rounded-lg object-cover shrink-0" />}
                        <div className="min-w-0 flex-1">
                          <div className="meta-mono text-accent">{label} Season</div>
                          <div className="text-sm font-bold text-foreground truncate group-hover:text-accent transition-colors">{rel?.title?.english || rel?.title?.romaji}</div>
                          {rel?.format && <div className="text-[10px] text-muted-foreground mt-0.5">{rel.format}</div>}
                        </div>
                      </button>
                    );
                  })}
                </div>
              )}
            </div>
          </div>

          {/* Tabs */}
          <div className="mt-8 space-y-6">
            <div className="flex border-b border-border pb-0 relative">
              {(['episodes', 'characters', 'seasons', 'more'] as const).map((tab) => (
                <button
                  key={tab}
                  onClick={() => setActiveTab(tab)}
                  className={`px-4 py-2.5 text-sm font-semibold relative transition-colors ${activeTab === tab ? 'text-foreground' : 'text-muted-foreground hover:text-foreground'}`}
                >
                  {tab === 'episodes' ? (isManga ? 'Chapters' : 'Episodes') : tab === 'seasons' ? 'Related' : tab.charAt(0).toUpperCase() + tab.slice(1)}
                  {activeTab === tab && (
                    <motion.div layoutId="tab-indicator" className="absolute bottom-0 left-0 right-0 h-[2px] bg-accent rounded-full" />
                  )}
                </button>
              ))}
            </div>

            <div className="min-h-[300px]">
              <AnimatePresence mode="popLayout">
                {activeTab === 'episodes' && (
                  <motion.div key="episodes" initial={{ opacity: 0, y: 6 }} animate={{ opacity: 1, y: 0 }} exit={{ opacity: 0, y: -6 }} transition={{ duration: 0.18 }} className="h-full w-full">
                    {!isManga && (
                      <div className="glass-panel p-3 mb-5 flex flex-col sm:flex-row sm:items-center justify-between gap-3">
                        <div className="flex flex-wrap gap-2">
                          <button
                            onClick={handleToggleAutoskip}
                            className={`flex items-center space-x-2 px-3 py-1.5 rounded-md text-xs font-semibold transition-all ${autoskip ? 'bg-accent/15 text-accent border border-accent/30' : 'bg-surface text-muted-foreground border border-border hover:bg-foreground/[0.03]'}`}
                          >
                            <SkipForward size={14} fill={autoskip ? 'currentColor' : 'none'} />
                            <span>Auto Skip Intro</span>
                          </button>
                          <button
                            onClick={handleToggleUpscaling}
                            className={`flex items-center space-x-2 px-3 py-1.5 rounded-md text-xs font-semibold transition-all ${shaderProfile !== 'off' ? 'bg-accent/15 text-accent border border-accent/30' : 'bg-surface text-muted-foreground border border-border hover:bg-foreground/[0.03]'}`}
                          >
                            <Sparkles size={14} className={shaderProfile !== 'off' ? 'text-accent' : ''} />
                            <span>Upscaling</span>
                          </button>
                          <button
                            onClick={handleToggleAutoNext}
                            className={`flex items-center space-x-2 px-3 py-1.5 rounded-md text-xs font-semibold transition-all ${autoplay ? 'bg-accent/15 text-accent border border-accent/30' : 'bg-surface text-muted-foreground border border-border hover:bg-foreground/[0.03]'}`}
                          >
                            <PlayCircle size={14} className={autoplay ? 'text-accent' : ''} />
                            <span>Auto Next</span>
                          </button>
                        </div>
                        <div className="flex items-center gap-2">
                          {(!isManga && episodes.length > 0) && (
                            <button
                              onClick={handleDownloadAll}
                              disabled={queueingAll}
                              className="p-1.5 rounded-lg glass-button transition-all active:scale-95 text-accent disabled:opacity-50"
                              title="Download All Episodes"
                            >
                              {queueingAll ? <Loader2 size={14} className="animate-spin" /> : <Download size={14} />}
                            </button>
                          )}
                          <select value={selectedProvider} onChange={(e) => setSelectedProvider(e.target.value)} className="text-xs bg-surface border border-border rounded-lg px-3 py-1.5 text-foreground outline-none">
                            <option value="mkissa">Mkissa</option>
                            <option value="anineko">AniNeko</option>
                            <option value="nyaa">Torrents (1080p)</option>
                          </select>
                          <button
                            onClick={async () => {
                              await mediaApi.clearProviderCache(item.id).catch(() => {});
                              queryClient.invalidateQueries({ queryKey: ['media-episodes', item.id] });
                              queryClient.invalidateQueries({ queryKey: ['media-detail', item.id] });
                            }}
                            className="p-1.5 rounded-lg glass-button transition-all active:scale-95"
                            title="Re-match source"
                          >
                            <RotateCcw size={14} />
                          </button>
                        </div>
                      </div>
                    )}
                    {(() => {
                      const total = isManga
                        ? (fullItem.chapters || episodes.length || 0)
                        : (fullItem.episodes || episodes.length || 0);
                      const nextAiringEp = fullItem.next_airing?.episode;
                      const latestAvailable = !isManga && nextAiringEp ? nextAiringEp - 1 : undefined;
                      return (
                        <WatchGrid
                          total={total}
                          progress={actualProgress}
                          latestAvailable={latestAvailable}
                          isManga={isManga}
                          onPlay={(n) => handlePlayNext(n)}
                        />
                      );
                    })()}
                    <EpisodeList
                      mediaId={item.id}
                      episodes={episodes}
                      loading={loadingEps}
                      progress={actualProgress}
                      isManga={isManga}
                      onRead={(chNum) => setActiveChapter(chNum)}
                      selectedProvider={selectedProvider}
                      mediaTitle={fullItem.title?.english || fullItem.title?.romaji || title}
                      coverImage={fullItem?.banner_image || fullItem?.cover_image?.large || item?.banner_image || item?.cover_image?.large || ''}
                      episodeTitleMap={episodeTitleMap}
                      fillerEpisodes={fillerEpisodes}
                      onUnwatch={(num) => handleUpdateProgress(Number(num) - 1)}
                      onWatch={(num) => handleUpdateProgress(Number(num))}
                      nextAiringEpisode={fullItem.next_airing?.episode}
                      nextAiringTime={fullItem.next_airing?.airing_at}
                      onRetry={async () => {
                        await mediaApi.clearProviderCache(item.id).catch(() => {});
                        queryClient.invalidateQueries({ queryKey: ['media-episodes', item.id], refetchType: 'all' });
                        queryClient.invalidateQueries({ queryKey: ['media-detail', item.id], refetchType: 'all' });
                      }}
                    />
                  </motion.div>
                )}
                {activeTab === 'characters' && (
                  <motion.div key="characters" initial={{ opacity: 0, y: 6 }} animate={{ opacity: 1, y: 0 }} exit={{ opacity: 0, y: -6 }} transition={{ duration: 0.18 }} className="h-full w-full">
                    <div className="grid grid-cols-2 sm:grid-cols-3 lg:grid-cols-4 gap-4">
                      {loadingChars ? (
                        <div className="col-span-4 py-20 flex justify-center"><Loader2 className="animate-spin text-accent" size={24} /></div>
                      ) : characters.length > 0 ? (
                        characters.map((char: Character) => (
                          <button key={char.id || char.name.full} onClick={() => setSelectedCharacter(char)} className="flex items-center space-x-3 p-3 glass-panel hover:bg-foreground/[0.03] transition-colors group character-card text-left">
                            {char.image?.large && <img src={char.image.large} alt={char.name.full} className="w-14 h-14 rounded-xl object-cover shadow-lg" />}
                            <div className="min-w-0">
                              <div className="text-[13px] font-bold text-foreground group-hover:text-accent transition-colors truncate">{char.name.full}</div>
                              <div className="text-[10px] text-muted-foreground">{char.role?.replace(/_/g, ' ')?.toLowerCase()}</div>
                            </div>
                          </button>
                        ))
                      ) : (
                        <div className="col-span-4 py-20 text-center text-muted-foreground text-xs font-bold">No character data available.</div>
                      )}
                    </div>
                  </motion.div>
                )}
                {activeTab === 'seasons' && (
                  <motion.div key="seasons" initial={{ opacity: 0, y: 6 }} animate={{ opacity: 1, y: 0 }} exit={{ opacity: 0, y: -6 }} transition={{ duration: 0.18 }} className="h-full w-full">
                    {(() => {
                      type RelEdge = { relationType: string; node?: MediaItem };
                      const seasonRels = relations.filter((r: RelEdge) => ['PREQUEL','SEQUEL','PARENT','SIDE_STORY','SUMMARY','ADAPTATION'].includes(r.relationType));
                      const otherRels = relations.filter((r: RelEdge) => !['PREQUEL','SEQUEL','PARENT','SIDE_STORY','SUMMARY','ADAPTATION'].includes(r.relationType));
                      if (!seasonRels.length && !otherRels.length) return <div className="py-20 text-center text-muted-foreground text-xs font-bold">No related content.</div>;
                      return (
                        <div className="space-y-6">
                          {seasonRels.length > 0 && (
                            <div className="space-y-3">
                              <p className="text-xs font-semibold text-foreground">Seasons & Adaptations</p>
                              <div className="grid grid-cols-2 sm:grid-cols-3 lg:grid-cols-4 gap-4">
                                {seasonRels.map((rel: { relationType: string; node?: MediaItem }) => {
                                  const m = rel.node; if (!m) return null;
                                  return (
                                    <button key={m.id} onClick={() => selectItem(m)} className="flex items-start gap-3 group text-left p-2 rounded-md hover:bg-foreground/[0.03] transition-colors">
                                      {(m.cover_image?.large || m.coverImage?.large) && <img src={proxyImage(m.cover_image?.large || m.coverImage?.large)} className="w-12 h-16 rounded-lg object-cover shrink-0" />}
                                      <div className="min-w-0">
                                        <div className="text-xs font-semibold text-foreground group-hover:text-accent transition-colors">{m.title?.english || m.title?.romaji}</div>
                                        {rel.relationType && <div className="text-[9px] font-bold text-accent/80 mt-0.5">{rel.relationType.replace(/_/g, ' ')}</div>}
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
                              <div className="grid grid-cols-2 sm:grid-cols-3 lg:grid-cols-4 gap-4">
                                {otherRels.map((rel: { relationType: string; node?: MediaItem }) => {
                                  const m = rel.node; if (!m) return null;
                                  return (
                                    <button key={m.id} onClick={() => selectItem(m)} className="flex items-start gap-3 group text-left p-2 rounded-md hover:bg-foreground/[0.03] transition-colors">
                                      {(m.cover_image?.large || m.coverImage?.large) && <img src={proxyImage(m.cover_image?.large || m.coverImage?.large)} className="w-12 h-16 rounded-lg object-cover shrink-0" />}
                                      <div className="min-w-0">
                                        <div className="text-xs font-semibold text-foreground group-hover:text-accent transition-colors">{m.title?.english || m.title?.romaji}</div>
                                        {rel.relationType && <div className="text-[9px] font-bold text-accent/80 mt-0.5">{rel.relationType.replace(/_/g, ' ')}</div>}
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
                {activeTab === 'more' && (
                  <motion.div key="more" initial={{ opacity: 0, y: 6 }} animate={{ opacity: 1, y: 0 }} exit={{ opacity: 0, y: -6 }} transition={{ duration: 0.18 }} className="h-full w-full">
                    {recommendations.length > 0 ? (
                      <div className="space-y-4">
                        <p className="text-xs font-semibold text-foreground">Recommendations</p>
                        <div className="grid grid-cols-3 sm:grid-cols-4 lg:grid-cols-6 gap-4">
                          {(recommendations as { mediaRecommendation?: MediaItem; cover_image?: { large?: string }; coverImage?: { large?: string }; rating?: number }[]).map((rec) => {
                            const m = rec.mediaRecommendation; if (!m) return null;
                            return (
                              <button key={m.id} onClick={() => selectItem(m)} className="group space-y-2 text-left relative">
                                <div className="aspect-[2/3] rounded-xl overflow-hidden border border-border shadow-lg">
                                  <img src={proxyImage(rec.cover_image?.large || m.coverImage?.large)} className="w-full h-full object-cover transition-transform duration-500 group-hover:scale-110" />
                                </div>
                                {(rec.rating ?? 0) > 0 && <span className="absolute top-2 right-2 px-1.5 py-0.5 rounded bg-accent text-background text-[9px] font-bold">{rec.rating}%</span>}
                                <div className="text-[11px] font-bold text-muted-foreground line-clamp-2 group-hover:text-foreground transition-colors">{m.title?.english || m.title?.romaji}</div>
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

      {/* Character detail modal */}
      {selectedCharacter && (
        <div className="fixed inset-0 z-[200] flex items-center justify-center" onClick={() => setSelectedCharacter(null)}>
          <div className="absolute inset-0 bg-black/60" />
          <div className="relative max-w-md w-[90%] bg-background border border-border rounded-lg p-6 shadow-2xl" onClick={(e) => e.stopPropagation()}>
            <button onClick={() => setSelectedCharacter(null)} className="absolute top-3 right-3 text-muted-foreground hover:text-foreground transition-colors"><X size={16} /></button>
            <div className="flex items-start space-x-4">
              {selectedCharacter.image?.large && <img src={selectedCharacter.image.large} alt={selectedCharacter.name?.full} className="w-20 h-20 rounded-xl object-cover shadow-lg shrink-0" />}
              <div className="min-w-0 space-y-1">
                <div className="text-base font-bold text-foreground">{selectedCharacter.name?.full}</div>
                <div className="text-[11px] text-muted-foreground capitalize">{selectedCharacter.role?.replace(/_/g, ' ')?.toLowerCase()}</div>
                {(selectedCharacter.voiceActors?.length ?? 0) > 0 && (
                  <div className="pt-2 space-y-1.5">
                    <div className="meta-mono text-muted-foreground">Voice Actors</div>
                    {selectedCharacter.voiceActors?.map((va) => (
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

      {/* Manga reader */}
      {activeChapter && (
        <MangaReader
          mediaId={item.id}
          chapterNumber={activeChapter}
          onClose={() => setActiveChapter(null)}
          onProgressUpdate={async (chapterNum) => {
            const num = parseInt(chapterNum) || 0;
            if (num > actualProgress) await handleUpdateProgress(num);
          }}
          onNavigateChapter={(direction) => {
            const idx = episodes.findIndex((ep) => String(ep.number) === activeChapter);
            if (direction === 'prev' && idx > 0) setActiveChapter(String(episodes[idx - 1].number));
            else if (direction === 'next' && idx < episodes.length - 1) setActiveChapter(String(episodes[idx + 1].number));
          }}
          hasPrevChapter={episodes.findIndex((ep) => String(ep.number) === activeChapter) > 0}
          hasNextChapter={episodes.findIndex((ep) => String(ep.number) === activeChapter) < episodes.length - 1}
        />
      )}
    </>
  );
}
