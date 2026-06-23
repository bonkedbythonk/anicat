import { invoke } from "@tauri-apps/api/core";
import type {
  MediaItem,
  Episode,
  StreamServer,
  Character,
  AiringSchedule,
  Notification,
} from "./types";

// ── Config ────────────────────────────────────────────────

// Normalize API response: add snake_case aliases for old v4 components
function snakify(item: Record<string, unknown>): Record<string, unknown> {
  if (!item || typeof item !== "object") return item;
  const camelToSnake: Record<string, string> = {
    coverImage: "cover_image",
    bannerImage: "banner_image",
    averageScore: "average_score",
    meanScore: "mean_score",
    nextAiringEpisode: "next_airing",
    startDate: "start_date",
    endDate: "end_date",
    mediaListEntry: "media_list_entry",
  };
  for (const [camel, snake] of Object.entries(camelToSnake)) {
    if (camel in item && !(snake in item)) {
      (item as Record<string, unknown>)[snake] = (item as Record<string, unknown>)[camel];
    }
  }
  
  const nextAiring = item.next_airing || item.nextAiringEpisode;
  if (nextAiring && typeof nextAiring === "object") {
    const na = nextAiring as Record<string, unknown>;
    if ("airingAt" in na && !("airing_at" in na)) {
      na.airing_at = na.airingAt;
    }
    if ("timeUntilAiring" in na && !("time_until_airing" in na)) {
      na.time_until_airing = na.timeUntilAiring;
    }
  }
  
  return item;
}

function snakifyMediaList(items: unknown[]): unknown[] {
  return items.map((m) => snakify(m as Record<string, unknown>));
}

export async function getConfig(): Promise<{
  general: {
    provider: string;
    autoplay: boolean;
    autoskip: boolean;
    anime_preview: boolean;
    preferred_title_language: string;
    downloads_path: string;
    update_branch?: string;
    time_format?: string;
  };
  stream: {
    player_type: string;
    preferred_quality: string;
    data_saver: boolean;
    shader_profile?: string;
    translation_type?: string;
  };
  api: {
    anilist_token: string | null;
  };
}> {
  return invoke("get_config");
}

export async function setConfig(updates: Record<string, unknown>): Promise<void> {
  return invoke("update_config", { updates });
}

// ── Media ─────────────────────────────────────────────────

interface PageInfo {
  total: number | null;
  currentPage: number | null;
  lastPage: number | null;
  hasNextPage: boolean | null;
}

interface PagedMedia {
  Page: {
    media: MediaItem[] | null;
    pageInfo: PageInfo | null;
  };
}

interface MediaResponse {
  Media: MediaItem | null;
}

interface CharacterEdge {
  role: string;
  node: {
    id: number;
    name: { full: string };
    image: { large?: string };
  };
  voiceActors: {
    id: number;
    name: { full: string };
    image: { large?: string };
    language: string;
  }[];
}

interface MediaCharacters {
  Media: {
    characters: {
      edges: CharacterEdge[];
    };
  } | null;
}

export async function searchAnime(query: string, page?: number, mediaType?: string, filters?: Record<string, string>): Promise<PagedMedia> {
  return invoke("search_media", { query, page, mediaType, ...filters });
}

export async function getAnimeDetail(mediaId: number, mediaType?: string): Promise<MediaResponse> {
  return invoke("get_media_detail", { mediaId, mediaType });
}

/** Fetch filler episode numbers from Jikan API (MyAnimeList). Returns empty array on error. */
export async function fetchJikanFiller(malId: number): Promise<number[]> {
  const fillers = new Set<number>();
  try {
    let page = 1;
    let hasNext = true;
    while (hasNext) {
      const res = await fetch(`https://api.jikan.moe/v4/anime/${malId}/episodes?page=${page}`);
      if (!res.ok) return Array.from(fillers);
      const data = await res.json();
      for (const ep of data?.data || []) {
        if (ep.filler === true) {
          fillers.add(ep.mal_id);
        }
      }
      hasNext = data?.pagination?.has_next_page ?? false;
      page++;
    }
  } catch {
    // ignore
  }
  return Array.from(fillers);
}

