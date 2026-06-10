import { useEffect, useCallback } from "react";
import { useAppStore } from "@/stores/app";
import { useSettingsStore } from "@/stores/app";
import { invoke } from "@tauri-apps/api/core";

import { Sidebar } from "@/components/layout/Sidebar";
import { AmbientBackground } from "@/components/layout/AmbientBackground";
import { NowPlaying } from "@/components/layout/NowPlaying";
import { HomeView } from "@/components/views/HomeView";
import { SearchView } from "@/components/views/SearchView";
import { LibraryView } from "@/components/views/LibraryView";
import { ListsView } from "@/components/views/ListsView";
import { ScheduleView } from "@/components/views/ScheduleView";
import { NotificationsView } from "@/components/views/NotificationsView";
import { ProfileView } from "@/components/views/ProfileView";
import { SettingsView } from "@/components/views/SettingsView";
import { DownloadsView } from "@/components/views/DownloadsView";
import { MediaDetail } from "@/components/media/MediaDetail";
import { AnimePlayer } from "@/components/media/AnimePlayer";
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
  const { currentView, selectedItem, setConnectionState, openDetail, closeDetail } = useAppStore();

  useKeyboardShortcuts();
  useTheme();

  const checkConnection = useCallback(async () => {
    try {
      const health = await invoke<{
        connected: boolean;
        authenticated: boolean;
        offline: boolean;
        data_version: number;
      }>("check_health");
      setConnectionState(
        health.connected,
        health.authenticated,
        health.offline,
      );
    } catch {
      setConnectionState(false, false, true);
    }
  }, [setConnectionState]);

  useEffect(() => {
    loadConfig();
    checkConnection();
    const interval = setInterval(checkConnection, 30_000);
    return () => clearInterval(interval);
  }, [checkConnection]);

  const renderView = () => {
    const onSelect = openDetail;
    switch (currentView) {
      case "home": return <HomeView onSelect={onSelect} />;
      case "search": return <SearchView onSelect={onSelect} />;
      case "library": return <LibraryView onSelect={onSelect} />;
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
        {renderView()}
        {selectedItem && <MediaDetail item={selectedItem} onClose={closeDetail} />}
        <AnimePlayer />
      </main>
      <NowPlaying />
      <Toast />
    </div>
  );
}
