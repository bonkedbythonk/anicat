import { useEffect, useState, useCallback, useRef, lazy, Suspense } from "react";
import { AnimatePresence, motion } from "framer-motion";
import { useAppStore, useSettingsStore } from "@/stores/app";
import { getConfig, getHealth, mediaApi } from "@/lib/api";
import { getMobileToken, mobileFetch } from "@/lib/transport";

import { ScheduleView } from "@/components/views/ScheduleView";
import { NotificationsView } from "@/components/views/NotificationsView";
import { ProfileView } from "@/components/views/ProfileView";
const MangaView = lazy(() => import("@/components/views/MangaView").then((m) => ({ default: m.MangaView })));

import { PinGate } from "./PinGate";
import { ConnectAniList } from "./ConnectAniList";
import { BottomNav } from "./BottomNav";
import { MobileHeader } from "./MobileHeader";
import { MoreView } from "./MoreView";
import { MobileHomeView } from "./MobileHomeView";
import { MobileSearchView } from "./MobileSearchView";
import { MobileListsView } from "./MobileListsView";
import { MobileMediaDetail } from "./MobileMediaDetail";
import { VideoPlayerOverlay, type VideoPlayerOverlayProps } from "./VideoPlayerOverlay";

async function loadConfig() {
  try {
    const config = await getConfig();
    useSettingsStore.getState().loadFromConfig(config);
  } catch {
    // Config will use defaults
  }
}

type PlayerState = Omit<VideoPlayerOverlayProps, "onClose">;
type Tab = "home" | "search" | "lists" | "more";
type MoreSubView = "schedule" | "manga" | "notifications" | "profile";

const TITLES: Record<Tab, string> = { home: "Anicat", search: "Search", lists: "My Lists", more: "More" };
const SUB_TITLES: Record<MoreSubView, string> = {
  schedule: "Schedule",
  manga: "Manga",
  notifications: "Notifications",
  profile: "Profile",
};

interface Whoami {
  user_id: number;
  display_name: string;
  anilist_connected: boolean;
  anilist_username: string | null;
}

