import type { QueryClient } from "@tanstack/react-query";

const REFRESH_KEYS = [
  "home",
  "library",
  "lists",
  "notifications",
  "user-profile",
  "media-episodes",
];

let queryClient: QueryClient | null = null;

export function setQueryClient(client: QueryClient) {
  queryClient = client;
}

export function dispatchRefresh() {
  if (!queryClient) return;
  for (const key of REFRESH_KEYS) {
    queryClient.invalidateQueries({ queryKey: [key] });
  }
}

export function invalidateEpisodes(mediaId: number) {
  if (!queryClient) return;
  queryClient.invalidateQueries({ queryKey: ["media-episodes", mediaId] });
}