/** Fetch episode titles from AniZip API (all episodes, English + Japanese) */
export async function fetchAniZipTitles(anilistId: number): Promise<Record<number, string>> {
  try {
    const res = await fetch(`https://api.ani.zip/mappings?anilist_id=${anilistId}`);
    if (!res.ok) return {};
    const data = await res.json();
    const episodes = data?.episodes;
    if (!episodes) return {};
    const map: Record<number, string> = {};
    for (const [num, ep] of Object.entries(episodes)) {
      const epData = ep as any;
      const title = epData?.title?.en || epData?.title?.ja || "";
      if (title && !title.startsWith("Episode ") && !title.startsWith("EPISODE ")) {
        map[Number(num)] = title;
      }
    }
    return map;
  } catch {
    return {};
  }
}

export async function getTrending(page?: number, mediaType?: string): Promise<PagedMedia> {
  return invoke("get_trending", { page, mediaType });
}

export async function getSeasonal(
  season?: string,
  seasonYear?: number,
  page?: number,
  mediaType?: string,
): Promise<PagedMedia> {
  return invoke("get_seasonal", { season, seasonYear, page, mediaType });
}

export async function getUpcoming(page?: number, mediaType?: string): Promise<PagedMedia> {
  return invoke("get_upcoming", { page, mediaType });
}

export async function getCharacters(mediaId: number): Promise<MediaCharacters> {
  return invoke("get_media_characters", { mediaId });
}

export async function getSmartPlaylist(): Promise<{
  Page: { media: MediaItem[] | null; pageInfo: { hasNextPage: boolean | null } | null };
}> {
  return invoke("get_smart_playlist");
}

// ── Episodes / Scraper ────────────────────────────────────

export async function getEpisodes(
  mediaId: number,
  provider?: string,
  title?: string,
): Promise<Episode[]> {
  return invoke("get_episodes", { mediaId, provider: provider || "allanime", title: title || null });
}

export async function getChapterPages(
  mediaId: number,
  chapterNumber: string,
): Promise<{ thumbnails: string[]; title: string }> {
  return invoke("get_chapter_pages", { mediaId, chapterNumber });
}

export async function resolveStream(
  mediaId: number,
  episodeNumber: number,
  provider?: string,
): Promise<StreamServer[]> {
  return invoke("resolve_stream", { mediaId, episodeNumber, provider });
}

export async function searchProvider(
  query: string,
  provider?: string,
): Promise<{ id: string; title: string; year?: number }[]> {
  return invoke("search_provider", { query, provider });
}

export async function mapProviderSlug(
  mediaId: number,
  provider: string,
  slug: string,
): Promise<void> {
  return invoke("map_provider_slug", { mediaId, provider, slug });
}

export async function clearProviderCache(mediaId: number): Promise<void> {
  return invoke("clear_provider_cache", { mediaId });
}

// ── User ──────────────────────────────────────────────────

interface ViewerData {
  id: number;
  name: string;
  about?: string;
  avatar?: { large?: string; medium?: string };
  bannerImage?: string;
  options?: { displayAdultContent?: boolean };
  statistics?: {
    anime?: {
      count: number;
      meanScore: number;
      minutesWatched: number;
      episodesWatched: number;
    };
  };
}

interface ListEntry {
  id: number;
  status: string;
  score: number;
  progress: number;
  progressVolumes?: number;
  repeat: number;
  private: boolean;
  notes?: string;
  startedAt?: { year?: number; month?: number; day?: number };
  completedAt?: { year?: number; month?: number; day?: number };
  media: MediaItem;
}

interface MediaListCollection {
  MediaListCollection: {
    lists: {
      name: string;
      status: string;
      entries: ListEntry[];
    }[];
  };
}

export async function getUser(): Promise<{ Viewer: ViewerData | null }> {
  return invoke("get_user_profile");
}

export async function getUserLists(
  userName?: string,
  status?: string,
  mediaType?: string,
): Promise<MediaListCollection> {
  return invoke("get_user_list", { userName, status, mediaType });
}

