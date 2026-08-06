import { useEffect, useRef, useState, useCallback } from "react";
import { X, Loader2, AlertCircle, Play, Pause, RotateCcw, RotateCw, Maximize, SkipForward } from "lucide-react";
import { mobileFetch } from "@/lib/transport";
import { useSettingsStore } from "@/stores/app";
import Hls from "hls.js";

export interface VideoPlayerOverlayProps {
  mediaId: number;
  episodeNumber: number;
  provider?: string;
  title?: string;
  episodeTitle?: string;
  coverImage?: string;
  totalEpisodes?: number;
  onClose: () => void;
}

/** Mobile has no mpv — this plays episodes with a plain <video> tag driven
 * by fully custom controls (native `controls` is off): gradient chrome,
 * center play/±10s cluster, a scrubber with buffered-range fill, speed
 * cycling, and Next Episode — the Crunchyroll/YouTube gesture vocabulary
 * (tap to toggle chrome, double-tap edges to seek 10s).
 *
 * Soft-sub servers carry an external WebVTT sidecar rather than burned-in
 * captions; the backend proxies it and hands the URL back on resolve, and it
 * is attached here as a <track>. Hard-sub servers have no sidecar (captions
 * are in the video) and correctly get none.
 *
 * Progress reporting reuses the same /player/* endpoints the desktop mpv Lua
 * script calls — but next/prev episode advancement does NOT go through
 * /player/next or /player/prev, since those launch mpv on the desktop
 * machine. Instead this resolves the next/previous episode directly via
 * /mobile-api/playback/resolve and swaps the <video> source itself. */
// MediaError.code numeric values don't come with names on the object itself.
const MEDIA_ERROR_NAMES: Record<number, string> = {
  1: "MEDIA_ERR_ABORTED",
  2: "MEDIA_ERR_NETWORK",
  3: "MEDIA_ERR_DECODE",
  4: "MEDIA_ERR_SRC_NOT_SUPPORTED",
};

interface SkipSegment {
  skip_type: string; // "op" | "ed"
  start: number;
  end: number;
}

// iOS Safari's video fullscreen is a non-standard API predating the
// Fullscreen spec — not in lib.dom.d.ts.
interface IOSVideoElement extends HTMLVideoElement {
  webkitEnterFullscreen?: () => void;
  webkitExitFullscreen?: () => void;
  webkitDisplayingFullscreen?: boolean;
}

const SPEEDS = [1, 1.25, 1.5, 2];

function fmtTime(sec: number): string {
  if (!isFinite(sec) || sec < 0) sec = 0;
  const m = Math.floor(sec / 60);
  const s = Math.floor(sec % 60);
  const h = Math.floor(m / 60);
  return h > 0 ? `${h}:${String(m % 60).padStart(2, "0")}:${String(s).padStart(2, "0")}` : `${m}:${String(s).padStart(2, "0")}`;
}

