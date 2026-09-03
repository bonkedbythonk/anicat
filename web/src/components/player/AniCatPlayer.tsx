import { useEffect, useRef, useState, useCallback, useMemo } from "react";
import {
  Play,
  Pause,
  RotateCcw,
  RotateCw,
  Volume2,
  VolumeX,
  Volume1,
  Maximize,
  Minimize,
  SkipForward,
  SkipBack,
  List,
  X,
  Loader2,
  AlertCircle,
  HelpCircle,
  ExternalLink,
  Tv,
} from "lucide-react";
import { useQuery } from "@tanstack/react-query";
import Hls from "hls.js";
import { invoke } from "@tauri-apps/api/core";
import { mediaApi, apiOrigin, type Episode } from "@/lib/api";
import { useSettingsStore } from "@/stores/app";
import { dispatchRefresh } from "@/lib/events";

export interface AniCatPlayerProps {
  mediaId: number;
  episodeNumber: number;
  provider?: string;
  server?: string;
  title?: string;
  episodeTitle?: string;
  coverImage?: string;
  totalEpisodes?: number;
  onClose: () => void;
}

interface SkipSegment {
  skip_type: string; // "op" | "ed"
  start: number;
  end: number;
}

const SPEEDS = [0.5, 0.75, 1, 1.25, 1.5, 2];

function fmtTime(sec: number): string {
  if (!isFinite(sec) || sec < 0) sec = 0;
  const m = Math.floor(sec / 60);
  const s = Math.floor(sec % 60);
  const h = Math.floor(m / 60);
  return h > 0
    ? `${h}:${String(m % 60).padStart(2, "0")}:${String(s).padStart(2, "0")}`
    : `${m}:${String(s).padStart(2, "0")}`;
}

function toAbsoluteStreamUrl(url: string | null | undefined): string {
  if (!url) return "";
  if (url.startsWith("http://") || url.startsWith("https://")) return url;
  const origin = apiOrigin();
  return `${origin}${url.startsWith("/") ? "" : "/"}${url}`;
}

