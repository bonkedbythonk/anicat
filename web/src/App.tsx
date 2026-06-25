import { useEffect, useCallback, useState } from "react";
import { motion, AnimatePresence } from "framer-motion";
import { useAppStore, useSettingsStore } from "@/stores/app";
import { invoke } from "@tauri-apps/api/core";
import { listen } from "@tauri-apps/api/event";
import { getQueryClient, invalidateProgressQueries } from "@/lib/events";
import { initProxyPort } from "@/lib/proxy";
import { usesOverlayTitlebar, isWindows } from "@/lib/platform";

import { Sidebar } from "@/components/layout/Sidebar";
import { AmbientBackground } from "@/components/layout/AmbientBackground";
import { HomeView } from "@/components/views/HomeView";
import { MangaView } from "@/components/views/MangaView";
import { SearchView } from "@/components/views/SearchView";
import { ListsView } from "@/components/views/ListsView";
import { ScheduleView } from "@/components/views/ScheduleView";
import { NotificationsView } from "@/components/views/NotificationsView";
import { ProfileView } from "@/components/views/ProfileView";
import { SettingsView } from "@/components/views/SettingsView";
import { DownloadsView } from "@/components/views/DownloadsView";
import { MediaDetail } from "@/components/media/MediaDetail";
import { useKeyboardShortcuts } from "@/hooks/useKeyboardShortcuts";
import { useTheme } from "@/hooks/useTheme";
import { Onboarding } from "@/components/layout/Onboarding";

async function loadConfig() {
  try {
    const config = await invoke<Record<string, unknown>>("get_config");
    useSettingsStore.getState().loadFromConfig(config);
  } catch {
    // Config will use defaults
  }
}

