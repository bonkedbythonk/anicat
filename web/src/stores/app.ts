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
  detailStack: MediaItem[];
  initialAction: "play" | null;
  initialPlayEpisode: string | null;
  openDetail: (item: MediaItem, action?: "play" | null, episode?: string | null) => void;
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


  // Sidebar
  sidebarCompact: boolean;
  toggleSidebar: () => void;

  // Settings
  settingsDefaultTab: string | null;
  setSettingsDefaultTab: (tab: string | null) => void;

  // Notifications
  notification: { message: string; type: "info" | "error" } | null;
  setNotification: (n: { message: string; type: "info" | "error" } | null) => void;
}

export const useAppStore = create<AppState>((set) => ({
  currentView: "home",
  // Switching top-level view exits any detail page and drops its back-stack.
  setCurrentView: (currentView) => set({ currentView, selectedItem: null, detailStack: [], initialAction: null, initialPlayEpisode: null }),

  selectedItem: null,
  detailStack: [],
  initialAction: null,
  initialPlayEpisode: null,
  openDetail: (selectedItem, initialAction, initialPlayEpisode) => set((s) => ({
    // Push the current detail item so back returns to it (prequel/sequel hops),
    // not all the way out to the previous view.
    detailStack: s.selectedItem ? [...s.detailStack, s.selectedItem] : s.detailStack,
    selectedItem,
    initialAction: initialAction || null,
    initialPlayEpisode: initialPlayEpisode || null,
  })),
  closeDetail: () => set((s) => {
    if (s.detailStack.length > 0) {
      const prev = s.detailStack[s.detailStack.length - 1];
      return { detailStack: s.detailStack.slice(0, -1), selectedItem: prev, initialAction: null, initialPlayEpisode: null };
    }
    return { selectedItem: null, detailStack: [], initialAction: null, initialPlayEpisode: null };
  }),

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
  setHealthState: (state) =>
    set({
      apiConnected: state.connected,
      apiAuthenticated: state.authenticated,
      isOffline: state.offline,
      authError: state.authError,
      tokenPresent: state.tokenPresent,
    }),


  sidebarCompact: localStorage.getItem("anicat_sidebar_compact") === "true",
  toggleSidebar: () =>
    set((state) => {
      const next = !state.sidebarCompact;
      localStorage.setItem("anicat_sidebar_compact", String(next));
      return { sidebarCompact: next };
    }),

  settingsDefaultTab: null,
  setSettingsDefaultTab: (settingsDefaultTab) => set({ settingsDefaultTab }),

  notification: null,
  setNotification: (notification) => set({ notification }),
}));

// Separate store for playback to avoid re-rendering non-playback components
export const usePlaybackStore = create<PlaybackState>(() => ({
  item: null,
  episode: null,
  provider: "allanime",
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
    provider: "allanime",
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
  translationType: "sub" | "dub";
  shaderProfile: string;
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
  setTranslationType: (v: "sub" | "dub") => void;
  setShaderProfile: (v: string) => void;
  loadFromConfig: (config: Record<string, unknown>) => void;
}

export const useSettingsStore = create<SettingsState>((set) => ({
  playerType: "external",
  defaultProvider: "allanime",
  autoplay: true,
  autoskip: false,
  animePreview: true,
  preferredQuality: "1080p",
  preferredTitleLanguage: "romaji",
  downloadsPath: "",
  anilistToken: null,
  dataSaver: false,
  notifications: true,
  translationType: "sub",
  shaderProfile: "balanced",
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
  setTranslationType: (translationType) => set({ translationType }),
  setShaderProfile: (shaderProfile) => set({ shaderProfile }),
  loadFromConfig: (config) =>
    set({
      playerType:
        ((config as any)?.stream?.player_type as "embedded" | "external") ||
        "embedded",
      defaultProvider:
        ((config as any)?.general?.provider as string) ||
        "allanime",
      autoplay: ((config as any)?.general?.autoplay as boolean) ?? true,
      autoskip: ((config as any)?.general?.autoskip as boolean) ?? false,
      animePreview:
        ((config as any)?.general?.anime_preview as boolean) ?? true,
      preferredQuality:
        ((config as any)?.stream?.preferred_quality as string) || "1080p",
      preferredTitleLanguage:
        ((config as any)?.general?.preferred_title_language as string) ||
        "romaji",
      downloadsPath:
        ((config as any)?.general?.downloads_path as string) || "",
      dataSaver: ((config as any)?.stream?.data_saver as boolean) ?? false,
      notifications:
        ((config as any)?.general?.notifications as boolean) ?? true,
      anilistToken:
        ((config as any)?.api?.anilist_token as string) || null,
      translationType:
        ((config as any)?.stream?.translation_type as "sub" | "dub") || "sub",
      shaderProfile:
        ((config as any)?.stream?.shader_profile as string) || "balanced",
    }),
}));
