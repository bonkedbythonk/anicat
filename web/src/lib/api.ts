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
  };
  stream: {
    player_type: string;
    preferred_quality: string;
    data_saver: boolean;
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

export async function searchAnime(query: string, page?: number, filters?: Record<string, string>): Promise<PagedMedia> {
  return invoke("search_media", { query, page, ...filters });
}

export async function getAnimeDetail(mediaId: number): Promise<MediaResponse> {
  return invoke("get_media_detail", { mediaId });
}

export async function getTrending(page?: number): Promise<PagedMedia> {
  return invoke("get_trending", { page });
}

export async function getSeasonal(
  season?: string,
  seasonYear?: number,
  page?: number,
): Promise<PagedMedia> {
  return invoke("get_seasonal", { season, seasonYear, page });
}

export async function getUpcoming(page?: number): Promise<PagedMedia> {
  return invoke("get_upcoming", { page });
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
  return invoke("get_episodes", { mediaId, provider: provider || "anineko", title: title || null });
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
): Promise<{ id: string; title: string; year?: number }[]> {
  return invoke("search_provider", { query });
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
  const rawKeys = raw ? Object.keys(raw) : [];
  const notifications = raw?.Page?.notifications ?? [];
  return raw;
}

// ── Playback ──────────────────────────────────────────────

export async function startPlayback(
  mediaId: number,
  episodeNumber: number,
  provider?: string,
): Promise<{ stream_url: string; servers: StreamServer[] }> {
  return invoke("start_playback", { mediaId, episodeNumber, provider });
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

// ── Health ────────────────────────────────────────────────

export async function getHealth(): Promise<{
  connected: boolean;
  authenticated: boolean;
  offline: boolean;
  data_version: number;
}> {
  return invoke("check_health");
}

export async function getAppVersion(): Promise<string> {
  return invoke("get_app_version");
}

// ── Legacy mediaApi compatibility layer ──────────────────

export const API_BASE_ORIGIN = "http://127.0.0.1:13370";

export const mediaApi = {
  getConfig,
  setConfig,
  searchMedia: searchAnime,
  getMediaDetail: async (id: number) => {
    const result = await getAnimeDetail(id);
    return result?.Media ? snakify(result.Media as unknown as Record<string, unknown>) : null;
  },
  getTrending: async (_type?: string) => {
    const result = await getTrending();
    return { media: snakifyMediaList(result?.Page?.media || []), page_info: result?.Page?.pageInfo || null };
  },
  getSeasonal: async (_type?: string) => {
    const result = await getSeasonal();
    return { media: snakifyMediaList(result?.Page?.media || []), page_info: result?.Page?.pageInfo || null };
  },
  getUpcoming: async (_type?: string) => {
    const result = await getUpcoming();
    return { media: snakifyMediaList(result?.Page?.media || []), page_info: result?.Page?.pageInfo || null };
  },
  getCharacters,
  getSmartPlaylist: async () => {
    const result = await getSmartPlaylist();
    const rawKeys = result ? Object.keys(result) : [];
    const mediaCount = result?.Page?.media?.length ?? 0;
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
      const rawKeys = result ? Object.keys(result) : [];
      const lists = (result as any)?.MediaListCollection?.lists ?? [];
      const entries = lists.flatMap((l: any) => l.entries ?? []);
      const media = entries.map((entry: any) => ({
        ...entry.media,
        user_status: {
          id: entry.id,
          status: entry.status,
          score: entry.score,
          progress: entry.progress,
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
  addToQueue: async (mediaId: number, episodes: number[]) => {
    try {
      return await invoke("add_to_queue", { mediaId, episodes });
    } catch (err) {
      console.warn("[addToQueue] not implemented, ignoring:", err);
    }
  },
  playNext: async (mediaId: number, provider: string) => {
    try {
      const history = await invoke<{ episode_number: number }[]>("get_watched_episodes", { mediaId });
      const nextEp = history.length > 0 ? Math.max(...history.map((h) => h.episode_number)) + 1 : 1;
      return await invoke("start_playback", { mediaId, episodeNumber: nextEp, provider });
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
  play: async (mediaId: number, epNum: number, provider?: string, server?: string) => {
    return invoke("start_playback", { mediaId, episodeNumber: epNum, provider });
  },
  getStreams: async (mediaId: number, epNum: number, provider?: string) => {
    return invoke("resolve_stream", { mediaId, episodeNumber: epNum, provider });
  },
  getDetails: async (mediaId: number) => {
    const result = await getAnimeDetail(mediaId);
    if (!result?.Media) return null;
    const media = result.Media;
    snakify(media as unknown as Record<string, unknown>);
    if (media.media_list_entry) {
      media.user_status = {
        id: media.media_list_entry.id,
        status: media.media_list_entry.status,
        score: media.media_list_entry.score,
        progress: media.media_list_entry.progress,
        updated_at: media.media_list_entry.updated_at || null,
      };
    }
    return media;
  },
  getQueue: async () => [],
  retryQueue: async () => {},
  removeFromQueue: async () => {},
  search: async (query: string = '', _type?: string, page?: number, filters?: Record<string, string>) => {
    const result = await searchAnime(query || '', page, filters);
    const rawKeys = result ? Object.keys(result) : [];
    const mediaCount = result?.Page?.media?.length ?? 0;
    return { media: snakifyMediaList(result?.Page?.media || []), page_info: result?.Page?.pageInfo || null };
  },
  getRecent: async () => {
    const result = await mediaApi.getUserList("watching", "ANIME");
    return result;
  },
  getSchedule: async (daysBack = 1, daysAhead = 3, page = 1, perPage = 50, mediaIds?: number[]) => {
    const raw = await invoke<any>("get_airing_schedule", { daysBack, daysAhead, page, perPage, mediaIds: mediaIds || [] });
    const rawKeys = raw ? Object.keys(raw) : [];
    const schedules = raw?.Page?.airingSchedules ?? [];
    const media = schedules.map((s: any) => ({
      ...s.media,
      next_airing: { episode: s.episode, airing_at: new Date(s.airingAt * 1000).toISOString() },
    }));
    const finalResult = { media: snakifyMediaList(media), page_info: raw?.Page?.pageInfo || null };
    return finalResult;
  },
  getPlaybackStatus: async () => null,
   getProfile: async () => {
     try {
       const raw = await invoke("get_user_profile");
       const rawKeys = raw ? Object.keys(raw) : [];
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
         favorite_anime: viewer.favourites?.anime?.nodes || [],
         favorite_manga: viewer.favourites?.manga?.nodes || [],
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
  getLogs: async () => [],
  wipeRegistry: async () => {},
  checkUpdate: async () => ({}),
  triggerUpdate: async () => {},
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
};

export type { StreamServer, AiringSchedule, Notification };
export { dispatchRefresh } from "./events";

export interface HealthStatus {
  connected: boolean;
  authenticated: boolean;
  offline: boolean;
  data_version: number;
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
  title: string;
}

export interface SearchFilters {
  genre?: string[];
  year?: number;
  season?: string;
  format?: string;
  status?: string;
  sort?: string;
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
