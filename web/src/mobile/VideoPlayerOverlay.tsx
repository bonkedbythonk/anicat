import { useEffect, useRef, useState, useCallback } from "react";
import { X, Loader2, ChevronLeft, ChevronRight, AlertCircle } from "lucide-react";
import { mobileFetch } from "@/lib/transport";
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

/** Mobile has no mpv — this plays episodes with a plain <video> tag. iOS
 * Safari (and every other WebKit-based iOS browser) has native HLS support,
 * so no hls.js is needed; the resolved stream URL already points through the
 * existing /proxy route, which injects the referer/UA headers a raw <video>
 * tag can't attach itself.
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

export function VideoPlayerOverlay(props: VideoPlayerOverlayProps) {
  const [episodeNumber, setEpisodeNumber] = useState(props.episodeNumber);
  const [streamUrl, setStreamUrl] = useState<string | null>(null);
  const [resumeSeconds, setResumeSeconds] = useState(0);
  const [loading, setLoading] = useState(true);
  const [error, setError] = useState<string | null>(null);
  const [errorDetail, setErrorDetail] = useState<string | null>(null);
  const [stalled, setStalled] = useState(false);
  const [skipSegments, setSkipSegments] = useState<SkipSegment[]>([]);
  const [activeSkip, setActiveSkip] = useState<SkipSegment | null>(null);
  const videoRef = useRef<HTMLVideoElement>(null);
  const lastProgressReport = useRef(0);

  const resolve = useCallback(async (epNum: number) => {
    setLoading(true);
    setError(null);
    setErrorDetail(null);
    setStalled(false);
    setStreamUrl(null);
    setSkipSegments([]);
    setActiveSkip(null);
    try {
      const res = await mobileFetch("/mobile-api/playback/resolve", {
        method: "POST",
        headers: { "Content-Type": "application/json" },
        body: JSON.stringify({
          media_id: props.mediaId,
          episode_number: epNum,
          provider: props.provider === "nyaa" ? "anineko" : props.provider,
          title: props.title,
          episode_title: props.episodeTitle,
          cover_image: props.coverImage,
          total_episodes: props.totalEpisodes,
        }),
      });
      if (!res.ok) throw new Error(await res.text().catch(() => "Failed to load stream"));
      const data = (await res.json()) as { stream_url: string; resume_seconds: number };
      console.log("[VideoPlayerOverlay] resolved stream_url:", data.stream_url);
      setStreamUrl(data.stream_url);
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

  const callPlayer = (action: string, pos: number, duration: number, extra?: Record<string, string>) => {
    const params = new URLSearchParams({ pos: String(Math.floor(pos)), duration: String(Math.floor(duration)), ...extra });
    mobileFetch(`/player/${action}?${params.toString()}`).catch(() => {});
  };

  const currentPosDuration = (): [number, number] => {
    const v = videoRef.current;
    return v ? [v.currentTime, v.duration || 0] : [0, 0];
  };

  const goToEpisode = async (target: number) => {
    if (props.totalEpisodes && (target < 1 || target > props.totalEpisodes)) return;
    const [pos, duration] = currentPosDuration();
    if (duration > 0) callPlayer("stop", pos, duration);
    setEpisodeNumber(target);
  };

  const handleLoadedMetadata = () => {
    if (videoRef.current && resumeSeconds > 0) {
      videoRef.current.currentTime = resumeSeconds;
    }
  };

  const handleTimeUpdate = () => {
    const [pos, duration] = currentPosDuration();
    if (pos - lastProgressReport.current >= 10) {
      lastProgressReport.current = pos;
      callPlayer("progress", pos, duration);
    }
    const inSegment = skipSegments.find((s) => pos >= s.start && pos < s.end) || null;
    setActiveSkip((prev) => (prev?.start === inSegment?.start && prev?.end === inSegment?.end ? prev : inSegment));
  };

  const handleSkip = () => {
    if (!activeSkip || !videoRef.current) return;
    videoRef.current.currentTime = activeSkip.end;
    setActiveSkip(null);
  };

  const handlePause = () => {
    if (videoRef.current?.ended) return;
    const [pos, duration] = currentPosDuration();
    callPlayer("pause", pos, duration);
  };

  const handlePlay = () => {
    const [pos, duration] = currentPosDuration();
    callPlayer("resume", pos, duration);
  };

  const handleEnded = () => {
    const [, duration] = currentPosDuration();
    callPlayer("stop", duration, duration);
    if (!props.totalEpisodes || episodeNumber < props.totalEpisodes) {
      setEpisodeNumber((n) => n + 1);
    }
  };

  const close = () => {
    const [pos, duration] = currentPosDuration();
    if (duration > 0) callPlayer("stop", pos, duration);
    props.onClose();
  };

  return (
    <div className="fixed inset-0 z-[999] bg-black flex flex-col">
      <div className="flex items-center justify-between px-4 py-3 text-white" style={{ paddingTop: "max(0.75rem, env(safe-area-inset-top))" }}>
        <div className="min-w-0">
          <p className="text-sm font-semibold truncate">{props.title}</p>
          <p className="text-xs text-white/60">Episode {episodeNumber}</p>
        </div>
        <button onClick={close} className="p-2 -mr-2">
          <X size={22} />
        </button>
      </div>

      <div className="flex-1 flex items-center justify-center relative">
        {loading && <Loader2 className="animate-spin text-white/70" size={36} />}
        {error && !loading && (
          <div className="flex flex-col items-center gap-3 text-white/80 px-8 text-center">
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
                <summary className="text-[11px] text-white/40 cursor-pointer">Details</summary>
                <p className="mt-1 max-w-xs break-all text-[10px] text-white/40">{errorDetail}</p>
              </details>
            )}
          </div>
        )}
        {stalled && !error && !loading && (
          <div className="flex flex-col items-center gap-3 text-white/80 px-8 text-center">
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
        {streamUrl && !error && (
          <video
            key={streamUrl}
            ref={videoRef}
            controls
            playsInline
            autoPlay
            className="w-full h-full"
            onLoadedMetadata={handleLoadedMetadata}
            onTimeUpdate={handleTimeUpdate}
            onPause={handlePause}
            onPlay={handlePlay}
            onEnded={handleEnded}
            onError={handleVideoError}
            onCanPlay={() => setStalled(false)}
            onLoadedData={() => setStalled(false)}
          />
        )}
        {activeSkip && !error && (
          <button
            onClick={handleSkip}
            className="absolute bottom-4 right-4 rounded-lg bg-black/70 backdrop-blur px-4 py-2.5 text-sm font-semibold text-white border border-white/20 active:scale-95 transition-transform"
          >
            Skip {activeSkip.skip_type === "ed" ? "Outro" : "Intro"}
          </button>
        )}
      </div>

      <div className="flex items-center justify-center gap-8 py-4" style={{ paddingBottom: "max(1rem, env(safe-area-inset-bottom))" }}>
        <button
          onClick={() => goToEpisode(episodeNumber - 1)}
          disabled={episodeNumber <= 1}
          className="text-white/80 disabled:opacity-30 flex items-center gap-1 text-sm"
        >
          <ChevronLeft size={20} /> Prev
        </button>
        <button
          onClick={() => goToEpisode(episodeNumber + 1)}
          disabled={!!props.totalEpisodes && episodeNumber >= props.totalEpisodes}
          className="text-white/80 disabled:opacity-30 flex items-center gap-1 text-sm"
        >
          Next <ChevronRight size={20} />
        </button>
      </div>
    </div>
  );
}
