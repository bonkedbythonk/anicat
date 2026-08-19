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

// Invalidate every cache that can display a media item's progress/status, so the
// UI reconciles with AniList after a watch or an inline edit. Pass a mediaId to
// also refresh that title's detail drawer and episode list.
//
// Uses explicit queryKey arrays (not a predicate) because TanStack Query v5 with
// persist-client does not reliably trigger refetches for predicate-only filters.
export function invalidateProgressQueries(qc: QueryClient, mediaId?: number) {
  // Home view rows — all "active" so they re-render immediately
  qc.invalidateQueries({ queryKey: ["home-watching"], refetchType: "all" });
  qc.invalidateQueries({ queryKey: ["home-last-watched"], refetchType: "all" });
  qc.invalidateQueries({ queryKey: ["home-repeating"], refetchType: "all" });
  qc.invalidateQueries({ queryKey: ["home-planning"], refetchType: "all" });
  qc.invalidateQueries({ queryKey: ["home-airing-today"], refetchType: "all" });
  qc.invalidateQueries({ queryKey: ["home-recent-releases"], refetchType: "all" });
  qc.invalidateQueries({ queryKey: ["home-smart-playlist"], refetchType: "all" });
  qc.invalidateQueries({ queryKey: ["home-trending"], refetchType: "all" });
  qc.invalidateQueries({ queryKey: ["home-seasonal"], refetchType: "all" });
  qc.invalidateQueries({ queryKey: ["home-newly-releasing"], refetchType: "all" });
  // Lists / library / profile / manga
  qc.invalidateQueries({ queryKey: ["lists"], refetchType: "active" });
  qc.invalidateQueries({ queryKey: ["library"], refetchType: "active" });
  qc.invalidateQueries({ queryKey: ["profile"], refetchType: "active" });
  qc.invalidateQueries({ queryKey: ["manga-data"], refetchType: "active" });
  // Media-specific (only if mediaId provided)
  if (mediaId !== undefined) {
    qc.invalidateQueries({ queryKey: ["media-detail", mediaId], refetchType: "all" });
    qc.invalidateQueries({ queryKey: ["media-episodes", mediaId], refetchType: "all" });
    qc.invalidateQueries({ queryKey: ["watch-history", mediaId], refetchType: "all" });
  }
}

const OPTIMISTIC_UPDATE_PREFIXES = [
  "home-", "lists", "library", "profile", "manga-data", "search",
  // The detail page itself. Missing this was the whole point of an
  // optimistic update turned backwards: every *other* cached view patched
  // instantly on a manual progress edit, while the one query backing the
  // screen actually being edited waited on the real AniList round trip
  // (then an invalidate, then a refetch) before the number on screen moved
  // -- which is what made a manual edit feel slow. It never was slow
  // elsewhere; nothing elsewhere was being watched.
  "media-detail",
];

export function updateProgressInQueries(qc: QueryClient, mediaId: number, progress: number, status?: string) {
  const queries = qc.getQueryCache().getAll();
  for (const q of queries) {
    const queryKey = q.queryKey;
    const firstKey = String(queryKey[0] ?? "");
    if (!OPTIMISTIC_UPDATE_PREFIXES.some((p) => firstKey.startsWith(p))) continue;

    const data = q.state.data;
    if (!data) continue;

    const visited = new Set<object>();
    let mutated = false;

    const updateObject = (obj: unknown): unknown => {
      if (!obj || typeof obj !== "object") return obj;
      if (visited.has(obj)) return obj;
      visited.add(obj);

      if (Array.isArray(obj)) {
        return obj.map(item => updateObject(item));
      }

      const record = obj as Record<string, unknown>;

      // Check if this is a media item with the matching ID
      if (record.id === mediaId && (record.title || record.coverImage || record.cover_image)) {
        mutated = true;
        const entry = (record.media_list_entry || record.mediaListEntry || record.user_status) as Record<string, unknown> | undefined;
        const rawStatus = status || (entry?.status as string) || "watching";

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
          ...(record.user_status as Record<string, unknown>),
          progress,
          status: rawStatus.toLowerCase(),
        };

        return {
          ...record,
          media_list_entry: updatedEntry,
          mediaListEntry: updatedEntry,
          user_status: userStatus,
        };
      }

      // Check if this is a media list entry with a media object matching mediaId
      const recordMedia = record.media as Record<string, unknown> | undefined;
      if (recordMedia && recordMedia.id === mediaId) {
        mutated = true;
        const rawStatus = status || (record.status as string) || "CURRENT";
        return {
          ...record,
          progress,
          status: rawStatus.toUpperCase(),
          media: updateObject(record.media),
        };
      }

      // Otherwise recurse into all fields
      const newObj: Record<string, unknown> = {};
      let localMutated = false;
      for (const [k, v] of Object.entries(record)) {
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

    const visited = new Set<object>();
    let mutated = false;

    const removeObject = (obj: unknown): unknown => {
      if (!obj || typeof obj !== "object") return obj;
      if (visited.has(obj)) return obj;
      visited.add(obj);

      if (Array.isArray(obj)) {
        const filtered = obj.filter(item => {
          if (item && typeof item === "object") {
            const r = item as Record<string, unknown>;
            if (r.id === mediaId && (r.title || r.coverImage || r.cover_image)) {
              mutated = true;
              return false;
            }
            const m = r.media as Record<string, unknown> | undefined;
            if (m && m.id === mediaId) {
              mutated = true;
              return false;
            }
          }
          return true;
        });
        return filtered.map(item => removeObject(item));
      }

      const record = obj as Record<string, unknown>;
      if (record.id === mediaId && (record.title || record.coverImage || record.cover_image)) {
        mutated = true;
        return {
          ...record,
          media_list_entry: null,
          mediaListEntry: null,
          user_status: null,
        };
      }

      const newObj: Record<string, unknown> = {};
      for (const [k, v] of Object.entries(record)) {
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
