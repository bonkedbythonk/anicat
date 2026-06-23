import type { QueryClient } from "@tanstack/react-query";

let queryClient: QueryClient | null = null;

export function setQueryClient(client: QueryClient) {
  queryClient = client;
}

export function getQueryClient() { return queryClient; }

export function dispatchRefresh() {
  if (!queryClient) return;
  invalidateProgressQueries(queryClient);
}

export function invalidateEpisodes(mediaId: number) {
  if (!queryClient) return;
  queryClient.invalidateQueries({ queryKey: ["media-episodes", mediaId] });
}

// Single source of truth for which query families carry per-media progress/status.
const PROGRESS_QUERY_KEY_PREFIXES = [
  "home-", "user-list", "lists", "schedule", "search",
  "trending", "seasonal", "upcoming", "smart-playlist",
  "profile", "recently-watched",
];

// Invalidate every cache that can display a media item's progress/status, so the
// UI reconciles with AniList after a watch or an inline edit. Pass a mediaId to
// also refresh that title's detail drawer and episode list.
export function invalidateProgressQueries(qc: QueryClient, mediaId?: number) {
  qc.invalidateQueries({
    predicate: (q) => {
      const firstKey = String(q.queryKey[0] ?? "");
      return PROGRESS_QUERY_KEY_PREFIXES.some((p) => firstKey.startsWith(p));
    },
    refetchType: "all",
  });
  if (mediaId !== undefined) {
    qc.invalidateQueries({ queryKey: ["media-detail", mediaId], refetchType: "all" });
    qc.invalidateQueries({ queryKey: ["media-episodes", mediaId], refetchType: "all" });
  }
}

export function updateProgressInQueries(qc: QueryClient, mediaId: number, progress: number, status?: string) {
  const queries = qc.getQueryCache().getAll();
  for (const q of queries) {
    const queryKey = q.queryKey;
    const firstKey = String(queryKey[0] ?? "");
    if (!PROGRESS_QUERY_KEY_PREFIXES.some((p) => firstKey.startsWith(p))) continue;

    const data = q.state.data;
    if (!data) continue;

    const visited = new Set();
    let mutated = false;

    const updateObject = (obj: any): any => {
      if (!obj || typeof obj !== "object") return obj;
      if (visited.has(obj)) return obj;
      visited.add(obj);

      if (Array.isArray(obj)) {
        return obj.map(item => updateObject(item));
      }

      // Check if this is a media item with the matching ID
      if (obj.id === mediaId && (obj.title || obj.coverImage || obj.cover_image)) {
        mutated = true;
        const entry = obj.media_list_entry || obj.mediaListEntry || obj.user_status;
        const rawStatus = status || entry?.status || "watching";
        
        const updatedEntry = entry ? {
          ...entry,
          progress,
          status: rawStatus,
        } : {
          id: 0,
          progress,
          status: rawStatus,
          score: 0,
          repeat: 0,
          private: false,
        };

        const userStatus = {
          ...obj.user_status,
          progress,
          status: rawStatus.toLowerCase(),
        };

        return {
          ...obj,
          media_list_entry: updatedEntry,
          mediaListEntry: updatedEntry,
          user_status: userStatus,
        };
      }

      // Check if this is a media list entry with a media object matching mediaId
      if (obj.media && obj.media.id === mediaId) {
        mutated = true;
        const rawStatus = status || obj.status || "CURRENT";
        return {
          ...obj,
          progress,
          status: rawStatus.toUpperCase(),
          media: updateObject(obj.media),
        };
      }

      // Otherwise recurse into all fields
      const newObj: any = {};
      let localMutated = false;
      for (const [k, v] of Object.entries(obj)) {
        const updated = updateObject(v);
        newObj[k] = updated;
        if (updated !== v) localMutated = true;
      }
      if (!localMutated) return obj;
      return newObj;
    };

    const updatedData = updateObject(data);
    if (mutated) {
      qc.setQueryData(queryKey, updatedData);
    }
  }
}

export function removeMediaFromQueries(qc: QueryClient, mediaId: number) {
  const queries = qc.getQueryCache().getAll();
  for (const q of queries) {
    const queryKey = q.queryKey;
    const data = q.state.data;
    if (!data) continue;

    const visited = new Set();
    let mutated = false;

    const removeObject = (obj: any): any => {
      if (!obj || typeof obj !== "object") return obj;
      if (visited.has(obj)) return obj;
      visited.add(obj);

      if (Array.isArray(obj)) {
        const filtered = obj.filter(item => {
          if (item && typeof item === "object") {
            if (item.id === mediaId && (item.title || item.coverImage || item.cover_image)) {
              mutated = true;
              return false;
            }
            if (item.media && item.media.id === mediaId) {
              mutated = true;
              return false;
            }
          }
          return true;
        });
        return filtered.map(item => removeObject(item));
      }

      if (obj.id === mediaId && (obj.title || obj.coverImage || obj.cover_image)) {
        mutated = true;
        return {
          ...obj,
          media_list_entry: null,
          mediaListEntry: null,
          user_status: null,
        };
      }

      const newObj: any = {};
      for (const [k, v] of Object.entries(obj)) {
        newObj[k] = removeObject(v);
      }
      return newObj;
    };

    const updatedData = removeObject(data);
    if (mutated) {
      qc.setQueryData(queryKey, updatedData);
    }
  }
}
