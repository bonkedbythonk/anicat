import React, { useEffect, useState } from "react";
import { useAppStore } from "@/stores/app";
import { listen } from "@tauri-apps/api/event";
import { Loader2, Play, X, Tv } from "lucide-react";
import { proxyImage } from "@/lib/proxy";

export const StreamLoadingModal: React.FC = () => {
  const { playbackLoading, setPlaybackLoading, playerActive } = useAppStore();
  const { isLoading, episodeNumber, title, coverImage, statusText, step } = playbackLoading;
  const [visible, setVisible] = useState(false);

  // Threshold delay: only display modal if loading takes longer than 800ms (prevents UI flicker on instant streams)
  useEffect(() => {
    if (isLoading) {
      if (step === 0) {
        // Errors show immediately
        setVisible(true);
        return;
      }
      const delayTimer = setTimeout(() => {
        setVisible(true);
      }, 800);
      return () => clearTimeout(delayTimer);
    } else {
      setVisible(false);
    }
  }, [isLoading, step]);

  // Auto-dismiss modal when MPV window becomes active or exits
  useEffect(() => {
    if (isLoading && playerActive) {
      setPlaybackLoading({ isLoading: false });
    }
  }, [playerActive, isLoading, setPlaybackLoading]);

  // Listen to Tauri IPC events: playback_loading_status and anicat_playback_state.
  // Mounted once, independent of `isLoading` — a launch can fail a few
  // seconds *after* the modal already dismissed itself on an optimistic
  // `active:true` (mpv survives the initial grace check, then dies moments
  // later). If these listeners tore down whenever the modal closed, that
  // late `status: "error"` event — the one thing that reopens the modal to
  // tell the user mpv never actually opened — would just be dropped.
  useEffect(() => {
    let unlistenStatus: (() => void) | null = null;
    let unlistenPlayback: (() => void) | null = null;

    const setupListeners = async () => {
      try {
        const u1 = await listen<{
          status: string;
          step?: number;
          message?: string;
          media_id?: number;
          episode_number?: number;
        }>("playback_loading_status", (event) => {
          const { status, step: eventStep, message } = event.payload;

          if (status === "done" || status === "ready") {
            setTimeout(() => {
              setPlaybackLoading({ isLoading: false });
            }, 400);
          } else if (status === "error") {
            setPlaybackLoading({
              isLoading: true,
              statusText: message || "Couldn't load stream.",
              step: 0,
            });
          } else {
            setPlaybackLoading({
              isLoading: true,
              statusText: message || "Loading stream...",
              step: eventStep || 1,
            });
          }
        });
        unlistenStatus = u1;

        const u2 = await listen<{ active: boolean }>("anicat_playback_state", (event) => {
          // Success: dismiss the loading overlay. A `false` here just means
          // mpv exited/closed (including a normal, later user-initiated
          // close) — real launch failures are reported separately via
          // playback_loading_status above, so a bare `false` shouldn't
          // reopen or otherwise touch the modal.
          if (event.payload.active) {
            setPlaybackLoading({ isLoading: false });
          }
        });
        unlistenPlayback = u2;
      } catch (err) {
        // Web preview fallback
      }
    };

    setupListeners();

    return () => {
      if (unlistenStatus) unlistenStatus();
      if (unlistenPlayback) unlistenPlayback();
    };
  }, [setPlaybackLoading]);

  // Safety timeout: if stream resolution hangs for over 30s, show timeout error
  useEffect(() => {
    if (!isLoading || step === 0) return;

    const timeoutTimer = setTimeout(() => {
      setPlaybackLoading({
        isLoading: true,
        statusText: "Couldn't load stream in time. Try another provider or server.",
        step: 0,
      });
    }, 30000);

    return () => clearTimeout(timeoutTimer);
  }, [isLoading, step, setPlaybackLoading]);

  // Keyboard Escape listener to dismiss modal
  useEffect(() => {
    if (!isLoading) return;

    const handleKeyDown = (e: KeyboardEvent) => {
      if (e.key === "Escape") {
        setPlaybackLoading({ isLoading: false });
      }
    };

    window.addEventListener("keydown", handleKeyDown);
    return () => window.removeEventListener("keydown", handleKeyDown);
  }, [isLoading, setPlaybackLoading]);

  if (!isLoading || !visible) return null;

  const handleCancel = () => {
    setPlaybackLoading({ isLoading: false });
  };

  const progressPct = step === 0 ? 100 : step === 1 ? 30 : step === 2 ? 65 : step === 3 ? 90 : 100;
  const isError = step === 0;

  return (
    <div
      className="fixed inset-0 z-[300] bg-black/60 backdrop-blur-sm flex items-center justify-center p-4 animate-fade-in-fast"
      onClick={handleCancel}
      role="dialog"
      aria-modal="true"
    >
      <div
        className="relative w-[min(420px,90vw)] rounded-lg border border-border bg-surface shadow-2xl shadow-black/50 p-6 overflow-hidden"
        onClick={(e) => e.stopPropagation()}
      >
        {/* Close/Cancel button */}
        <button
          onClick={handleCancel}
          className="absolute right-3.5 top-3.5 rounded p-1 text-muted-foreground hover:bg-border/50 hover:text-foreground transition-colors"
          title="Cancel (Esc)"
        >
          <X className="h-4 w-4" />
        </button>

        <div className="flex flex-col items-center text-center">
          {/* Cover image or Poster banner */}
          {coverImage ? (
            <div className="relative mb-4 h-28 w-20 overflow-hidden rounded-md border border-border bg-background shadow-md">
              <img
                src={proxyImage(coverImage)}
                alt={title || "Anime"}
                className="h-full w-full object-cover"
              />
              <div className="absolute inset-0 bg-black/40 flex items-center justify-center">
                <Play className="h-5 w-5 text-accent fill-accent animate-pulse" />
              </div>
            </div>
          ) : (
            <div className="mb-4 flex h-14 w-14 items-center justify-center rounded-md bg-border/40 text-accent border border-border">
              <Tv className="h-6 w-6 animate-pulse" />
            </div>
          )}

          {/* Titles matching Anicat font hierarchy */}
          <h3 className="text-[16px] font-semibold text-foreground line-clamp-1 leading-tight">
            {title || "Starting stream"}
          </h3>
          {episodeNumber && (
            <p className="meta-mono mt-1 text-[11px] text-accent font-medium">
              EP {episodeNumber}
            </p>
          )}

          {/* Progress Bar */}
          <div className="my-4 w-full">
            <div className="h-1.5 w-full overflow-hidden rounded-full bg-border/60">
              <div
                className={`h-full transition-all duration-300 ease-out ${
                  isError ? "bg-danger" : "bg-accent"
                }`}
                style={{ width: `${progressPct}%` }}
              />
            </div>
          </div>

          {/* Status Message & Spinner */}
          <div className="flex items-center gap-2 text-[13px] text-foreground/90 min-h-[22px]">
            {!isError && progressPct < 100 && (
              <Loader2 className="h-3.5 w-3.5 animate-spin text-accent shrink-0" />
            )}
            <span className={isError ? "text-danger-light font-medium" : "text-foreground/80 font-normal"}>
              {statusText || "Preparing stream..."}
            </span>
          </div>

          {/* Helper caption */}
          <p className="meta-mono mt-3 text-[10px] text-muted-foreground/70">
            {isError ? "Click anywhere or press Esc to close" : "Resolving stream and preparing player"}
          </p>
        </div>
      </div>
    </div>
  );
};
