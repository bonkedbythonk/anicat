import { useEffect, useState, useRef, useMemo } from "react";
import { useQuery, useQueryClient } from "@tanstack/react-query";
import { motion, AnimatePresence } from "framer-motion";
import {
  ChevronLeft, ChevronDown, ChevronUp, Play, BookOpen, Heart, Loader2, Star,
  SkipForward, PlayCircle, RotateCcw, Frown, Meh, Smile, Minus, Plus,
} from "lucide-react";
import { mediaApi, type MediaItem, type Episode, type Character } from "@/lib/api";
import { sanitizeHtml } from "@/lib/sanitize";
import { proxyImage } from "@/lib/proxy";
import { dispatchRefresh, updateProgressInQueries, removeMediaFromQueries } from "@/lib/events";
import { formatRelativeTimeFromUnix } from "@/lib/date";
import { useProgressEditor } from "@/lib/useProgressEditor";
import { useAppStore, useSettingsStore } from "@/stores/app";
import MangaReader from "@/components/media/MangaReader";
import { MobileEpisodeList } from "./MobileEpisodeList";
import { loadMobileSettings } from "./mobileSettings";
import { PosterCard } from "./PosterCard";
import { BottomSheet, SheetRow } from "./BottomSheet";

const SCORE_FORMAT_MAX: Record<string, number> = {
  POINT_100: 100, POINT_10: 10, POINT_10_DECIMAL: 10, POINT_5: 5, POINT_3: 3,
};

const STATUS_OPTIONS = [
  { value: "planning", label: "Planning" },
  { value: "watching", label: "Watching", mangaLabel: "Reading" },
  { value: "repeating", label: "Rewatching", mangaLabel: "Rereading" },
  { value: "completed", label: "Completed" },
  { value: "paused", label: "Paused" },
  { value: "dropped", label: "Dropped" },
];

interface MobileMediaDetailProps {
  item: MediaItem;
  onClose: () => void;
  initialAction?: "play";
}

/** Mobile-native detail page — same AniList queries/mutations as the shared
 * desktop `MediaDetail` (kept byte-identical for desktop), entirely
 * different presentation: no side-by-side cover+title layout, no hover-only
 * actions, native bottom sheets instead of `<select>`/centered modals. */
