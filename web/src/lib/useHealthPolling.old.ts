"use client";

import { useState, useEffect, useRef, useCallback, useMemo } from "react";
import { useQuery, useQueryClient } from "@tanstack/react-query";
import { mediaApi, type HealthStatus } from "@/lib/api";

import packageJson from "../../package.json";
const FRONTEND_VERSION = packageJson.version;

async function showNativeNotification(title: string, body: string) {
  try {
    const { isPermissionGranted, requestPermission, sendNotification } = await import("@tauri-apps/plugin-notification");
    let permissionGranted = await isPermissionGranted();
    if (!permissionGranted) {
      const permission = await requestPermission();
      permissionGranted = permission === "granted";
    }
    if (permissionGranted) {
      sendNotification({ title, body });
    }
  } catch (err) {
    console.warn("Tauri native notification failed, falling back to Web Notification API:", err);
    if ("Notification" in window) {
      if (Notification.permission === "granted") {
        new Notification(title, { body });
      } else if (Notification.permission !== "denied") {
        Notification.requestPermission().then(permission => {
          if (permission === "granted") {
            new Notification(title, { body });
          }
        });
      }
    }
  }
}

async function requestNotificationPermission() {
  try {
    const { isPermissionGranted, requestPermission } = await import("@tauri-apps/plugin-notification");
    const permissionGranted = await isPermissionGranted();
    if (!permissionGranted) {
      await requestPermission();
    }
  } catch (err) {
    console.warn("Tauri notification permission check failed, trying Web Notification permission:", err);
    if ("Notification" in window && Notification.permission !== "granted" && Notification.permission !== "denied") {
      await Notification.requestPermission();
    }
  }
}

export interface HealthPollingState {
  connectionStatus: "checking" | "connected" | "failed";
  connectionError: string | null;
  healthStatus: HealthStatus | null;
  isOffline: boolean;
  dismissedOffline: boolean;
  notificationCount: number;
  dismissOffline: () => void;
}