export async function updateProgress(
  mediaId: number,
  progress: number,
  status?: string,
): Promise<{ SaveMediaListEntry: { id: number; status: string; score: number; progress: number } | null }> {
  return invoke("save_media_list_entry", {
    mediaId,
    updates: { progress, ...(status ? { status } : {}) },
  });
}

export async function updateMediaEntry(
  mediaId: number,
  updates: Record<string, unknown>,
): Promise<{
  SaveMediaListEntry: {
    id: number;
    status: string;
    score: number;
    progress: number;
    progressVolumes?: number;
    repeat: number;
    private: boolean;
  } | null;
}> {
  return invoke("save_media_list_entry", { mediaId, updates });
}

export async function removeMediaEntry(
  entryId: number,
): Promise<{ DeleteMediaListEntry: { deleted: boolean } | null }> {
  return invoke("delete_media_list_entry", { entryId });
}

export async function getNotifications(page?: number): Promise<{
  Page: { notifications: Notification[]; pageInfo: PageInfo | null };
}> {
  const raw = await invoke<any>("get_notifications", { page });
  return raw;
}

// ── Playback ──────────────────────────────────────────────

export async function startPlayback(
  mediaId: number,
  episodeNumber: number,
  provider?: string,
  server?: string,
): Promise<{ stream_url: string; servers: StreamServer[] }> {
  return invoke("start_playback", { mediaId, episodeNumber, provider, server });
}

export async function stopPlayback(
  mediaId: number,
  episodeNumber: number,
  stopTime: number,
  duration: number,
): Promise<void> {
  return invoke("stop_playback", { mediaId, episodeNumber, stopTime, duration });
}

export async function getWatchHistory(
  mediaId: number,
): Promise<{ episode_number: number; stop_time: number; duration: number }[]> {
  return invoke("get_watched_episodes", { mediaId });
}

export async function getAllLastWatched(): Promise<Record<number, string>> {
  return invoke("get_all_last_watched");
}

// ── Health ────────────────────────────────────────────────

export async function getHealth(): Promise<{
  connected: boolean;
  authenticated: boolean;
  offline: boolean;
}> {
  return invoke("check_health");
}

export async function getAppVersion(): Promise<string> {
  return invoke("get_app_version");
}

let latestDownloadUrl = "";

export async function getLogs(): Promise<string> {
  return invoke("get_logs");
}

export async function checkUpdate(): Promise<{ version: string; url: string; notes: string } | null> {
  try {
    const data = await invoke<{ current_version: string; update_available: boolean; latest_version: string; release_url: string | null; release_notes: string | null } | null>("check_update");
    if (data?.release_url) latestDownloadUrl = data.release_url;
    return data ? { version: data.latest_version || data.current_version, url: data.release_url || "", notes: data.release_notes || "" } : null;
  } catch {
    return null;
  }
}

export async function triggerUpdate(): Promise<void> {
  return invoke("trigger_update", { url: latestDownloadUrl });
}

// ── Legacy mediaApi compatibility layer ──────────────────

export const API_BASE_ORIGIN = "http://127.0.0.1:13370";