export function MobileMediaDetail({ item, onClose, initialAction }: MobileMediaDetailProps) {
  const [isExpanded, setIsExpanded] = useState(false);
  const [synopsisOverflows, setSynopsisOverflows] = useState(false);
  const synopsisRef = useRef<HTMLParagraphElement>(null);
  const [isPlayingNext, setIsPlayingNext] = useState(false);
  const [activeTab, setActiveTab] = useState<"episodes" | "characters" | "related" | "more">("episodes");
  const [activeChapter, setActiveChapter] = useState<string | null>(null);
  const [selectedCharacter, setSelectedCharacter] = useState<Character | null>(null);
  const [statusSheetOpen, setStatusSheetOpen] = useState(false);
  const [progressSheetOpen, setProgressSheetOpen] = useState(false);
  const [scoreSheetOpen, setScoreSheetOpen] = useState(false);
  const [episodeSettingsOpen, setEpisodeSettingsOpen] = useState(false);
  const initialPlayEpisode = useAppStore((s) => s.initialPlayEpisode);
  const setNotification = useAppStore((s) => s.setNotification);
  const selectItem = useAppStore((s) => s.openDetail);
  const queryClient = useQueryClient();

  const notifyError = (msg: string) => {
    setNotification({ message: msg, type: "error" });
    setTimeout(() => setNotification(null), 5000);
  };

  const { data: config = null } = useQuery({
    queryKey: ["media-config", item.id],
    queryFn: () => mediaApi.getConfig(),
  });

  // Device-local Source setting (You tab) wins over the server's global
  // provider — config.toml is shared by every user in multi-user mode.
  const [selectedProvider, setSelectedProvider] = useState<string>("mkissa");
  useEffect(() => {
    const deviceProvider = loadMobileSettings().defaultProvider;
    const provider = deviceProvider || (config?.general?.provider as string | undefined);
    if (provider) setSelectedProvider(provider);
  }, [config]);

  const isManga = item.type === "MANGA" || !!(item.format && ["MANGA", "ONE_SHOT", "NOVEL"].includes(item.format));

  const { data: fullItemData, isLoading: loading } = useQuery({
    queryKey: ["media-detail", item.id],
    queryFn: () => mediaApi.getDetails(item.id, isManga ? "MANGA" : "ANIME"),
  });
  const fullItem = fullItemData ?? item;
  const banner = fullItem?.banner_image || fullItem?.cover_image?.large || item?.banner_image || item?.cover_image?.large;
  const progressEditor = useProgressEditor();
  const scoreEditor = useProgressEditor();

  const { data: episodesRaw, isLoading: loadingEps } = useQuery({
    queryKey: ["media-episodes", item.id, isManga ? "mangakatana" : selectedProvider],
    queryFn: () => mediaApi.getEpisodes(item.id, isManga ? "mangakatana" : selectedProvider, item.title?.english || item.title?.romaji || item.title?.native || undefined, fullItem?.episodes ?? item.episodes ?? undefined),
    enabled: !!selectedProvider || isManga,
  });
  const episodes: Episode[] = Array.isArray(episodesRaw) ? episodesRaw : [];

  const actualProgress =
    fullItem?.media_list_entry?.progress ??
    fullItem?.user_status?.progress ??
    item?.media_list_entry?.progress ??
    item?.user_status?.progress ??
    0;
  const actualScore = fullItem?.media_list_entry?.score ?? fullItem?.user_status?.score ?? null;
  const actualProgressVolumes = fullItem?.media_list_entry?.progress_volumes ?? fullItem?.user_status?.progress_volumes ?? null;

  const relations = useMemo(() => fullItem?.relations?.edges || item.relations?.edges || [], [fullItem, item]);
  const recommendations = useMemo(() => fullItem?.recommendations?.nodes || item.recommendations?.nodes || [], [fullItem, item]);

  const pickRel = (type: string) => {
    const matches = relations.filter((r: { relationType: string; node?: MediaItem }) => r.relationType === type && r.node);
    if (!matches.length) return null;
    return (matches.find((r: { relationType: string; node?: MediaItem }) => r.node?.format === "TV") || matches[0]).node;
  };
  const prequel = useMemo(() => pickRel("PREQUEL"), [relations]);
  const sequel = useMemo(() => pickRel("SEQUEL"), [relations]);

  const { data: anizipTitles = {} } = useQuery({
    queryKey: ["anizip-titles", item.id],
    queryFn: () => mediaApi.fetchAniZipTitles(item.id),
    staleTime: 24 * 60 * 60 * 1000,
  });
  const { data: scoreFormat = "POINT_100" } = useQuery({
    queryKey: ["viewer-score-format"],
    queryFn: async () => (await mediaApi.getUserProfile())?.Viewer?.mediaListOptions?.scoreFormat || "POINT_100",
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
    for (const [num, title] of Object.entries(anizipTitles)) map[Number(num)] = title;
    return map;
  }, [fullItem, anizipTitles]);

  const { data: characters = [], isLoading: loadingChars } = useQuery({
    queryKey: ["media-characters", item.id],
    queryFn: async () => {
      const res = await mediaApi.getCharacters(item.id);
      const r = res as { Media?: { characters?: { edges?: unknown[] } }; media?: { characters?: { edges?: unknown[] } }; characters?: { edges?: unknown[] }; edges?: unknown[] };
      const edges = r?.Media?.characters?.edges || r?.media?.characters?.edges || r?.characters?.edges || r?.edges || [];
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
  // The specific episode requested by whatever quick-play button opened this
  // page only applies to this one automatic trigger, never to later manual
  // clicks of the Continue button (see handlePlayNext).
  useEffect(() => {
    if (initialAction === "play" && !loading && config && !hasTriggeredInitial) {
      setHasTriggeredInitial(true);
      handlePlayNext(initialPlayEpisode ? Number(initialPlayEpisode) : undefined, config?.general?.provider as string);
    }
    // eslint-disable-next-line react-hooks/exhaustive-deps
  }, [initialAction, loading, config, hasTriggeredInitial]);

  useEffect(() => {
    if (!synopsisRef.current) return;
    setSynopsisOverflows(synopsisRef.current.scrollHeight > 60);
  }, [fullItem.description]);

  useEffect(() => {
    if (isManga || !selectedProvider) return;
    const continueEpisode = actualProgress + 1;
    mediaApi.preloadEpisode(item.id, continueEpisode, selectedProvider, item.title?.english || item.title?.romaji || item.title?.native || undefined).catch(() => {});
  }, [isManga, selectedProvider, actualProgress, item.id]);

  const isProcessingAction = useRef(false);
  // `overrideEpisode` is only passed by the one-time initial-action effect
  // above. Manual clicks of the Continue button omit it, always falling
  // through to the freshly computed `actualProgress + 1` — otherwise a stale
  // `initialPlayEpisode` left over from how this page was originally opened
  // would keep getting replayed on every later click, even after watching
  // further episodes from within the same open session.
  const handlePlayNext = async (overrideEpisode?: number, providerOverride?: string) => {
    if (isPlayingNext || isProcessingAction.current) return;
    isProcessingAction.current = true;
    setIsPlayingNext(true);
    try {
      if (isManga) {
        setActiveChapter(String(overrideEpisode ?? actualProgress + 1));
      } else {
        if (!overrideEpisode && (!fullItem.status || fullItem.status === "FINISHED" || fullItem.status === "CANCELLED")) {
          if (fullItem.episodes && actualProgress >= fullItem.episodes) return;
        }
        const nextEpNum = overrideEpisode ?? actualProgress + 1;
        const coverImg = fullItem?.banner_image || fullItem?.cover_image?.large || item?.banner_image || item?.cover_image?.large || "";
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
      setTimeout(() => { isProcessingAction.current = false; }, 500);
    }
  };

  const autoskip = useSettingsStore((s) => s.autoskip);
  const setAutoskip = useSettingsStore((s) => s.setAutoskip);
  const autoplay = useSettingsStore((s) => s.autoplay);
  const setAutoplay = useSettingsStore((s) => s.setAutoplay);

  const handleToggleAutoskip = async () => {
    const v = !autoskip; setAutoskip(v);
    try { await mediaApi.updateConfig({ general: { autoskip: v } }); } catch { /* noop */ }
  };
  const handleToggleAutoNext = async () => {
    const v = !autoplay; setAutoplay(v);
    try { await mediaApi.updateConfig({ general: { autoplay: v } }); } catch { /* noop */ }
  };

  const handleUpdateProgress = async (newProgress: number) => {
    const updates: Record<string, unknown> = { progress: newProgress };
    if (newProgress > 0) {
      const currentStatus = fullItem?.media_list_entry?.status ?? fullItem?.user_status?.status;
      if (!currentStatus || currentStatus === "PLANNING") updates.status = "CURRENT";
    }
    updateProgressInQueries(queryClient, item.id, newProgress);
    progressEditor.cancelEditing();
    mediaApi.saveMediaListEntry(item.id, updates)
      .then(() => {
        queryClient.invalidateQueries({ queryKey: ["media-detail", item.id], refetchType: "all" });
        queryClient.invalidateQueries({ queryKey: ["lists"] });
        queryClient.invalidateQueries({ queryKey: ["home-watching"], refetchType: "all" });
        queryClient.invalidateQueries({ queryKey: ["home-repeating"], refetchType: "all" });
        queryClient.invalidateQueries({ queryKey: ["manga-data"], refetchType: "all" });
        dispatchRefresh();
      })
      .catch((err) => { console.error("Failed to update progress:", err); notifyError("Couldn't update progress on AniList."); });
  };

  const handleUpdateScore = async (newScore: number) => {
    const clamped = Math.max(0, Math.min(SCORE_FORMAT_MAX[scoreFormat] ?? 100, newScore));
    scoreEditor.cancelEditing();
    queryClient.setQueryData(["media-detail", item.id], (old: MediaItem | undefined) => old && ({ ...old, media_list_entry: { ...(old.media_list_entry || {}), score: clamped } }));
    mediaApi.saveMediaListEntry(item.id, { score: clamped })
      .then(() => {
        queryClient.invalidateQueries({ queryKey: ["media-detail", item.id], refetchType: "all" });
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
    queryClient.setQueryData(["media-detail", item.id], (old: MediaItem | undefined) => old && ({ ...old, is_favourite: next }));
    try {
      await mediaApi.toggleFavourite(item.id, isManga);
    } catch (err) {
      console.error("Failed to toggle favourite:", err);
      notifyError(next ? "Couldn't add to AniList favourites." : "Couldn't remove from AniList favourites.");
      queryClient.setQueryData(["media-detail", item.id], (old: MediaItem | undefined) => old && ({ ...old, is_favourite: !next }));
    } finally {
      setIsTogglingFavourite(false);
    }
  };

  const handleRemoveFromList = async () => {
    setStatusSheetOpen(false);
    onClose();
    const qc = queryClient;
    const listQueryKeys = [["lists"], ["home-recently-watched"], ["home-watching"], ["home-repeating"]];
    interface ListPage { media?: MediaItem[]; page_info?: unknown }
    const snapshots = new Map<string, ListPage | undefined>();
    for (const key of listQueryKeys) {
      snapshots.set(JSON.stringify(key), qc.getQueryData<ListPage>(key as unknown[]));
      qc.setQueryData(key as unknown[], (old: ListPage | undefined) => old?.media && ({ ...old, media: old.media.filter((m) => m.id !== item.id) }));
    }
    qc.invalidateQueries({ queryKey: ["media-detail", item.id] });
    mediaApi.deleteFromList(fullItem?.user_status?.id || fullItem?.media_list_entry?.id || 0)
      .then(() => {
        removeMediaFromQueries(qc, item.id);
        for (const key of listQueryKeys) qc.invalidateQueries({ queryKey: key as unknown[] });
        qc.invalidateQueries({ queryKey: ["playback-status"] });
        dispatchRefresh();
      })
      .catch((error) => {
        console.error("Failed to remove from list:", error);
        notifyError("Couldn't remove this from your AniList list.");
        for (const [keyStr, snapshot] of snapshots) qc.setQueryData(JSON.parse(keyStr) as unknown[], snapshot);
      });
  };

  const handleSetStatus = (newStatus: string) => {
    setStatusSheetOpen(false);
    mediaApi.updateStatus(item.id, newStatus)
      .then(() => {
        updateProgressInQueries(queryClient, item.id, actualProgress, newStatus);
        queryClient.invalidateQueries({ queryKey: ["media-detail", item.id], refetchType: "all" });
        queryClient.invalidateQueries({ queryKey: ["lists"] });
        queryClient.invalidateQueries({ queryKey: ["home-watching"], refetchType: "all" });
        queryClient.invalidateQueries({ queryKey: ["home-repeating"], refetchType: "all" });
        dispatchRefresh();
      })
      .catch((err) => { console.error("Failed to update status:", err); notifyError("Couldn't update your list status on AniList."); });
  };

  const title = fullItem?.title?.english || fullItem?.title?.romaji || item?.title?.english || item?.title?.romaji || "";
  const currentStatus = fullItem.user_status?.status?.toLowerCase();
  const currentStatusLabel = STATUS_OPTIONS.find((s) => s.value === (currentStatus === "current" ? "watching" : currentStatus));

  const total = fullItem.episodes || fullItem.chapters || 0;
  const nextAiringEp = fullItem.next_airing?.episode;
  const filteredEps = episodes.filter((e) => !nextAiringEp || Number(e.number) < nextAiringEp).map((e) => Number(e.number));
  const latestAvailable = episodes.length > 0 && filteredEps.length > 0 ? Math.max(...filteredEps) : total;
  const nextEpisode = actualProgress + 1;
  // A still-RELEASING show can't be "Completed" even if AniList's reported
  // `episodes` total happens to already match how many have aired so far
  // (its eventual total, once known, is often set before the season
  // finishes) — without this guard, watching everything currently out
  // shows "Completed" instead of "Caught Up".
  const isFinished = total > 0 && actualProgress >= total && fullItem.status !== "RELEASING";
  const isCaughtUp = !isFinished && latestAvailable > 0 && actualProgress >= latestAvailable;

  const seasonRels = relations.filter((r: { relationType: string }) => ["PREQUEL", "SEQUEL", "PARENT", "SIDE_STORY", "SUMMARY", "ADAPTATION"].includes(r.relationType));

  return (
    <>
      <div className="-mx-6 -mt-4">
        {/* Banner — art carries the color; chrome stays quiet. No ambient
            radial glow (banned by the skin), just a straight fade into the
            ink ground. */}
        <div className="relative w-full overflow-hidden" style={{ height: "32vh" }}>
          <img src={proxyImage(banner)} alt={title} className="h-full w-full object-cover" />
          <div className="absolute inset-0" style={{ background: "linear-gradient(to bottom, rgba(0,0,0,0.1) 0%, rgba(0,0,0,0.3) 45%, var(--background) 100%)" }} />
          <button onClick={onClose} className="absolute left-4 top-4 flex h-9 w-9 items-center justify-center rounded-full bg-black/50 text-white active:scale-90" style={{ marginTop: "env(safe-area-inset-top)" }}>
            <ChevronLeft size={20} />
          </button>
          <button
            onClick={handleToggleFavourite}
            disabled={isTogglingFavourite}
            className={`absolute right-4 top-4 flex h-9 w-9 items-center justify-center rounded-full active:scale-90 ${fullItem?.is_favourite ? "bg-accent text-background" : "bg-black/50 text-white"}`}
            style={{ marginTop: "env(safe-area-inset-top)" }}
          >
            <Heart size={17} fill={fullItem?.is_favourite ? "currentColor" : "none"} />
          </button>
        </div>

        <div className="px-6 -mt-5 relative space-y-4">
          {/* Mono metadata line — the card-catalog signature. */}
          <div className="flex flex-wrap gap-x-4 gap-y-1 font-mono text-[10.5px] uppercase tracking-[0.08em] text-muted-foreground tabular-nums">
            <span>{fullItem.format || (isManga ? "MANGA" : "ANIME")}</span>
            {!isManga && fullItem.episodes ? <span>{fullItem.episodes} EP</span> : null}
            {isManga && fullItem.chapters ? <span>{fullItem.chapters} CH</span> : null}
            {(fullItem.season_year || fullItem.seasonYear || fullItem.startDate?.year) && <span>{fullItem.season_year || fullItem.seasonYear || fullItem.startDate?.year}</span>}
            {fullItem.studios?.nodes?.[0]?.name && <span>{fullItem.studios.nodes[0].name}</span>}
            {fullItem.average_score ? <span>Score {fullItem.average_score}</span> : null}
            {fullItem.status === "RELEASING" && <span className="text-accent">Airing</span>}
          </div>
          <h1 className="text-[24px] font-bold leading-tight tracking-tight text-foreground">{title}</h1>
          {/* Genres are descriptive text, not structured metadata — normal-case
              pills, unlike the mono caps of the format/year/studio line above,
              which stays dense on purpose. */}
          {fullItem.genres && (
            <div className="flex flex-wrap gap-1.5">
              {fullItem.genres.slice(0, 4).map((g: string) => (
                <span
                  key={g}
                  className="rounded-full bg-foreground/[0.06] px-2.5 py-[3px] text-[12px] text-foreground/55"
                >
                  {g}
                </span>
              ))}
            </div>
          )}

          {/* Primary action */}
          <button
            onClick={() => handlePlayNext()}
            disabled={isPlayingNext || isCaughtUp}
            className="flex w-full items-center justify-center gap-2 rounded-md bg-accent py-3 text-[14px] font-semibold text-background active:scale-[0.98] disabled:opacity-40"
          >
            {isPlayingNext ? <Loader2 className="animate-spin" size={17} /> : isManga ? <BookOpen size={17} /> : <Play size={17} fill="currentColor" />}
            {isFinished ? "Completed" : isCaughtUp ? "Caught up" : `${isManga ? "Read" : "Play"} ${isManga ? "CH" : "EP"} ${nextEpisode}`}
          </button>

          {/* Watch grid — one square per episode, whole season legible in
              one glance; tap a square to play it. Skipped for very long
              shows where a thousand squares stops being legible (the
              episode list below still covers them). */}
          {!isManga && total > 0 && total <= 100 && (
            <div>
              <div className="flex flex-wrap gap-[5px]" style={{ touchAction: "pan-y" }}>
                {Array.from({ length: total }, (_, i) => i + 1).map((n) => {
                  const watched = n <= actualProgress;
                  const current = n === nextEpisode;
                  const unaired = nextAiringEp !== undefined && n >= nextAiringEp;
                  return (
                    <button
                      key={n}
                      disabled={unaired}
                      onClick={() => handlePlayNext(n)}
                      style={{ touchAction: "pan-y" }}
                      className={`grid h-[24px] w-[24px] place-items-center rounded-[4px] border font-mono text-[9px] tabular-nums ${
                        watched
                          ? "border-transparent bg-foreground/10 text-foreground"
                          : current
                            ? "border-accent text-foreground"
                            : unaired
                              ? "border-border text-muted-foreground/40"
                              : "border-border text-muted-foreground"
                      }`}
                    >
                      {n}
                    </button>
                  );
                })}
              </div>
              <p className="mt-2 font-mono text-[10px] uppercase tracking-[0.08em] text-muted-foreground tabular-nums">
                {actualProgress} of {total} watched{!isFinished && !isCaughtUp ? ` · up next EP ${nextEpisode}` : ""}
              </p>
            </div>
          )}

          {/* Status / progress / score row */}
          <div className="flex items-stretch gap-2">
            <button onClick={() => setStatusSheetOpen(true)} className="flex-1 rounded-md border border-border bg-surface px-3.5 py-2.5 text-left active:bg-foreground/[0.06]">
              <p className="font-mono text-[9.5px] uppercase tracking-[0.08em] text-muted-foreground">Status</p>
              <p className="mt-0.5 text-[13.5px] font-semibold text-foreground">{currentStatusLabel ? (isManga ? currentStatusLabel.mangaLabel || currentStatusLabel.label : currentStatusLabel.label) : "Add to list"}</p>
            </button>
            <button onClick={() => { progressEditor.startEditing(actualProgress); setProgressSheetOpen(true); }} className="flex-1 rounded-md border border-border bg-surface px-3.5 py-2.5 text-left active:bg-foreground/[0.06]">
              <p className="font-mono text-[9.5px] uppercase tracking-[0.08em] text-muted-foreground">Progress</p>
              <p className="mt-0.5 text-[13.5px] font-semibold text-foreground tabular-nums">{actualProgress} / {isManga ? fullItem.chapters || "?" : fullItem.episodes || "?"}</p>
            </button>
            <button onClick={() => { scoreEditor.startEditing(actualScore || 0); setScoreSheetOpen(true); }} className="flex-1 rounded-md border border-border bg-surface px-3.5 py-2.5 text-left active:bg-foreground/[0.06]">
              <p className="font-mono text-[9.5px] uppercase tracking-[0.08em] text-muted-foreground">{actualScore ? "Your score" : "Avg score"}</p>
              <p className="mt-0.5 text-[13.5px] font-semibold text-foreground tabular-nums">{actualScore ? actualScore : fullItem.average_score ? `${fullItem.average_score}%` : "-"}</p>
            </button>
          </div>

          {/* Synopsis */}
          {fullItem.description && (
            <div className="space-y-2">
              <motion.div className="relative overflow-hidden" animate={{ maxHeight: isExpanded ? 2000 : 60 }} initial={false} transition={{ duration: 0.35 }}>
                <p ref={synopsisRef} className="text-[13.5px] leading-relaxed text-muted-foreground" dangerouslySetInnerHTML={{ __html: sanitizeHtml(fullItem.description) }} />
              </motion.div>
              {synopsisOverflows && (
                <button onClick={() => setIsExpanded((v) => !v)} className="flex items-center gap-1 text-[12px] font-bold text-muted-foreground active:opacity-60">
                  {isExpanded ? "Show Less" : "Read More"}
                  {isExpanded ? <ChevronUp size={13} /> : <ChevronDown size={13} />}
                </button>
              )}
            </div>
          )}

          {/* Next episode — one mono countdown line, not a billboard card. */}
          {!isManga && fullItem.next_airing && (
            <p className="font-mono text-[10.5px] uppercase tracking-[0.08em] tabular-nums">
              <span className="text-accent">EP {fullItem.next_airing.episode}</span>{" "}
              <span className="text-muted-foreground">airing {formatRelativeTimeFromUnix(fullItem.next_airing.airing_at ?? 0)}</span>
            </p>
          )}

          {/* Prequel / sequel */}
          {(prequel || sequel) && (
            <div className="grid grid-cols-2 gap-2.5">
              {[{ rel: prequel, label: "Previous" }, { rel: sequel, label: "Next" }].filter((s) => s.rel).map(({ rel, label }) => (
                <button key={label} onClick={() => rel && selectItem(rel)} className="flex items-center gap-2.5 rounded-md border border-border bg-surface p-2.5 text-left active:bg-foreground/[0.06]">
                  {(rel?.cover_image?.large || rel?.coverImage?.large) && <img src={proxyImage(rel?.cover_image?.large || rel?.coverImage?.large)} className="h-14 w-10 shrink-0 rounded-[4px] object-cover" />}
                  <div className="min-w-0">
                    <p className="font-mono text-[9px] uppercase tracking-[0.08em] text-accent">{label}</p>
                    <p className="truncate text-[12px] font-semibold text-foreground">{rel?.title?.english || rel?.title?.romaji}</p>
                  </div>
                </button>
              ))}
            </div>
          )}

          {/* Tabs */}
          <div className="-mx-6 flex gap-2 overflow-x-auto px-6 pb-1 pt-2 scrollbar-hide">
            {(["episodes", "characters", "related", "more"] as const).map((tab) => (
              <button
                key={tab}
                onClick={() => setActiveTab(tab)}
                className={`shrink-0 rounded-full border px-3.5 py-1.5 font-mono text-[10px] uppercase tracking-[0.08em] ${
                  activeTab === tab ? "border-transparent bg-foreground/10 text-foreground" : "border-border text-muted-foreground"
                }`}
              >
                {tab === "episodes" ? (isManga ? "Chapters" : "Episodes") : tab === "related" ? "Related" : tab.charAt(0).toUpperCase() + tab.slice(1)}
              </button>
            ))}
          </div>

          <AnimatePresence mode="popLayout">
            {activeTab === "episodes" && (
              <motion.div key="episodes" initial={{ opacity: 0 }} animate={{ opacity: 1 }} exit={{ opacity: 0 }} className="space-y-3 w-full">
                {!isManga && (
                  <button onClick={() => setEpisodeSettingsOpen(true)} className="flex w-full items-center justify-between rounded-md border border-border px-4 py-2.5 text-[13px] text-muted-foreground active:bg-foreground/[0.06]">
                    <span>Playback settings and source</span>
                    <ChevronDown size={15} />
                  </button>
                )}
                <MobileEpisodeList
                  mediaId={item.id}
                  episodes={episodes}
                  loading={loadingEps}
                  progress={actualProgress}
                  isManga={isManga}
                  onRead={(chNum) => setActiveChapter(chNum)}
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
                    queryClient.invalidateQueries({ queryKey: ["media-episodes", item.id], refetchType: "all" });
                    queryClient.invalidateQueries({ queryKey: ["media-detail", item.id], refetchType: "all" });
                  }}
                />
              </motion.div>
            )}

            {activeTab === "characters" && (
              <motion.div key="characters" initial={{ opacity: 0 }} animate={{ opacity: 1 }} exit={{ opacity: 0 }} className="grid grid-cols-3 gap-3 w-full">
                {loadingChars ? (
                  <div className="col-span-3 flex justify-center py-16"><Loader2 className="animate-spin text-accent" size={24} /></div>
                ) : characters.length > 0 ? (
                  characters.map((char) => (
                    <button key={char.id || char.name.full} onClick={() => setSelectedCharacter(char)} className="space-y-1.5 text-left active:opacity-70">
                      {char.image?.large && <img src={char.image.large} alt={char.name.full} className="aspect-square w-full rounded-xl object-cover" />}
                      <p className="line-clamp-2 text-[12px] font-bold text-foreground">{char.name.full}</p>
                    </button>
                  ))
                ) : (
                  <p className="col-span-3 py-16 text-center text-xs font-bold text-muted-foreground">No character data.</p>
                )}
              </motion.div>
            )}

            {activeTab === "related" && (
              <motion.div key="related" initial={{ opacity: 0 }} animate={{ opacity: 1 }} exit={{ opacity: 0 }} className="w-full">
                {seasonRels.length > 0 ? (
                  <div className="grid grid-cols-3 gap-x-3 gap-y-4">
                    {seasonRels.map((rel: { relationType: string; node?: MediaItem }) => rel.node && (
                      <PosterCard key={rel.node.id} item={rel.node} onSelect={selectItem} width="100%" />
                    ))}
                  </div>
                ) : (
                  <p className="py-16 text-center text-xs font-bold text-muted-foreground">No related content.</p>
                )}
              </motion.div>
            )}

            {activeTab === "more" && (
              <motion.div key="more" initial={{ opacity: 0 }} animate={{ opacity: 1 }} exit={{ opacity: 0 }} className="w-full">
                {recommendations.length > 0 ? (
                  <div className="grid grid-cols-3 gap-x-3 gap-y-4">
                    {(recommendations as { mediaRecommendation?: MediaItem }[]).map((rec) => rec.mediaRecommendation && (
                      <PosterCard key={rec.mediaRecommendation.id} item={rec.mediaRecommendation} onSelect={selectItem} width="100%" />
                    ))}
                  </div>
                ) : (
                  <p className="py-16 text-center text-xs font-bold text-muted-foreground">No recommendations.</p>
                )}
              </motion.div>
            )}
          </AnimatePresence>
        </div>
      </div>

      {/* Status sheet */}
      <BottomSheet open={statusSheetOpen} onClose={() => setStatusSheetOpen(false)} title="List Status">
        {STATUS_OPTIONS.map((opt) => (
          <SheetRow key={opt.value} active={currentStatusLabel?.value === opt.value} onClick={() => handleSetStatus(opt.value)}>
            {isManga ? opt.mangaLabel || opt.label : opt.label}
          </SheetRow>
        ))}
        {currentStatusLabel && <SheetRow destructive onClick={handleRemoveFromList}>Remove from List</SheetRow>}
      </BottomSheet>

      {/* Progress sheet */}
      <BottomSheet open={progressSheetOpen} onClose={() => { setProgressSheetOpen(false); progressEditor.cancelEditing(); }} title="Update Progress">
        <div className="flex items-center justify-center gap-6 px-4 py-4">
          <button onClick={() => progressEditor.setEditValue(String(Math.max(0, (parseInt(progressEditor.editValue) || 0) - 1)))} className="flex h-11 w-11 items-center justify-center rounded-full border border-border bg-surface active:scale-90"><Minus size={18} /></button>
          <input
            type="number"
            value={progressEditor.editValue}
            onChange={(e) => progressEditor.setEditValue(e.target.value)}
            className="w-20 bg-transparent text-center text-3xl font-bold tabular-nums text-foreground outline-none"
          />
          <button onClick={() => progressEditor.setEditValue(String((parseInt(progressEditor.editValue) || 0) + 1))} className="flex h-11 w-11 items-center justify-center rounded-full border border-border bg-surface active:scale-90"><Plus size={18} /></button>
        </div>
        <div className="px-4 pb-2">
          <button
            onClick={() => { handleUpdateProgress(parseInt(progressEditor.editValue) || 0); setProgressSheetOpen(false); }}
            className="w-full rounded-md bg-accent py-3 text-[14px] font-semibold text-background active:scale-[0.98]"
          >
            Save
          </button>
        </div>
      </BottomSheet>

      {/* Score sheet */}
      <BottomSheet open={scoreSheetOpen} onClose={() => { setScoreSheetOpen(false); scoreEditor.cancelEditing(); }} title="Your Score">
        {scoreFormat === "POINT_5" || scoreFormat === "POINT_3" ? (
          <div className="flex items-center justify-center gap-2 px-4 py-6">
            {Array.from({ length: SCORE_FORMAT_MAX[scoreFormat] }, (_, i) => i + 1).map((n) => {
              if (scoreFormat === "POINT_5") {
                const active = (actualScore || 0) >= n;
                return <button key={n} onClick={() => { handleUpdateScore(n); setScoreSheetOpen(false); }} className="active:scale-90"><Star size={30} className={active ? "text-accent" : "text-muted-foreground/30"} fill={active ? "currentColor" : "none"} /></button>;
              }
              const Icon = n === 1 ? Frown : n === 2 ? Meh : Smile;
              const selected = (actualScore || 0) === n;
              return <button key={n} onClick={() => { handleUpdateScore(n); setScoreSheetOpen(false); }} className="active:scale-90"><Icon size={32} className={selected ? "text-accent" : "text-muted-foreground/30"} /></button>;
            })}
          </div>
        ) : (
          <>
            <div className="flex items-center justify-center gap-6 px-4 py-4">
              <button onClick={() => scoreEditor.setEditValue(String(Math.max(0, (parseFloat(scoreEditor.editValue) || 0) - 1)))} className="flex h-11 w-11 items-center justify-center rounded-full border border-border bg-surface active:scale-90"><Minus size={18} /></button>
              <input
                type="number"
                value={scoreEditor.editValue}
                onChange={(e) => scoreEditor.setEditValue(e.target.value)}
                className="w-20 bg-transparent text-center text-3xl font-bold tabular-nums text-foreground outline-none"
              />
              <button onClick={() => scoreEditor.setEditValue(String((parseFloat(scoreEditor.editValue) || 0) + 1))} className="flex h-11 w-11 items-center justify-center rounded-full border border-border bg-surface active:scale-90"><Plus size={18} /></button>
            </div>
            <div className="px-4 pb-2">
              <button
                onClick={() => { handleUpdateScore(parseFloat(scoreEditor.editValue) || 0); setScoreSheetOpen(false); }}
                className="w-full rounded-md bg-accent py-3 text-[14px] font-semibold text-background active:scale-[0.98]"
              >
                Save
              </button>
            </div>
          </>
        )}
      </BottomSheet>

      {/* Episode settings sheet */}
      <BottomSheet open={episodeSettingsOpen} onClose={() => setEpisodeSettingsOpen(false)} title="Playback Settings">
        <SheetRow active={autoskip} onClick={handleToggleAutoskip}><SkipForward size={18} /> Auto-Skip Intro {autoskip ? "(On)" : "(Off)"}</SheetRow>
        <SheetRow active={autoplay} onClick={handleToggleAutoNext}><PlayCircle size={18} /> Auto Next Episode {autoplay ? "(On)" : "(Off)"}</SheetRow>
        <SheetRow onClick={() => setSelectedProvider((p) => (p === "mkissa" ? "anineko" : "mkissa"))}>
          <RotateCcw size={18} /> Source: {selectedProvider === "mkissa" ? "Mkissa" : "AniNeko"} (tap to switch)
        </SheetRow>
      </BottomSheet>

      {/* Character detail sheet */}
      <BottomSheet open={!!selectedCharacter} onClose={() => setSelectedCharacter(null)} title="Character">
        {selectedCharacter && (
          <div className="flex items-start gap-4 px-4 pb-4">
            {selectedCharacter.image?.large && <img src={selectedCharacter.image.large} alt={selectedCharacter.name?.full} className="h-20 w-20 shrink-0 rounded-xl object-cover" />}
            <div className="min-w-0 space-y-1">
              <p className="text-[15px] font-bold text-foreground">{selectedCharacter.name?.full}</p>
              <p className="text-[11px] capitalize text-muted-foreground">{selectedCharacter.role?.replace(/_/g, " ")?.toLowerCase()}</p>
              {(selectedCharacter.voiceActors?.length ?? 0) > 0 && (
                <div className="space-y-1.5 pt-2">
                  <p className="text-[10px] font-bold uppercase tracking-wider text-muted-foreground">Voice Actors</p>
                  {selectedCharacter.voiceActors?.map((va) => (
                    <div key={va.id} className="flex items-center gap-2">
                      {va.image?.large && <img src={va.image.large} alt={va.name?.full} className="h-6 w-6 rounded-full object-cover" />}
                      <span className="text-[12px] text-foreground">{va.name?.full}</span>
                      <span className="text-[10px] text-muted-foreground">{va.language}</span>
                    </div>
                  ))}
                </div>
              )}
            </div>
          </div>
        )}
      </BottomSheet>

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
            if (direction === "prev" && idx > 0) setActiveChapter(String(episodes[idx - 1].number));
            else if (direction === "next" && idx < episodes.length - 1) setActiveChapter(String(episodes[idx + 1].number));
          }}
          hasPrevChapter={episodes.findIndex((ep) => String(ep.number) === activeChapter) > 0}
          hasNextChapter={episodes.findIndex((ep) => String(ep.number) === activeChapter) < episodes.length - 1}
        />
      )}
    </>
  );
}