export default function App() {
  const currentView = useAppStore((s) => s.currentView);
  const selectedItem = useAppStore((s) => s.selectedItem);
  const initialAction = useAppStore((s) => s.initialAction);
  const initialPlayEpisode = useAppStore((s) => s.initialPlayEpisode);
  const setConnectionState = useAppStore((s) => s.setConnectionState);
  const openDetail = useAppStore((s) => s.openDetail);
  const closeDetail = useAppStore((s) => s.closeDetail);
  const sidebarCompact = useAppStore((s) => s.sidebarCompact);

  const sidebarW = sidebarCompact ? 72 : 248;

  const [health, setHealth] = useState<any>(null);
  const [onboardingSeen, setOnboardingSeen] = useState(true);

  // Two-finger swipe left on trackpad = go back from detail page
  useEffect(() => {
    // Registered once. Reading live state from the store (instead of effect
    // deps) keeps the cooldown alive across detail navigations — otherwise a
    // re-subscribe on every selectedItem change would reset it, letting the
    // inertial momentum tail pop the whole prequel/sequel chain at once.
    let accX = 0;
    let accY = 0;
    let cooldownUntil = 0;
    let reset: ReturnType<typeof setTimeout>;

    const onWheel = (e: WheelEvent) => {
      const { selectedItem: cur, closeDetail: close } = useAppStore.getState();
      if (!cur) return;
      const now = Date.now();
      // Ignore the inertial momentum tail after a swipe so one physical gesture
      // pops exactly one level.
      if (now < cooldownUntil) return;
      accX += e.deltaX;
      accY += Math.abs(e.deltaY);
      clearTimeout(reset);
      reset = setTimeout(() => { accX = 0; accY = 0; }, 180);
      // Swipe left (negative deltaX on macOS) with horizontal dominance = back
      if (accX < -60 && Math.abs(accX) > accY * 2) {
        accX = 0;
        accY = 0;
        cooldownUntil = now + 600;
        close();
      }
    };

    window.addEventListener('wheel', onWheel, { passive: true });
    return () => window.removeEventListener('wheel', onWheel);
  }, []);

  // Mouse "back" button and Alt+Left = go back from the detail page (the
  // Windows/Linux conventions; the trackpad swipe above is macOS-only).
  useEffect(() => {
    const back = () => {
      const { selectedItem, closeDetail } = useAppStore.getState();
      if (selectedItem) closeDetail();
    };
    const onMouseUp = (e: MouseEvent) => {
      if (e.button === 3) { e.preventDefault(); back(); }
    };
    const onKeyDown = (e: KeyboardEvent) => {
      if (e.altKey && e.key === 'ArrowLeft') { e.preventDefault(); back(); }
    };
    window.addEventListener('mouseup', onMouseUp);
    window.addEventListener('keydown', onKeyDown);
    return () => {
      window.removeEventListener('mouseup', onMouseUp);
      window.removeEventListener('keydown', onKeyDown);
    };
  }, []);

  useEffect(() => {
    if (typeof window !== "undefined") {
      const seen = localStorage.getItem("anicat_onboarding_seen") === "true";
      setOnboardingSeen(seen);
    }
  }, []);

  useKeyboardShortcuts();
  useTheme();

  useEffect(() => {
    if (isWindows) {
      document.documentElement.setAttribute("data-mica", "");
    }
  }, []);

  const checkConnection = useCallback(async () => {
    try {
      const healthData = await invoke<{
        connected: boolean;
        authenticated: boolean;
        offline: boolean;
        auth_error: string | null;
        token_present: boolean;
        current_version: string;
      }>("check_health");
      setHealth(healthData);
      useAppStore.getState().setHealthState({
        connected: healthData.connected,
        authenticated: healthData.authenticated,
        offline: healthData.offline,
        authError: healthData.auth_error,
        tokenPresent: healthData.token_present,
      });
    } catch {
      setConnectionState(false, false, true);
      setHealth(null);
    }
  }, [setConnectionState]);

  useEffect(() => {
    loadConfig();
    checkConnection();
    initProxyPort();
    const interval = setInterval(checkConnection, 300_000);
    window.addEventListener("anicat_health_recheck", checkConnection);
    return () => {
      clearInterval(interval);
      window.removeEventListener("anicat_health_recheck", checkConnection);
    };
  }, [checkConnection]);

  const renderView = () => {
    const onSelect = openDetail;
    switch (currentView) {
      case "home": return <HomeView onSelect={onSelect} />;
      case "manga": return <MangaView onSelect={onSelect} />;
      case "search": return <SearchView onSelect={onSelect} />;
      case "lists": return <ListsView onSelect={onSelect} />;
      case "schedule": return <ScheduleView onSelect={onSelect} />;
      case "notifications": return <NotificationsView onSelect={onSelect} />;
      case "profile": return <ProfileView onSelect={onSelect} />;
      case "settings": return <SettingsView health={health} />;
      case "downloads": return <DownloadsView />;
      default: return <HomeView onSelect={onSelect} />;
    }
  };

  const notification = useAppStore((s) => s.notification);
  const setNotification = useAppStore((s) => s.setNotification);

  useEffect(() => {
    const unlisten = listen<{ message: string }>("show_notification", (event) => {
      setNotification({ message: event.payload.message, type: "info" });
      setTimeout(() => setNotification(null), 4000);
    });
    const unlistenProgress = listen<{ media_id: number; episode_number: number }>("progress_updated", (event) => {
      const qc = getQueryClient();
      if (qc) {
        // Reconcile every progress-bearing view (home rows, lists, schedule,
        // search, profile, detail drawer) with AniList — not just a few keys.
        invalidateProgressQueries(qc, event.payload.media_id);
      }
    });
    return () => {
      unlisten.then((fn) => fn());
      unlistenProgress.then((fn) => fn());
    };
  }, [setNotification]);

  return (
    <div className={`flex h-screen w-screen overflow-hidden text-foreground relative ${isWindows ? "bg-black/[0.85]" : "bg-background"}`}>
      <AmbientBackground />
      <Sidebar />
      <AnimatePresence>
        {notification && (
          <motion.div
            initial={{ opacity: 0, y: -20, x: "-50%", scale: 0.95 }}
            animate={{ opacity: 1, y: 0, x: "-50%", scale: 1 }}
            exit={{ opacity: 0, y: -20, x: "-50%", scale: 0.95 }}
            transition={{ type: "spring", stiffness: 350, damping: 25 }}
            className="fixed top-4 left-1/2 z-[999] flex items-center gap-3 px-5 py-3 rounded-2xl bg-card border border-border backdrop-blur-xl text-foreground text-sm font-semibold shadow-2xl shadow-black/40"
          >
            <div className="flex h-6 w-6 shrink-0 items-center justify-center rounded-lg bg-accent/15 text-accent">
              <svg
                xmlns="http://www.w3.org/2000/svg"
                width="14"
                height="14"
                viewBox="0 0 24 24"
                fill="none"
                stroke="currentColor"
                strokeWidth="2.5"
                strokeLinecap="round"
                strokeLinejoin="round"
              >
                <path d="M21 15v4a2 2 0 0 1-2 2H5a2 2 0 0 1-2-2v-4" />
                <polyline points="7 10 12 15 17 10" />
                <line x1="12" x2="12" y1="15" y2="3" />
              </svg>
            </div>
            <span className="max-w-xs truncate">{notification.message}</span>
          </motion.div>
        )}
      </AnimatePresence>
      {/* Titlebar drag region — only macOS uses an overlay titlebar; Windows
          and Linux have a native titlebar that already handles dragging. */}
      {usesOverlayTitlebar && (
        <div
          data-tauri-drag-region
          className="fixed top-0 right-0 h-10 z-40 pointer-events-none select-none"
          style={{ left: sidebarW }}
        >
          <div
            data-tauri-drag-region
            className="w-full h-full pointer-events-auto cursor-default"
          />
        </div>
      )}

      <main className="flex-1 flex flex-col overflow-hidden relative" style={{ marginLeft: sidebarW }}>
        <AnimatePresence mode="wait">
          {selectedItem ? (
            <motion.div
              key={`detail-${selectedItem.id}`}
              initial={{ opacity: 0, y: 18 }}
              animate={{ opacity: 1, y: 0 }}
              exit={{ opacity: 0, y: -10 }}
              transition={{ duration: 0.25, ease: [0.25, 0.46, 0.45, 0.94] }}
              className="flex-1 overflow-y-auto scroll-container transform-gpu"
            >
              <MediaDetail item={selectedItem} initialAction={initialAction || undefined} onClose={closeDetail} />
            </motion.div>
          ) : (
            <motion.div
              key={currentView}
              initial={{ opacity: 0, y: 12 }}
              animate={{ opacity: 1, y: 0 }}
              exit={{ opacity: 0, y: -8 }}
              transition={{ duration: 0.22, ease: [0.25, 0.46, 0.45, 0.94] }}
              className="flex-1 overflow-y-auto scroll-container px-6 lg:px-10 pb-8 pt-10"
            >
              {renderView()}
            </motion.div>
          )}
        </AnimatePresence>
      </main>

      <AnimatePresence>
        {!onboardingSeen && <Onboarding onComplete={() => setOnboardingSeen(true)} />}
      </AnimatePresence>
    </div>
  );
}