export const mediaApi = {
  getConfig,
  setConfig,
  getAllLastWatched,
  searchMedia: searchAnime,
  getMediaDetail: async (id: number, mediaType?: string) => {
    const result = await getAnimeDetail(id, mediaType);
    return result?.Media ? snakify(result.Media as unknown as Record<string, unknown>) : null;
  },
  getTrending: async (_type?: string) => {
    const result = await getTrending(undefined, _type);
    return { media: snakifyMediaList(result?.Page?.media || []), page_info: result?.Page?.pageInfo || null };
  },
  getSeasonal: async (_type?: string) => {
    const result = await getSeasonal(undefined, undefined, undefined, _type);
    return { media: snakifyMediaList(result?.Page?.media || []), page_info: result?.Page?.pageInfo || null };
  },
  getUpcoming: async (_type?: string) => {
    const result = await getUpcoming(undefined, _type);
    return { media: snakifyMediaList(result?.Page?.media || []), page_info: result?.Page?.pageInfo || null };
  },
  getCharacters,
  getSmartPlaylist: async () => {
    const result = await getSmartPlaylist();
    return { media: snakifyMediaList(result?.Page?.media || []) };
  },
  getEpisodes,
  getChapterPages,
  resolveStream,
  searchProvider,
  mapProviderSlug,
  clearProviderCache,
  getUserProfile: getUser,
  getUserList: async (status?: string, type?: string, page?: number) => {
    try {
      const anilistStatus = ({
        watching: "CURRENT",
        current: "CURRENT",
        completed: "COMPLETED",
        paused: "PAUSED",
        dropped: "DROPPED",
        planning: "PLANNING",
        repeating: "REPEATING",
      } as Record<string, string>)[status?.toLowerCase() ?? ""] ?? status?.toUpperCase() ?? "CURRENT";

      const result = await getUserLists(undefined, anilistStatus, type);
      const lists = (result as any)?.MediaListCollection?.lists ?? [];
      const entries = lists.flatMap((l: any) => l.entries ?? []);
      const media = entries.map((entry: any) => ({
        ...entry.media,
        user_status: {
          id: entry.id,
          status: entry.status,
          score: entry.score,
          progress: entry.progress,
          progress_volumes: entry.progressVolumes ?? null,
          updated_at: entry.updatedAt,
        },
      }));
      const snakified = snakifyMediaList(media);
      // Client-side pagination (AniList MediaListCollection returns all entries)
      const PER_PAGE = 50;
      const pageNum = page || 1;
      const start = (pageNum - 1) * PER_PAGE;
      const finalMedia = snakified.slice(start, start + PER_PAGE);
      return {
        media: finalMedia,
        page_info: { has_next_page: start + PER_PAGE < snakified.length },
      };
    } catch (err) {
      console.error("[getUserList] failed:", err);
      throw err;
    }
  },
  saveMediaListEntry: updateMediaEntry,
  deleteMediaListEntry: removeMediaEntry,
  startPlayback,
  stopPlayback,
  trackPlayback: stopPlayback,
  getWatchHistory,
  checkHealth: getHealth,
  getAppVersion,
  // Stub methods for old component compatibility — delegate to real commands where possible
  getReviews: async () => [],
  getRecommendations: async () => [],
  getRelations: async () => [],
  addToQueue: async (mediaId: number, episodes: number[], title?: string, coverImage?: string) => {
    try {
      return await invoke("add_to_queue", { mediaId, episodes, title, coverImage });
    } catch (err) {
      console.warn("[addToQueue] failed:", err);
    }
  },
  playNext: async (mediaId: number, provider: string, title?: string, coverImage?: string, episodeTitle?: string, totalEpisodes?: number) => {
    try {
      const history = await invoke<{ episode_number: number }[]>("get_watched_episodes", { mediaId }) ?? [];
      const nextEp = history.length > 0 ? Math.max(...history.map((h) => h.episode_number)) + 1 : 1;
      return await invoke("start_playback", { mediaId, episodeNumber: nextEp, provider, title, coverImage, episodeTitle, totalEpisodes });
    } catch (err) {
      console.warn("[playNext] failed:", err);
    }
  },
  deleteFromList: async (entryId: number) => {
    try {
      return await invoke("delete_media_list_entry", { entryId });
    } catch (err) {
      console.warn("[deleteFromList] failed:", err);
    }
  },
  updateStatus: async (mediaId: number, status: string) => {
    const mapped = ({
      watching: "CURRENT", reading: "CURRENT", current: "CURRENT",
      planning: "PLANNING", completed: "COMPLETED", paused: "PAUSED",
      dropped: "DROPPED", repeating: "REPEATING",
    } as Record<string, string>)[status] || status.toUpperCase();
    try {
      return await invoke("save_media_list_entry", { mediaId, updates: { status: mapped } });
    } catch (err) {
      console.warn("[updateStatus] failed:", err);
    }
  },
  play: async (mediaId: number, epNum: number, provider?: string, server?: string, title?: string, episodeTitle?: string, coverImage?: string, totalEpisodes?: number) => {
    return invoke("start_playback", { mediaId, episodeNumber: epNum, provider, server, title, episodeTitle, coverImage, totalEpisodes });
  },
  getStreams: async (mediaId: number, epNum: number, provider?: string) => {
    return invoke("resolve_stream", { mediaId, episodeNumber: epNum, provider });
  },
  getDetails: async (mediaId: number, mediaType?: string) => {
    const result = await getAnimeDetail(mediaId, mediaType);
    if (!result?.Media) return null;
    const media = result.Media;
    snakify(media as unknown as Record<string, unknown>);
    if (media.media_list_entry) {
      media.user_status = {
        id: media.media_list_entry.id,
        status: media.media_list_entry.status,
        score: media.media_list_entry.score,
        progress: media.media_list_entry.progress,
        progress_volumes: media.media_list_entry.progress_volumes ?? null,
        updated_at: media.media_list_entry.updated_at || null,
      };
    }
    return media;
  },
  getQueue: async () => {
    try {
      return await invoke<QueueItem[]>("get_queue");
    } catch (err) {
      console.warn("[getQueue] failed:", err);
      return [];
    }
  },
  retryQueue: async () => {
    try {
      return await invoke("retry_queue");
    } catch (err) {
      console.warn("[retryQueue] failed:", err);
    }
  },
  removeFromQueue: async (mediaId: number, ep: string | number) => {
    try {
      const episodeNumber = typeof ep === "string" ? parseInt(ep, 10) : ep;
      return await invoke("remove_from_queue", { mediaId, episodeNumber });
    } catch (err) {
      console.warn("[removeFromQueue] failed:", err);
    }
  },
  search: async (query: string = '', _type?: string, page?: number, filters?: Record<string, string>) => {
    const result = await searchAnime(query || '', page, _type, filters);
    return { media: snakifyMediaList(result?.Page?.media || []), page_info: result?.Page?.pageInfo || null };
  },
  getRecent: async (type?: string) => {
    const result = await mediaApi.getUserList("watching", type || "ANIME");
    return result;
  },
  getSchedule: async (daysBack = 1, daysAhead = 7, page = 1, perPage = 50, mediaIds?: number[]) => {
    const raw = await invoke<any>("get_airing_schedule", { daysBack, daysAhead, page, perPage, mediaIds: mediaIds || [] });
    const schedules = raw?.Page?.airingSchedules ?? [];
    const media = schedules.map((s: any) => ({
      ...s.media,
      next_airing: { episode: s.episode, airing_at: new Date(s.airingAt * 1000).toISOString() },
    }));
    const finalResult = { media: snakifyMediaList(media), page_info: raw?.Page?.pageInfo || null };
    return finalResult;
  },
  getPlaybackStatus: async () => null,
  clearPlaybackStatus: async () => {},
   getProfile: async () => {
     try {
       const raw = await invoke("get_user_profile");
       const viewer = (raw as any)?.Viewer;
       if (!viewer) return null;
       const animeStats = viewer.statistics?.anime;
       const mangaStats = viewer.statistics?.manga;
       return {
         id: viewer.id,
         name: viewer.name,
         about: viewer.about || null,
         avatar: viewer.avatar?.large || viewer.avatar?.medium || null,
         avatar_url: viewer.avatar?.large || viewer.avatar?.medium || null,
         banner_image: viewer.bannerImage || null,
         banner_url: viewer.bannerImage || null,
         site_url: viewer.siteUrl || null,
         minutes_watched: animeStats?.minutesWatched || 0,
         episodes_watched: animeStats?.episodesWatched || 0,
         anime_count: animeStats?.count || 0,
         mean_score: animeStats?.meanScore || 0,
         chapters_read: mangaStats?.chaptersRead || 0,
         manga_count: mangaStats?.count || 0,
         volumes_read: mangaStats?.volumesRead || 0,
         statistics: animeStats || null,
         genres: animeStats?.genres || [],
         favorite_anime: snakifyMediaList(viewer.favourites?.anime?.nodes || []) as MediaItem[],
         favorite_manga: snakifyMediaList(viewer.favourites?.manga?.nodes || []) as MediaItem[],
       };
     } catch (err) {
       console.error("[API:getProfile] failed:", err);
       return null;
     }
   },
  getNotifications: async (page?: number) => {
    try {
      const raw = await getNotifications(page);
      return raw?.Page?.notifications ?? [];
    } catch (err) {
      console.error("[API:getNotifications] failed:", err);
      return [];
    }
  },
  markNotificationsAsRead: async () => {
    return invoke("mark_notifications_read");
  },
  getLogs: async (limit = 100) => {
    try {
      const logs = await invoke<string>("get_logs", { limit });
      return { logs };
    } catch (err) {
      console.error("[getLogs] failed:", err);
      return { logs: "" };
    }
  },
  wipeRegistry: async () => {},
  checkUpdate: async () => {
    try {
      const config = await getConfig();
      const branch = config?.general?.update_branch || "stable";
      const result = await invoke<{
        current_version: string;
        update_available: boolean;
        latest_version: string;
        release_url: string | null;
        release_notes: string | null;
      }>("check_update", { updateBranch: branch });

      if (result.release_url) {
        latestDownloadUrl = result.release_url;
      }

      if (result.update_available) {
        return {
          status: "success",
          update_available: true,
          message: `A new version ${result.latest_version} is available!`,
          release_notes: result.release_notes,
          release_url: result.release_url,
        };
      }

      return {
        status: "success",
        update_available: false,
        message: "Anicat is already up to date!",
      };
    } catch (err) {
      console.error("[checkUpdate] error:", err);
      return {
        status: "error",
        message: "Failed to connect to the update server. Please try again later.",
      };
    }
  },
  triggerUpdate: async () => {
    try {
      const url = latestDownloadUrl || "https://github.com/bonkedbythonk/anicat/releases";
      await invoke("trigger_update", { url });
      return {
        status: "success",
        message: "Update downloaded and installed! Restart the app to use the new version.",
      };
    } catch (err) {
      return {
        status: "error",
        message: "Failed to install update. Try downloading from the website.",
      };
    }
  },
  updateConfig: setConfig,
  getRegistryStats: async () => ({}),
  triggerBackup: async () => {},
  getConfigOptions: async () => ({}),
  testProvider: async () => ({}),
  openUrl: async (url: string) => {
    const { open } = await import("@tauri-apps/plugin-shell");
    return open(url);
  },
  commitProgress: async () => {},
  startEditing: async () => {},
  cancelEditing: async () => {},
  fetchAniZipTitles,
  fetchJikanFiller,
};

export type { StreamServer, AiringSchedule, Notification };
export { dispatchRefresh } from "./events";

export interface HealthStatus {
  connected: boolean;
  authenticated: boolean;
  offline: boolean;
  update_available?: boolean;
  token_present?: boolean;
  viewer_name?: string | null;
  auth_error?: string | null;
}

export interface PlaybackStatus {
  item: MediaItem | null;
  episode: number;
  provider: string;
  server: string | null;
}

export interface QueueItem {
  media_id: number;
  episode_number: number;
  status: string;
  media_title: string;
  cover_image: string;
  error_message?: string | null;
  progress: number;
}

export interface SearchFilters {
  genre?: string[];
  year?: number;
  season?: string;
  format?: string;
  status?: string;
  sort?: string;
  minScore?: number;
}

export type UserProfile = {
  id: number;
  name: string;
  avatar?: { large?: string; medium?: string };
  bannerImage?: string;
  about?: string;
  statistics?: {
    anime?: {
      count: number;
      meanScore: number;
      minutesWatched: number;
      episodesWatched: number;
    };
  };
};

export type { MediaItem, Episode, Character } from "./types";

export interface Review {
  id: number;
  summary: string;
  score: number;
  user: { id: number; name: string; avatar?: string };
}
