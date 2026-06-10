"use client";

import { useMutation, useQueryClient } from "@tanstack/react-query";
import { mediaApi, type MediaItem } from "@/lib/api";
import { dispatchRefresh } from "@/lib/events";

/**
 * Checks if query data has any MediaItems matching mediaId
 */
function checkHasMedia(data: any, mediaId: number): boolean {
  if (!data) return false;
  if (typeof data === "object" && data !== null && data.id === mediaId) return true;
  if (Array.isArray(data)) {
    return data.some(item => item && item.id === mediaId);
  }
  if (data.pages && Array.isArray(data.pages)) {
    return data.pages.some((page: any) => page && Array.isArray(page.items) && page.items.some((item: any) => item && item.id === mediaId));
  }
  if (data.media && Array.isArray(data.media)) {
    return data.media.some((item: any) => item && item.id === mediaId);
  }
  return false;
}

/**
 * Traverses and updates a cached MediaItem with matching mediaId in-place
 */
function updateMediaItemInPlace(oldData: any, mediaId: number, updateFn: (item: any) => any): any {
  if (!oldData) return oldData;

  // Case 1: Single MediaItem
  if (typeof oldData === "object" && oldData !== null && oldData.id === mediaId) {
    return updateFn(oldData);
  }

  // Case 2: Array of MediaItems
  if (Array.isArray(oldData)) {
    return oldData.map(item => {
      if (item && item.id === mediaId) {
        return updateFn(item);
      }
      return item;
    });
  }

  // Case 3: Infinite query data: { pages: Array<{ items: MediaItem[] }> }
  if (oldData.pages && Array.isArray(oldData.pages)) {
    return {
      ...oldData,
      pages: oldData.pages.map((page: any) => {
        if (page && Array.isArray(page.items)) {
          return {
            ...page,
            items: page.items.map((item: any) => {
              if (item && item.id === mediaId) {
                return updateFn(item);
              }
              return item;
            }),
          };
        }
        return page;
      }),
    };
  }

  // Case 4: Object containing a media list (e.g. { media: MediaItem[] })
  if (oldData.media && Array.isArray(oldData.media)) {
    return {
      ...oldData,
      media: oldData.media.map((item: any) => {
        if (item && item.id === mediaId) {
          return updateFn(item);
        }
        return item;
      }),
    };
  }

  return oldData;
}

/**
 * UX-10: Optimistic progress update mutation.
 *
 * Updates the user's progress instantly in the React Query cache before
 * the API call completes. Rolls back on error to prevent stale UI.
 */
export function useUpdateProgress() {
  const queryClient = useQueryClient();

  return useMutation({
    mutationFn: async ({
      mediaId,
      progress,
      status,
      score,
    }: {
      mediaId: number;
      progress?: number;
      status?: string;
      score?: number;
    }) => {
      return mediaApi.updateStatus(mediaId, status, score, progress);
    },

    onMutate: async ({ mediaId, progress, status, score }) => {
      const queries = queryClient.getQueryCache().getAll();
      const snapshots: Array<{ queryKey: any; data: any }> = [];

      for (const query of queries) {
        const data = query.state.data;
        if (data && checkHasMedia(data, mediaId)) {
          // Cancel active query execution to prevent overwrite
          await queryClient.cancelQueries({ queryKey: query.queryKey });

          // Snapshot previous data for rollback
          snapshots.push({ queryKey: query.queryKey, data });

          // Optimistically update matching media item in cache
          queryClient.setQueryData(query.queryKey, (old: any) => {
            return updateMediaItemInPlace(old, mediaId, (item: any) => {
              const currentStatus = item.user_status || {};
              const nextStatus = {
                ...currentStatus,
                status: status !== undefined ? status : currentStatus.status || "watching",
                progress: progress !== undefined ? progress : currentStatus.progress,
                score: score !== undefined ? score : currentStatus.score,
              };

              return {
                ...item,
                user_status: nextStatus,
              };
            });
          });
        }
      }

      return { snapshots };
    },

    onError: (_err, _variables, context) => {
      // Rollback snapshots
      if (context?.snapshots) {
        for (const snapshot of context.snapshots) {
          queryClient.setQueryData(snapshot.queryKey, snapshot.data);
        }
      }
    },

    onSettled: (_data, _error, { mediaId }) => {
      // Invalidate target details and general affected views
      queryClient.invalidateQueries({ queryKey: ["media-detail", mediaId] });
      dispatchRefresh();
    },
  });
}
