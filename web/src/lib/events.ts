import type { QueryClient } from "@tanstack/react-query";

let queryClient: QueryClient | null = null;

export function setQueryClient(client: QueryClient) {
  queryClient = client;
}

export function dispatchRefresh() {
  if (!queryClient) return;
  // Invalidate all queries — they'll refetch with the current auth state
  queryClient.invalidateQueries();
}

export function invalidateEpisodes(mediaId: number) {
  if (!queryClient) return;
  queryClient.invalidateQueries({ queryKey: ["media-episodes", mediaId] });
}
