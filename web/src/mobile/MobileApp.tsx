import { useEffect, useState, useCallback, useRef, lazy, Suspense } from "react";
import { AnimatePresence, motion } from "framer-motion";
import { useAppStore, useSettingsStore } from "@/stores/app";
import { getConfig, getHealth, mediaApi } from "@/lib/api";
import { getMobileToken, clearMobileToken, mobileFetch } from "@/lib/transport";
import { applyMobileSettings } from "./mobileSettings";

import { ScheduleView } from "@/components/views/ScheduleView";
import { ProfileView } from "@/components/views/ProfileView";
const MobileMangaView = lazy(() => import("./MobileMangaView").then((m) => ({ default: m.MobileMangaView })));

import { PinGate } from "./PinGate";
import { ConnectAniList } from "./ConnectAniList";
import { BottomNav, type PrimaryTab } from "./BottomNav";
import { useAiringSoon } from "./useAiringSoon";
import { MobileHeader } from "./MobileHeader";
import { YouView } from "./YouView";
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
  // Device-local preference overrides win over server config — the server's
  // config.toml is shared by every user in multi-user mode.
  applyMobileSettings();
}

type PlayerState = Omit<VideoPlayerOverlayProps, "onClose">;
type Tab = PrimaryTab;
type YouSubView = "schedule" | "notifications" | "profile";

const TITLES: Record<Tab, string> = { home: "Up Next", search: "Search", library: "Library", manga: "Manga", you: "You" };
const SUB_TITLES: Record<YouSubView, string> = {
  schedule: "Schedule",
  notifications: "Notifications",
  profile: "Profile",
};

interface Whoami {
  user_id: number;
  display_name: string;
  anilist_connected: boolean;
  anilist_username: string | null;
  server_version?: string;
}

export default function MobileApp() {
  const [unlocked, setUnlocked] = useState(() => !!getMobileToken());
  const [whoami, setWhoami] = useState<Whoami | null>(null);
  const [player, setPlayer] = useState<PlayerState | null>(null);

  // Mobile owns its own navigation state entirely, independent of the
  // shared store's `currentView` (which desktop's Sidebar/App.tsx still use)
  // — the two nav shells are different enough (5-tab bar vs desktop's full
  // sidebar) that tying them together would just create edge cases.
  const [activeTab, setActiveTab] = useState<Tab>("home");
  const [youSubView, setYouSubView] = useState<YouSubView | null>(null);

  const selectedItem = useAppStore((s) => s.selectedItem);
  const initialAction = useAppStore((s) => s.initialAction);
  // The tab bar's something-new dot is decided here, not in BottomNav: the
  // bar stays purely prop-driven, and this reads the same `home-watching`
  // cache entry Home's "Airing soon" shelf does, so the two agree.
  const hasSomethingNew = useAiringSoon().length > 0;
  const openDetail = useAppStore((s) => s.openDetail);
  const closeDetail = useAppStore((s) => s.closeDetail);

  // Matches what the shared store's setCurrentView does on desktop when
  // switching sidebar tabs — clears any open detail page/stack so switching
  // tabs never leaves a stale detail view mounted underneath.
  const clearDetail = () => useAppStore.setState({ selectedItem: null, detailStack: [], initialAction: null, initialPlayEpisode: null });

  const goToTab = (tab: Tab) => {
    clearDetail();
    setActiveTab(tab);
    setYouSubView(null);
  };
  const goToYouSub = (view: YouSubView) => {
    clearDetail();
    setActiveTab("you");
    setYouSubView(view);
  };
  const backToYouHub = () => setYouSubView(null);

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

  // Version handshake: the Pi's server binary and this PWA bundle only stay
  // in sync via a manual deploy-pi.sh run — surface drift instead of letting
  // it show up as mysteriously broken views. (Old servers that don't send
  // server_version yet count as drift too.)
  const serverVersion = whoami ? (whoami.server_version ?? "pre-handshake") : null;
  const versionDrift = serverVersion !== null && serverVersion !== __APP_VERSION__;

  const onSelect = openDetail;
  const isYouTab = activeTab === "you";
  const title = isYouTab && youSubView ? SUB_TITLES[youSubView] : TITLES[activeTab];

  const renderContent = () => {
    if (isYouTab) {
      if (!youSubView) {
        return (
          <YouView
            displayName={whoami?.display_name || "You"}
            anilistUsername={whoami?.anilist_username ?? null}
            onNavigate={goToYouSub}
            onLogout={() => {
              clearMobileToken();
              setUnlocked(false);
            }}
          />
        );
      }
      switch (youSubView) {
        case "schedule": return <ScheduleView onSelect={onSelect} />;
        case "profile": return <ProfileView onSelect={onSelect} />;
      }
    }
    switch (activeTab) {
      case "home": return <MobileHomeView onSelect={onSelect} onSeeAllWatching={() => goToTab("library")} onOpenSchedule={() => goToYouSub("schedule")} />;
      case "search": return <MobileSearchView onSelect={onSelect} />;
      case "library": return <MobileListsView onSelect={onSelect} />;
      case "manga": return <MobileMangaView onSelect={onSelect} />;
      default: return <MobileHomeView onSelect={onSelect} onSeeAllWatching={() => goToTab("library")} onOpenSchedule={() => goToYouSub("schedule")} />;
    }
  };

  return (
    <div className="mobile-shell flex h-screen w-screen flex-col overflow-hidden bg-background text-foreground">
      {versionDrift && (
        <div className="shrink-0 bg-amber-500/15 text-amber-500 text-[11px] font-medium px-4 py-1.5 text-center">
          Server is v{serverVersion}, app is v{__APP_VERSION__} — ask the admin to redeploy.
        </div>
      )}
      {!selectedItem && (
        <MobileHeader title={title} onBack={isYouTab && youSubView ? backToYouHub : undefined} />
      )}
      <main
        className="flex-1 overflow-y-auto scroll-container px-6 pt-4"
        /* The bar is fixed, so this padding is what keeps content clear of it.
           64px was 2px under the bar's real height, clipping the last row. */
        style={{ paddingBottom: "calc(80px + env(safe-area-inset-bottom))" }}
        onTouchStart={onTouchStart}
        onTouchEnd={onTouchEnd}
      >
        {/* Stays "popLayout" — see App.tsx: with mode="wait" a backgrounded
            tab (screen locked, app switched away) freezes the exit animation
            and the next tab never mounts. */}
        <AnimatePresence mode="popLayout">
          {selectedItem ? (
            <motion.div
              key={`detail-${selectedItem.id}`}
              initial={{ opacity: 0, y: 18 }}
              animate={{ opacity: 1, y: 0 }}
              exit={{ opacity: 0, y: -10 }}
              transition={{ duration: 0.22 }}
              className="min-h-full w-full"
            >
              <MobileMediaDetail item={selectedItem} initialAction={initialAction || undefined} onClose={closeDetail} />
            </motion.div>
          ) : (
            <motion.div
              key={`${activeTab}-${youSubView ?? ""}`}
              initial={{ opacity: 0, y: 10 }}
              animate={{ opacity: 1, y: 0 }}
              exit={{ opacity: 0, y: -8 }}
              transition={{ duration: 0.18 }}
              className="h-full w-full"
            >
              <Suspense fallback={null}>{renderContent()}</Suspense>
            </motion.div>
          )}
        </AnimatePresence>
      </main>

      <BottomNav activeTab={activeTab} onTabChange={goToTab} hasSomethingNew={hasSomethingNew} />

      {player && <VideoPlayerOverlay {...player} onClose={() => setPlayer(null)} />}
    </div>
  );
}
