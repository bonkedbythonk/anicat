import type { QueryClient } from "@tanstack/react-query";

let queryClient: QueryClient | null = null;

export function setQueryClient(client: QueryClient) {
  queryClient = client;
}

export function dispatchRefresh() {
  if (!queryClient) return;
  queryClient.invalidateQueries({ queryKey: ["home-watching"] });
  queryClient.invalidateQueries({ queryKey: ["home-airing-today"] });
  queryClient.invalidateQueries({ queryKey: ["home-recent-releases"] });
  queryClient.invalidateQueries({ queryKey: ["home-smart-playlist"] });
}

export function invalidateEpisodes(mediaId: number) {
  if (!queryClient) return;
  queryClient.invalidateQueries({ queryKey: ["media-episodes", mediaId] });
}
