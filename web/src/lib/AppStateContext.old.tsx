"use client";

import { createContext, useContext, useState, useCallback, useMemo, type ReactNode } from "react";
import type { MediaItem } from "@/lib/api";

// ---------------------------------------------------------------------------
// Types
// ---------------------------------------------------------------------------

export interface AppState {
  selectedItem: MediaItem | null;
  initialAction: "play" | null;
  playingItem: MediaItem | null;
  playingEpisode: string | null;
  readingItem: MediaItem | null;
  readingChapter: string | null;
  playingProvider: string | null;
  playingServer: string | null;
  playingSubtitleType: string | null;
}

export interface AppOverlayState {
  selectedItem: MediaItem | null;
  initialAction: "play" | null;
}

export interface AppPlaybackState {
  playingItem: MediaItem | null;
  playingEpisode: string | null;
  playingProvider: string | null;
  playingServer: string | null;
  playingSubtitleType: string | null;
}

export interface AppReadingState {
  readingItem: MediaItem | null;
  readingChapter: string | null;
}

export interface AppStateActions {
  selectItem: (item: MediaItem, action?: "play") => void;
  closeDetail: () => void;
  startPlayback: (item: MediaItem, episode: string, provider?: string, server?: string, subtitleType?: string) => void;
  closePlayback: () => void;
  startReading: (item: MediaItem, chapter: string) => void;
  closeReader: () => void;
  setEpisode: (episode: string) => void;
}

// ---------------------------------------------------------------------------
// Contexts — split by concern so consumers only re-render on relevant changes
// ---------------------------------------------------------------------------

const AppStateActionsContext = createContext<AppStateActions | null>(null);

const AppStateOverlayContext = createContext<AppOverlayState | null>(null);
const AppStatePlaybackContext = createContext<AppPlaybackState | null>(null);
const AppStateReadingContext = createContext<AppReadingState | null>(null);

// ---------------------------------------------------------------------------
// Provider
// ---------------------------------------------------------------------------

export function AppStateProvider({ children }: { children: ReactNode }) {
  const [selectedItem, setSelectedItem] = useState<MediaItem | null>(null);
  const [initialAction, setInitialAction] = useState<"play" | null>(null);
  const [playingItem, setPlayingItem] = useState<MediaItem | null>(null);
  const [playingEpisode, setPlayingEpisode] = useState<string | null>(null);
  const [readingItem, setReadingItem] = useState<MediaItem | null>(null);
  const [readingChapter, setReadingChapter] = useState<string | null>(null);
  const [playingProvider, setPlayingProvider] = useState<string | null>(null);
  const [playingServer, setPlayingServer] = useState<string | null>(null);
  const [playingSubtitleType, setPlayingSubtitleType] = useState<string | null>(null);

  const actions = useMemo<AppStateActions>(() => ({
    selectItem: (item, action) => { setSelectedItem(item); setInitialAction(action || null); },
    closeDetail: () => { setSelectedItem(null); setInitialAction(null); },
    startPlayback: (item, episode, provider, server, subtitleType) => {
      setPlayingItem(item); setPlayingEpisode(episode);
      setPlayingProvider(provider || null); setPlayingServer(server || null);
      setPlayingSubtitleType(subtitleType || null);
    },
    closePlayback: () => { setPlayingItem(null); setPlayingEpisode(null); setPlayingProvider(null); setPlayingServer(null); setPlayingSubtitleType(null); },
    startReading: (item, chapter) => { setReadingItem(item); setReadingChapter(chapter); },
    closeReader: () => { setReadingItem(null); setReadingChapter(null); },
    setEpisode: (episode) => setPlayingEpisode(episode),
  }), []);

  const overlay = useMemo<AppOverlayState>(() => ({
    selectedItem, initialAction,
  }), [selectedItem, initialAction]);

  const playback = useMemo<AppPlaybackState>(() => ({
    playingItem, playingEpisode, playingProvider, playingServer, playingSubtitleType,
  }), [playingItem, playingEpisode, playingProvider, playingServer, playingSubtitleType]);

  const reading = useMemo<AppReadingState>(() => ({
    readingItem, readingChapter,
  }), [readingItem, readingChapter]);

  return (
    <AppStateActionsContext.Provider value={actions}>
      <AppStateOverlayContext.Provider value={overlay}>
        <AppStatePlaybackContext.Provider value={playback}>
          <AppStateReadingContext.Provider value={reading}>
            {children}
          </AppStateReadingContext.Provider>
        </AppStatePlaybackContext.Provider>
      </AppStateOverlayContext.Provider>
    </AppStateActionsContext.Provider>
  );
}

// ---------------------------------------------------------------------------
// Consumer hooks
// ---------------------------------------------------------------------------

export function useAppActions(): AppStateActions {
  const ctx = useContext(AppStateActionsContext);
  if (!ctx) throw new Error("useAppActions must be used within an <AppStateProvider>");
  return ctx;
}

export function useAppOverlay(): AppOverlayState {
  const ctx = useContext(AppStateOverlayContext);
  if (!ctx) throw new Error("useAppOverlay must be used within an <AppStateProvider>");
  return ctx;
}

export function useAppPlayback(): AppPlaybackState {
  const ctx = useContext(AppStatePlaybackContext);
  if (!ctx) throw new Error("useAppPlayback must be used within an <AppStateProvider>");
  return ctx;
}

export function useAppReading(): AppReadingState {
  const ctx = useContext(AppStateReadingContext);
  if (!ctx) throw new Error("useAppReading must be used within an <AppStateProvider>");
  return ctx;
}

export function useAppState(): AppState & AppStateActions {
  const overlay = useAppOverlay();
  const playback = useAppPlayback();
  const reading = useAppReading();
  const actions = useAppActions();
  return useMemo(() => ({ ...overlay, ...playback, ...reading, ...actions }),
    [overlay, playback, reading, actions]);
}
