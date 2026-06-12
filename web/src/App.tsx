import { useEffect, useCallback, useState } from "react";
import { motion, AnimatePresence } from "framer-motion";
import { useAppStore, useSettingsStore } from "@/stores/app";
import { invoke } from "@tauri-apps/api/core";
import { listen } from "@tauri-apps/api/event";
import { getQueryClient } from "@/lib/events";

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
  const setConnectionState = useAppStore((s) => s.setConnectionState);
  const openDetail = useAppStore((s) => s.openDetail);
  const closeDetail = useAppStore((s) => s.closeDetail);

  const [health, setHealth] = useState<any>(null);
  const [onboardingSeen, setOnboardingSeen] = useState(true);

  useEffect(() => {
    if (typeof window !== "undefined") {
      const seen = localStorage.getItem("anicat_onboarding_seen") === "true";
      setOnboardingSeen(seen);
    }
  }, []);

  useKeyboardShortcuts();
  useTheme();

  const checkConnection = useCallback(async () => {
    try {
      const healthData = await invoke<{
        connected: boolean;
        authenticated: boolean;
        offline: boolean;
        data_version: number;
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
      case "settings": return <SettingsView health={health} onUpdateStarted={() => {}} />;
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
        qc.invalidateQueries({ queryKey: ["media-detail", event.payload.media_id], refetchType: "all" });
        qc.invalidateQueries({ queryKey: ["home-watching"], refetchType: "all" });
        qc.invalidateQueries({ queryKey: ["lists"], refetchType: "active" });
      }
    });
    return () => {
      unlisten.then((fn) => fn());
      unlistenProgress.then((fn) => fn());
    };
  }, [setNotification]);

  return (
    <div className="flex h-screen w-screen overflow-hidden bg-background text-foreground relative">
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
      {/* Titlebar drag region for macOS */}
      <div
        data-tauri-drag-region
        className="fixed top-0 left-[72px] lg:left-[248px] right-0 h-10 z-40 pointer-events-none select-none"
      >
        <div
          data-tauri-drag-region
          className="w-full h-full pointer-events-auto cursor-default"
        />
      </div>

      <main className="flex-1 ml-[72px] lg:ml-[248px] flex flex-col overflow-hidden relative">
        <div className="flex-1 overflow-y-auto scroll-container px-6 lg:px-10 pb-8 pt-10">
          <AnimatePresence mode="wait">
            <motion.div
              key={currentView}
              initial={{ opacity: 0, y: 12 }}
              animate={{ opacity: 1, y: 0 }}
              exit={{ opacity: 0, y: -8 }}
              transition={{ duration: 0.22, ease: [0.25, 0.46, 0.45, 0.94] }}
              className="h-full"
            >
              {renderView()}
            </motion.div>
          </AnimatePresence>
        </div>
        <AnimatePresence>
          {selectedItem && <MediaDetail item={selectedItem} initialAction={initialAction || undefined} onClose={closeDetail} />}
        </AnimatePresence>
      </main>

      <AnimatePresence>
        {!onboardingSeen && <Onboarding onComplete={() => setOnboardingSeen(true)} />}
      </AnimatePresence>
    </div>
  );
}
