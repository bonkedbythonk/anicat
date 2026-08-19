import { invoke } from "./transport";
import { isCinemaId } from "./mediaId";
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
    isFavourite: "is_favourite",
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

function snakifyMediaList(items: unknown[]): MediaItem[] {
  return items.map((m) => snakify(m as Record<string, unknown>)) as unknown as MediaItem[];
}

export async function getConfig(): Promise<{
  general: {
    provider: string;
    autoplay: boolean;
    autoskip: boolean;
    anime_preview: boolean;
    preferred_title_language: string;
    downloads_path: string;
    time_format?: string;
  };
  stream: {
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
    name: { full: string; native?: string };
    image: { large?: string };
    description?: string;
    age?: string;
    gender?: string;
    favourites?: number;
    dateOfBirth?: { year?: number | null; month?: number | null; day?: number | null };
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

export async function searchAnime(query: string, page?: number, mediaType?: string, filters?: SearchFilters): Promise<PagedMedia> {
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

export interface AniZipMeta {
  /** Episode number -> episode title (English preferred, Japanese fallback) */
  titles: Record<number, string>;
  /** Episode number -> TVDB still frame */
  thumbnails: Record<number, string>;
  /** Series-level artwork, grouped by AniZip's `coverType` */
  artwork: { fanart: string[]; banner: string[] };
}

const EMPTY_ANIZIP_META: AniZipMeta = {
  titles: {},
  thumbnails: {},
  artwork: { fanart: [], banner: [] },
};

/**
 * Fetch episode titles, per-episode still frames and series artwork from the
 * AniZip API. The `episodes` object is keyed by episode number as a string,
 * so it maps to episode numbers directly — no index guessing. Specials use
 * non-numeric keys ("S1") and are skipped.
 */
export async function fetchAniZipMeta(anilistId: number): Promise<AniZipMeta> {
  try {
    const res = await fetch(`https://api.ani.zip/mappings?anilist_id=${anilistId}`);
    if (!res.ok) return EMPTY_ANIZIP_META;
    const data = await res.json();

    const titles: Record<number, string> = {};
    const thumbnails: Record<number, string> = {};
    for (const [key, ep] of Object.entries(data?.episodes ?? {})) {
      const num = Number(key);
      if (!Number.isInteger(num) || num < 1) continue;
      const epData = ep as { title?: { en?: string; ja?: string }; image?: string };
      const title = epData?.title?.en || epData?.title?.ja || "";
      if (title && !title.startsWith("Episode ") && !title.startsWith("EPISODE ")) {
        titles[num] = title;
      }
      if (epData?.image) thumbnails[num] = epData.image;
    }

    const artwork = { fanart: [] as string[], banner: [] as string[] };
    for (const img of (data?.images ?? []) as { coverType?: string; url?: string }[]) {
      if (!img?.url) continue;
      const bucket = (img.coverType || "").toLowerCase();
      // Only landscape types: the strip is 16:9, and Poster is portrait while
      // Clearlogo is a transparent overlay — both read as broken art there.
      if (bucket === "fanart" || bucket === "banner") {
        artwork[bucket].push(img.url);
      }
    }

    return { titles, thumbnails, artwork };
  } catch {
    return EMPTY_ANIZIP_META;
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

export interface StaffRole {
  media: MediaItem;
  /** MAIN / SUPPORTING / BACKGROUND, for the character they played in it */
  characterRole?: string;
  characters: { id: number; name: { full: string }; image?: { large?: string } }[];
}

export interface StaffDetail {
  id: number;
  name: { full: string; native?: string };
  image?: { large?: string };
  /** AniList markdown rendered to HTML; pass through `stripSpoilers` first */
  description?: string;
  language?: string;
  occupations: string[];
  age?: number;
  homeTown?: string;
  yearsActive: number[];
  favourites?: number;
  dateOfBirth?: { year?: number | null; month?: number | null; day?: number | null };
  roles: StaffRole[];
  hasNextPage: boolean;
  totalRoles: number;
}

/**
 * A voice actor (or any staff member) and the roles they are credited with,
 * most popular show first. `page` walks the filmography — prolific actors run
 * to hundreds of credits.
 */
export async function getStaff(staffId: number, page?: number): Promise<StaffDetail | null> {
  const res = await invoke<unknown>("get_staff", { staffId, page });
  const staff = (res as { Staff?: Record<string, unknown> })?.Staff;
  if (!staff) return null;

  const cm = staff.characterMedia as {
    pageInfo?: { hasNextPage?: boolean; total?: number };
    edges?: {
      characterRole?: string;
      node?: MediaItem;
      characters?: StaffRole["characters"];
    }[];
  } | undefined;

  return {
    id: staff.id as number,
    name: (staff.name as StaffDetail["name"]) ?? { full: "" },
    image: staff.image as StaffDetail["image"],
    description: staff.description as string | undefined,
    language: staff.languageV2 as string | undefined,
    occupations: (staff.primaryOccupations as string[]) ?? [],
    age: staff.age as number | undefined,
    homeTown: staff.homeTown as string | undefined,
    yearsActive: (staff.yearsActive as number[]) ?? [],
    favourites: staff.favourites as number | undefined,
    dateOfBirth: staff.dateOfBirth as StaffDetail["dateOfBirth"],
    // The command returns AniList's raw JSON, so the media nodes arrive
    // camelCase and need the same snake_case aliases every other media list
    // in this file gets before components can read `cover_image`.
    roles: (cm?.edges ?? [])
      .filter((e): e is typeof e & { node: MediaItem } => !!e.node)
      .map((e) => ({
        media: snakify(e.node as unknown as Record<string, unknown>) as unknown as MediaItem,
        characterRole: e.characterRole,
        characters: e.characters ?? [],
      })),
    hasNextPage: cm?.pageInfo?.hasNextPage ?? false,
    totalRoles: cm?.pageInfo?.total ?? 0,
  };
}

/**
 * Flatten `getCharacters`'s edge list into `Character` objects. The response
 * has been seen unwrapped to varying depths depending on the transport, so
 * every shape it has arrived in is accepted.
 */
export function flattenCharacterEdges(res: unknown): Character[] {
  const r = res as {
    Media?: { characters?: { edges?: unknown[] } };
    media?: { characters?: { edges?: unknown[] } };
    characters?: { edges?: unknown[] };
    edges?: unknown[];
  };
  const edges =
    r?.Media?.characters?.edges || r?.media?.characters?.edges || r?.characters?.edges || r?.edges || [];

  type RawNode = Omit<Character, "role" | "voiceActors">;
  type RawEdge = Partial<RawNode> & {
    role?: string;
    node?: Partial<RawNode>;
    voiceActors?: Character["voiceActors"];
  };

  return (edges as RawEdge[]).map((edge): Character => {
    const node = edge.node ?? edge;
    return {
      id: node.id ?? 0,
      name: node.name ?? { full: "" },
      image: node.image,
      description: node.description,
      age: node.age,
      gender: node.gender,
      favourites: node.favourites,
      dateOfBirth: node.dateOfBirth,
      role: edge.role ?? "",
      voiceActors: edge.voiceActors ?? [],
    };
  });
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
  episodeCount?: number,
): Promise<Episode[]> {
  return invoke("get_episodes", { mediaId, provider: provider || "anineko", title: title || null, episodeCount: episodeCount ?? null });
}

export async function getChapterPages(
  mediaId: number,
  chapterNumber: string,
): Promise<{ thumbnails: string[]; title: string }> {
  return invoke("get_chapter_pages", { mediaId, chapterNumber });
}

export async function getStreams(
  mediaId: number,
  episodeNumber: number,
  provider?: string,
  title?: string,
): Promise<StreamServer[]> {
  return invoke("resolve_stream", { mediaId, episodeNumber, provider, title });
}

export const resolveStream = getStreams;

export async function preloadEpisode(
  mediaId: number,
  episodeNumber: number,
  provider?: string,
  title?: string,
): Promise<void> {
  return invoke("preload_episode", { mediaId, episodeNumber, provider, title });
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
  siteUrl?: string;
  options?: { displayAdultContent?: boolean };
  mediaListOptions?: { scoreFormat?: string };
  statistics?: {
    anime?: {
      count: number;
      meanScore: number;
      minutesWatched: number;
      episodesWatched: number;
      genres?: { genre: string; count: number }[];
    };
    manga?: {
      count: number;
      meanScore: number;
      chaptersRead: number;
      volumesRead: number;
    };
  };
  favourites?: {
    anime?: { nodes?: MediaItem[] };
    manga?: { nodes?: MediaItem[] };
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
  updatedAt?: number;
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

export async function toggleFavourite(mediaId: number, isManga: boolean): Promise<void> {
  return invoke("toggle_favourite", { mediaId, isManga });
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

export interface WatchActivityEntry {
  media_id: number;
  episode_number: number;
  watched_at: string;
}

/** Full per-episode watch log from the local registry, newest first. */
export async function getWatchActivity(): Promise<WatchActivityEntry[]> {
  return invoke("get_watch_history");
}

export async function playTrailer(trailerId: string): Promise<void> {
  return invoke("play_trailer", { trailerId });
}

// ── Per-show preference overrides ─────────────────────────

export interface MediaPrefs {
  provider: string | null;
  translation_type: string | null;
}

export async function getMediaPrefs(mediaId: number): Promise<MediaPrefs> {
  return invoke("get_media_prefs", { mediaId });
}

/** null clears an override back to "inherit the global setting". */
export async function setMediaPrefs(mediaId: number, prefs: MediaPrefs): Promise<void> {
  return invoke("set_media_prefs", { mediaId, provider: prefs.provider, translationType: prefs.translation_type });
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

export { apiOrigin } from "./proxy";

/** The named rows cinema mode's home screen is built from. The backend maps
 *  each to a fixed TMDB endpoint, so this list and `row_path` in
 *  `commands/cinema.rs` have to agree. */
/** One episode of a series. `number` is the absolute count across seasons —
 *  what the app stores and what auto-next adds one to — while `season` and
 *  `episode_in_season` are for display and for the release search. */
export interface CinemaEpisode {
  number: number;
  season: number | null;
  episode_in_season: number | null;
  title: string | null;
  description: string | null;
  thumbnail: string | null;
  air_date: string | null;
  duration: number | null;
}

/** One row of the local cinema library. */
export interface CinemaLibraryEntry {
  media_id: number;
  media_type: string | null;
  status: string | null;
  score: number | null;
  progress: number | null;
  notes: string | null;
  updated_at: string | null;
}

export type CinemaRow =
  | "trending_movies"
  | "trending_series"
  | "popular_movies"
  | "popular_series"
  | "now_playing"
  | "top_rated_movies"
  | "top_rated_series";

export const mediaApi = {
  getConfig,
  setConfig,
  getAllLastWatched,
  getWatchActivity,
  searchMedia: searchAnime,
  getMediaDetail: async (id: number, mediaType?: string) => {
    // The id says which catalog owns it, so callers don't have to. Without
    // this a cinema id would be sent to AniList, which has never heard of it.
    if (isCinemaId(id)) {
      const result = await invoke<Record<string, unknown> | null>("tmdb_detail", { mediaId: id });
      if (!result) return null;
      // `similar` holds whole media items, and snakify only walks the object it
      // is given — so without this the nested entries keep `coverImage` while
      // every card reads `cover_image`, and the row renders as blank posters.
      if (Array.isArray(result.similar)) {
        result.similar = snakifyMediaList(result.similar);
      }
      return snakify(result);
    }
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
  getStaff,

  // Cinema mode. The backend hands these back in the same {Page:{media,
  // pageInfo}} envelope the AniList commands use, so they unwrap through the
  // same helper and produce the same MediaItem shape the cards already render.
  cinemaRow: async (row: CinemaRow, page?: number) => {
    const result = await invoke<PagedMedia>("tmdb_row", { row, page: page ?? 1 });
    return { media: snakifyMediaList(result?.Page?.media || []), page_info: result?.Page?.pageInfo || null };
  },
  cinemaSearch: async (query: string, page?: number) => {
    const result = await invoke<PagedMedia>("tmdb_search", { query, page: page ?? 1 });
    return { media: snakifyMediaList(result?.Page?.media || []), page_info: result?.Page?.pageInfo || null };
  },
  /** Cinema mode's library, held locally rather than on a tracking service.
   *  Entries carry only ids, so each is paired with its TMDB record before it
   *  can be rendered. */
  cinemaLibrary: async (): Promise<{ entry: CinemaLibraryEntry; media: MediaItem }[]> => {
    const entries = await invoke<CinemaLibraryEntry[]>("get_library");
    const cinema = (entries ?? []).filter((e) => isCinemaId(e.media_id));
    const withMedia = await Promise.all(
      cinema.map(async (entry) => {
        try {
          const media = (await mediaApi.getMediaDetail(entry.media_id)) as unknown as MediaItem;
          return media ? { entry, media } : null;
        } catch {
          return null;
        }
      }),
    );
    return withMedia.filter((x): x is { entry: CinemaLibraryEntry; media: MediaItem } => x !== null);
  },
  /** Put a title on the watchlist, or move it between statuses. The library
   *  is a local table, so this is the only thing that writes PLANNING —
   *  watched state comes from playback instead. */
  cinemaSetLibraryStatus: async (mediaId: number, mediaType: "MOVIE" | "TV", status: string) => {
    return invoke("add_to_library", { mediaId, mediaType, status });
  },
  cinemaRemoveFromLibrary: async (mediaId: number) => {
    return invoke("remove_from_library", { mediaId });
  },
  cinemaEpisodes: async (mediaId: number) => {
    const result = await invoke<{ episodes: CinemaEpisode[] }>("tmdb_episodes", { mediaId });
    return result?.episodes ?? [];
  },
  cinemaConfigured: async () => {
    try {
      return await invoke<boolean>("tmdb_configured");
    } catch {
      return false;
    }
  },
  getSmartPlaylist: async () => {
    const result = await getSmartPlaylist();
    return { media: snakifyMediaList(result?.Page?.media || []) };
  },
  getEpisodes,
  getChapterPages,
  resolveStream,
  preloadEpisode,
  searchProvider,
  mapProviderSlug,
  clearProviderCache,
  getUserProfile: getUser,
  getUserList: async (status?: string, type?: string, page?: number) => {
    try {
      const anilistStatus = ({
        watching: "CURRENT",
        reading: "CURRENT",
        current: "CURRENT",
        rereading: "REPEATING",
        completed: "COMPLETED",
        paused: "PAUSED",
        dropped: "DROPPED",
        planning: "PLANNING",
        repeating: "REPEATING",
      } as Record<string, string>)[status?.toLowerCase() ?? ""] ?? status?.toUpperCase() ?? "CURRENT";

      const result = await getUserLists(undefined, anilistStatus, type);
      const lists = result?.MediaListCollection?.lists ?? [];
      const entries = lists.flatMap((l) => l.entries ?? []);
      const media = entries.map((entry) => ({
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
  toggleFavourite,
  startPlayback,
  stopPlayback,
  trackPlayback: stopPlayback,
  playTrailer,
  getWatchHistory,
  getMediaPrefs,
  setMediaPrefs,
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
  play: async (mediaId: number, epNum: number, provider?: string, server?: string, title?: string, episodeTitle?: string, coverImage?: string, totalEpisodes?: number, startOver?: boolean) => {
    return invoke("start_playback", { mediaId, episodeNumber: epNum, provider, server, title, episodeTitle, coverImage, totalEpisodes, startOver });
  },
  getStreams: async (mediaId: number, epNum: number, provider?: string) => {
    return invoke("resolve_stream", { mediaId, episodeNumber: epNum, provider });
  },
  getDetails: async (mediaId: number, mediaType?: string) => {
    // MediaCard is shared between anime rows and cinema rows, and its hover
    // prefetch calls this with no mediaType -- without this branch every
    // cinema card hovered sent a live AniList query for a banded id AniList
    // has never heard of, 404ing every time. getMediaDetail already knows
    // how to route a cinema id; this is the second, separately-reachable
    // path into the same bug.
    if (isCinemaId(mediaId)) {
      return (await mediaApi.getMediaDetail(mediaId)) as unknown as MediaItem | null;
    }
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
  search: async (query: string = '', _type?: string, page?: number, filters?: SearchFilters) => {
    const result = await searchAnime(query || '', page, _type, filters);
    return { media: snakifyMediaList(result?.Page?.media || []), page_info: result?.Page?.pageInfo || null };
  },
  getRecent: async (type?: string) => {
    const result = await mediaApi.getUserList("watching", type || "ANIME");
    return result;
  },
  getSchedule: async (daysBack = 1, daysAhead = 7, page = 1, perPage = 50, mediaIds?: number[]) => {
    const raw = await invoke<{
      Page: {
        airingSchedules: { episode: number; airingAt: number; media: MediaItem }[];
        pageInfo?: PageInfo | null;
      } | null;
    }>("get_airing_schedule", { daysBack, daysAhead, page, perPage, mediaIds: mediaIds || [] });
    const schedules = raw?.Page?.airingSchedules ?? [];
    const media = schedules.map((s) => ({
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
       const raw = await invoke<{ Viewer: ViewerData | null }>("get_user_profile");
       const viewer = raw?.Viewer;
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
      const result = await invoke<{
        current_version: string;
        update_available: boolean;
        latest_version: string;
        release_url: string | null;
        release_notes: string | null;
      }>("check_update");

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
        message: "Couldn't connect to the update server. Try again later.",
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
        message: "Couldn't install update. Try downloading from the website.",
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
  fetchAniZipMeta,
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
  current_version?: string;
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
  genre?: string;
  year?: number;
  season?: string;
  format?: string;
  status?: string;
  sort?: string;
  minScore?: number;
}

// Matches the snake_cased object built by getProfile() below.
export type UserProfile = {
  id: number;
  name: string;
  about?: string | null;
  avatar?: string | null;
  avatar_url?: string | null;
  banner_image?: string | null;
  banner_url?: string | null;
  site_url?: string | null;
  minutes_watched?: number;
  episodes_watched?: number;
  anime_count?: number;
  mean_score?: number;
  chapters_read?: number;
  manga_count?: number;
  volumes_read?: number;
  statistics?: unknown;
  genres?: { genre: string; count: number; minutesWatched?: number }[];
  favorite_anime?: MediaItem[];
  favorite_manga?: MediaItem[];
};

export type { MediaItem, Episode, Character } from "./types";

export interface Review {
  id: number;
  summary: string;
  score: number;
  user: { id: number; name: string; avatar?: string };
}