export function AniCatPlayer(props: AniCatPlayerProps) {
  const [episodeNumber, setEpisodeNumber] = useState(props.episodeNumber);
  const [streamUrl, setStreamUrl] = useState<string | null>(null);
  const [subtitleUrl, setSubtitleUrl] = useState<string | null>(null);
  const [resumeSeconds, setResumeSeconds] = useState(0);
  const [loading, setLoading] = useState(true);
  const [buffering, setBuffering] = useState(false);
  const [error, setError] = useState<string | null>(null);

  // Playback state
  const [playing, setPlaying] = useState(false);
  const [currentTime, setCurrentTime] = useState(0);
  const [duration, setDuration] = useState(0);
  const [buffered, setBuffered] = useState(0);
  const [speed, setSpeed] = useState(1);
  const [volume, setVolume] = useState(1);
  const [muted, setMuted] = useState(false);
  const [isFullscreen, setIsFullscreen] = useState(false);
  const [chromeVisible, setChromeVisible] = useState(true);
  const [timeRemainingMode, setTimeRemainingMode] = useState(false);

  // Scrubber hover state
  const [hoverTime, setHoverTime] = useState<number | null>(null);
  const [hoverX, setHoverX] = useState<number | null>(null);

  // Skip state
  const [skipSegments, setSkipSegments] = useState<SkipSegment[]>([]);
  const [activeSkip, setActiveSkip] = useState<SkipSegment | null>(null);
  const [outroCountdown, setOutroCountdown] = useState<number | null>(null);
  const [dismissOutro, setDismissOutro] = useState(false);

  // Menus & Drawers
  const [showDrawer, setShowDrawer] = useState(false);
  const [showShortcutsModal, setShowShortcutsModal] = useState(false);

  // Double tap / ripple feedback
  const [seekFeedback, setSeekFeedback] = useState<{ direction: "left" | "right"; time: number } | null>(null);
  const [playPauseFeedback, setPlayPauseFeedback] = useState<"play" | "pause" | null>(null);

  // Refs
  const containerRef = useRef<HTMLDivElement>(null);
  const videoRef = useRef<HTMLVideoElement>(null);
  const scrubberRef = useRef<HTMLDivElement>(null);
  const hlsRef = useRef<Hls | null>(null);
  const hideTimer = useRef<ReturnType<typeof setTimeout> | null>(null);
  const lastProgressReport = useRef(0);
  const currentTimeRef = useRef(0);
  const durationRef = useRef(0);
  // The release's real runtime, from the container header rather than
  // `video.duration` -- see the backend's `MediaLayout::duration_seconds`
  // doc comment. Only set for a remuxed torrent stream; null otherwise
  // (a normal HTTP/CDN stream's `video.duration` is already correct, since
  // nothing is progressively rewriting the file under it).
  const expectedDurationRef = useRef<number | null>(null);
  const hasSeekedResume = useRef(false);
  const wasFullscreenRef = useRef(false);
  const suppressFullscreenWatcher = useRef(false);

  // Settings
  const autoskip = useSettingsStore((s) => s.autoskip);

  // Helper for Rust backend progress reporting
  const callPlayer = useCallback(
    (action: string, pos: number, dur: number) => {
      invoke("report_builtin_player_state", {
        action,
        pos: Math.floor(pos),
        duration: Math.floor(dur),
      }).catch(() => {});
    },
    []
  );

  // Query episodes for the Episode Drawer
  const { data: mediaDetail } = useQuery({
    queryKey: ["media-detail", props.mediaId],
    queryFn: () => mediaApi.getDetails(props.mediaId),
    staleTime: 10 * 60 * 1000,
  });

  const allEpisodes = useMemo(() => {
    const list: Episode[] = [];
    const count = props.totalEpisodes || mediaDetail?.episodes || 24;
    for (let i = 1; i <= count; i++) {
      list.push({
        number: i,
        title: `Episode ${i}`,
      });
    }
    return list;
  }, [props.totalEpisodes, mediaDetail]);

  const currentEpTitle = useMemo(() => {
    return props.episodeTitle ? `${props.episodeTitle}` : `Episode ${episodeNumber}`;
  }, [props.episodeTitle, episodeNumber]);

  // Chrome Auto-Hide Timer
  const bumpChrome = useCallback(() => {
    setChromeVisible(true);
    if (hideTimer.current) clearTimeout(hideTimer.current);
    hideTimer.current = setTimeout(() => {
      if (!showDrawer && !showShortcutsModal && videoRef.current && !videoRef.current.paused) {
        setChromeVisible(false);
      }
    }, 2800);
  }, [showDrawer, showShortcutsModal]);

  // Auto Fullscreen on mount
  useEffect(() => {
    const enterFullscreen = async () => {
      try {
        if (typeof window !== "undefined" && Boolean((window as any).__TAURI_INTERNALS__)) {
          const { getCurrentWindow } = await import("@tauri-apps/api/window");
          const appWindow = getCurrentWindow();
          const isFs = await appWindow.isFullscreen();
          if (!isFs) {
            suppressFullscreenWatcher.current = true;
            await appWindow.setFullscreen(true);
            setIsFullscreen(true);
          }
          wasFullscreenRef.current = true;
          return;
        }
      } catch {}
      const element = containerRef.current as any;
      if (element && !document.fullscreenElement) {
        try {
          if (element.requestFullscreen) await element.requestFullscreen();
          else if (element.webkitRequestFullscreen) element.webkitRequestFullscreen();
          setIsFullscreen(true);
        } catch {}
      }
    };
    enterFullscreen();
  }, []);

  // Stream Resolution
  const resolveStream = useCallback(
    async (epNum: number, excludeList?: string[]) => {
      setLoading(true);
      setError(null);
      setOutroCountdown(null);
      setDismissOutro(false);
      setActiveSkip(null);
      setSkipSegments([]);
      hasSeekedResume.current = false;
      // Reset before the new resolve returns, not after: a stale value from
      // the previous episode must not be read as this one's real duration
      // during the window between the episode switching and the response
      // landing.
      expectedDurationRef.current = null;

      try {
        const data: any = await invoke("resolve_builtin_player_stream", {
          mediaId: props.mediaId,
          episodeNumber: epNum,
          provider: props.provider,
          server: props.server,
          title: props.title,
          coverImage: props.coverImage,
          totalEpisodes: props.totalEpisodes,
          excludeUrls: excludeList,
        });
        setStreamUrl(data.stream_url);
        setSubtitleUrl(data.subtitle_url ?? null);
        setResumeSeconds(data.resume_seconds && data.resume_seconds > 0 ? data.resume_seconds : 0);
        expectedDurationRef.current = typeof data.duration_seconds === "number" && data.duration_seconds > 0
          ? data.duration_seconds
          : null;

        // Fetch AniSkip segments
        try {
          const skipRes = await fetch(
            `https://api.aniskip.com/v2/skip-times/${props.mediaId}/${epNum}?types[]=op&types[]=ed&episodeLength=0`
          );
          if (skipRes.ok) {
            const skipData = await skipRes.json();
            if (skipData.found && Array.isArray(skipData.results)) {
              const segs: SkipSegment[] = skipData.results.map((r: any) => ({
                skip_type: r.skipType,
                start: r.interval.startTime,
                end: r.interval.endTime,
              }));
              setSkipSegments(segs);
            }
          }
        } catch {
          // AniSkip non-critical
        }
      } catch (err: any) {
        console.error("[AniCatPlayer] Resolve error:", err);
        setError(typeof err === "string" ? err : err.message || "Could not load video stream.");
      } finally {
        setLoading(false);
      }
    },
    [props.mediaId, props.provider, props.server, props.title, props.coverImage, props.totalEpisodes]
  );

  useEffect(() => {
    resolveStream(episodeNumber);
  }, [episodeNumber, resolveStream]);

  // Video Element & Hls.js Setup
  useEffect(() => {
    const video = videoRef.current;
    if (!video || !streamUrl) return;

    if (hlsRef.current) {
      hlsRef.current.destroy();
      hlsRef.current = null;
    }

    const fullUrl = toAbsoluteStreamUrl(streamUrl);

    // Determine if HLS stream
    let inner = streamUrl;
    try {
      const parsed = new URL(fullUrl, window.location.origin);
      inner = decodeURIComponent(parsed.searchParams.get("url") || streamUrl);
    } catch {}
    const isHls = inner.includes(".m3u8") || streamUrl.includes("/hls/");

    if (!isHls) {
      video.src = fullUrl;
      video.play().catch(() => {});
    } else if (Hls.isSupported()) {
      const hls = new Hls({
        debug: false,
        startLevel: -1,
      });
      hlsRef.current = hls;
      hls.loadSource(fullUrl);
      hls.attachMedia(video);

      hls.on(Hls.Events.MANIFEST_PARSED, () => {
        video.play().catch(() => {});
      });

      hls.on(Hls.Events.ERROR, (_, data) => {
        if (!data.fatal) return;
        switch (data.type) {
          case Hls.ErrorTypes.NETWORK_ERROR:
            console.warn("[AniCatPlayer] HLS network error, recovering...", data.details);
            hls.startLoad();
            break;
          case Hls.ErrorTypes.MEDIA_ERROR:
            console.warn("[AniCatPlayer] HLS media error, recovering...", data.details);
            hls.recoverMediaError();
            break;
          default:
            console.error("[AniCatPlayer] HLS unrecoverable error:", data.details);
            hls.destroy();
            setError("Playback error. Try reloading or switching servers.");
            break;
        }
      });
    } else if (video.canPlayType("application/vnd.apple.mpegurl")) {
      video.src = fullUrl;
      video.play().catch(() => {});
    } else {
      setError("HLS playback is not supported on this browser.");
    }

    return () => {
      if (hlsRef.current) {
        hlsRef.current.destroy();
        hlsRef.current = null;
      }
      video.removeAttribute("src");
      video.load();
    };
  }, [streamUrl]);

  // Subtitle track enablement
  useEffect(() => {
    const video = videoRef.current;
    if (!video || !subtitleUrl) return;
    const enable = () => {
      for (let i = 0; i < video.textTracks.length; i++) {
        if (video.textTracks[i].kind === "subtitles") {
          video.textTracks[i].mode = "showing";
        }
      }
    };
    enable();
    video.textTracks.addEventListener?.("addtrack", enable);
    return () => video.textTracks.removeEventListener?.("addtrack", enable);
  }, [subtitleUrl, streamUrl]);

  // Handle Video Time Updates, AniSkip, Outro, and Progress Reporting
  const handleTimeUpdate = () => {
    const video = videoRef.current;
    if (!video) return;

    const cur = video.currentTime;
    const dur = video.duration || 0;
    // `dur` (video.duration) is what the seek bar and buffered-% legitimately
    // want: how much of the episode is currently seekable, which for a
    // remux still being written genuinely does grow as more arrives. Every
    // check below that decides "are we near the end" wants the release's
    // real length instead, or that growth reads as repeatedly reaching the
    // end -- reported as "every time it nears the end it adds to the current
    // time" and, before that, as the episode being marked watched minutes
    // early, over and over, each time the known duration jumped.
    const effectiveDur = expectedDurationRef.current || dur;

    currentTimeRef.current = cur;
    durationRef.current = effectiveDur;
    setCurrentTime(cur);
    setDuration(dur);

    // Initial resume seek
    if (!hasSeekedResume.current && resumeSeconds > 0 && dur > 0) {
      hasSeekedResume.current = true;
      video.currentTime = resumeSeconds;
    }

    // Buffer calculation
    if (video.buffered.length > 0) {
      const bufferedEnd = video.buffered.end(video.buffered.length - 1);
      setBuffered(dur > 0 ? (bufferedEnd / dur) * 100 : 0);
    }

    // AniSkip Detection
    const matchingSkip = skipSegments.find((s) => cur >= s.start && cur < s.end);
    if (matchingSkip) {
      if (autoskip) {
        video.currentTime = matchingSkip.end;
      } else {
        setActiveSkip(matchingSkip);
      }
    } else {
      setActiveSkip(null);
    }

    // Outro Detection (near end of episode)
    if (effectiveDur > 60 && effectiveDur - cur <= 25) {
      setOutroCountdown((prev) => (prev === null ? Math.min(Math.max(1, Math.ceil(effectiveDur - cur)), 5) : prev));
    } else {
      setOutroCountdown(null);
    }

    // Periodic Progress Reporting (every 10s)
    if (cur - lastProgressReport.current >= 10 && effectiveDur > 0) {
      lastProgressReport.current = cur;
      callPlayer("progress", cur, effectiveDur);
      if ((cur / effectiveDur) * 100 >= 80) {
        mediaApi.saveMediaListEntry(props.mediaId, { progress: episodeNumber }).catch(() => {});
        dispatchRefresh();
      }
    }
  };

  const handleClose = useCallback(async () => {
    if ((durationRef.current || 0) > 0) {
      callPlayer("stop", currentTimeRef.current, durationRef.current);
    }
    if (typeof window !== "undefined" && Boolean((window as any).__TAURI_INTERNALS__)) {
      try {
        suppressFullscreenWatcher.current = true;
        const { getCurrentWindow } = await import("@tauri-apps/api/window");
        await getCurrentWindow().setFullscreen(false);
      } catch {}
    }
    props.onClose();
  }, [callPlayer, props]);

  const togglePlay = useCallback(() => {
    const video = videoRef.current;
    if (!video) return;

    if (video.paused) {
      video.play().catch(() => {});
      setPlayPauseFeedback("play");
      callPlayer("resume", currentTimeRef.current, durationRef.current);
    } else {
      video.pause();
      setPlayPauseFeedback("pause");
      callPlayer("pause", currentTimeRef.current, durationRef.current);
    }
    setTimeout(() => setPlayPauseFeedback(null), 500);
    bumpChrome();
  }, [callPlayer, bumpChrome]);

  const seekRelative = (sec: number) => {
    const video = videoRef.current;
    if (!video) return;

    const target = Math.max(0, Math.min(video.duration || Infinity, video.currentTime + sec));
    video.currentTime = target;
    setSeekFeedback({ direction: sec < 0 ? "left" : "right", time: Math.abs(sec) });
    setTimeout(() => setSeekFeedback(null), 600);
    bumpChrome();
  };

  const toggleFullscreen = async () => {
    try {
      if (typeof window !== "undefined" && Boolean((window as any).__TAURI_INTERNALS__)) {
        const { getCurrentWindow } = await import("@tauri-apps/api/window");
        const appWindow = getCurrentWindow();
        const current = await appWindow.isFullscreen();
        suppressFullscreenWatcher.current = true;
        await appWindow.setFullscreen(!current);
        setIsFullscreen(!current);
        return;
      }
    } catch (err) {
      console.warn("Native fullscreen toggle failed:", err);
    }

    const element = containerRef.current as any;
    if (!element) return;
    if (!document.fullscreenElement) {
      if (element.requestFullscreen) {
        element.requestFullscreen().catch(() => {});
      } else if (element.webkitRequestFullscreen) {
        element.webkitRequestFullscreen();
      }
      setIsFullscreen(true);
    } else {
      if (document.exitFullscreen) {
        document.exitFullscreen().catch(() => {});
      } else if ((document as any).webkitExitFullscreen) {
        (document as any).webkitExitFullscreen();
      }
      setIsFullscreen(false);
    }
  };

  // Fullscreen watcher on macOS
  useEffect(() => {
    if (typeof window === "undefined" || !Boolean((window as any).__TAURI_INTERNALS__)) return;
    let unlisten: (() => void) | undefined;
    let cancelled = false;
    (async () => {
      const { getCurrentWindow } = await import("@tauri-apps/api/window");
      const appWindow = getCurrentWindow();
      const fn = await appWindow.onResized(async () => {
        const fs = await appWindow.isFullscreen();
        if (suppressFullscreenWatcher.current) {
          suppressFullscreenWatcher.current = false;
          wasFullscreenRef.current = fs;
          return;
        }
        if (!fs && wasFullscreenRef.current) {
          wasFullscreenRef.current = false;
          handleClose();
          return;
        }
        wasFullscreenRef.current = fs;
      });
      if (cancelled) fn();
      else unlisten = fn;
    })();
    return () => {
      cancelled = true;
      unlisten?.();
    };
  }, [handleClose]);

  const handleNextEpisode = () => {
    const maxEp = props.totalEpisodes || mediaDetail?.episodes || 999;
    if (episodeNumber < maxEp) {
      if ((durationRef.current || 0) > 0) {
        callPlayer("stop", currentTimeRef.current, durationRef.current);
      }
      setEpisodeNumber((e) => e + 1);
    }
  };

  const handlePrevEpisode = () => {
    if (episodeNumber > 1) {
      if ((durationRef.current || 0) > 0) {
        callPlayer("stop", currentTimeRef.current, durationRef.current);
      }
      setEpisodeNumber((e) => e - 1);
    }
  };

  const handleOpenInExternalMpv = async () => {
    if ((durationRef.current || 0) > 0) {
      callPlayer("stop", currentTimeRef.current, durationRef.current);
    }
    handleClose();
    try {
      await mediaApi.play(
        props.mediaId,
        episodeNumber,
        props.provider,
        props.server,
        props.title,
        props.episodeTitle,
        props.coverImage,
        props.totalEpisodes,
        false
      );
    } catch (e) {
      console.error("Failed to launch external mpv:", e);
    }
  };

  // Keyboard Shortcuts
  useEffect(() => {
    const handleKeyDown = (e: KeyboardEvent) => {
      if (["input", "textarea"].includes((e.target as HTMLElement)?.tagName?.toLowerCase())) return;

      bumpChrome();

      if (e.key === " " || e.key === "k" || e.key === "K") {
        e.preventDefault();
        togglePlay();
      } else if (e.key === "ArrowLeft") {
        e.preventDefault();
        seekRelative(-5);
      } else if (e.key === "ArrowRight") {
        e.preventDefault();
        seekRelative(5);
      } else if (e.key === "j" || e.key === "J") {
        e.preventDefault();
        seekRelative(-10);
      } else if (e.key === "l" || e.key === "L") {
        e.preventDefault();
        seekRelative(10);
      } else if (e.key === "ArrowUp") {
        e.preventDefault();
        setVolume((v) => {
          const nv = Math.min(1, parseFloat((v + 0.1).toFixed(2)));
          if (videoRef.current) {
            videoRef.current.volume = nv;
            videoRef.current.muted = false;
          }
          setMuted(false);
          return nv;
        });
      } else if (e.key === "ArrowDown") {
        e.preventDefault();
        setVolume((v) => {
          const nv = Math.max(0, parseFloat((v - 0.1).toFixed(2)));
          if (videoRef.current) {
            videoRef.current.volume = nv;
          }
          return nv;
        });
      } else if (e.key === "m" || e.key === "M") {
        e.preventDefault();
        setMuted((m) => {
          const nm = !m;
          if (videoRef.current) {
            videoRef.current.muted = nm;
          }
          return nm;
        });
      } else if (e.key === "f" || e.key === "F") {
        e.preventDefault();
        toggleFullscreen();
      } else if (e.key === "s" || e.key === "S") {
        if (activeSkip && videoRef.current) {
          e.preventDefault();
          videoRef.current.currentTime = activeSkip.end;
          setActiveSkip(null);
        }
      } else if (e.key === "e" || e.key === "E") {
        e.preventDefault();
        setShowDrawer((d) => !d);
      } else if (e.key === "N" && e.shiftKey) {
        e.preventDefault();
        handleNextEpisode();
      } else if (e.key === "P" && e.shiftKey) {
        e.preventDefault();
        handlePrevEpisode();
      } else if (e.key === "?" || (e.shiftKey && e.key === "/")) {
        e.preventDefault();
        setShowShortcutsModal((s) => !s);
      } else if (e.key === "Escape") {
        if (showDrawer) setShowDrawer(false);
        else if (showShortcutsModal) setShowShortcutsModal(false);
        else handleClose();
      }
    };

    window.addEventListener("keydown", handleKeyDown);
    return () => window.removeEventListener("keydown", handleKeyDown);
  }, [bumpChrome, togglePlay, activeSkip, showDrawer, showShortcutsModal, handleClose]);

  return (
    <div
      ref={containerRef}
      onMouseMove={bumpChrome}
      onMouseEnter={bumpChrome}
      onMouseLeave={() => {
        if (!showDrawer && !showShortcutsModal && playing) {
          setChromeVisible(false);
        }
      }}
      className={`fixed inset-0 z-[9999] bg-black select-none overflow-hidden flex items-center justify-center font-sans ${
        chromeVisible ? "cursor-default" : "cursor-none"
      }`}
    >
      {/* HTML5 Video Element */}
      <video
        ref={videoRef}
        className="w-full h-full object-contain cursor-pointer"
        playsInline
        onTimeUpdate={handleTimeUpdate}
        onPlay={() => setPlaying(true)}
        onPause={() => setPlaying(false)}
        onWaiting={() => setBuffering(true)}
        onPlaying={() => setBuffering(false)}
        onCanPlay={() => setBuffering(false)}
        onEnded={handleNextEpisode}
        onError={() => {
          setBuffering(false);
          setError("Failed to play this video stream.");
        }}
      >
        {subtitleUrl && (
          <track
            src={toAbsoluteStreamUrl(subtitleUrl)}
            kind="subtitles"
            srcLang="en"
            label="English"
            default
          />
        )}
      </video>

      {/* Seek Feedback Ripple */}
      {seekFeedback && (
        <div
          className={`absolute top-1/2 -translate-y-1/2 flex items-center justify-center pointer-events-none animate-ping-once z-30 ${
            seekFeedback.direction === "left" ? "left-16" : "right-16"
          }`}
        >
          <div className="flex flex-col items-center justify-center p-5 rounded-full bg-black/75 text-white backdrop-blur-md shadow-2xl">
            {seekFeedback.direction === "left" ? <RotateCcw size={32} /> : <RotateCw size={32} />}
            <span className="font-mono text-sm font-bold mt-1">±{seekFeedback.time}s</span>
          </div>
        </div>
      )}

      {/* Play/Pause Central Feedback Ripple */}
      {playPauseFeedback && (
        <div className="absolute inset-0 flex items-center justify-center pointer-events-none z-30 animate-scale-in">
          <div className="p-6 rounded-full bg-black/60 text-white backdrop-blur-md shadow-2xl">
            {playPauseFeedback === "play" ? (
              <Play size={44} fill="currentColor" />
            ) : (
              <Pause size={44} fill="currentColor" />
            )}
          </div>
        </div>
      )}

      {/* Loading & Buffering Indicator */}
      {(loading || buffering) && !error && (
        <div className="absolute inset-0 flex flex-col items-center justify-center bg-black/40 backdrop-blur-xs z-20 space-y-4 pointer-events-none">
          <Loader2 className="w-12 h-12 text-accent animate-spin" />
          <div className="text-center">
            <p className="font-bold text-white text-base">
              {loading ? "Resolving Stream" : "Buffering..."}
            </p>
            <p className="font-mono text-xs text-white/70">Episode {episodeNumber}</p>
          </div>
        </div>
      )}

      {/* Error Overlay */}
      {error && !loading && (
        <div className="absolute inset-0 flex flex-col items-center justify-center bg-black/85 backdrop-blur-md z-40 p-6 space-y-4 text-center">
          <AlertCircle className="w-14 h-14 text-rose-500" />
          <div className="max-w-md space-y-1">
            <p className="font-bold text-white text-lg">Playback Error</p>
            <p className="text-sm text-rose-200">{error}</p>
          </div>
          <div className="flex items-center gap-3">
            <button
              onClick={() => resolveStream(episodeNumber)}
              className="px-4 py-2 bg-accent text-background font-bold text-xs rounded-xl hover:opacity-90 transition-opacity cursor-pointer shadow-lg"
            >
              Retry
            </button>
            <button
              onClick={handleOpenInExternalMpv}
              className="px-4 py-2 bg-white/10 hover:bg-white/20 text-white font-bold text-xs rounded-xl transition-all cursor-pointer flex items-center gap-1.5 border border-white/10"
            >
              <ExternalLink size={14} />
              Open in External MPV
            </button>
            <button
              onClick={handleClose}
              className="px-4 py-2 bg-white/10 hover:bg-white/20 text-white font-bold text-xs rounded-xl transition-all cursor-pointer border border-white/10"
            >
              Close
            </button>
          </div>
        </div>
      )}

      {/* AniSkip Floating Button */}
      {activeSkip && (
        <div className="absolute bottom-24 right-8 z-40 animate-slide-up">
          <button
            onClick={() => {
              if (videoRef.current) {
                videoRef.current.currentTime = activeSkip.end;
                setActiveSkip(null);
              }
            }}
            className="flex items-center gap-2 px-5 py-2.5 rounded-2xl bg-accent text-background font-bold text-sm shadow-2xl hover:scale-105 active:scale-95 transition-all cursor-pointer border border-white/20"
          >
            <SkipForward size={16} />
            <span>Skip {activeSkip.skip_type.toUpperCase()}</span>
            <span className="font-mono text-xs opacity-75 font-normal ml-1">([S])</span>
          </button>
        </div>
      )}

      {/* Outro Next Episode Countdown */}
      {outroCountdown !== null && !dismissOutro && (
        <div className="absolute bottom-24 left-8 z-40 animate-slide-up">
          <div className="flex items-center gap-3 p-3 rounded-2xl bg-neutral-950/90 border border-white/15 backdrop-blur-md shadow-2xl">
            <div className="space-y-0.5">
              <p className="text-xs text-white/70">Next episode in</p>
              <p className="font-mono font-bold text-sm text-accent">{outroCountdown}s</p>
            </div>
            <button
              onClick={handleNextEpisode}
              className="px-3 py-1.5 rounded-xl bg-accent text-background font-bold text-xs hover:opacity-90 transition-opacity cursor-pointer"
            >
              Play Now
            </button>
            <button
              onClick={() => setDismissOutro(true)}
              className="p-1.5 rounded-xl text-white/60 hover:text-white hover:bg-white/10 transition-colors cursor-pointer"
            >
              <X size={14} />
            </button>
          </div>
        </div>
      )}

      {/* Backdrop Click-to-Play/Pause Hit Target */}
      <div
        className="absolute inset-0 z-10"
        onClick={togglePlay}
        onDoubleClick={toggleFullscreen}
      />

      {/* Top Header Chrome */}
      <div
        className={`absolute top-0 inset-x-0 z-30 p-4 sm:p-6 bg-gradient-to-b from-black/90 via-black/40 to-transparent flex items-center justify-between gap-4 transition-all duration-300 ${
          chromeVisible ? "opacity-100 translate-y-0" : "opacity-0 -translate-y-4 pointer-events-none"
        }`}
      >
        <div className="flex items-center gap-3 min-w-0">
          <button
            onClick={handleClose}
            className="p-2 rounded-xl bg-white/10 hover:bg-white/20 text-white backdrop-blur-md transition-all cursor-pointer"
            title="Exit Player (Esc)"
          >
            <X size={18} />
          </button>
          <div className="min-w-0">
            <h2 className="text-sm sm:text-base font-bold text-white truncate">
              {props.title || "AniCat Player"}
            </h2>
            <p className="font-mono text-[11px] text-white/60 truncate">
              {currentEpTitle}
            </p>
          </div>
        </div>

        <div className="flex items-center gap-2">
          {/* Open in External MPV */}
          <button
            onClick={handleOpenInExternalMpv}
            className="flex items-center gap-1.5 px-3 py-1.5 rounded-xl bg-white/10 hover:bg-white/20 text-white backdrop-blur-md border border-white/10 text-xs font-semibold transition-all cursor-pointer"
            title="Pop out to External MPV Player (with Anime4K Upscaling)"
          >
            <Tv size={13} />
            <span className="hidden sm:inline font-mono">External MPV</span>
          </button>

          {/* Episode Drawer Button */}
          <button
            onClick={() => setShowDrawer(true)}
            className="flex items-center gap-1.5 px-3 py-1.5 rounded-xl bg-white/10 hover:bg-white/20 text-white backdrop-blur-md border border-white/10 text-xs font-semibold transition-all cursor-pointer"
            title="Episodes List (E)"
          >
            <List size={14} />
            <span className="hidden sm:inline font-mono">Episodes</span>
          </button>

          {/* Shortcuts Help */}
          <button
            onClick={() => setShowShortcutsModal(true)}
            className="p-2 rounded-xl bg-white/10 hover:bg-white/20 text-white backdrop-blur-md transition-all cursor-pointer"
            title="Keyboard Shortcuts (?)"
          >
            <HelpCircle size={16} />
          </button>
        </div>
      </div>

      {/* Bottom Controls Chrome */}
      <div
        className={`absolute bottom-0 inset-x-0 z-30 p-4 sm:p-6 bg-gradient-to-t from-black/95 via-black/60 to-transparent space-y-3 transition-all duration-300 ${
          chromeVisible ? "opacity-100 translate-y-0" : "opacity-0 translate-y-4 pointer-events-none"
        }`}
      >
        {/* Timeline Scrubber */}
        <div
          ref={scrubberRef}
          onMouseMove={(e) => {
            const rect = scrubberRef.current?.getBoundingClientRect();
            if (!rect || duration <= 0) return;
            const pct = Math.max(0, Math.min(1, (e.clientX - rect.left) / rect.width));
            setHoverTime(pct * duration);
            setHoverX(e.clientX - rect.left);
          }}
          onMouseLeave={() => {
            setHoverTime(null);
            setHoverX(null);
          }}
          onClick={(e) => {
            const rect = scrubberRef.current?.getBoundingClientRect();
            if (!rect || duration <= 0 || !videoRef.current) return;
            const pct = Math.max(0, Math.min(1, (e.clientX - rect.left) / rect.width));
            const target = pct * duration;
            videoRef.current.currentTime = target;
            setCurrentTime(target);
          }}
          className="relative h-2 hover:h-3.5 bg-white/15 rounded-full cursor-pointer transition-all group flex items-center"
        >
          {/* Hover Time Tooltip */}
          {hoverTime !== null && hoverX !== null && (
            <div
              className="absolute -top-7 -translate-x-1/2 bg-black/85 text-white font-mono text-[11px] font-bold px-2 py-0.5 rounded-md border border-white/20 pointer-events-none shadow-lg"
              style={{ left: `${hoverX}px` }}
            >
              {fmtTime(hoverTime)}
            </div>
          )}

          {/* Buffered Progress */}
          <div
            className="absolute left-0 top-0 bottom-0 bg-white/25 rounded-full pointer-events-none transition-all"
            style={{ width: `${buffered}%` }}
          />

          {/* Played Progress */}
          <div
            className="absolute left-0 top-0 bottom-0 bg-accent rounded-full pointer-events-none shadow-sm shadow-accent/50"
            style={{ width: `${duration > 0 ? (currentTime / duration) * 100 : 0}%` }}
          />

          {/* AniSkip Segment Markers on Scrubber */}
          {skipSegments.map((seg, idx) => {
            if (duration <= 0) return null;
            const leftPct = (seg.start / duration) * 100;
            const widthPct = ((seg.end - seg.start) / duration) * 100;
            return (
              <div
                key={idx}
                className="absolute top-0 bottom-0 bg-amber-400/50 rounded-xs pointer-events-none border-x border-amber-300"
                style={{ left: `${leftPct}%`, width: `${widthPct}%` }}
                title={`${seg.skip_type.toUpperCase()} Segment`}
              />
            );
          })}

          {/* Scrubber Thumb Dot */}
          <div
            className="absolute top-1/2 -translate-y-1/2 -translate-x-1/2 w-3.5 h-3.5 rounded-full bg-white shadow-md border-2 border-accent transition-transform pointer-events-none group-hover:scale-125"
            style={{
              left: `${duration > 0 ? (currentTime / duration) * 100 : 0}%`,
            }}
          />
        </div>

        {/* Action Controls Toolbar */}
        <div className="flex items-center justify-between flex-wrap gap-2 text-white">
          {/* Left: Play / Next / Vol / Time */}
          <div className="flex items-center gap-3">
            <button
              onClick={togglePlay}
              className="p-2 rounded-xl hover:bg-white/15 text-white transition-colors cursor-pointer"
              title="Play/Pause (Space)"
            >
              {playing ? <Pause size={20} fill="currentColor" /> : <Play size={20} fill="currentColor" />}
            </button>

            <button
              onClick={handlePrevEpisode}
              disabled={episodeNumber <= 1}
              className="p-1.5 rounded-lg hover:bg-white/15 disabled:opacity-30 text-white transition-colors cursor-pointer"
              title="Previous Episode (Shift+P)"
            >
              <SkipBack size={17} />
            </button>

            <button
              onClick={handleNextEpisode}
              className="p-1.5 rounded-lg hover:bg-white/15 text-white transition-colors cursor-pointer"
              title="Next Episode (Shift+N)"
            >
              <SkipForward size={17} />
            </button>

            {/* Volume Control */}
            <div className="flex items-center gap-1.5 group/vol">
              <button
                onClick={() => {
                  setMuted((m) => {
                    const nm = !m;
                    if (videoRef.current) {
                      videoRef.current.muted = nm;
                    }
                    return nm;
                  });
                }}
                className="p-1.5 rounded-lg hover:bg-white/15 text-white transition-colors cursor-pointer"
                title="Mute/Unmute (M)"
              >
                {muted || volume === 0 ? (
                  <VolumeX size={18} />
                ) : volume < 0.5 ? (
                  <Volume1 size={18} />
                ) : (
                  <Volume2 size={18} />
                )}
              </button>

              <input
                type="range"
                min="0"
                max="1"
                step="0.05"
                value={muted ? 0 : volume}
                onChange={(e) => {
                  const v = parseFloat(e.target.value);
                  setVolume(v);
                  setMuted(false);
                  if (videoRef.current) {
                    videoRef.current.volume = v;
                    videoRef.current.muted = false;
                  }
                }}
                className="w-16 sm:w-20 accent-accent h-1.5 rounded-lg bg-white/20 cursor-pointer"
              />
            </div>

            {/* Time Readout */}
            <button
              onClick={() => setTimeRemainingMode((m) => !m)}
              className="font-mono text-xs text-white/80 hover:text-white cursor-pointer select-none"
              title="Click to toggle remaining time"
            >
              <span>{fmtTime(currentTime)}</span>
              <span className="text-white/40 mx-1">/</span>
              <span>
                {timeRemainingMode
                  ? `-${fmtTime(Math.max(0, duration - currentTime))}`
                  : fmtTime(duration)}
              </span>
            </button>
          </div>

          {/* Right: Speed, Fullscreen */}
          <div className="flex items-center gap-2">
            {/* Speed Selector */}
            <select
              value={speed}
              onChange={(e) => {
                const s = parseFloat(e.target.value);
                setSpeed(s);
                if (videoRef.current) {
                  videoRef.current.playbackRate = s;
                }
              }}
              className="bg-white/10 hover:bg-white/20 border border-white/10 rounded-lg px-2 py-1 text-xs font-mono font-bold text-white outline-none cursor-pointer appearance-none"
            >
              {SPEEDS.map((s) => (
                <option key={s} value={s} className="bg-neutral-900 text-white">
                  {s}x
                </option>
              ))}
            </select>

            {/* Fullscreen */}
            <button
              onClick={toggleFullscreen}
              className="p-1.5 rounded-lg hover:bg-white/15 text-white transition-colors cursor-pointer"
              title="Fullscreen (F)"
            >
              {isFullscreen ? <Minimize size={18} /> : <Maximize size={18} />}
            </button>
          </div>
        </div>
      </div>

      {/* Episode Drawer */}
      {showDrawer && (
        <div
          className="fixed inset-0 z-50 bg-black/60 backdrop-blur-xs flex justify-end animate-fade-in"
          onClick={() => setShowDrawer(false)}
        >
          <div
            className="w-full max-w-sm h-full bg-surface border-l border-border shadow-2xl flex flex-col overflow-hidden animate-slide-left"
            onClick={(e) => e.stopPropagation()}
          >
            <div className="p-4 border-b border-border flex items-center justify-between bg-foreground/[0.02]">
              <div className="flex items-center gap-2">
                <List size={16} className="text-accent" />
                <h3 className="text-sm font-bold text-foreground">Episodes</h3>
              </div>
              <button
                onClick={() => setShowDrawer(false)}
                className="p-1 rounded-lg text-muted-foreground hover:text-foreground hover:bg-foreground/10 transition-colors cursor-pointer"
              >
                <X size={18} />
              </button>
            </div>

            <div className="flex-1 overflow-y-auto p-3 space-y-1.5">
              {allEpisodes.map((ep) => {
                const isCur = ep.number === episodeNumber;
                return (
                  <button
                    key={ep.number}
                    onClick={() => {
                      if (ep.number !== episodeNumber) {
                        if ((durationRef.current || 0) > 0) {
                          callPlayer("stop", currentTimeRef.current, durationRef.current);
                        }
                        setEpisodeNumber(typeof ep.number === "number" ? ep.number : parseInt(ep.number, 10));
                      }
                      setShowDrawer(false);
                    }}
                    className={`w-full flex items-center gap-3 p-2.5 rounded-xl border text-left transition-all cursor-pointer ${
                      isCur
                        ? "bg-accent/15 border-accent text-accent font-bold"
                        : "bg-foreground/[0.02] border-border/60 hover:bg-foreground/[0.05] text-foreground"
                    }`}
                  >
                    <span
                      className={`w-7 h-7 rounded-lg font-mono text-xs flex items-center justify-center font-bold shrink-0 ${
                        isCur ? "bg-accent text-background" : "bg-foreground/10 text-muted-foreground"
                      }`}
                    >
                      {ep.number}
                    </span>
                    <span className="text-xs truncate flex-1 font-medium">
                      {ep.title || `Episode ${ep.number}`}
                    </span>
                    {isCur && (
                      <span className="font-mono text-[10px] uppercase font-bold tracking-wider">
                        Playing
                      </span>
                    )}
                  </button>
                );
              })}
            </div>
          </div>
        </div>
      )}

      {/* Keyboard Shortcuts Cheat Sheet Modal */}
      {showShortcutsModal && (
        <div
          className="fixed inset-0 z-50 bg-black/80 backdrop-blur-md flex items-center justify-center p-4 animate-fade-in"
          onClick={() => setShowShortcutsModal(false)}
        >
          <div
            className="w-full max-w-lg bg-surface rounded-2xl border border-border shadow-2xl p-6 space-y-4 animate-scale-in"
            onClick={(e) => e.stopPropagation()}
          >
            <div className="flex items-center justify-between border-b border-border pb-3">
              <div className="flex items-center gap-2">
                <HelpCircle size={18} className="text-accent" />
                <h3 className="text-sm font-bold text-foreground">Player Keyboard Shortcuts</h3>
              </div>
              <button
                onClick={() => setShowShortcutsModal(false)}
                className="p-1 rounded-lg text-muted-foreground hover:text-foreground cursor-pointer"
              >
                <X size={16} />
              </button>
            </div>

            <div className="grid grid-cols-2 gap-2 text-xs font-mono">
              <div className="flex justify-between p-2 rounded-lg bg-foreground/[0.03]">
                <span className="text-muted-foreground">Play / Pause</span>
                <kbd className="px-1.5 py-0.5 bg-foreground/10 rounded">Space / K</kbd>
              </div>
              <div className="flex justify-between p-2 rounded-lg bg-foreground/[0.03]">
                <span className="text-muted-foreground">Seek ±10s</span>
                <kbd className="px-1.5 py-0.5 bg-foreground/10 rounded">J / L</kbd>
              </div>
              <div className="flex justify-between p-2 rounded-lg bg-foreground/[0.03]">
                <span className="text-muted-foreground">Seek ±5s</span>
                <kbd className="px-1.5 py-0.5 bg-foreground/10 rounded">← / →</kbd>
              </div>
              <div className="flex justify-between p-2 rounded-lg bg-foreground/[0.03]">
                <span className="text-muted-foreground">Volume ±10%</span>
                <kbd className="px-1.5 py-0.5 bg-foreground/10 rounded">↑ / ↓</kbd>
              </div>
              <div className="flex justify-between p-2 rounded-lg bg-foreground/[0.03]">
                <span className="text-muted-foreground">Mute / Unmute</span>
                <kbd className="px-1.5 py-0.5 bg-foreground/10 rounded">M</kbd>
              </div>
              <div className="flex justify-between p-2 rounded-lg bg-foreground/[0.03]">
                <span className="text-muted-foreground">Fullscreen</span>
                <kbd className="px-1.5 py-0.5 bg-foreground/10 rounded">F</kbd>
              </div>
              <div className="flex justify-between p-2 rounded-lg bg-foreground/[0.03]">
                <span className="text-muted-foreground">Skip OP / ED</span>
                <kbd className="px-1.5 py-0.5 bg-foreground/10 rounded">S</kbd>
              </div>
              <div className="flex justify-between p-2 rounded-lg bg-foreground/[0.03]">
                <span className="text-muted-foreground">Episode Drawer</span>
                <kbd className="px-1.5 py-0.5 bg-foreground/10 rounded">E</kbd>
              </div>
              <div className="flex justify-between p-2 rounded-lg bg-foreground/[0.03]">
                <span className="text-muted-foreground">Next Episode</span>
                <kbd className="px-1.5 py-0.5 bg-foreground/10 rounded">Shift + N</kbd>
              </div>
              <div className="flex justify-between p-2 rounded-lg bg-foreground/[0.03]">
                <span className="text-muted-foreground">Prev Episode</span>
                <kbd className="px-1.5 py-0.5 bg-foreground/10 rounded">Shift + P</kbd>
              </div>
              <div className="flex justify-between p-2 rounded-lg bg-foreground/[0.03]">
                <span className="text-muted-foreground">Close / Exit</span>
                <kbd className="px-1.5 py-0.5 bg-foreground/10 rounded">Esc</kbd>
              </div>
            </div>
          </div>
        </div>
      )}
    </div>
  );
}
