import { useEffect, useCallback } from "react";
import { motion, AnimatePresence } from "framer-motion";
import { useAppStore } from "@/stores/app";
import { useSettingsStore } from "@/stores/app";
import { invoke } from "@tauri-apps/api/core";

import { Sidebar } from "@/components/layout/Sidebar";
import { AmbientBackground } from "@/components/layout/AmbientBackground";
import { NowPlaying } from "@/components/layout/NowPlaying";
import { HomeView } from "@/components/views/HomeView";
import { SearchView } from "@/components/views/SearchView";
import { ListsView } from "@/components/views/ListsView";
import { ScheduleView } from "@/components/views/ScheduleView";
import { NotificationsView } from "@/components/views/NotificationsView";
import { ProfileView } from "@/components/views/ProfileView";
import { SettingsView } from "@/components/views/SettingsView";
import { DownloadsView } from "@/components/views/DownloadsView";
import { MediaDetail } from "@/components/media/MediaDetail";
import { Toast } from "@/components/shared/Toast";
import { useKeyboardShortcuts } from "@/hooks/useKeyboardShortcuts";
import { useTheme } from "@/hooks/useTheme";

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
  const setConnectionState = useAppStore((s) => s.setConnectionState);
  const openDetail = useAppStore((s) => s.openDetail);
  const closeDetail = useAppStore((s) => s.closeDetail);

  useKeyboardShortcuts();
  useTheme();

  const checkConnection = useCallback(async () => {
    try {
      const health = await invoke<{
        connected: boolean;
        authenticated: boolean;
        offline: boolean;
        data_version: number;
        auth_error: string | null;
        token_present: boolean;
      }>("check_health");
      useAppStore.getState().setHealthState({
        connected: health.connected,
        authenticated: health.authenticated,
        offline: health.offline,
        authError: health.auth_error,
        tokenPresent: health.token_present,
      });
    } catch {
      setConnectionState(false, false, true);
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
      case "search": return <SearchView onSelect={onSelect} />;
      case "lists": return <ListsView onSelect={onSelect} />;
      case "schedule": return <ScheduleView onSelect={onSelect} />;
      case "notifications": return <NotificationsView onSelect={onSelect} />;
      case "profile": return <ProfileView onSelect={onSelect} />;
      case "settings": return <SettingsView health={null} onUpdateStarted={() => {}} />;
      case "downloads": return <DownloadsView />;
      default: return <HomeView onSelect={onSelect} />;
    }
  };

  return (
    <div className="flex h-screen w-screen overflow-hidden bg-background text-foreground">
      <AmbientBackground />
      <Sidebar />
      <main className="flex-1 ml-[72px] lg:ml-[248px] flex flex-col overflow-hidden relative">
        <div className="flex-1 overflow-y-auto scroll-container px-6 lg:px-10 pt-8">
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
          {selectedItem && <MediaDetail item={selectedItem} onClose={closeDetail} />}
        </AnimatePresence>
      </main>
      <NowPlaying />
      <Toast />
    </div>
  );
}
