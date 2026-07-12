import { create } from "zustand";
import type { MediaItem, Episode, ViewType } from "@/lib/types";

interface AppConfig {
  general?: {
    provider?: string;
    autoplay?: boolean;
    autoskip?: boolean;
    anime_preview?: boolean;
    preferred_title_language?: string;
    downloads_path?: string;
    notifications?: boolean;
  };
  stream?: {
    data_saver?: boolean;
    shader_profile?: string;
    interpolation?: string;
    translation_type?: string;
  };
  api?: {
    anilist_token?: string | null;
  };
}

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

  // My Lists tab/type — lifted out of ListsView because it unmounts whenever
  // the detail page opens (a sibling branch in App.tsx's AnimatePresence
  // ternary), which would otherwise reset the selected tab back to Watching
  // every time you open an item and come back.
  listsActiveTab: WatchStatus;
  setListsActiveTab: (tab: WatchStatus) => void;
  listsType: "ANIME" | "MANGA";
  setListsType: (type: "ANIME" | "MANGA") => void;

  // Search state — lifted out of SearchView because it unmounts whenever
  // the detail page opens, which resets the search query and filters.
  searchQuery: string;
  setSearchQuery: (query: string) => void;
  searchType: "ANIME" | "MANGA";
  setSearchType: (type: "ANIME" | "MANGA") => void;
  searchFilters: Record<string, any>;
  setSearchFilters: (filters: Record<string, any>) => void;

  // Other preserved view states
  libraryType: "ANIME" | "MANGA";
  setLibraryType: (type: "ANIME" | "MANGA") => void;
  profileFavType: "ANIME" | "MANGA";
  setProfileFavType: (type: "ANIME" | "MANGA") => void;
  scheduleWatchingOnly: boolean;
  setScheduleWatchingOnly: (val: boolean) => void;
  downloadsTab: "library" | "queue";
  setDownloadsTab: (tab: "library" | "queue") => void;
}

export type WatchStatus = "watching" | "completed" | "planning" | "paused" | "dropped" | "repeating";

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

  listsActiveTab: "watching",
  setListsActiveTab: (listsActiveTab) => set({ listsActiveTab }),
  listsType: "ANIME",
  setListsType: (listsType) => set({ listsType }),

  searchQuery: "",
  setSearchQuery: (searchQuery) => set({ searchQuery }),
  searchType: "ANIME",
  setSearchType: (searchType) => set({ searchType }),
  searchFilters: {},
  setSearchFilters: (searchFilters) => set({ searchFilters }),

  libraryType: "ANIME",
  setLibraryType: (libraryType) => set({ libraryType }),
  profileFavType: "ANIME",
  setProfileFavType: (profileFavType) => set({ profileFavType }),
  scheduleWatchingOnly: false,
  setScheduleWatchingOnly: (scheduleWatchingOnly) => set({ scheduleWatchingOnly }),
  downloadsTab: "library",
  setDownloadsTab: (downloadsTab) => set({ downloadsTab }),

  settingsDefaultTab: null,
  setSettingsDefaultTab: (settingsDefaultTab) => set({ settingsDefaultTab }),

  notification: null,
  setNotification: (notification) => set({ notification }),
}));

// Separate store for playback to avoid re-rendering non-playback components
export const usePlaybackStore = create<PlaybackState>(() => ({
  item: null,
  episode: null,
  provider: "mkissa",
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
    provider: "mkissa",
    server: null,
  });
}

interface SettingsState {
  defaultProvider: string;
  autoplay: boolean;
  autoskip: boolean;
  animePreview: boolean;
  preferredTitleLanguage: string;
  downloadsPath: string;
  anilistToken: string | null;
  dataSaver: boolean;
  notifications: boolean;
  translationType: "sub" | "dub";
  shaderProfile: string;
  interpolation: string;
  setDefaultProvider: (p: string) => void;
  setAutoplay: (v: boolean) => void;
  setAutoskip: (v: boolean) => void;
  setAnimePreview: (v: boolean) => void;
  setPreferredTitleLanguage: (l: string) => void;
  setDataSaver: (v: boolean) => void;
  setNotifications: (v: boolean) => void;
  setAnilistToken: (t: string | null) => void;
  setTranslationType: (v: "sub" | "dub") => void;
  setShaderProfile: (v: string) => void;
  setInterpolation: (v: string) => void;
  loadFromConfig: (config: AppConfig) => void;
}

export const useSettingsStore = create<SettingsState>((set) => ({
  defaultProvider: "mkissa",
  autoplay: true,
  autoskip: false,
  animePreview: true,
  preferredTitleLanguage: "romaji",
  downloadsPath: "",
  anilistToken: null,
  dataSaver: false,
  notifications: true,
  translationType: "sub",
  shaderProfile: "balanced",
  interpolation: "off",
  setDefaultProvider: (defaultProvider) => set({ defaultProvider }),
  setAutoplay: (autoplay) => set({ autoplay }),
  setAutoskip: (autoskip) => set({ autoskip }),
  setAnimePreview: (animePreview) => set({ animePreview }),
  setPreferredTitleLanguage: (preferredTitleLanguage) =>
    set({ preferredTitleLanguage }),
  setDataSaver: (dataSaver) => set({ dataSaver }),
  setNotifications: (notifications) => set({ notifications }),
  setAnilistToken: (anilistToken) => set({ anilistToken }),
  setTranslationType: (translationType) => set({ translationType }),
  setShaderProfile: (shaderProfile) => set({ shaderProfile }),
  setInterpolation: (interpolation) => set({ interpolation }),
  loadFromConfig: (config) =>
    set({
      defaultProvider: config?.general?.provider || "mkissa",
      autoplay: config?.general?.autoplay ?? true,
      autoskip: config?.general?.autoskip ?? false,
      animePreview: config?.general?.anime_preview ?? true,
      preferredTitleLanguage: config?.general?.preferred_title_language || "romaji",
      downloadsPath: config?.general?.downloads_path || "",
      dataSaver: config?.stream?.data_saver ?? false,
      notifications: config?.general?.notifications ?? true,
      anilistToken: config?.api?.anilist_token || null,
      translationType: (config?.stream?.translation_type as "sub" | "dub") || "sub",
      shaderProfile: config?.stream?.shader_profile || "balanced",
      interpolation: config?.stream?.interpolation || "off",
    }),
}));
