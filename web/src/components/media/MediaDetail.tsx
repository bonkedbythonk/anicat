
import { useEffect, useState, useRef, useMemo } from "react";
import { useQuery, useQueryClient } from "@tanstack/react-query";
import { motion, AnimatePresence } from "framer-motion";
import { X, Play, Loader2, Star, Users, Calendar, Clock, Building2, Monitor, CheckCircle2, Bookmark, Pause, XCircle, Download, BookOpen, RotateCcw, ChevronDown, ChevronUp, ChevronLeft, ChevronRight, MoreHorizontal, Trash2, Edit2, Check, SkipForward, Sparkles, PlayCircle, Film, Heart, Frown, Meh, Smile, Search, Zap } from "lucide-react";
import { mediaApi, flattenCharacterEdges, type MediaItem, type Episode, type Character, type Review } from "@/lib/api";
import { sanitizeHtml, stripSpoilers } from "@/lib/sanitize";
import { proxyImage } from "@/lib/proxy";
import { dispatchRefresh, updateProgressInQueries, removeMediaFromQueries } from "@/lib/events";
import { formatTime, formatRelativeTime, formatRelativeTimeFromUnix, formatAiringCountdown, formatFuzzyDate } from "@/lib/date";
import { useProgressEditor } from "@/lib/useProgressEditor";
import { useAppStore, useSettingsStore } from "@/stores/app";
import { FocusScope, ScopeNav, useFocusable } from "@/focus";
import { EpisodeList } from "./EpisodeList";
import { MediaGallery, buildGalleryImages } from "./MediaGallery";
import { VoiceActorList } from "./VoiceActorList";
import { StaffProfile } from "./StaffProfile";
import { WatchGrid } from "./WatchGrid";
import MangaReader from "./MangaReader";
import { NovelReader } from "./NovelReader";
import { EreaderDownloadModal } from "./EreaderDownloadModal";
import { novelApi } from "@/lib/api";
import type { NovelDetailItem, NovelVolume } from "@/lib/types";
import { MediaDiscussions } from "./MediaDiscussions";
import { AnimeThemeList } from "./AnimeThemeList";
import { useModalDismiss } from "@/hooks/useModalDismiss";

type DetailTabKey = "episodes" | "characters" | "seasons" | "discussions" | "more";

function FocusableButton({ children, ...props }: React.ButtonHTMLAttributes<HTMLButtonElement>) {
  const { ref, tabIndex } = useFocusable<HTMLButtonElement>();
  return <button ref={ref} tabIndex={tabIndex} {...props}>{children}</button>;
}

function FocusableSelect({ children, ...props }: React.SelectHTMLAttributes<HTMLSelectElement>) {
  const { ref, tabIndex } = useFocusable<HTMLSelectElement>();
  return <select ref={ref} tabIndex={tabIndex} {...props}>{children}</select>;
}

// Focusable tab button — a child component so useFocusable runs per-tab inside
// the tabs FocusScope (hooks can't be called in a .map).
function DetailTab({
  tab, label, active, onSelect, count,
}: { tab: DetailTabKey; label: string; active: boolean; onSelect: (t: DetailTabKey) => void; count?: number | string }) {
  const { ref, tabIndex } = useFocusable<HTMLButtonElement>();
  return (
    <button
      ref={ref}
      role="tab"
      aria-selected={active}
      tabIndex={tabIndex}
      onClick={() => onSelect(tab)}
      className={`px-4 pb-3 text-xs font-mono uppercase tracking-wider relative transition-colors font-semibold ${active ? 'text-foreground' : 'text-muted-foreground hover:text-foreground'}`}
    >
      <span>{label}</span>
      {count != null && <span className="ml-1.5 opacity-60 text-[10.5px]">({count})</span>}
      {active && (
        <motion.div layoutId="tab-indicator" className="absolute bottom-0 left-0 right-0 h-[2px] bg-accent rounded-full" />
      )}
    </button>
  );
}

// AniList airing timestamps are ISO strings without a zone suffix (UTC).
// AniList score formats — the raw score value lives on a different scale
// depending on which one the viewer's account uses.
const SCORE_FORMAT_MAX: Record<string, number> = {
  POINT_100: 100,
  POINT_10: 10,
  POINT_10_DECIMAL: 10,
  POINT_5: 5,
  POINT_3: 3,
};

