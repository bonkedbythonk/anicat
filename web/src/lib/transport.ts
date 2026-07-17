// Transport shim so lib/api.ts's ~40 exported functions work unchanged in
// both the desktop Tauri webview (real invoke()) and the mobile PWA (plain
// fetch() against the LAN-facing /mobile-api/* routes on the same origin the
// page was loaded from). Everything else in api.ts is unaware of the switch.
import { invoke as tauriInvoke } from "@tauri-apps/api/core";

const TOKEN_KEY = "anicat_mobile_token";
const USER_KEY = "anicat_mobile_user";

export function isTauri(): boolean {
  return typeof window !== "undefined" && !!(window as unknown as { __TAURI_INTERNALS__?: unknown }).__TAURI_INTERNALS__;
}

export function getMobileToken(): string | null {
  if (typeof window === "undefined") return null;
  return window.localStorage.getItem(TOKEN_KEY);
}

export function setMobileToken(token: string): void {
  window.localStorage.setItem(TOKEN_KEY, token);
}

export function clearMobileToken(): void {
  window.localStorage.removeItem(TOKEN_KEY);
  window.localStorage.removeItem(USER_KEY);
}

export interface MobileUser {
  userId: number;
  displayName: string;
}

/** Only meaningful in multi-user mode — single-PIN mode never calls
 * `setMobileUser`, so `getMobileUser()` stays `null` and callers that only
 * care about "is a specific person logged in" (vs. the single shared PIN)
 * naturally no-op. */
export function getMobileUser(): MobileUser | null {
  if (typeof window === "undefined") return null;
  const raw = window.localStorage.getItem(USER_KEY);
  if (!raw) return null;
  try {
    return JSON.parse(raw) as MobileUser;
  } catch {
    return null;
  }
}

export function setMobileUser(user: MobileUser): void {
  window.localStorage.setItem(USER_KEY, JSON.stringify(user));
}

function qs(params: Record<string, unknown>): string {
  const search = new URLSearchParams();
  for (const [key, value] of Object.entries(params)) {
    if (value === undefined || value === null || value === "") continue;
    if (Array.isArray(value)) {
      if (value.length > 0) search.set(key, value.join(","));
    } else {
      search.set(key, String(value));
    }
  }
  const str = search.toString();
  return str ? `?${str}` : "";
}

interface Route {
  method: "GET" | "POST" | "DELETE";
  // Builds the request path (including query string) from the invoke() args.
  path: (args: Record<string, unknown>) => string;
  // Builds the JSON body for POST requests. Omit for GET/DELETE.
  body?: (args: Record<string, unknown>) => unknown;
}

