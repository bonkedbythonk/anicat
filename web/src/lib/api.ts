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

export async function searchAnime(query: string, page?: number): Promise<PagedMedia> {
  return invoke("search_media", { query, page });
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
): Promise<Episode[]> {
  return invoke("get_episodes", { mediaId, provider });
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
): Promise<MediaListCollection> {
  return invoke("get_user_list", { userName, status });
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
  return invoke("get_notifications", { page });
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
  getMediaDetail: getAnimeDetail,
  getTrending: async (_type?: string) => {
    const result = await getTrending();
    return { media: result?.Page?.media || [], page_info: result?.Page?.pageInfo || null };
  },
  getSeasonal: async (_type?: string) => {
    const result = await getSeasonal();
    return { media: result?.Page?.media || [], page_info: result?.Page?.pageInfo || null };
  },
  getUpcoming: async (_type?: string) => {
    const result = await getUpcoming();
    return { media: result?.Page?.media || [], page_info: result?.Page?.pageInfo || null };
  },
  getCharacters,
  getSmartPlaylist: async () => {
    const result = await getSmartPlaylist();
    return { media: result?.Page?.media || [] };
  },
  getEpisodes,
  resolveStream,
  searchProvider,
  mapProviderSlug,
  clearProviderCache,
  getUserProfile: getUser,
  getUserList: async (status?: string, _type?: string) => {
    try {
      const result = await getUserLists(undefined, status);
      const lists = result?.MediaListCollection?.lists || [];
      const media = lists.flatMap((l: { entries?: { media: MediaItem }[] }) =>
        l.entries?.map(e => e.media) || []
      );
      return { media };
    } catch {
      return { media: [] };
    }
  },
  saveMediaListEntry: updateMediaEntry,
  deleteMediaListEntry: removeMediaEntry,
  getNotifications,
  startPlayback,
  stopPlayback,
  trackPlayback: stopPlayback,
  getWatchHistory,
  checkHealth: getHealth,
  getAppVersion,
  play: async (mediaId: number, epNum: number, provider?: string, server?: string) => {
    return invoke("start_playback", { mediaId, episodeNumber: epNum, provider });
  },
  getStreams: async (mediaId: number, epNum: number, provider?: string) => {
    return invoke("resolve_stream", { mediaId, episodeNumber: epNum, provider });
  },
  addToQueue: async (mediaId: number, episodes: number[]) => {
    return invoke("add_to_queue", { mediaId, episodes });
  },
  getDetails: async (mediaId: number) => {
    return invoke("get_media_detail", { mediaId });
  },
  // Stub methods for old component compatibility
  getReviews: async () => [],
  getRecommendations: async () => [],
  getRelations: async () => [],
  playNext: async () => {},
  deleteFromList: async () => {},
  updateStatus: async () => {},
  getQueue: async () => [],
  retryQueue: async () => {},
  removeFromQueue: async () => {},
  search: async (query: string = '', _type?: string, page?: number) => {
    const result = await searchAnime(query || '', page);
    return { media: result?.Page?.media || [], page_info: result?.Page?.pageInfo || null };
  },
  getRecent: async (_type?: string) => {
    const result = await getTrending();
    return { media: result?.Page?.media || [] };
  },
  getSchedule: async () => {
    const result = await getSeasonal();
    return { media: result?.Page?.media || [] };
  },
  getPlaybackStatus: async () => null,
  getProfile: async () => ({}),
  markNotificationsAsRead: async () => {},
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
