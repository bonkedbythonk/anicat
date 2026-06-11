import { create } from "zustand";
import type { MediaItem, Episode, ViewType } from "@/lib/types";

interface PlaybackState {
  item: MediaItem | null;
  episode: Episode | null;
  provider: string;
  server: string | null;
}

interface AppState {
  // Navigation
  currentView: ViewType;
  setCurrentView: (view: ViewType) => void;

  // Detail drawer
  selectedItem: MediaItem | null;
  openDetail: (item: MediaItem) => void;
  closeDetail: () => void;

  // Overlays
  helpOpen: boolean;
  updatesOpen: boolean;
  setHelpOpen: (open: boolean) => void;
  setUpdatesOpen: (open: boolean) => void;

  // Connection
  apiConnected: boolean;
  apiAuthenticated: boolean;
  isOffline: boolean;
  authError: string | null;
  tokenPresent: boolean;
  setConnectionState: (
    connected: boolean,
    authenticated: boolean,
    offline: boolean,
  ) => void;
  setHealthState: (state: {
    connected: boolean;
    authenticated: boolean;
    offline: boolean;
    authError: string | null;
    tokenPresent: boolean;
  }) => void;

  // Metrics last loaded
  dataVersion: number;
  setDataVersion: (v: number) => void;

  // Settings
  settingsDefaultTab: string | null;
  setSettingsDefaultTab: (tab: string | null) => void;
}

export const useAppStore = create<AppState>((set) => ({
  currentView: "home",
  setCurrentView: (currentView) => set({ currentView }),

  selectedItem: null,
  openDetail: (selectedItem) => set({ selectedItem }),
  closeDetail: () => set({ selectedItem: null }),

  helpOpen: false,
  updatesOpen: false,
  setHelpOpen: (helpOpen) => set({ helpOpen }),
  setUpdatesOpen: (updatesOpen) => set({ updatesOpen }),

  apiConnected: false,
  apiAuthenticated: false,
  isOffline: false,
  authError: null,
  tokenPresent: false,
  setConnectionState: (apiConnected, apiAuthenticated, isOffline) =>
    set({ apiConnected, apiAuthenticated, isOffline }),
  setHealthState: (state) => set(state),

  dataVersion: 0,
  setDataVersion: (dataVersion) => set({ dataVersion }),

  settingsDefaultTab: null,
  setSettingsDefaultTab: (settingsDefaultTab) => set({ settingsDefaultTab }),
}));

// Separate store for playback to avoid re-rendering non-playback components
export const usePlaybackStore = create<PlaybackState>(() => ({
  item: null,
  episode: null,
  provider: "anineko",
  server: null,
}));

export function setPlayback(
  item: MediaItem,
  episode: Episode,
  provider: string,
  server: string | null,
) {
  usePlaybackStore.setState({ item, episode, provider, server });
}

export function clearPlayback() {
  usePlaybackStore.setState({
    item: null,
    episode: null,
    provider: "anineko",
    server: null,
  });
}

interface SettingsState {
  playerType: "embedded" | "external";
  defaultProvider: string;
  autoplay: boolean;
  autoskip: boolean;
  animePreview: boolean;
  preferredQuality: string;
  preferredTitleLanguage: string;
  downloadsPath: string;
  anilistToken: string | null;
  dataSaver: boolean;
  notifications: boolean;
  setPlayerType: (t: "embedded" | "external") => void;
  setDefaultProvider: (p: string) => void;
  setAutoplay: (v: boolean) => void;
  setAutoskip: (v: boolean) => void;
  setAnimePreview: (v: boolean) => void;
  setPreferredQuality: (q: string) => void;
  setPreferredTitleLanguage: (l: string) => void;
  setDataSaver: (v: boolean) => void;
  setNotifications: (v: boolean) => void;
  setAnilistToken: (t: string | null) => void;
  loadFromConfig: (config: Record<string, unknown>) => void;
}

export const useSettingsStore = create<SettingsState>((set) => ({
  playerType: "embedded",
  defaultProvider: "anineko",
  autoplay: true,
  autoskip: true,
  animePreview: true,
  preferredQuality: "1080p",
  preferredTitleLanguage: "romaji",
  downloadsPath: "",
  anilistToken: null,
  dataSaver: false,
  notifications: true,
  setPlayerType: (playerType) => set({ playerType }),
  setDefaultProvider: (defaultProvider) => set({ defaultProvider }),
  setAutoplay: (autoplay) => set({ autoplay }),
  setAutoskip: (autoskip) => set({ autoskip }),
  setAnimePreview: (animePreview) => set({ animePreview }),
  setPreferredQuality: (preferredQuality) => set({ preferredQuality }),
  setPreferredTitleLanguage: (preferredTitleLanguage) =>
    set({ preferredTitleLanguage }),
  setDataSaver: (dataSaver) => set({ dataSaver }),
  setNotifications: (notifications) => set({ notifications }),
  setAnilistToken: (anilistToken) => set({ anilistToken }),
  loadFromConfig: (config) =>
    set({
      playerType: (config.player_type as "embedded" | "external") || "embedded",
      defaultProvider: (config.provider as string) || "anineko",
      autoplay: (config.autoplay as boolean) ?? true,
      autoskip: (config.autoskip as boolean) ?? true,
      animePreview: (config.anime_preview as boolean) ?? true,
      preferredQuality: (config.preferred_quality as string) || "1080p",
      preferredTitleLanguage:
        (config.preferred_title_language as string) || "romaji",
      downloadsPath: (config.downloads_path as string) || "",
      dataSaver: (config.data_saver as boolean) ?? false,
      notifications: (config.notifications as boolean) ?? true,
      anilistToken: (config.anilist_token as string) || null,
    }),
}));
