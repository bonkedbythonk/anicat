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

async function loadConfig() {
  try {
    const config = await invoke<Record<string, unknown>>("get_config");
    useSettingsStore.getState().loadFromConfig(config);
  } catch {
    // Config will use defaults
  }
}

const VIEWS: Record<string, React.ComponentType> = {
  home: HomeView,
  search: SearchView,
  library: LibraryView,
  lists: ListsView,
  schedule: ScheduleView,
  notifications: NotificationsView,
  profile: ProfileView,
  settings: SettingsView,
  downloads: DownloadsView,
};

export default function App() {
  const { currentView, selectedItem, setConnectionState } = useAppStore();

  useKeyboardShortcuts();

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

  const CurrentView = VIEWS[currentView] || HomeView;

  return (
    <div className="flex h-screen w-screen overflow-hidden bg-[var(--bg-primary)] text-[var(--text-primary)]">
      <AmbientBackground />
      <Sidebar />
      <main className="flex-1 flex flex-col overflow-hidden relative">
        <CurrentView />
        {selectedItem && <MediaDetail item={selectedItem} />}
        <AnimePlayer />
      </main>
      <NowPlaying />
      <Toast />
    </div>
  );
}