export function VideoPlayerOverlay(props: VideoPlayerOverlayProps) {
  const [episodeNumber, setEpisodeNumber] = useState(props.episodeNumber);
  const [streamUrl, setStreamUrl] = useState<string | null>(null);
  const [subtitleUrl, setSubtitleUrl] = useState<string | null>(null);
  const [resumeSeconds, setResumeSeconds] = useState(0);
  const [loading, setLoading] = useState(true);
  const [error, setError] = useState<string | null>(null);
  const [errorDetail, setErrorDetail] = useState<string | null>(null);
  const [stalled, setStalled] = useState(false);
  const [skipSegments, setSkipSegments] = useState<SkipSegment[]>([]);
  const [activeSkip, setActiveSkip] = useState<SkipSegment | null>(null);
  const [playing, setPlaying] = useState(false);
  const [currentTime, setCurrentTime] = useState(0);
  const [duration, setDuration] = useState(0);
  const [buffered, setBuffered] = useState(0);
  const [speed, setSpeed] = useState(1);
  const [chromeVisible, setChromeVisible] = useState(true);
  const [scrubbing, setScrubbing] = useState(false);
  const videoRef = useRef<HTMLVideoElement>(null);
  const trackRef = useRef<HTMLDivElement>(null);
  const hideTimer = useRef<ReturnType<typeof setTimeout> | null>(null);
  const lastTap = useRef<{ t: number; zone: "left" | "mid" | "right" } | null>(null);
  const tapTimer = useRef<ReturnType<typeof setTimeout> | null>(null);
  const lastProgressReport = useRef(0);
  const autoplay = useSettingsStore((s) => s.autoplay);
  const autoskip = useSettingsStore((s) => s.autoskip);

  const resolve = useCallback(async (epNum: number) => {
    setLoading(true);
    setError(null);
    setErrorDetail(null);
    setStalled(false);
    setStreamUrl(null);
    setSubtitleUrl(null);
    setSkipSegments([]);
    setActiveSkip(null);
    setCurrentTime(0);
    setDuration(0);
    setBuffered(0);
    try {
      const res = await mobileFetch("/mobile-api/playback/resolve", {
        method: "POST",
        headers: { "Content-Type": "application/json" },
        body: JSON.stringify({
          media_id: props.mediaId,
          episode_number: epNum,
          provider: props.provider,
          title: props.title,
          episode_title: props.episodeTitle,
          cover_image: props.coverImage,
          total_episodes: props.totalEpisodes,
        }),
      });
      if (!res.ok) throw new Error(await res.text().catch(() => "Failed to load stream"));
      const data = (await res.json()) as { stream_url: string; resume_seconds: number; subtitle_url?: string | null };
      console.log("[VideoPlayerOverlay] resolved stream_url:", data.stream_url, "subtitle_url:", data.subtitle_url);
      setStreamUrl(data.stream_url);
      setSubtitleUrl(data.subtitle_url ?? null);
      setResumeSeconds(data.resume_seconds);
    } catch (e) {
      console.error("[VideoPlayerOverlay] resolve failed:", e);
      setError("Couldn't load this episode.");
      setErrorDetail(e instanceof Error ? e.message : String(e));
    } finally {
      setLoading(false);
    }
  }, [props.mediaId, props.provider, props.title, props.episodeTitle, props.coverImage, props.totalEpisodes]);

  // AniSkip segments — best-effort, mirrors desktop's mpv skip-intro/outro.
  // Fetched alongside the stream resolve rather than blocking on it: a
  // missing or slow AniSkip response should never delay playback starting.
  useEffect(() => {
    const params = new URLSearchParams({
      episode_number: String(episodeNumber),
      title: props.title || "",
    });
    mobileFetch(`/mobile-api/media/${props.mediaId}/skip-times?${params.toString()}`)
      .then((res) => (res.ok ? res.json() : { segments: [] }))
      .then((data: { segments: SkipSegment[] }) => setSkipSegments(data.segments || []))
      .catch(() => setSkipSegments([]));
    // eslint-disable-next-line react-hooks/exhaustive-deps
  }, [props.mediaId, episodeNumber]);

  // The video element can fail silently (no `error` event) if the network
  // request just never resolves — surface a message either way instead of
  // an infinite spinner with nothing to report back.
  useEffect(() => {
    if (!streamUrl) return;
    setStalled(false);
    const timer = setTimeout(() => {
      const v = videoRef.current;
      if (v && v.readyState === 0) {
        console.warn("[VideoPlayerOverlay] still readyState=0 after 12s:", streamUrl);
        setStalled(true);
      }
    }, 12_000);
    return () => clearTimeout(timer);
  }, [streamUrl]);

  const handleVideoError = () => {
    const mediaError = videoRef.current?.error;
    const name = mediaError ? MEDIA_ERROR_NAMES[mediaError.code] || `code ${mediaError.code}` : "unknown";
    console.error("[VideoPlayerOverlay] <video> error:", name, mediaError?.message, streamUrl);
    setError("Playback failed.");
    setErrorDetail(`${name}${mediaError?.message ? `: ${mediaError.message}` : ""} — ${streamUrl}`);
  };

  useEffect(() => {
    resolve(episodeNumber);
    // eslint-disable-next-line react-hooks/exhaustive-deps
  }, [episodeNumber]);

  useEffect(() => {
    if (!streamUrl || !videoRef.current) return;
    const video = videoRef.current;
    let hls: Hls | null = null;

    // streamUrl is /proxy?url=<upstream>. Providers hand us either an HLS
    // playlist (.m3u8, e.g. ok.ru) or a direct file (e.g. mkissa's mp4upload
    // .mp4). Only HLS may go through hls.js — feeding it a raw mp4 makes it
    // fail to parse a "manifest" and stall/error, which is why mkissa mp4
    // playback broke on non-Safari browsers. Direct files always use the
    // native element (every browser can play an mp4 that way).
    let inner = streamUrl;
    try {
      const parsed = new URL(streamUrl, window.location.origin);
      inner = decodeURIComponent(parsed.searchParams.get("url") || streamUrl);
    } catch { /* keep streamUrl */ }
    const isHls = inner.includes(".m3u8");

    if (!isHls) {
      video.src = streamUrl;
    } else if (video.canPlayType("application/vnd.apple.mpegurl")) {
      video.src = streamUrl;
    } else if (Hls.isSupported()) {
      hls = new Hls({
        debug: false,
        // Optional: improve startup time for mobile
        startLevel: -1,
      });
      hls.loadSource(streamUrl);
      hls.attachMedia(video);
      hls.on(Hls.Events.ERROR, (_, data) => {
        if (data.fatal) {
          switch (data.type) {
            case Hls.ErrorTypes.NETWORK_ERROR:
              hls?.startLoad();
              break;
            case Hls.ErrorTypes.MEDIA_ERROR:
              hls?.recoverMediaError();
              break;
            default:
              setError(`HLS error: ${data.details}`);
              hls?.destroy();
              break;
          }
        }
      });
    } else {
      setError("HLS playback is not supported on this browser.");
    }

    return () => {
      if (hls) {
        hls.destroy();
      }
      // Clear src to stop native playback gracefully
      video.removeAttribute("src");
      video.load();
    };
  }, [streamUrl]);

  // `default` on a <track> only picks the track when the browser has no
  // stored preference, and Safari in particular ignores it for tracks added
  // after the element mounts — force the mode once the track is live so
  // soft-sub episodes actually show captions instead of silently shipping a
  // disabled track.
  useEffect(() => {
    const video = videoRef.current;
    if (!video || !subtitleUrl) return;
    const enable = () => {
      for (let i = 0; i < video.textTracks.length; i++) {
        if (video.textTracks[i].kind === "subtitles") video.textTracks[i].mode = "showing";
      }
    };
    enable();
    video.textTracks.addEventListener?.("addtrack", enable);
    return () => video.textTracks.removeEventListener?.("addtrack", enable);
  }, [subtitleUrl, streamUrl]);

  // Rotating the phone to landscape should feel like a fullscreen player,
  // not leave the video pinned inside the portrait-sized overlay chrome.
  useEffect(() => {
    const video = videoRef.current as IOSVideoElement | null;
    if (!video || !streamUrl) return;

    const mq = window.matchMedia("(orientation: landscape)");
    const syncFullscreen = () => {
      if (mq.matches) {
        if (typeof video.webkitEnterFullscreen === "function") {
          video.webkitEnterFullscreen();
        } else if (!document.fullscreenElement && video.requestFullscreen) {
          video.requestFullscreen().catch(() => {});
        }
      } else if (video.webkitDisplayingFullscreen && typeof video.webkitExitFullscreen === "function") {
        video.webkitExitFullscreen();
      } else if (document.fullscreenElement) {
        document.exitFullscreen().catch(() => {});
      }
    };
    syncFullscreen();
    mq.addEventListener("change", syncFullscreen);
    return () => mq.removeEventListener("change", syncFullscreen);
  }, [streamUrl]);

  // Brand the OS-level now-playing surface (iOS Dynamic Island / lock
  // screen, Android media notification) instead of leaving it generic —
  // the indicator itself can't be suppressed, it's OS behavior for any
  // playing <video>.
  useEffect(() => {
    if (!("mediaSession" in navigator) || !streamUrl) return;
    navigator.mediaSession.metadata = new MediaMetadata({
      title: props.episodeTitle || `Episode ${episodeNumber}`,
      artist: props.title || "",
      artwork: props.coverImage ? [{ src: props.coverImage, sizes: "512x512", type: "image/jpeg" }] : [],
    });
    return () => {
      navigator.mediaSession.metadata = null;
    };
  }, [streamUrl, props.title, props.episodeTitle, props.coverImage, episodeNumber]);

  // Chrome auto-hides while playing; any interaction resets the timer.
  const pokeChrome = useCallback(() => {
    setChromeVisible(true);
    if (hideTimer.current) clearTimeout(hideTimer.current);
    hideTimer.current = setTimeout(() => {
      const v = videoRef.current;
      if (v && !v.paused) setChromeVisible(false);
    }, 3_000);
  }, []);
  useEffect(() => {
    pokeChrome();
    return () => {
      if (hideTimer.current) clearTimeout(hideTimer.current);
      if (tapTimer.current) clearTimeout(tapTimer.current);
    };
  }, [pokeChrome]);

  const callPlayer = (action: string, pos: number, duration: number, extra?: Record<string, string>) => {
    const params = new URLSearchParams({ pos: String(Math.floor(pos)), duration: String(Math.floor(duration)), ...extra });
    mobileFetch(`/player/${action}?${params.toString()}`).catch(() => {});
  };

  const currentPosDuration = (): [number, number] => {
    const v = videoRef.current;
    return v ? [v.currentTime, v.duration || 0] : [0, 0];
  };

  const goToEpisode = async (target: number) => {
    if (target < 1 || (props.totalEpisodes && target > props.totalEpisodes)) return;
    const [pos, dur] = currentPosDuration();
    if (dur > 0) callPlayer("stop", pos, dur);
    setEpisodeNumber(target);
  };

  const seekBy = (delta: number) => {
    const v = videoRef.current;
    if (!v) return;
    v.currentTime = Math.max(0, Math.min(v.duration || Infinity, v.currentTime + delta));
    pokeChrome();
  };

  const togglePlay = () => {
    const v = videoRef.current;
    if (!v) return;
    if (v.paused) v.play().catch(() => {});
    else v.pause();
    pokeChrome();
  };

  const cycleSpeed = () => {
    const v = videoRef.current;
    if (!v) return;
    const next = SPEEDS[(SPEEDS.indexOf(speed) + 1) % SPEEDS.length];
    v.playbackRate = next;
    setSpeed(next);
    pokeChrome();
  };

  const enterFullscreen = () => {
    const v = videoRef.current as IOSVideoElement | null;
    if (!v) return;
    if (typeof v.webkitEnterFullscreen === "function") v.webkitEnterFullscreen();
    else if (v.requestFullscreen) v.requestFullscreen().catch(() => {});
  };

  // Tap = toggle chrome (after a beat), double-tap left/right = seek 10s.
  // The single-tap action is delayed just long enough to know a second tap
  // isn't coming — the standard video-player disambiguation.
  const onSurfaceTap = (e: React.PointerEvent) => {
    const rect = (e.currentTarget as HTMLElement).getBoundingClientRect();
    const x = (e.clientX - rect.left) / rect.width;
    const zone: "left" | "mid" | "right" = x < 0.33 ? "left" : x > 0.67 ? "right" : "mid";
    const now = Date.now();
    const prev = lastTap.current;
    lastTap.current = { t: now, zone };
    if (prev && now - prev.t < 300 && prev.zone === zone && zone !== "mid") {
      if (tapTimer.current) clearTimeout(tapTimer.current);
      lastTap.current = null;
      seekBy(zone === "left" ? -10 : 10);
      return;
    }
    if (tapTimer.current) clearTimeout(tapTimer.current);
    tapTimer.current = setTimeout(() => {
      setChromeVisible((v) => {
        if (!v) pokeChrome();
        return !v;
      });
    }, 280);
  };

  const seekToClientX = (clientX: number) => {
    const track = trackRef.current;
    const v = videoRef.current;
    if (!track || !v || !duration) return;
    const rect = track.getBoundingClientRect();
    const frac = Math.max(0, Math.min(1, (clientX - rect.left) / rect.width));
    v.currentTime = frac * duration;
    setCurrentTime(frac * duration);
  };

  const onTrackPointerDown = (e: React.PointerEvent) => {
    (e.currentTarget as HTMLElement).setPointerCapture(e.pointerId);
    setScrubbing(true);
    seekToClientX(e.clientX);
    pokeChrome();
  };
  const onTrackPointerMove = (e: React.PointerEvent) => {
    if (scrubbing) seekToClientX(e.clientX);
  };
  const onTrackPointerUp = () => setScrubbing(false);

  const handleLoadedMetadata = () => {
    const v = videoRef.current;
    if (!v) return;
    setDuration(v.duration || 0);
    v.playbackRate = speed;
    if (resumeSeconds > 0) v.currentTime = resumeSeconds;
  };

  const handleTimeUpdate = () => {
    const v = videoRef.current;
    if (!v) return;
    if (!scrubbing) setCurrentTime(v.currentTime);
    if (v.buffered.length > 0) setBuffered(v.buffered.end(v.buffered.length - 1));
    const [pos, dur] = currentPosDuration();
    if (pos - lastProgressReport.current >= 10) {
      lastProgressReport.current = pos;
      callPlayer("progress", pos, dur);
    }
    const inSegment = skipSegments.find((s) => pos >= s.start && pos < s.end) || null;
    if (inSegment && autoskip) {
      v.currentTime = inSegment.end;
      setActiveSkip(null);
      return;
    }
    setActiveSkip((prev) => (prev?.start === inSegment?.start && prev?.end === inSegment?.end ? prev : inSegment));
  };

  const handleSkip = () => {
    if (!activeSkip || !videoRef.current) return;
    videoRef.current.currentTime = activeSkip.end;
    setActiveSkip(null);
  };

  const handlePause = () => {
    setPlaying(false);
    setChromeVisible(true);
    if (videoRef.current?.ended) return;
    const [pos, dur] = currentPosDuration();
    callPlayer("pause", pos, dur);
  };

  const handlePlay = () => {
    setPlaying(true);
    pokeChrome();
    const [pos, dur] = currentPosDuration();
    callPlayer("resume", pos, dur);
  };

  const handleEnded = () => {
    const [, dur] = currentPosDuration();
    callPlayer("stop", dur, dur);
    if (!autoplay) return;
    if (!props.totalEpisodes || episodeNumber < props.totalEpisodes) {
      setEpisodeNumber((n) => n + 1);
    }
  };

  const close = () => {
    const [pos, dur] = currentPosDuration();
    if (dur > 0) callPlayer("stop", pos, dur);
    props.onClose();
  };

  const hasNext = !props.totalEpisodes || episodeNumber < props.totalEpisodes;
  const playedPct = duration > 0 ? (currentTime / duration) * 100 : 0;
  const bufferedPct = duration > 0 ? Math.min(100, (buffered / duration) * 100) : 0;
  const chromeOn = chromeVisible || !playing;

  return (
    <div className="fixed inset-0 z-[999] bg-black">
      {/* Video + tap surface */}
      <div className="absolute inset-0 flex items-center justify-center" onPointerUp={streamUrl && !error ? onSurfaceTap : undefined}>
        {streamUrl && !error && (
          <video
            key={streamUrl}
            ref={videoRef}
            playsInline
            autoPlay
            className="h-full w-full"
            onLoadedMetadata={handleLoadedMetadata}
            onTimeUpdate={handleTimeUpdate}
            onPause={handlePause}
            onPlay={handlePlay}
            onEnded={handleEnded}
            onError={handleVideoError}
            onCanPlay={() => setStalled(false)}
            onLoadedData={() => setStalled(false)}
          >
            {subtitleUrl && (
              <track kind="subtitles" srcLang="en" label="English" default src={subtitleUrl} />
            )}
          </video>
        )}
        {loading && <Loader2 className="absolute animate-spin text-white/70" size={36} />}
      </div>

      {/* Error / stalled states */}
      {error && !loading && (
        <div className="absolute inset-0 flex flex-col items-center justify-center gap-3 px-8 text-center text-white/80">
          <AlertCircle size={28} />
          <p className="text-sm">{error}</p>
          <button
            onClick={() => resolve(episodeNumber)}
            className="rounded-full bg-white/15 px-5 py-2 text-sm font-semibold active:scale-95 transition-transform"
          >
            Retry
          </button>
          {errorDetail && (
            <details className="mt-1 text-left">
              <summary className="cursor-pointer text-[11px] text-white/40">Details</summary>
              <p className="mt-1 max-w-xs break-all text-[10px] text-white/40">{errorDetail}</p>
            </details>
          )}
          <button onClick={close} aria-label="Close player" className="absolute right-4 top-4 p-3" style={{ marginTop: "env(safe-area-inset-top)" }}>
            <X size={22} />
          </button>
        </div>
      )}
      {stalled && !error && !loading && (
        <div className="absolute inset-x-0 top-1/2 flex -translate-y-1/2 flex-col items-center gap-3 px-8 text-center text-white/80">
          <AlertCircle size={28} />
          <p className="text-sm">This is taking longer than expected — the stream may be unreachable.</p>
          <button
            onClick={() => resolve(episodeNumber)}
            className="rounded-full bg-white/15 px-5 py-2 text-sm font-semibold active:scale-95 transition-transform"
          >
            Retry
          </button>
        </div>
      )}

      {/* Skip intro/outro pill — visible regardless of chrome state */}
      {activeSkip && !error && (
        <button
          onClick={handleSkip}
          className="absolute bottom-28 right-5 z-20 rounded-lg border border-white/25 bg-black/70 px-4 py-2.5 text-sm font-semibold text-white backdrop-blur active:scale-95 transition-transform"
        >
          Skip {activeSkip.skip_type === "ed" ? "Outro" : "Intro"}
        </button>
      )}

      {/* Chrome */}
      {!error && (
        <div className={`pointer-events-none absolute inset-0 transition-opacity duration-200 ${chromeOn ? "opacity-100" : "opacity-0"}`}>
          {/* Top gradient: title + close */}
          <div
            className="pointer-events-auto absolute inset-x-0 top-0 flex items-start justify-between bg-gradient-to-b from-black/70 to-transparent px-4 pb-10 text-white"
            style={{ paddingTop: "max(0.75rem, env(safe-area-inset-top))" }}
          >
            <div className="min-w-0">
              <p className="truncate text-sm font-semibold">{props.title}</p>
              <p className="text-xs text-white/60">
                Episode {episodeNumber}
                {props.episodeTitle ? ` — ${props.episodeTitle}` : ""}
              </p>
            </div>
            <button onClick={close} aria-label="Close player" className="-mr-2 p-3">
              <X size={22} />
            </button>
          </div>

          {/* Center cluster: -10 / play / +10 */}
          {streamUrl && (
            <div className="pointer-events-auto absolute left-1/2 top-1/2 flex -translate-x-1/2 -translate-y-1/2 items-center gap-10">
              <button
                onClick={() => seekBy(-10)}
                className="relative flex h-12 w-12 items-center justify-center rounded-full bg-white/10 text-white backdrop-blur active:scale-90 transition-transform"
                aria-label="Back 10 seconds"
              >
                <RotateCcw size={22} />
                <span
                  className="absolute bottom-1 text-[10px] font-extrabold"
                  style={{ textShadow: "0 1px 3px rgba(0,0,0,0.9)" }}
                >
                  10
                </span>
              </button>
              <button
                onClick={togglePlay}
                className="flex h-16 w-16 items-center justify-center rounded-full bg-white/15 text-white backdrop-blur active:scale-90 transition-transform"
                aria-label={playing ? "Pause" : "Play"}
              >
                {playing ? <Pause size={30} fill="currentColor" /> : <Play size={30} fill="currentColor" className="ml-1" />}
              </button>
              <button
                onClick={() => seekBy(10)}
                className="relative flex h-12 w-12 items-center justify-center rounded-full bg-white/10 text-white backdrop-blur active:scale-90 transition-transform"
                aria-label="Forward 10 seconds"
              >
                <RotateCw size={22} />
                <span
                  className="absolute bottom-1 text-[10px] font-extrabold"
                  style={{ textShadow: "0 1px 3px rgba(0,0,0,0.9)" }}
                >
                  10
                </span>
              </button>
            </div>
          )}

          {/* Bottom gradient: scrubber + controls row */}
          <div
            className="pointer-events-auto absolute inset-x-0 bottom-0 bg-gradient-to-t from-black/80 to-transparent px-5 pt-12 text-white"
            style={{ paddingBottom: "max(1rem, env(safe-area-inset-bottom))" }}
          >
            <div className="mb-1.5 flex justify-between text-[11px] font-medium tabular-nums text-white/70">
              <span>{fmtTime(currentTime)}</span>
              <span>-{fmtTime(Math.max(0, duration - currentTime))}</span>
            </div>
            <div
              ref={trackRef}
              className="group relative h-8 -my-3 flex items-center touch-none"
              onPointerDown={onTrackPointerDown}
              onPointerMove={onTrackPointerMove}
              onPointerUp={onTrackPointerUp}
              onPointerCancel={onTrackPointerUp}
            >
              <div className="relative h-1 w-full overflow-visible rounded-full bg-white/20">
                <div className="absolute inset-y-0 left-0 rounded-full bg-white/30" style={{ width: `${bufferedPct}%` }} />
                <div className="absolute inset-y-0 left-0 rounded-full bg-accent" style={{ width: `${playedPct}%` }} />
                <div
                  className={`absolute top-1/2 -translate-x-1/2 -translate-y-1/2 rounded-full bg-white shadow transition-transform ${
                    scrubbing ? "h-4 w-4" : "h-3 w-3"
                  }`}
                  style={{ left: `${playedPct}%` }}
                />
              </div>
            </div>
            <div className="mt-3 flex items-center justify-between">
              <div className="flex items-center gap-5">
                <button onClick={cycleSpeed} aria-label={`Playback speed ${speed}x, tap to change`} className="text-[13px] font-bold tabular-nums text-white/80 active:scale-95 transition-transform">
                  {speed}x
                </button>
              </div>
              <div className="flex items-center gap-5">
                {hasNext && (
                  <button
                    onClick={() => goToEpisode(episodeNumber + 1)}
                    className="flex items-center gap-1.5 text-[13px] font-semibold text-white/80 active:scale-95 transition-transform"
                  >
                    <SkipForward size={16} /> Next Ep
                  </button>
                )}
                <button onClick={enterFullscreen} className="text-white/80 active:scale-95 transition-transform" aria-label="Fullscreen">
                  <Maximize size={18} />
                </button>
              </div>
            </div>
          </div>
        </div>
      )}
    </div>
  );
}