export function useHealthPolling(): HealthPollingState {
  const queryClient = useQueryClient();
  const [dismissedOffline, setDismissedOffline] = useState(() => {
    if (typeof window !== "undefined") {
      return sessionStorage.getItem("anicat_offline_dismissed") === "true";
    }
    return false;
  });
  const [hasEverConnected, setHasEverConnected] = useState(false);

  const healthQuery = useQuery({
    queryKey: ["health"],
    queryFn: ({ signal }) => mediaApi.getHealthStatus(signal),
    refetchInterval: 30_000,
    staleTime: 10_000,
    retry: true,
    retryDelay: (attempt) => Math.min(1000 * 2 ** attempt, 10_000),
    structuralSharing: true,
  });

  const { data: healthStatus, error: healthError } = healthQuery;

  // Track first successful connection for state transitions
  useEffect(() => {
    if (healthQuery.isSuccess && !hasEverConnected) {
      setHasEverConnected(true);
    }
  }, [healthQuery.isSuccess, hasEverConnected]);

  const connectionStatus: "checking" | "connected" | "failed" = useMemo(() => {
    if (healthQuery.isSuccess) return "connected";
    if (!hasEverConnected) {
      return healthQuery.failureCount >= 8 ? "failed" : "checking";
    }
    return healthQuery.failureCount >= 6 ? "failed" : "connected";
  }, [healthQuery.isSuccess, healthQuery.failureCount, hasEverConnected]);

  const connectionError: string | null = useMemo(() => {
    if (!healthError) return null;
    const msg = healthError instanceof Error ? healthError.message : String(healthError);
    return msg || "Connection refused (backend sidecar unreachable on port 13370).";
  }, [healthError]);

  // ── Side effects: version mismatch, data_version invalidation, notifications ──

  const lastDataVersionRef = useRef<number | null>(null);
  const lastSeenNotificationIdRef = useRef<number | null>(null);
  const lastNotificationCountRef = useRef<number>(0);
  const versionMismatchWarnedRef = useRef(false);
  const invalidateTimerRef = useRef<ReturnType<typeof setTimeout> | null>(null);

  useEffect(() => {
    requestNotificationPermission();
  }, []);

  useEffect(() => {
    if (!healthStatus) return;

    // Version mismatch detection
    if (
      healthStatus.current_version &&
      healthStatus.current_version !== "unknown" &&
      healthStatus.current_version !== FRONTEND_VERSION &&
      !versionMismatchWarnedRef.current
    ) {
      versionMismatchWarnedRef.current = true;
      console.warn(
        `Version mismatch: frontend ${FRONTEND_VERSION}, backend ${healthStatus.current_version}. ` +
        "The backend may need to be rebuilt or restarted."
      );
    }

    // Data version tracking — invalidate cached queries when backend data changes
    if (healthStatus.data_version !== undefined) {
      if (
        lastDataVersionRef.current !== null &&
        healthStatus.data_version > lastDataVersionRef.current
      ) {
        console.log(
          `Live Sync: Data changed (version ${lastDataVersionRef.current} -> ${healthStatus.data_version}). Refreshing views...`
        );
        if (invalidateTimerRef.current) clearTimeout(invalidateTimerRef.current);
        invalidateTimerRef.current = setTimeout(() => {
          const targetQueryKeys = [
            "lists", "home-watching", "home-recently-watched", "library",
            "playback-status", "media-detail", "media-episodes",
          ];
          for (const key of targetQueryKeys) {
            queryClient.invalidateQueries({ queryKey: [key] });
          }
        }, 500);
      }
      lastDataVersionRef.current = healthStatus.data_version;
    }

    // Notification fetching — fire desktop notifications for new AniList activity
    void (async () => {
      if (!healthStatus.api_authenticated || healthStatus.is_offline) return;
      try {
        const newUnreadCount = healthStatus.unread_notifications || 0;
        if (lastSeenNotificationIdRef.current === null) {
          const notifs = await mediaApi.getNotifications();
          const notificationsList = notifs || [];
          const maxId = notificationsList.reduce((max: number, n: any) => Math.max(max, n.id), 0);
          lastSeenNotificationIdRef.current = maxId;
          lastNotificationCountRef.current = newUnreadCount;
        } else if (newUnreadCount > lastNotificationCountRef.current) {
          const notifs = await mediaApi.getNotifications();
          const notificationsList = notifs || [];
          const newNotifications = notificationsList.filter(
            (n: any) => n.id > lastSeenNotificationIdRef.current!
          );
          for (const notif of newNotifications) {
            const title = "AniCat Release Alert";
            const body = `${notif.contexts?.[0] ?? ""}${notif.episode || ""}${notif.contexts?.[1] ?? ""}${notif.media?.title?.english || notif.media?.title?.romaji || ""}${notif.contexts?.[2] ?? ""}`;
            await showNativeNotification(title, body);
          }
          if (notificationsList.length > 0) {
            const maxId = notificationsList.reduce((max: number, n: any) => Math.max(max, n.id), 0);
            lastSeenNotificationIdRef.current = Math.max(lastSeenNotificationIdRef.current, maxId);
          }
          lastNotificationCountRef.current = newUnreadCount;
        } else {
          lastNotificationCountRef.current = newUnreadCount;
        }
      } catch (err) {
        console.error("Failed to check notifications for desktop alerts:", err);
      }
    })();
  }, [healthStatus, queryClient]);

  // ── Derived values ──

  const isOffline = useMemo(() => {
    if (!healthStatus) return false;
    return healthStatus.api_authenticated && (healthStatus.is_offline || !healthStatus.api_connected);
  }, [healthStatus]);

  const notificationCount = healthStatus?.unread_notifications || 0;

  const dismissOffline = useCallback(() => {
    setDismissedOffline(true);
    sessionStorage.setItem("anicat_offline_dismissed", "true");
  }, []);

  // Auto-clear offline dismissal when reconnected
  useEffect(() => {
    if (!isOffline) setDismissedOffline(false);
  }, [isOffline]);

  // Cleanup invalidateTimer on unmount
  useEffect(() => {
    return () => {
      if (invalidateTimerRef.current) clearTimeout(invalidateTimerRef.current);
    };
  }, []);

  return {
    connectionStatus,
    connectionError,
    healthStatus: healthStatus || null,
    isOffline,
    dismissedOffline,
    notificationCount,
    dismissOffline,
  };
}