// Sources that are no longer selectable, so a stale saved per-show override
// pointing at one gets ignored rather than silently pinning the show to it.
const RETIRED_PROVIDERS = ["mkissa", "allanime", "gogoanime", "anizone", "animepahe", "anineko"];

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
  const [activeTab, setActiveTab] = useState<DetailTabKey>("episodes");
  // Two-step delete confirm (replaces window.confirm which is broken in Tauri WebView)
  const [deleteConfirmPending, setDeleteConfirmPending] = useState(false);
  const [activeChapter, setActiveChapter] = useState<string | null>(null);
  const [showEreaderModal, setShowEreaderModal] = useState(false);
  const [activeNovelVolume, setActiveNovelVolume] = useState<NovelVolume | null>(null);
  const [selectedNovelVolumeId, setSelectedNovelVolumeId] = useState<number | string | null>(null);
  const [selectedCharacter, setSelectedCharacter] = useState<Character | null>(null);
  
  // The voice actor whose filmography is showing, if any. It replaces the
  // character's own content inside the same dialog rather than stacking.
  const [selectedStaffId, setSelectedStaffId] = useState<number | null>(null);
  const closeCharacterModal = () => {
    setSelectedCharacter(null);
    setSelectedStaffId(null);
  };
  const characterModalRef = useModalDismiss<HTMLDivElement>(
    !!selectedCharacter,
    closeCharacterModal
  );
  const [showMatchModal, setShowMatchModal] = useState(false);
  const [matchQuery, setMatchQuery] = useState("");
  const [matchResults, setMatchResults] = useState<{ id: string; title: string; year?: number }[]>([]);
  const [matchLoading, setMatchLoading] = useState(false);
  const [matchSaving, setMatchSaving] = useState(false);
  const closeMatchModal = () => {
    setShowMatchModal(false);
    setMatchResults([]);
  };
  const matchModalRef = useModalDismiss<HTMLDivElement>(showMatchModal, closeMatchModal);
  const [isResolvingTrailer, setIsResolvingTrailer] = useState(false);
  const initialPlayEpisode = useAppStore((s) => s.initialPlayEpisode);
  const setNotification = useAppStore((s) => s.setNotification);
  const setActiveFocusScope = useAppStore((s) => s.setActiveFocusScope);
  const [showStatusMenu, setShowStatusMenu] = useState(false);
  const [showMoreMenu, setShowMoreMenu] = useState(false);
  const statusMenuRef = useRef<HTMLDivElement>(null);
  const moreMenuRef = useRef<HTMLDivElement>(null);

  useEffect(() => {
    const handleDismissMenus = (e: MouseEvent) => {
      if (statusMenuRef.current && !statusMenuRef.current.contains(e.target as Node)) {
        setShowStatusMenu(false);
      }
      if (moreMenuRef.current && !moreMenuRef.current.contains(e.target as Node)) {
        setShowMoreMenu(false);
      }
    };
    document.addEventListener("mousedown", handleDismissMenus);
    return () => document.removeEventListener("mousedown", handleDismissMenus);
  }, []);

  useEffect(() => {
    // When MediaDetail mounts (e.g. user clicked a card and navigated here),
    // we must claim the active focus scope so useSpatialNavigation knows to
    // route arrow keys into this page rather than discarding them because the
    // old page's scope no longer matches.
    setActiveFocusScope("detail-actions");
  }, [setActiveFocusScope]);

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

  const [selectedProvider, setSelectedProvider] = useState<string>("nyaa");

  // Per-show overrides (registry media_prefs): a saved provider or audio
  // choice for this show wins over the global config defaults.
  const { data: mediaPrefs, isPending: mediaPrefsPending } = useQuery({
    queryKey: ["media-prefs", item.id],
    queryFn: () => mediaApi.getMediaPrefs(item.id),
  });

  // Which provider the saved data implies, as a derived value rather than
  // only as state. The initial auto-play effect needs this in the very commit
  // the queries land — reading `selectedProvider` there would still see the
  // pre-update value, since the effect below hasn't re-rendered yet.
  // A per-show override saved before a source was retired is ignored: the
  // picker no longer lists it, so the user could neither see nor change it
  // while episode queries kept hitting the dead provider.
  const effectiveProvider = useMemo(() => {
    if (mediaPrefs?.provider && !RETIRED_PROVIDERS.includes(mediaPrefs.provider)) {
      return mediaPrefs.provider;
    }
    if (config?.general?.provider) return config.general.provider as string;
    return null;
  }, [config, mediaPrefs]);

  useEffect(() => {
    if (effectiveProvider) setSelectedProvider(effectiveProvider);
  }, [effectiveProvider]);

  const handleSelectProvider = async (provider: string) => {
    setSelectedProvider(provider);
    // Remember the choice for this show: picking the global default clears
    // the override, anything else saves it.
    const globalProvider = (config?.general?.provider as string) || "nyaa";
    try {
      await mediaApi.setMediaPrefs(item.id, {
        provider: provider === globalProvider ? null : provider,
        translation_type: mediaPrefs?.translation_type ?? null,
      });
      queryClient.invalidateQueries({ queryKey: ["media-prefs", item.id] });
    } catch (err) {
      console.error("Failed to save per-show provider:", err);
    }
  };

  const handleSelectAudio = async (audio: string) => {
    try {
      await mediaApi.setMediaPrefs(item.id, {
        provider: mediaPrefs?.provider ?? null,
        translation_type: audio === "default" ? null : audio,
      });
      queryClient.invalidateQueries({ queryKey: ["media-prefs", item.id] });
    } catch (err) {
      console.error("Failed to save per-show audio:", err);
    }
  };

  // Derived values (computed from state/props, must precede hooks that consume them)
  const isNovel = item.format === "NOVEL" || (item.format && item.format.toUpperCase() === "NOVEL");
  const isManga = (item.type === "MANGA" || !!(item.format && ["MANGA", "ONE_SHOT", "NOVEL"].includes(item.format))) && !isNovel;

  const {
    data: fullItemData,
    isLoading: loading,
    isFetching: detailFetching,
  } = useQuery({
    queryKey: ["media-detail", item.id],
    queryFn: async () => {
      const details = await mediaApi.getDetails(item.id, isManga || isNovel ? "MANGA" : "ANIME");
      return details;
    },
    // Always revalidate on mount instead of inheriting the global 5min
    // staleTime: this entry carries the progress a quick-play button turns
    // into an episode number, and the persisted cache can be a day old.
    staleTime: 0,
  });

  const { data: novelData } = useQuery<NovelDetailItem | null>({
    queryKey: ["novel-detail-ranobedb", item.id],
    queryFn: async () => {
      const q = item.title?.english || item.title?.romaji || item.title?.native || String(item.id);
      try {
        return await novelApi.getNovelDetails(q);
      } catch {
        const search = await novelApi.searchNovels(q);
        if (search && search.length > 0) {
          return await novelApi.getNovelDetails(search[0].id);
        }
        return null;
      }
    },
    enabled: Boolean(isNovel),
  });

  // Fall back to the always-present `item` prop so downstream code never
  // has to null-check the detail (the query data can be null).
  const fullItem = fullItemData ?? item;

  const effectiveNovelBooks: NovelVolume[] = useMemo(() => {
    if (novelData?.books && novelData.books.length > 0) {
      return novelData.books;
    }
    const count = fullItem?.volumes || fullItem?.chapters || 1;
    const volCount = Math.min(Math.max(count, 1), 60);
    return Array.from({ length: volCount }, (_, i) => ({
      id: i + 1,
      title: `Volume ${i + 1}`,
      cover_url: fullItem?.cover_image?.large || fullItem?.coverImage?.large,
      description:
        i === 0 && fullItem?.description
          ? fullItem.description
          : `Volume ${i + 1} of ${fullItem?.title?.english || fullItem?.title?.romaji || "the series"}.`,
      sort_order: i + 1,
    }));
  }, [novelData, fullItem]);

  // Only volumes carrying a source URL have text behind them; the rest are
  // metadata-only rows from AniList/RanobeDB.
  const readableNovelVolume: NovelVolume | null = useMemo(
    () => effectiveNovelBooks.find((v) => Boolean(v.url)) ?? null,
    [effectiveNovelBooks],
  );

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

  // Local watch history for this show — powers the "Resume from X / Start
  // over" affordance on the primary button.
  const { data: watchHistory = [] } = useQuery({
    queryKey: ["watch-history", item.id],
    queryFn: () => mediaApi.getWatchHistory(item.id),
    enabled: !isManga,
  });

  // Fallback chain: prefer raw AniList media_list_entry over derived user_status alias
  const actualProgress =
    fullItem?.media_list_entry?.progress ??
    fullItem?.user_status?.progress ??
    item?.media_list_entry?.progress ??
    item?.user_status?.progress ??
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
  // Key deliberately differs from the old "anizip-titles": that cache is
  // persisted, and a rehydrated entry from the titles-only shape would arrive
  // here as a bare Record where an AniZipMeta is expected.
  const { data: anizip } = useQuery({
    queryKey: ["anizip-meta", item.id],
    queryFn: () => mediaApi.fetchAniZipMeta(item.id),
    staleTime: 24 * 60 * 60 * 1000,
  });
  const anizipTitles = anizip?.titles ?? {};

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
  }, [fullItem, anizip]);

  /**
   * Episode number -> still frame. AniZip keys its episodes by number, so it
   * is authoritative; AniList's `streamingEpisodes` is a positional array that
   * drifts on shows with specials or gaps, so it only fills a slot when its
   * own title states the episode number.
   */
  const episodeThumbMap = useMemo(() => {
    const map: Record<number, string> = {};
    const eps = fullItem?.streaming_episodes;
    if (Array.isArray(eps)) {
      eps.forEach((ep) => {
        if (!ep?.thumbnail || !ep?.title) return;
        const epNumMatch = ep.title.match(/^Episode\s+(\d+)/i);
        if (!epNumMatch) return;
        map[parseInt(epNumMatch[1], 10)] = ep.thumbnail;
      });
    }
    for (const [num, url] of Object.entries(anizip?.thumbnails ?? {})) {
      map[Number(num)] = url;
    }
    return map;
  }, [fullItem, anizip]);

  const episodeOverviewMap = useMemo(() => anizip?.overviews ?? {}, [anizip]);
  const episodeAirDateMap = useMemo(() => anizip?.airdates ?? {}, [anizip]);
  const episodeRuntimeMap = useMemo(() => anizip?.runtimes ?? {}, [anizip]);

  const galleryImages = useMemo(
    () => buildGalleryImages(anizip, fullItem?.banner_image, episodeThumbMap),
    [anizip, fullItem, episodeThumbMap],
  );

  const {
    data: characters = [],
    isLoading: loadingChars,
  } = useQuery({
    queryKey: ["media-characters", item.id],
    queryFn: async () => flattenCharacterEdges(await mediaApi.getCharacters(item.id)),
    enabled: activeTab === "characters",
  });

  const [hasTriggeredInitial, setHasTriggeredInitial] = useState(false);

  // Handle initial action (e.g. from Hero "Play Now" button) — the specific
  // episode requested by whatever quick-play button opened this page only
  // applies to this one automatic trigger, never to later manual clicks of
  // the Continue button (see handlePlayNext).
  useEffect(() => {
    // Wait for media_prefs too, not just config: it carries this show's
    // provider override, and it only gets one shot at firing
    // (hasTriggeredInitial). Gating on config alone let a quick-play card
    // start on the global provider whenever config resolved first, silently
    // ignoring the per-show choice.
    // `isLoading` alone is not enough when no episode was handed to us: with
    // the persist-client plugin it is already false on the first commit
    // whenever a persisted detail exists, so the trigger would compute
    // `actualProgress + 1` from cached progress that can predate everything
    // watched since — which is how a quick-play button ends up starting at
    // episode 1. Wait for the refetch to land in that case.
    const needsFreshProgress = !initialPlayEpisode && detailFetching;
    if (
      initialAction === "play" &&
      !loading &&
      !needsFreshProgress &&
      config &&
      !mediaPrefsPending &&
      !hasTriggeredInitial
    ) {
      setHasTriggeredInitial(true);
      useAppStore.setState({ initialAction: null, initialPlayEpisode: null });
      handlePlayNext(
        initialPlayEpisode ? Number(initialPlayEpisode) : undefined,
        effectiveProvider ?? selectedProvider,
      );
    }
  }, [initialAction, loading, detailFetching, initialPlayEpisode, config, mediaPrefsPending, hasTriggeredInitial, effectiveProvider, selectedProvider]);

  // Measure whether synopsis actually overflows the collapsed height
  useEffect(() => {
    if (!synopsisRef.current) return;
    setSynopsisOverflows(synopsisRef.current.scrollHeight > 60);
  }, [fullItem.description]);

  const preloadStatus = useAppStore((s) => s.preloadStatus);

  // Preload the Continue episode as soon as the detail page opens. It's
  // background work: the user is reading the synopsis or looking at cast while
  // it is, so by the time the user presses play, mpv has nothing left to wait
  // on — start_playback finds it already sitting in the preload slot.
  useEffect(() => {
    if (isManga || !selectedProvider) return;
    const continueEpisode = actualProgress + 1;
    // Written whatever the answer is, "idle" included. Skipping the idle case
    // let a stale "ready" left over from an earlier visit survive a mount where
    // the backend said it holds nothing -- and the episode list refuses to
    // re-preload anything the store still calls ready, so that episode stayed
    // cold and unwarmable. This poll is the one place a status the push events
    // missed can still be corrected.
    mediaApi.getPreloadStatus(item.id, continueEpisode, selectedProvider).then((status) => {
      if (status === "ready" || status === "fetching" || status === "idle") {
        useAppStore.getState().setPreloadStatus(item.id, continueEpisode, status);
      }
    }).catch(() => {});

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
      useAppStore.getState().setNotification({
        message: `Queued ${allEpNums.length} episodes for download`,
        type: "info",
      });
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
  const handlePlayNext = async (overrideEpisode?: number, providerOverride?: string, startOver?: boolean) => {
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
            return;
          }
        }
        const nextEpisode = overrideEpisode ?? (actualProgress + 1);
        const coverImg = fullItem?.banner_image || fullItem?.cover_image?.large || item?.banner_image || item?.cover_image?.large || "";
        const nextEpNum = nextEpisode;
        const nextEpTitle = episodeTitleMap?.[nextEpNum] || "";
        const totalEps = fullItem?.episodes || episodes?.length || 0;
        const activeProvider = providerOverride || selectedProvider;

        const playerType = useSettingsStore.getState().playerType;
        if (playerType === "builtin") {
          useAppStore.getState().openPlayer({
            mediaId: item.id,
            episodeNumber: nextEpNum,
            provider: activeProvider,
            title: title,
            episodeTitle: nextEpTitle,
            coverImage: coverImg,
            totalEpisodes: totalEps,
          });
          return;
        }

        useAppStore.getState().setPlaybackLoading({
          isLoading: true,
          mediaId: item.id,
          episodeNumber: nextEpNum,
          title: title,
          coverImage: coverImg,
          statusText: "Starting...",
          step: activeProvider === "nyaa" ? 2 : 1,
        });

        await mediaApi.play(item.id, nextEpNum, activeProvider, undefined, title, nextEpTitle, coverImg, totalEps, startOver);
        dispatchRefresh();
      }
    } catch (error: any) {
      console.error("Failed to play next:", error);
      useAppStore.getState().setPlaybackLoading({
        isLoading: true,
        statusText: typeof error === "string" ? error : "Couldn't start playback.",
        step: 0,
      });
    } finally {
      setIsPlayingNext(false);
      setTimeout(() => {
        isProcessingAction.current = false;
      }, 500);
    }
  };

  const globalTranslationType = useSettingsStore((s) => s.translationType);
  const setTranslationType = useSettingsStore((s) => s.setTranslationType);
  const [viewMode, setViewMode] = useState<"cards" | "compact">(() => {
    if (typeof window === "undefined") return "cards";
    return (localStorage.getItem("anicat_episode_view_mode") as "cards" | "compact") || "cards";
  });
  const handleSetViewMode = (mode: "cards" | "compact") => {
    setViewMode(mode);
    localStorage.setItem("anicat_episode_view_mode", mode);
  };
  // Dub viewers want the English cast, everyone else the Japanese one. The
  // per-show override wins over the global setting, same as playback.
  const preferredVaLanguage =
    (mediaPrefs?.translation_type ?? globalTranslationType) === "dub" ? "ENGLISH" : "JAPANESE";
  const preferredVoiceActor = (char: Character) =>
    char.voiceActors?.find((va) => va.language === preferredVaLanguage) ?? char.voiceActors?.[0];

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
    const newVal = shaderProfile === "off" ? "on" : "off";
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

    const entryId = fullItem?.user_status?.id || fullItem?.media_list_entry?.id || 0;
    if (!entryId) {
      // No real AniList list-entry id to delete — happens when a cached copy
      // was stamped with the `{ id: 0, ... }` placeholder that
      // updateProgressInQueries fabricates for an item it hasn't seen a real
      // entry for yet (e.g. right after adding to the list, before the next
      // refetch lands). Calling deleteFromList(0) would just 400 and the
      // catch below rolls the optimistic removal back — putting the stale
      // entry right back and making it look undeletable. There's nothing on
      // the server to delete in that case, so just purge it locally.
      removeMediaFromQueries(qc, item.id);
      dispatchRefresh();
      return;
    }

    mediaApi.deleteFromList(entryId)
      .then(() => {
        removeMediaFromQueries(qc, item.id);
        for (const key of listQueryKeys) {
          qc.invalidateQueries({ queryKey: key as unknown[] });
        }
        qc.invalidateQueries({ queryKey: ["playback-status"] });
        dispatchRefresh();
      })
      .catch((error) => {
        console.error("Failed to remove from list:", error);
        notifyError("Couldn't remove this from your AniList list.");
        for (const [keyStr, snapshot] of snapshots) {
          qc.setQueryData(JSON.parse(keyStr) as unknown[], snapshot);
        }
      });
  };

  const [isUpdatingStatus, setIsUpdatingStatus] = useState(false);
  const queryClient = useQueryClient();
  const selectItem = useAppStore((s) => s.openDetail);


  const title = fullItem?.title?.english || fullItem?.title?.romaji || item?.title?.english || item?.title?.romaji || '';

  // Mirror the backend's resume rules (playback.rs resume_position): a stored
  // position only counts past a 30s floor and below the 85% watched threshold.
  // The backend is still the authority — this only drives the button label.
  const resumeSeconds = useMemo(() => {
    if (isManga) return 0;
    const entry = watchHistory.find((e) => e.episode_number === actualProgress + 1);
    if (!entry || entry.duration <= 0 || entry.stop_time < 30) return 0;
    if ((entry.stop_time / entry.duration) * 100 >= 85) return 0;
    return entry.stop_time;
  }, [isManga, watchHistory, actualProgress]);

  const totalMediaEpisodes = fullItem.episodes || fullItem.chapters || 0;
  const nextAiringEpisode = fullItem.next_airing?.episode;
  const filteredEpisodeNums = episodes
    .filter(e => !nextAiringEpisode || Number(e.number) < nextAiringEpisode)
    .map(e => Number(e.number));
  const latestAvailableEpisode = episodes.length > 0 && filteredEpisodeNums.length > 0 ? Math.max(...filteredEpisodeNums) : totalMediaEpisodes;
  const isFinishedMedia = totalMediaEpisodes > 0 && actualProgress >= totalMediaEpisodes && fullItem.status !== 'RELEASING';
  const isCaughtUpMedia = !isFinishedMedia && latestAvailableEpisode > 0 && actualProgress >= latestAvailableEpisode;
  const showResume = resumeSeconds > 0 && !isFinishedMedia && !isCaughtUpMedia && !isManga;

  const primaryActionButton = (() => {
    if (isNovel) {
      return (
        <div className="flex items-center gap-2 flex-wrap">
          <button
            onClick={() => setActiveNovelVolume(readableNovelVolume)}
            disabled={!readableNovelVolume}
            title={readableNovelVolume ? "Read online" : "No readable text source for this series"}
            className="flex items-center gap-2 px-5 py-3 max-w-[280px] bg-accent hover:bg-accent-light text-background font-bold text-[13.5px] rounded-lg shadow-lg shadow-accent/10 transition-all active:scale-95 cursor-pointer disabled:opacity-40 disabled:cursor-not-allowed disabled:hover:bg-accent disabled:active:scale-100"
          >
            <BookOpen size={18} className="shrink-0" />
            <span>Read Light Novel</span>
          </button>
          <button
            onClick={() => {
              setSelectedNovelVolumeId(null);
              setShowEreaderModal(true);
            }}
            className="flex items-center gap-2 px-4 py-3 bg-foreground/[0.08] hover:bg-foreground/[0.15] text-foreground font-semibold text-[13.5px] rounded-lg border border-border transition-all cursor-pointer"
            title="Download CrossPoint EPUB for E-Reader"
          >
            <Download size={18} className="text-accent" />
            <span>Download for E-Reader</span>
          </button>
        </div>
      );
    }

    const currentProgress = actualProgress;
    const nextEpisode = actualProgress + 1;
    const isFinished = isFinishedMedia;
    const isCaughtUp = isCaughtUpMedia;
    // Sequel handoff: a finished season's primary button flows straight into
    // the next one instead of dead-ending at "Completed".
    const handoffSequel = isFinished && !isManga ? sequel : null;
    const sequelTitle = handoffSequel?.title?.english || handoffSequel?.title?.romaji || '';
    const epPreloadStatus = !isManga ? preloadStatus[`${item.id}-${nextEpisode}`] : undefined;
    return (
      <div className="flex items-center gap-2">
        <button
          onClick={() => handoffSequel ? selectItem(handoffSequel, "play") : handlePlayNext()}
          disabled={isPlayingNext || isCaughtUp || (isFinished && !handoffSequel)}
          title={handoffSequel ? `Start ${sequelTitle}` : undefined}
          className="flex items-center gap-2 px-5 py-3 max-w-[280px] bg-accent hover:bg-accent-light text-background font-bold text-[13.5px] rounded-lg shadow-lg shadow-accent/10 transition-all active:scale-95 disabled:opacity-50 disabled:bg-foreground/[0.05] disabled:text-muted-foreground"
        >
          {isPlayingNext ? (
            <Loader2 className="animate-spin" size={18} />
          ) : (
            <>
              {isManga ? <BookOpen size={18} className="shrink-0" /> : <Play size={18} fill="currentColor" className="shrink-0" />}
              {handoffSequel ? (
                <span className="truncate">Start {sequelTitle}</span>
              ) : (
                <span>
                  {isFinished ? 'Completed' : isCaughtUp ? 'Caught Up'
                    : showResume ? `Resume Episode ${nextEpisode} · ${formatTime(resumeSeconds)}`
                    : `${isManga ? 'Read' : actualProgress > 0 ? 'Continue' : 'Start'} ${isManga ? 'Chapter' : 'Episode'} ${nextEpisode}`}
                </span>
              )}
              {!isFinished && !isCaughtUp && !isManga && epPreloadStatus === "ready" && (
                <span className="w-1.5 h-1.5 rounded-full bg-emerald-950 ml-1 shrink-0" title="Stream Ready" />
              )}
            </>
          )}
        </button>
      </div>
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
            <FocusScope name="detail-header" className="max-w-[1150px] mx-auto">
              <ScopeNav />
              <FocusableButton
                onClick={onClose}
                className="flex items-center gap-1.5 text-[12.5px] font-medium text-foreground/70 hover:text-foreground cursor-pointer"
              >
                <ChevronLeft size={14} />
                Back
              </FocusableButton>
            </FocusScope>
          </div>
        </div>

        {/* Main content — cover + info side by side */}
        <div className="relative z-10 px-4 sm:px-8 lg:px-14 -mt-24 sm:-mt-28 pb-16 max-w-[1150px] mx-auto">
          <div className="flex flex-col sm:flex-row gap-6 sm:gap-8">
            {/* Cover art — left column */}
            <div className="shrink-0 flex flex-col items-center sm:items-start gap-3">
              <div className="w-36 sm:w-44 lg:w-48 aspect-[2/3] rounded-xl overflow-hidden border border-border shadow-2xl bg-surface relative group">
                <img
                  src={proxyImage(fullItem?.cover_image?.large || item?.cover_image?.large || '')}
                  alt={title}
                  className="w-full h-full object-cover"
                />
              </div>
            </div>

            {/* Info — right column */}
            <div className="flex-1 min-w-0 pt-0 sm:pt-6 space-y-4">
              {/* Meta tags */}
              <div className="flex flex-wrap items-center gap-x-3 gap-y-1 font-mono text-[10.5px] uppercase tracking-[0.08em] text-muted-foreground">
                {fullItem.format && <span className="text-foreground font-semibold">{fullItem.format}</span>}
                {fullItem.status === 'RELEASING' && <span className="text-accent font-semibold">AIRING</span>}
                {fullItem.status === 'FINISHED' && <span className="text-emerald-400 font-semibold">FINISHED</span>}
                {!isManga && fullItem.episodes ? <span className="text-accent font-semibold">{fullItem.episodes} EP</span> : null}
                {isManga && fullItem.chapters ? <span className="text-accent font-semibold">{fullItem.chapters} CH</span> : null}
                {(fullItem.season_year || fullItem.seasonYear || fullItem.startDate?.year) && (
                  <span>{fullItem.season_year || fullItem.seasonYear || fullItem.startDate?.year}</span>
                )}
                {fullItem.studios?.nodes?.[0]?.name && <span>{fullItem.studios.nodes[0].name}</span>}
                {fullItem.average_score ? <span className="text-accent font-semibold">SCORE {fullItem.average_score}%</span> : null}
                {!isManga && fullItem.next_airing?.episode && (
                  <span className="text-accent font-semibold">
                    EP {fullItem.next_airing.episode} {formatAiringCountdown(fullItem.next_airing.airing_at) || ""}
                  </span>
                )}
              </div>

              {/* Title */}
              <h1 className="text-2xl sm:text-4xl font-bold text-foreground tracking-tight leading-tight">{title}</h1>

              {/* Genres */}
              {fullItem.genres && fullItem.genres.length > 0 && (
                <div className="flex items-center flex-wrap gap-1.5 pt-0.5">
                  {fullItem.genres.map((genre) => (
                    <span
                      key={genre}
                      className="px-2.5 py-0.5 rounded-full bg-foreground/[0.05] border border-border text-[11px] text-muted-foreground"
                    >
                      {genre}
                    </span>
                  ))}
                </div>
              )}

              {/* Clean Action Bar: Primary Play + Status Pill + Favorite + More */}
              <FocusScope name="detail-actions" orientation="horizontal" className="flex items-center gap-2.5 flex-wrap pt-1 relative z-30">
                <ScopeNav />
                {primaryActionButton}

                {/* Status Dropdown Pill */}
                <div ref={statusMenuRef} className="relative">
                  <FocusableButton
                    onClick={() => {
                      setShowStatusMenu(!showStatusMenu);
                      setShowMoreMenu(false);
                    }}
                    disabled={isUpdatingStatus}
                    className="glass-button px-4 py-3 rounded-md text-xs font-semibold text-foreground flex items-center gap-2 transition-all active:scale-95 disabled:opacity-50"
                  >
                    {isUpdatingStatus ? <Loader2 size={13} className="animate-spin text-accent" /> : null}
                    <span>
                      {(() => {
                        const s = fullItem.user_status?.status?.toLowerCase();
                        const st = s === 'current' ? 'watching' : (s || 'none');
                        switch (st) {
                          case "watching": return isManga ? "Reading" : "Watching";
                          case "planning": return "Planning";
                          case "completed": return "Completed";
                          case "paused": return "Paused";
                          case "dropped": return "Dropped";
                          case "repeating": return isManga ? "Rereading" : "Rewatching";
                          default: return "+ Add to List";
                        }
                      })()}
                    </span>
                    <ChevronDown size={14} className="text-muted-foreground transition-transform" />
                  </FocusableButton>

                  {showStatusMenu && (
                    <div className="absolute left-0 top-full mt-1.5 w-40 bg-surface border border-border rounded-xl p-1.5 shadow-2xl z-50 text-xs font-mono animate-fade-in space-y-0.5">
                      {[
                        { key: "watching", label: isManga ? "Reading" : "Watching" },
                        { key: "planning", label: "Planning" },
                        { key: "completed", label: "Completed" },
                        { key: "paused", label: "Paused" },
                        { key: "dropped", label: "Dropped" },
                        { key: "repeating", label: isManga ? "Rereading" : "Rewatching" },
                      ].map(({ key, label }) => {
                        const currentSt = (() => {
                          const s = fullItem.user_status?.status?.toLowerCase();
                          return s === 'current' ? 'watching' : (s || 'none');
                        })();
                        const isSelected = currentSt === key;
                        return (
                          <button
                            key={key}
                            onClick={() => {
                              setShowStatusMenu(false);
                              setIsUpdatingStatus(true);
                              const anilistStatus = key === "watching" ? "CURRENT" : key.toUpperCase();
                              const updates: Record<string, unknown> = { status: anilistStatus };
                              let newProgress = actualProgress;
                              if (key === "repeating") {
                                updates.progress = 0;
                                newProgress = 0;
                              }
                              mediaApi.saveMediaListEntry(item.id, updates)
                                .then(() => {
                                  updateProgressInQueries(queryClient, item.id, newProgress, key);
                                  queryClient.invalidateQueries({ queryKey: ['media-detail', item.id], refetchType: 'all' });
                                  queryClient.invalidateQueries({ queryKey: ['lists'] });
                                  queryClient.invalidateQueries({ queryKey: ['home-watching'], refetchType: 'all' });
                                  queryClient.invalidateQueries({ queryKey: ['home-repeating'], refetchType: 'all' });
                                  dispatchRefresh();
                                })
                                .catch((err) => {
                                  console.error('Failed to update status:', err);
                                  notifyError("Couldn't update your list status on AniList.");
                                })
                                .finally(() => setIsUpdatingStatus(false));
                            }}
                            className={`w-full text-left px-3 py-2 rounded-lg flex items-center justify-between transition-colors ${
                              isSelected ? "bg-accent/15 text-accent font-semibold" : "text-foreground/80 hover:bg-foreground/5 hover:text-foreground"
                            }`}
                          >
                            <span>{label}</span>
                            {isSelected && <Check size={13} className="text-accent" />}
                          </button>
                        );
                      })}
                    </div>
                  )}
                </div>

                {/* Favorite Heart Button */}
                <FocusableButton
                  onClick={handleToggleFavourite}
                  disabled={isTogglingFavourite}
                  title={fullItem?.is_favourite ? "Remove from AniList favourites" : "Add to AniList favourites"}
                  className={`p-3 rounded-md border transition-all active:scale-95 disabled:opacity-50 ${
                    fullItem?.is_favourite
                      ? "bg-pink-500/15 hover:bg-pink-500/25 text-pink-500 border-pink-500/30"
                      : "glass-button text-muted-foreground hover:text-foreground"
                  }`}
                >
                  <Heart size={16} fill={fullItem?.is_favourite ? "currentColor" : "none"} />
                </FocusableButton>

                {/* "···" More Options Menu */}
                <div ref={moreMenuRef} className="relative">
                  <FocusableButton
                    onClick={() => {
                      setShowMoreMenu(!showMoreMenu);
                      setShowStatusMenu(false);
                    }}
                    title="More options"
                    className="glass-button p-3 rounded-md text-muted-foreground hover:text-foreground transition-all active:scale-95"
                  >
                    <MoreHorizontal size={16} />
                  </FocusableButton>

                  {showMoreMenu && (
                    <div className="absolute left-0 sm:right-0 sm:left-auto top-full mt-1.5 w-52 bg-surface border border-border rounded-xl p-1.5 shadow-2xl z-50 text-xs animate-fade-in space-y-0.5">
                      {showResume && (
                        <button
                          onClick={() => {
                            setShowMoreMenu(false);
                            handlePlayNext(undefined, undefined, true);
                          }}
                          className="w-full text-left px-3 py-2 rounded-lg hover:bg-foreground/5 flex items-center gap-2.5 text-foreground transition-colors"
                        >
                          <RotateCcw size={14} className="text-muted-foreground" />
                          <span>Start over (from 0:00)</span>
                        </button>
                      )}

                      {hasTrailer && (
                        <button
                          onClick={() => {
                            setShowMoreMenu(false);
                            handlePlayTrailer();
                          }}
                          disabled={isResolvingTrailer}
                          className="w-full text-left px-3 py-2 rounded-lg hover:bg-foreground/5 flex items-center gap-2.5 text-foreground transition-colors disabled:opacity-50"
                        >
                          <Film size={14} className="text-muted-foreground" />
                          <span>Watch trailer</span>
                        </button>
                      )}

                      {!isManga && episodes.length > 0 && (
                        <button
                          onClick={() => {
                            setShowMoreMenu(false);
                            handleDownloadAll();
                          }}
                          disabled={queueingAll}
                          className="w-full text-left px-3 py-2 rounded-lg hover:bg-foreground/5 flex items-center gap-2.5 text-foreground transition-colors disabled:opacity-50"
                        >
                          <Download size={14} className="text-muted-foreground" />
                          <span>Download all episodes</span>
                        </button>
                      )}

                      {!isManga && (
                        <button
                          onClick={() => {
                            setShowMoreMenu(false);
                            const defaultQuery = fullItem.title?.english || fullItem.title?.romaji || title || "";
                            setMatchQuery(defaultQuery);
                            setMatchResults([]);
                            setShowMatchModal(true);
                          }}
                          className="w-full text-left px-3 py-2 rounded-lg hover:bg-foreground/5 flex items-center gap-2.5 text-foreground transition-colors"
                        >
                          <Search size={14} className="text-muted-foreground" />
                          <span>Source & match settings</span>
                        </button>
                      )}

                      {fullItem.user_status?.status && (
                        <>
                          <div className="h-px bg-border my-1" />
                          <button
                            onClick={() => {
                              setShowMoreMenu(false);
                              handleRemoveFromList();
                            }}
                            className="w-full text-left px-3 py-2 rounded-lg hover:bg-danger/10 flex items-center gap-2.5 text-danger-light transition-colors"
                          >
                            <Trash2 size={14} className="text-danger-light" />
                            <span>Remove from AniList</span>
                          </button>
                        </>
                      )}
                    </div>
                  )}
                </div>
              </FocusScope>

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
                    {/* Body copy, not metadata — it reads at foreground/80
                        rather than the muted token the labels use. */}
                    <p ref={synopsisRef} className="text-sm text-foreground/80 leading-relaxed" dangerouslySetInnerHTML={{ __html: sanitizeHtml(fullItem.description) }} />
                  </motion.div>
                  {synopsisOverflows && (
                    <FocusScope name="detail-synopsis">
                      <ScopeNav />
                      <FocusableButton onClick={() => setIsExpanded(!isExpanded)} className="flex items-center space-x-1.5 text-[11px] font-bold text-foreground/50 hover:text-foreground transition-colors group">
                        <span>{isExpanded ? 'Show Less' : 'Read Full Synopsis'}</span>
                        {isExpanded ? <ChevronUp size={14} /> : <ChevronDown size={14} className="group-hover:translate-y-0.5 transition-transform" />}
                      </FocusableButton>
                    </FocusScope>
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
                <FocusScope name="detail-relations" orientation="horizontal" className="grid grid-cols-1 sm:grid-cols-2 gap-3">
                  <ScopeNav />
                  {[
                    { rel: prequel, label: 'Previous', side: 'prev' as const },
                    { rel: sequel, label: 'Next', side: 'next' as const },
                  ].filter((s) => s.rel).map(({ rel, label, side }) => {
                    const cover = rel?.cover_image?.large || rel?.coverImage?.large;
                    return (
                      <FocusableButton
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
                      </FocusableButton>
                    );
                  })}
                </FocusScope>
              )}
            </div>
          </div>

          {/* Tabs */}
          <div className="mt-8 space-y-6">
            <div className="flex items-center justify-between border-b border-border pb-0 relative">
              <FocusScope
                name="detail-tabs"
                orientation="horizontal"
                role="tablist"
                className="flex"
              >
                <ScopeNav />
                {(['episodes', 'characters', 'seasons', 'discussions', 'more'] as const).map((tab) => {
                  const totalEps = isNovel
                    ? (novelData?.books?.length || fullItem.volumes || fullItem.chapters || 0)
                    : isManga
                    ? (fullItem.chapters || episodes.length || 0)
                    : (fullItem.episodes || episodes.length || 0);
                  const charactersCount = fullItem.characters?.edges?.length || 0;
                  const relationsCount = (fullItem.relations?.edges?.length || 0) + (sequel ? 1 : 0);
                  const count = tab === 'episodes' ? (totalEps > 0 ? totalEps : undefined)
                    : tab === 'characters' ? (charactersCount > 0 ? charactersCount : undefined)
                    : tab === 'seasons' ? (relationsCount > 0 ? relationsCount : undefined)
                    : undefined;
                  return (
                    <DetailTab
                      key={tab}
                      tab={tab}
                      active={activeTab === tab}
                      onSelect={setActiveTab}
                      count={count}
                      label={tab === 'episodes' ? (isNovel ? 'Volumes & Books' : isManga ? 'Chapters' : 'Episodes') : tab === 'seasons' ? 'Related' : tab === 'characters' ? 'Cast & Staff' : tab === 'discussions' ? 'Discussions' : tab.charAt(0).toUpperCase() + tab.slice(1)}
                    />
                  );
                })}
              </FocusScope>

              {activeTab === 'episodes' && !isManga && !isNovel && episodes.length > 0 && (
                <div className="flex items-center gap-2.5 pb-2.5">
                  <div className="flex items-center gap-2">
                    <span className="font-mono text-[10.5px] uppercase tracking-wider text-muted-foreground font-semibold">Audio:</span>
                    <div className="flex bg-surface p-0.5 rounded-md border border-border text-[10.5px] font-mono">
                      <button
                        onClick={async () => {
                          setTranslationType("sub");
                          await handleSelectAudio("sub");
                        }}
                        className={`px-2.5 py-0.5 rounded transition-all cursor-pointer ${
                          (mediaPrefs?.translation_type ?? globalTranslationType) !== "dub"
                            ? "bg-accent/20 text-accent font-semibold"
                            : "text-muted-foreground hover:text-foreground"
                        }`}
                      >
                        Sub (JP)
                      </button>
                      <button
                        onClick={async () => {
                          setTranslationType("dub");
                          await handleSelectAudio("dub");
                        }}
                        className={`px-2.5 py-0.5 rounded transition-all cursor-pointer ${
                          (mediaPrefs?.translation_type ?? globalTranslationType) === "dub"
                            ? "bg-accent/20 text-accent font-semibold"
                            : "text-muted-foreground hover:text-foreground"
                        }`}
                      >
                        Dub (EN)
                      </button>
                    </div>
                  </div>

                  <div className="flex items-center bg-surface p-0.5 rounded-md border border-border text-[10.5px] font-mono">
                    <button
                      onClick={() => handleSetViewMode("cards")}
                      className={`px-2.5 py-0.5 rounded transition-all ${
                        viewMode === "cards"
                          ? "bg-foreground/10 text-foreground font-semibold"
                          : "text-muted-foreground hover:text-foreground"
                      }`}
                    >
                      Cards
                    </button>
                    <button
                      onClick={() => handleSetViewMode("compact")}
                      className={`px-2.5 py-0.5 rounded transition-all ${
                        viewMode === "compact"
                          ? "bg-foreground/10 text-foreground font-semibold"
                          : "text-muted-foreground hover:text-foreground"
                      }`}
                    >
                      Compact
                    </button>
                  </div>
                </div>
              )}
            </div>

            <div className="min-h-[300px]">
              <AnimatePresence mode="popLayout">
                {activeTab === 'episodes' && isNovel && (
                  <motion.div key="novel-volumes" initial={{ opacity: 0, y: 6 }} animate={{ opacity: 1, y: 0 }} exit={{ opacity: 0, y: -6 }} transition={{ duration: 0.18 }} className="h-full w-full space-y-6">
                    <div className="flex items-center justify-between pb-2 border-b border-border/60">
                      <div>
                        <h3 className="text-sm font-bold text-foreground">Light Novel Volumes & Compilations</h3>
                        <p className="meta-mono text-xs text-muted-foreground mt-0.5">
                          {effectiveNovelBooks.length} volumes indexed ·{" "}
                          {readableNovelVolume ? "text source linked" : "metadata only, no text source"}
                        </p>
                      </div>
                      <button
                        onClick={() => {
                          setSelectedNovelVolumeId(null);
                          setShowEreaderModal(true);
                        }}
                        className="flex items-center gap-1.5 rounded-md bg-accent/15 px-3 py-1.5 text-xs font-semibold text-accent hover:bg-accent/25 transition-colors cursor-pointer"
                      >
                        <Download size={13} />
                        <span>Download Full Series Guide</span>
                      </button>
                    </div>

                    {effectiveNovelBooks.length > 0 ? (
                      <div className="grid grid-cols-2 sm:grid-cols-3 md:grid-cols-4 lg:grid-cols-5 gap-4">
                        {effectiveNovelBooks.map((vol: NovelVolume, idx: number) => (
                          <div
                            key={String(vol.id || idx)}
                            onClick={() => vol.url && setActiveNovelVolume(vol)}
                            className={`group rounded-lg border border-border bg-card/60 p-3 transition-all flex flex-col justify-between ${
                              vol.url
                                ? "hover:border-accent/60 hover:bg-card cursor-pointer active:scale-[0.99]"
                                : "cursor-default"
                            }`}
                          >
                            <div>
                              <div className="aspect-[2/3] w-full overflow-hidden rounded-md bg-muted mb-2 relative">
                                {vol.cover_url ? (
                                  <img src={vol.cover_url} alt={vol.title} className="w-full h-full object-cover group-hover:scale-105 transition-transform duration-200" />
                                ) : (
                                  <div className="w-full h-full flex items-center justify-center text-muted-foreground">
                                    <BookOpen size={24} />
                                  </div>
                                )}
                              </div>
                              <h4 className="text-xs font-semibold text-foreground line-clamp-2 leading-tight group-hover:text-accent transition-colors">
                                {vol.title || `Volume ${idx + 1}`}
                              </h4>
                              {vol.release_date && (
                                <p className="meta-mono text-[10px] text-muted-foreground mt-1">
                                  {vol.release_date}
                                </p>
                              )}
                            </div>

                            <div className="mt-3 pt-2 border-t border-border/50 flex items-center gap-1.5">
                              <button
                                onClick={(e) => {
                                  e.stopPropagation();
                                  setSelectedNovelVolumeId(vol.id);
                                  setShowEreaderModal(true);
                                }}
                                className="flex-1 flex items-center justify-center gap-1 rounded bg-accent/15 py-1 text-[11px] font-semibold text-accent hover:bg-accent/25 transition-colors cursor-pointer"
                                title="Download EPUB for E-Reader"
                              >
                                <Download size={11} />
                                <span>EPUB</span>
                              </button>
                              <button
                                onClick={(e) => {
                                  e.stopPropagation();
                                  setActiveNovelVolume(vol);
                                }}
                                disabled={!vol.url}
                                className="flex-1 flex items-center justify-center gap-1 rounded border border-border py-1 text-[11px] font-medium text-foreground hover:bg-muted transition-colors cursor-pointer disabled:opacity-40 disabled:cursor-not-allowed disabled:hover:bg-transparent"
                                title={vol.url ? "Read Online" : "No readable text source for this volume"}
                              >
                                <BookOpen size={11} />
                                <span>Read</span>
                              </button>
                            </div>
                          </div>
                        ))}
                      </div>
                    ) : (
                      <div className="text-center py-16 border border-dashed border-border rounded-xl">
                        <BookOpen size={32} className="mx-auto text-muted-foreground/60 mb-2" />
                        <h4 className="text-xs font-bold text-foreground">No volume breakdown indexed</h4>
                        <p className="meta-mono text-[11px] text-muted-foreground mt-1 max-w-sm mx-auto">
                          You can still download the full light novel compendium or read online with CrossPoint optimization.
                        </p>
                        <button
                          onClick={() => setShowEreaderModal(true)}
                          className="mt-4 inline-flex items-center gap-1.5 rounded-lg bg-accent px-4 py-2 text-xs font-semibold text-accent-foreground hover:opacity-90 transition-opacity cursor-pointer"
                        >
                          <Download size={14} />
                          <span>Generate E-Reader EPUB</span>
                        </button>
                      </div>
                    )}
                  </motion.div>
                )}

                {activeTab === 'episodes' && !isNovel && (
                  <motion.div key="episodes" initial={{ opacity: 0, y: 6 }} animate={{ opacity: 1, y: 0 }} exit={{ opacity: 0, y: -6 }} transition={{ duration: 0.18 }} className="h-full w-full">
                    <EpisodeList
                      translationType={(mediaPrefs?.translation_type ?? globalTranslationType) as "sub" | "dub"}
                      viewMode={viewMode}
                      onViewModeChange={handleSetViewMode}
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
                      episodeThumbMap={episodeThumbMap}
                      episodeOverviewMap={episodeOverviewMap}
                      episodeAirDateMap={episodeAirDateMap}
                      episodeRuntimeMap={episodeRuntimeMap}
                      resumeSeconds={resumeSeconds}
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
                    {/* Portrait cards: AniList character art is 2:3, and the
                        old square avatar cropped every face down to a chin. */}
                    <FocusScope name="detail-characters" orientation="horizontal" className="grid grid-cols-3 sm:grid-cols-4 lg:grid-cols-6 gap-3">
                      <ScopeNav />
                      {loadingChars ? (
                        <div className="col-span-full py-20 flex justify-center"><Loader2 className="animate-spin text-accent" size={24} /></div>
                      ) : characters.length > 0 ? (
                        characters.map((char: Character) => {
                          const va = preferredVoiceActor(char);
                          return (
                            <FocusableButton
                              key={char.id || char.name.full}
                              onClick={() => setSelectedCharacter(char)}
                              className="group text-left rounded-md overflow-hidden border border-border bg-foreground/[0.02] hover:border-accent/40 transition-all active:scale-[0.98] character-card"
                            >
                              <div className="relative w-full aspect-[2/3] overflow-hidden bg-foreground/5">
                                {char.image?.large && (
                                  <img
                                    src={proxyImage(char.image.large)}
                                    alt={char.name.full}
                                    loading="lazy"
                                    className="w-full h-full object-cover transition-transform duration-300 group-hover:scale-105"
                                  />
                                )}
                                <span className="absolute top-1.5 left-1.5 px-1.5 py-0.5 rounded bg-black/70 text-[9px] font-black uppercase tracking-wider text-white/90">
                                  {char.role?.replace(/_/g, ' ')?.toLowerCase()}
                                </span>
                              </div>
                              <div className="p-2 space-y-0.5">
                                <div className="text-[12px] font-bold text-foreground group-hover:text-accent transition-colors truncate">{char.name.full}</div>
                                {va && (
                                  <div
                                    role="button"
                                    tabIndex={0}
                                    onClick={(e) => {
                                      e.stopPropagation();
                                      setSelectedCharacter(char);
                                      setSelectedStaffId(va.id);
                                    }}
                                    onKeyDown={(e) => {
                                      if (e.key === "Enter" || e.key === " ") {
                                        e.preventDefault();
                                        e.stopPropagation();
                                        setSelectedCharacter(char);
                                        setSelectedStaffId(va.id);
                                      }
                                    }}
                                    className="text-[10px] text-muted-foreground hover:text-accent transition-colors truncate cursor-pointer"
                                    title={`View ${va.name.full}'s filmography`}
                                  >
                                    <span className="truncate hover:underline">{va.name.full}</span>
                                  </div>
                                )}
                              </div>
                            </FocusableButton>
                          );
                        })
                      ) : (
                        <div className="col-span-full py-20 text-center text-muted-foreground text-xs font-bold">No character data available.</div>
                      )}
                    </FocusScope>
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
                              <FocusScope name="detail-seasons-grid" orientation="horizontal" className="grid grid-cols-2 sm:grid-cols-3 lg:grid-cols-4 gap-4">
                                <ScopeNav />
                                {seasonRels.map((rel: { relationType: string; node?: MediaItem }) => {
                                  const m = rel.node; if (!m) return null;
                                  return (
                                    <FocusableButton key={m.id} onClick={() => selectItem(m)} className="flex items-start gap-3 group text-left p-2 rounded-md hover:bg-foreground/[0.03] transition-colors">
                                      {(m.cover_image?.large || m.coverImage?.large) && <img src={proxyImage(m.cover_image?.large || m.coverImage?.large)} className="w-12 h-16 rounded-lg object-cover shrink-0" />}
                                      <div className="min-w-0">
                                        <div className="text-xs font-semibold text-foreground group-hover:text-accent transition-colors">{m.title?.english || m.title?.romaji}</div>
                                        {rel.relationType && <div className="text-[9px] font-bold text-accent/80 mt-0.5">{rel.relationType.replace(/_/g, ' ')}</div>}
                                        {m.format && <div className="text-[10px] text-muted-foreground mt-0.5">{m.format}</div>}
                                      </div>
                                    </FocusableButton>
                                  );
                                })}
                              </FocusScope>
                            </div>
                          )}
                          {otherRels.length > 0 && (
                            <div className="space-y-3">
                              <p className="text-xs font-semibold text-foreground">Other Relations</p>
                              <FocusScope name="detail-others-grid" orientation="horizontal" className="grid grid-cols-2 sm:grid-cols-3 lg:grid-cols-4 gap-4">
                                <ScopeNav />
                                {otherRels.map((rel: { relationType: string; node?: MediaItem }) => {
                                  const m = rel.node; if (!m) return null;
                                  return (
                                    <FocusableButton key={m.id} onClick={() => selectItem(m)} className="flex items-start gap-3 group text-left p-2 rounded-md hover:bg-foreground/[0.03] transition-colors">
                                      {(m.cover_image?.large || m.coverImage?.large) && <img src={proxyImage(m.cover_image?.large || m.coverImage?.large)} className="w-12 h-16 rounded-lg object-cover shrink-0" />}
                                      <div className="min-w-0">
                                        <div className="text-xs font-semibold text-foreground group-hover:text-accent transition-colors">{m.title?.english || m.title?.romaji}</div>
                                        {rel.relationType && <div className="text-[9px] font-bold text-accent/80 mt-0.5">{rel.relationType.replace(/_/g, ' ')}</div>}
                                        {m.format && <div className="text-[10px] text-muted-foreground mt-0.5">{m.format}</div>}
                                      </div>
                                    </FocusableButton>
                                  );
                                })}
                              </FocusScope>
                            </div>
                          )}
                        </div>
                      );
                    })()}
                  </motion.div>
                )}
                {activeTab === 'discussions' && (
                  <motion.div key="discussions" initial={{ opacity: 0, y: 6 }} animate={{ opacity: 1, y: 0 }} exit={{ opacity: 0, y: -6 }} transition={{ duration: 0.18 }} className="h-full w-full">
                    <MediaDiscussions
                      mediaId={item.id}
                      mediaTitle={fullItem.title?.english || fullItem.title?.romaji || title}
                      isManga={isManga}
                    />
                  </motion.div>
                )}
                {activeTab === 'more' && (
                  <motion.div key="more" initial={{ opacity: 0, y: 6 }} animate={{ opacity: 1, y: 0 }} exit={{ opacity: 0, y: -6 }} transition={{ duration: 0.18 }} className="h-full w-full space-y-8">
                    {!isManga && <AnimeThemeList mediaId={item.id} />}
                    {recommendations.length > 0 ? (
                      <div className="space-y-4">
                        <p className="text-xs font-semibold text-foreground">Recommendations</p>
                        <FocusScope name="detail-recommendations" orientation="horizontal" className="grid grid-cols-3 sm:grid-cols-4 lg:grid-cols-6 gap-4">
                          <ScopeNav />
                          {(recommendations as { mediaRecommendation?: MediaItem; cover_image?: { large?: string }; coverImage?: { large?: string }; rating?: number }[]).map((rec) => {
                            const m = rec.mediaRecommendation; if (!m) return null;
                            return (
                              <FocusableButton key={m.id} onClick={() => selectItem(m)} className="group space-y-2 text-left relative">
                                <div className="aspect-[2/3] rounded-xl overflow-hidden border border-border shadow-lg">
                                  <img src={proxyImage(rec.cover_image?.large || m.coverImage?.large)} className="w-full h-full object-cover transition-transform duration-500 group-hover:scale-110" />
                                </div>
                                {(rec.rating ?? 0) > 0 && <span className="absolute top-2 right-2 px-1.5 py-0.5 rounded bg-accent text-background text-[9px] font-bold">{rec.rating}%</span>}
                                <div className="text-[11px] font-bold text-muted-foreground line-clamp-2 group-hover:text-foreground transition-colors">{m.title?.english || m.title?.romaji}</div>
                              </FocusableButton>
                            );
                          })}
                        </FocusScope>
                      </div>
                    ) : (
                      isManga && <div className="py-20 text-center text-muted-foreground text-xs font-bold">No additional content.</div>
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
        <div 
          ref={characterModalRef}
          className="fixed inset-0 z-[200] flex items-center justify-center" 
          onClick={closeCharacterModal}
          role="dialog"
          aria-modal="true"
          aria-label={selectedCharacter.name?.full || "Character Details"}
          tabIndex={-1}
        >
          <div className="absolute inset-0 bg-black/60" />
          <div className="relative max-w-lg w-[90%] max-h-[85vh] overflow-y-auto bg-background border border-border rounded-lg p-6 shadow-2xl" onClick={(e) => e.stopPropagation()}>
            <button onClick={closeCharacterModal} className="absolute top-3 right-3 text-muted-foreground hover:text-foreground transition-colors z-10"><X size={16} /></button>
            {selectedStaffId ? (
              /* Same dialog, swapped content: a second stacked modal would put
                 two Escape handlers and two focus traps on the document. */
              <StaffProfile
                staffId={selectedStaffId}
                onBack={() => setSelectedStaffId(null)}
                onSelectMedia={(media) => { closeCharacterModal(); selectItem(media); }}
              />
            ) : (
            <>
            <div className="flex items-start space-x-4">
              {selectedCharacter.image?.large && <img src={proxyImage(selectedCharacter.image.large)} alt={selectedCharacter.name?.full} className="w-28 rounded-md aspect-[2/3] object-cover shadow-lg shrink-0" />}
              <div className="min-w-0 space-y-1 pr-6">
                <div className="text-base font-bold text-foreground">{selectedCharacter.name?.full}</div>
                {selectedCharacter.name?.native && <div className="text-xs text-muted-foreground">{selectedCharacter.name.native}</div>}
                <div className="text-[11px] text-muted-foreground capitalize">{selectedCharacter.role?.replace(/_/g, ' ')?.toLowerCase()}</div>
                <dl className="pt-2 grid grid-cols-[auto_1fr] gap-x-3 gap-y-1 text-[11px]">
                  {[
                    { label: 'Age', value: selectedCharacter.age },
                    { label: 'Gender', value: selectedCharacter.gender },
                    { label: 'Birthday', value: formatFuzzyDate(selectedCharacter.dateOfBirth) },
                    { label: 'Favourites', value: selectedCharacter.favourites ? selectedCharacter.favourites.toLocaleString() : undefined },
                  ].filter((f) => f.value).map((f) => (
                    <div key={f.label} className="contents">
                      <dt className="text-muted-foreground">{f.label}</dt>
                      <dd className="text-foreground font-medium">{f.value}</dd>
                    </div>
                  ))}
                </dl>
              </div>
            </div>

            {selectedCharacter.description && (
              <div className="mt-4 pt-4 border-t border-border space-y-2">
                <div className="meta-mono text-muted-foreground">About</div>
                {/* Spoiler blocks are cut before sanitizing: sanitizeHtml drops
                    the class AniList marks them with, so they would otherwise
                    render as plain visible text. */}
                <div
                  className="text-[12px] text-foreground/80 leading-relaxed whitespace-pre-line character-bio"
                  dangerouslySetInnerHTML={{ __html: sanitizeHtml(stripSpoilers(selectedCharacter.description)) }}
                />
              </div>
            )}

            {(selectedCharacter.voiceActors?.length ?? 0) > 0 && (
              <div className="mt-4 pt-4 border-t border-border space-y-2">
                <div className="meta-mono text-muted-foreground">Voice Actors</div>
                <VoiceActorList
                  voiceActors={selectedCharacter.voiceActors ?? []}
                  preferredLanguage={preferredVaLanguage}
                  onSelect={setSelectedStaffId}
                />
              </div>
            )}
            </>
            )}
          </div>
        </div>
      )}

      {/* Source match override modal */}
      {showMatchModal && (
        <div
          ref={matchModalRef}
          className="fixed inset-0 z-[200] flex items-center justify-center"
          onClick={closeMatchModal}
          role="dialog"
          aria-modal="true"
          aria-label="Source & Match Settings"
          tabIndex={-1}
        >
          <div className="absolute inset-0 bg-black/60 backdrop-blur-sm" />
          <div className="relative max-w-md w-[90%] max-h-[80vh] overflow-y-auto bg-background border border-border rounded-xl p-6 shadow-2xl space-y-4" onClick={(e) => e.stopPropagation()}>
            <button onClick={closeMatchModal} className="absolute top-4 right-4 text-muted-foreground hover:text-foreground transition-colors z-10"><X size={16} /></button>
            <div>
              <div className="text-base font-bold text-foreground">Source & Match Settings</div>
              <div className="text-xs text-muted-foreground mt-0.5">
                Configure stream provider source or search to fix unmatched titles.
              </div>
            </div>

            {/* Provider Switcher Tabs */}
            <div className="flex bg-surface p-1 rounded-lg border border-border text-xs font-mono">
              <button
                onClick={() => handleSelectProvider("nyaa")}
                className="flex-1 py-1.5 rounded-md font-semibold transition-all bg-accent/20 text-accent"
              >
                Torrents (Nyaa)
              </button>
            </div>

            <div className="flex items-center justify-between pt-1">
              <span className="text-xs font-semibold text-foreground">Fix title mapping</span>
              <button
                onClick={async () => {
                  await mediaApi.clearProviderCache(item.id).catch(() => {});
                  queryClient.invalidateQueries({ queryKey: ['media-episodes', item.id] });
                  queryClient.invalidateQueries({ queryKey: ['media-detail', item.id] });
                  closeMatchModal();
                }}
                className="flex items-center gap-1 text-[11px] font-mono text-muted-foreground hover:text-accent transition-colors"
                title="Clears cached episode list and forces a fresh query"
              >
                <RotateCcw size={11} />
                <span>Re-match source</span>
              </button>
            </div>
            <form
              className="flex gap-2 mb-4"
              onSubmit={async (e) => {
                e.preventDefault();
                if (!matchQuery.trim()) return;
                setMatchLoading(true);
                try {
                  const results = await mediaApi.searchProvider(matchQuery.trim(), selectedProvider);
                  setMatchResults(results);
                } catch {
                  notifyError("Search failed.");
                } finally {
                  setMatchLoading(false);
                }
              }}
            >
              <input
                type="text"
                value={matchQuery}
                onChange={(e) => setMatchQuery(e.target.value)}
                placeholder="Search title"
                className="flex-1 text-xs bg-surface border border-border rounded-lg px-3 py-2 text-foreground outline-none"
                autoFocus
              />
              <button
                type="submit"
                disabled={matchLoading || !matchQuery.trim()}
                className="px-3 py-2 rounded-lg bg-accent/15 text-accent border border-accent/30 text-xs font-semibold disabled:opacity-50"
              >
                {matchLoading ? <Loader2 size={14} className="animate-spin" /> : "Search"}
              </button>
            </form>
            {matchResults.length > 0 && (
              <div className="space-y-1.5">
                {matchResults.map((r) => (
                  <button
                    key={r.id}
                    disabled={matchSaving}
                    onClick={async () => {
                      setMatchSaving(true);
                      try {
                        await mediaApi.mapProviderSlug(item.id, selectedProvider, r.id);
                        await mediaApi.clearProviderCache(item.id).catch(() => {});
                        queryClient.invalidateQueries({ queryKey: ['media-episodes', item.id], refetchType: 'all' });
                        queryClient.invalidateQueries({ queryKey: ['media-detail', item.id], refetchType: 'all' });
                        closeMatchModal();
                      } catch {
                        notifyError("Could not save the match.");
                      } finally {
                        setMatchSaving(false);
                      }
                    }}
                    className="w-full text-left px-3 py-2 rounded-lg bg-foreground/[0.03] border border-border hover:border-accent/40 transition-all disabled:opacity-50"
                  >
                    <div className="text-xs font-semibold text-foreground">{r.title}</div>
                    {r.year && <div className="text-[10px] text-muted-foreground">{r.year}</div>}
                  </button>
                ))}
              </div>
            )}
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

      {/* Light Novel Reader */}
      {activeNovelVolume && (
        <NovelReader
          title={fullItem.title?.english || fullItem.title?.romaji || novelData?.title || item.title?.english || item.title?.romaji || "Light Novel"}
          author={novelData?.author}
          slug={fullItem.title?.english || fullItem.title?.romaji || String(item.id)}
          volumeUrl={activeNovelVolume.url}
          volumeTitle={activeNovelVolume.title}
          onClose={() => setActiveNovelVolume(null)}
        />
      )}

      {/* E-Reader EPUB Downloader Modal */}
      {showEreaderModal && (
        <EreaderDownloadModal
          isOpen={showEreaderModal}
          onClose={() => setShowEreaderModal(false)}
          media={fullItem}
          volumes={effectiveNovelBooks}
          selectedVolumeId={selectedNovelVolumeId}
        />
      )}
    </>
  );
}