// One entry per Tauri command lib/api.ts actually calls. Field names on the
// left are the camelCase keys api.ts passes to invoke(); the right-hand side
// translates them into the snake_case query/body shape the Rust mobile-api
// handlers expect (Tauri does this camelCase->snake_case conversion for us
// automatically for real invoke() calls — here it has to be done by hand).
const ROUTES: Record<string, Route> = {
  get_config: { method: "GET", path: () => "/mobile-api/config" },
  update_config: { method: "POST", path: () => "/mobile-api/config", body: (a) => a.updates },

  search_media: {
    method: "GET",
    path: (a) => `/mobile-api/media/search${qs({
      query: a.query, page: a.page, media_type: a.mediaType, status: a.status,
      genre: a.genre, year: a.year, min_score: a.minScore,
    })}`,
  },
  get_media_detail: { method: "GET", path: (a) => `/mobile-api/media/${a.mediaId}${qs({ media_type: a.mediaType })}` },
  get_trending: { method: "GET", path: (a) => `/mobile-api/media/trending${qs({ page: a.page, media_type: a.mediaType })}` },
  get_seasonal: {
    method: "GET",
    path: (a) => `/mobile-api/media/seasonal${qs({
      season: a.season, season_year: a.seasonYear, page: a.page, media_type: a.mediaType,
    })}`,
  },
  get_upcoming: { method: "GET", path: (a) => `/mobile-api/media/upcoming${qs({ page: a.page, media_type: a.mediaType })}` },
  get_media_characters: { method: "GET", path: (a) => `/mobile-api/media/${a.mediaId}/characters` },
  get_smart_playlist: { method: "GET", path: () => "/mobile-api/smart-playlist" },

  get_episodes: {
    method: "GET",
    path: (a) => `/mobile-api/media/${a.mediaId}/episodes${qs({
      provider: a.provider, title: a.title, episode_count: a.episodeCount,
    })}`,
  },
  get_chapter_pages: { method: "GET", path: (a) => `/mobile-api/media/${a.mediaId}/chapters/${a.chapterNumber}` },
  resolve_stream: {
    method: "GET",
    path: (a) => `/mobile-api/media/${a.mediaId}/streams${qs({ episode_number: a.episodeNumber, provider: a.provider })}`,
  },
  preload_episode: {
    method: "POST",
    path: () => "/mobile-api/playback/preload",
    body: (a) => ({ media_id: a.mediaId, episode_number: a.episodeNumber, provider: a.provider, title: a.title }),
  },
  search_provider: { method: "GET", path: (a) => `/mobile-api/provider/search${qs({ query: a.query, provider: a.provider })}` },
  map_provider_slug: {
    method: "POST",
    path: () => "/mobile-api/provider/map-slug",
    body: (a) => ({ media_id: a.mediaId, provider: a.provider, slug: a.slug }),
  },
  clear_provider_cache: {
    method: "POST",
    path: () => "/mobile-api/provider/clear-cache",
    body: (a) => ({ media_id: a.mediaId }),
  },

  get_user_profile: { method: "GET", path: () => "/mobile-api/user/profile" },
  get_user_list: {
    method: "GET",
    path: (a) => `/mobile-api/user/list${qs({ user_name: a.userName, status: a.status, media_type: a.mediaType })}`,
  },
  save_media_list_entry: {
    method: "POST",
    path: () => "/mobile-api/user/list-entry",
    body: (a) => ({ media_id: a.mediaId, updates: a.updates }),
  },
  delete_media_list_entry: { method: "DELETE", path: (a) => `/mobile-api/user/list-entry/${a.entryId}` },
  toggle_favourite: {
    method: "POST",
    path: () => "/mobile-api/user/favourite",
    body: (a) => ({ media_id: a.mediaId, is_manga: a.isManga }),
  },

  get_airing_schedule: {
    method: "GET",
    path: (a) => `/mobile-api/schedule${qs({
      days_back: a.daysBack, days_ahead: a.daysAhead, media_ids: a.mediaIds, page: a.page, per_page: a.perPage,
    })}`,
  },

  get_library: { method: "GET", path: () => "/mobile-api/library" },
  add_to_library: {
    method: "POST",
    path: () => "/mobile-api/library",
    body: (a) => ({
      media_id: a.mediaId, media_type: a.mediaType, status: a.status,
      score: a.score, progress: a.progress, notes: a.notes,
    }),
  },
  remove_from_library: { method: "DELETE", path: (a) => `/mobile-api/library/${a.mediaId}` },

  get_watched_episodes: { method: "GET", path: (a) => `/mobile-api/playback/watched/${a.mediaId}` },
  get_all_last_watched: { method: "GET", path: () => "/mobile-api/playback/last-watched" },
  get_watch_history: { method: "GET", path: () => "/mobile-api/playback/history" },

  check_health: { method: "GET", path: () => "/mobile-api/health" },
  get_app_version: { method: "GET", path: () => "/mobile-api/version" },
};

class MobileUnauthorizedError extends Error {
  constructor() {
    super("Unauthorized");
    this.name = "MobileUnauthorizedError";
  }
}

/** Attaches the stored bearer token and, on 401/403, clears it and fires
 * anicat_mobile_unauthorized (the mobile shell listens for this and bounces
 * back to the PIN gate) — the one place this handling lives, shared by both
 * the invoke() shim below and anything else that talks to /mobile-api or
 * /player directly (e.g. the video overlay's playback progress reporting). */
export async function mobileFetch(path: string, init: RequestInit = {}): Promise<Response> {
  const token = getMobileToken();
  const headers = new Headers(init.headers);
  if (token) headers.set("Authorization", `Bearer ${token}`);
  const res = await fetch(path, { ...init, headers });
  if (res.status === 401 || res.status === 403) {
    clearMobileToken();
    window.dispatchEvent(new Event("anicat_mobile_unauthorized"));
  }
  return res;
}

async function mobileInvoke<T>(cmd: string, args: Record<string, unknown>): Promise<T> {
  const route = ROUTES[cmd];
  if (!route) {
    throw new Error(`[transport] "${cmd}" isn't available on mobile.`);
  }
  const res = await mobileFetch(route.path(args), {
    method: route.method,
    headers: route.body ? { "Content-Type": "application/json" } : undefined,
    body: route.body ? JSON.stringify(route.body(args) ?? null) : undefined,
  });

  if (res.status === 401 || res.status === 403) {
    throw new MobileUnauthorizedError();
  }
  if (!res.ok) {
    const text = await res.text().catch(() => res.statusText);
    throw new Error(text || res.statusText);
  }
  if (res.status === 204) return undefined as T;
  return res.json() as Promise<T>;
}

export async function invoke<T>(cmd: string, args: Record<string, unknown> = {}): Promise<T> {
  if (isTauri()) {
    return tauriInvoke<T>(cmd, args);
  }
  return mobileInvoke<T>(cmd, args);
}