export default function MobileApp() {
  const [unlocked, setUnlocked] = useState(() => !!getMobileToken());
  const [whoami, setWhoami] = useState<Whoami | null>(null);
  const [player, setPlayer] = useState<PlayerState | null>(null);

  // Mobile owns its own navigation state entirely, independent of the
  // shared store's `currentView` (which desktop's Sidebar/App.tsx still use)
  // — the two nav shells are different enough (4-tab + More hub vs desktop's
  // full sidebar) that tying them together would just create edge cases.
  const [activeTab, setActiveTab] = useState<Tab>("home");
  const [moreSubView, setMoreSubView] = useState<MoreSubView | null>(null);

  const selectedItem = useAppStore((s) => s.selectedItem);
  const initialAction = useAppStore((s) => s.initialAction);
  const openDetail = useAppStore((s) => s.openDetail);
  const closeDetail = useAppStore((s) => s.closeDetail);

  // Matches what the shared store's setCurrentView does on desktop when
  // switching sidebar tabs — clears any open detail page/stack so switching
  // tabs never leaves a stale detail view mounted underneath.
  const clearDetail = () => useAppStore.setState({ selectedItem: null, detailStack: [], initialAction: null, initialPlayEpisode: null });

  const goToTab = (tab: Tab) => {
    clearDetail();
    setActiveTab(tab);
    setMoreSubView(null);
  };
  const goToMoreSub = (view: MoreSubView) => {
    clearDetail();
    setActiveTab("more");
    setMoreSubView(view);
  };
  const backToMoreHub = () => setMoreSubView(null);

  useEffect(() => {
    const onUnauthorized = () => setUnlocked(false);
    window.addEventListener("anicat_mobile_unauthorized", onUnauthorized);
    return () => window.removeEventListener("anicat_mobile_unauthorized", onUnauthorized);
  }, []);

  useEffect(() => {
    if (unlocked) loadConfig();
  }, [unlocked]);

  // Gates the ConnectAniList screen below. Refetched on every unlock (a
  // fresh login, or bouncing back after a 401) rather than cached, since
  // whether AniList is connected can change between sessions.
  useEffect(() => {
    if (!unlocked) {
      setWhoami(null);
      return;
    }
    mobileFetch("/mobile-api/session/whoami")
      .then((res) => (res.ok ? res.json() : null))
      .then((data: Whoami | null) => setWhoami(data))
      .catch(() => setWhoami(null));
  }, [unlocked]);

  // Desktop's App.tsx does this same check to drive apiAuthenticated/
  // apiConnected in the store (which HomeView etc. read to decide whether to
  // show "Connect AniList" or real personalized data) — without it, mobile
  // would always look logged-out even when the desktop app already has a
  // saved AniList token, since that's the only thing populating these flags.
  const checkConnection = useCallback(async () => {
    try {
      const health = await getHealth();
      useAppStore.getState().setConnectionState(health.connected, health.authenticated, health.offline);
    } catch {
      useAppStore.getState().setConnectionState(false, false, true);
    }
  }, []);

  useEffect(() => {
    if (!unlocked) return;
    checkConnection();
    const interval = setInterval(checkConnection, 300_000);
    return () => clearInterval(interval);
  }, [unlocked, checkConnection]);

  // The one function in the shared api.ts that launches mpv on desktop —
  // overridden here so every existing call site (MediaDetail, EpisodeList)
  // opens the in-page video overlay instead, unmodified.
  const mobilePlay = useCallback(
    async (
      mediaId: number,
      epNum: number,
      provider?: string,
      _server?: string,
      title?: string,
      episodeTitle?: string,
      coverImage?: string,
      totalEpisodes?: number,
    ) => {
      setPlayer({ mediaId, episodeNumber: epNum, provider, title, episodeTitle, coverImage, totalEpisodes });
    },
    [],
  );

  useEffect(() => {
    if (unlocked) mediaApi.play = mobilePlay;
  }, [unlocked, mobilePlay]);

  // iOS edge-swipe-back: start a touch within ~30px of the left edge, drag
  // right past the threshold, and it closes the open detail page — the
  // single most-used iOS navigation gesture, and the detail view otherwise
  // only closes via its own in-page Back button.
  const touchStartX = useRef<number | null>(null);
  const onTouchStart = (e: React.TouchEvent) => {
    const x = e.touches[0].clientX;
    touchStartX.current = x < 30 ? x : null;
  };
  const onTouchEnd = (e: React.TouchEvent) => {
    if (touchStartX.current === null) return;
    const dx = e.changedTouches[0].clientX - touchStartX.current;
    if (dx > 80) closeDetail();
    touchStartX.current = null;
  };

  if (!unlocked) {
    return <PinGate onSuccess={() => setUnlocked(true)} />;
  }

  if (whoami && !whoami.anilist_connected) {
    return (
      <ConnectAniList
        displayName={whoami.display_name}
        onConnected={() => setWhoami({ ...whoami, anilist_connected: true })}
      />
    );
  }

  const onSelect = openDetail;
  const isMoreTab = activeTab === "more";
  const title = isMoreTab && moreSubView ? SUB_TITLES[moreSubView] : TITLES[activeTab];

  const renderContent = () => {
    if (isMoreTab) {
      if (!moreSubView) return <MoreView onNavigate={goToMoreSub} />;
      switch (moreSubView) {
        case "schedule": return <ScheduleView onSelect={onSelect} />;
        case "manga": return <MangaView onSelect={onSelect} />;
        case "notifications": return <NotificationsView onSelect={onSelect} />;
        case "profile": return <ProfileView onSelect={onSelect} />;
      }
    }
    switch (activeTab) {
      case "home": return <MobileHomeView onSelect={onSelect} />;
      case "search": return <MobileSearchView onSelect={onSelect} />;
      case "lists": return <MobileListsView onSelect={onSelect} />;
      default: return <MobileHomeView onSelect={onSelect} />;
    }
  };

  return (
    <div className="mobile-shell flex h-screen w-screen flex-col overflow-hidden bg-background text-foreground">
      {!selectedItem && (
        <MobileHeader title={title} onBack={isMoreTab && moreSubView ? backToMoreHub : undefined} />
      )}
      <main
        className="flex-1 overflow-y-auto scroll-container px-6 pt-4"
        style={{ paddingBottom: "calc(64px + env(safe-area-inset-bottom))" }}
        onTouchStart={onTouchStart}
        onTouchEnd={onTouchEnd}
      >
        <AnimatePresence mode="wait">
          {selectedItem ? (
            <motion.div
              key={`detail-${selectedItem.id}`}
              initial={{ opacity: 0, y: 18 }}
              animate={{ opacity: 1, y: 0 }}
              exit={{ opacity: 0, y: -10 }}
              transition={{ duration: 0.22 }}
            >
              <MobileMediaDetail item={selectedItem} initialAction={initialAction || undefined} onClose={closeDetail} />
            </motion.div>
          ) : (
            <motion.div
              key={`${activeTab}-${moreSubView ?? ""}`}
              initial={{ opacity: 0, y: 10 }}
              animate={{ opacity: 1, y: 0 }}
              exit={{ opacity: 0, y: -8 }}
              transition={{ duration: 0.18 }}
            >
              <Suspense fallback={null}>{renderContent()}</Suspense>
            </motion.div>
          )}
        </AnimatePresence>
      </main>

      <BottomNav
        activeTab={activeTab === "more" ? null : activeTab}
        moreActive={isMoreTab}
        onTabChange={goToTab}
        onMoreTap={() => goToTab("more")}
      />

      {player && <VideoPlayerOverlay {...player} onClose={() => setPlayer(null)} />}
    </div>
  );
}
