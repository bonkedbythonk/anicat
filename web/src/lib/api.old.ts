import { invoke } from "@tauri-apps/api/core";
import type { Episode, StreamServer, UserProfile } from "./types";

// Config
export async function getConfig(): Promise<Record<string, unknown>> {
  return invoke("get_config");
}

export async function updateConfig(updates: Record<string, unknown>): Promise<void> {
  return invoke("update_config", { updates });
}

// Media
export async function searchMedia(query: string, page?: number): Promise<unknown> {
  return invoke("search_media", { query, page });
}

export async function getMediaDetail(mediaId: number): Promise<unknown> {
  return invoke("get_media_detail", { mediaId });
}

export async function getTrending(page?: number): Promise<unknown> {
  return invoke("get_trending", { page });
}

export async function getSeasonal(season?: string, seasonYear?: number, page?: number): Promise<unknown> {
  return invoke("get_seasonal", { season, seasonYear, page });
}

export async function getUpcoming(page?: number): Promise<unknown> {
  return invoke("get_upcoming", { page });
}

export async function getMediaCharacters(mediaId: number): Promise<unknown> {
  return invoke("get_media_characters", { mediaId });
}

export async function getSmartPlaylist(): Promise<unknown> {
  return invoke("get_smart_playlist");
}

// Episodes / Streaming
export async function getEpisodes(mediaId: number, provider?: string): Promise<Episode[]> {
  return invoke("get_episodes", { mediaId, provider });
}

export async function resolveStream(mediaId: number, episodeNumber: number, provider?: string): Promise<StreamServer[]> {
  return invoke("resolve_stream", { mediaId, episodeNumber, provider });
}

// Provider
export async function searchProvider(query: string): Promise<{ id: string; title: string; year?: number }[]> {
  return invoke("search_provider", { query });
}

export async function mapProviderSlug(mediaId: number, provider: string, slug: string): Promise<void> {
  return invoke("map_provider_slug", { mediaId, provider, slug });
}

export async function clearProviderCache(mediaId: number): Promise<void> {
  return invoke("clear_provider_cache", { mediaId });
}

// User
export async function getUserList(userName?: string, status?: string): Promise<unknown> {
  return invoke("get_user_list", { userName, status });
}

export async function getUserProfile(): Promise<unknown> {
  return invoke("get_user_profile");
}

export async function saveMediaListEntry(mediaId: number, updates: Record<string, unknown>): Promise<unknown> {
  return invoke("save_media_list_entry", { mediaId, updates });
}

export async function deleteMediaListEntry(entryId: number): Promise<unknown> {
  return invoke("delete_media_list_entry", { entryId });
}

export async function getNotifications(page?: number): Promise<unknown> {
  return invoke("get_notifications", { page });
}

// Playback
export async function trackPlayback(mediaId: number, episodeNumber: number, stopTime: number, duration: number): Promise<void> {
  return invoke("track_playback", { mediaId, episodeNumber, stopTime, duration });
}

export async function getWatchedEpisodes(mediaId: number): Promise<[number, number, number][]> {
  return invoke("get_watched_episodes", { mediaId });
}

// Health
export async function checkHealth(): Promise<{ connected: boolean; authenticated: boolean; offline: boolean; data_version: number }> {
  return invoke("check_health");
}

export async function getAppVersion(): Promise<string> {
  return invoke("get_app_version");
}
