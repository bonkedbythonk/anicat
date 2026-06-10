import { useEffect, useRef, useState } from "react";
import Hls from "hls.js";
import { usePlaybackStore, clearPlayback } from "@/stores/app";
import {
  Play,
  Pause,
  SkipForward,
  SkipBack,
  X,
  Maximize,
  Minimize,
} from "lucide-react";

export function AnimePlayer() {
  const { item, episode, server } = usePlaybackStore();
  const videoRef = useRef<HTMLVideoElement>(null);
  const containerRef = useRef<HTMLDivElement>(null);
  const [playing, setPlaying] = useState(false);
  const [currentTime, setCurrentTime] = useState(0);
  const [duration, setDuration] = useState(0);
  const [isFullscreen, setIsFullscreen] = useState(false);
  const [showControls, setShowControls] = useState(true);
  const hideTimer = useRef<ReturnType<typeof setTimeout> | null>(null);
  const hlsRef = useRef<Hls | null>(null);

  if (!item || !episode || !server) return null;

  const title = item.title.romaji || item.title.english || "";

  useEffect(() => {
    const video = videoRef.current;
    if (!video) return;

    const detached = new AbortController();

    if (server.endsWith(".m3u8") || server.includes("m3u8")) {
      if (Hls.isSupported()) {
        const hls = new Hls({
          enableWorker: true,
          maxBufferLength: 300,
          maxMaxBufferLength: 600,
          maxBufferSize: 500 * 1000 * 1000,
        });
        hlsRef.current = hls;
        hls.loadSource(server);
        hls.attachMedia(video);
        hls.on(Hls.Events.MANIFEST_PARSED, () => {
          if (video.paused) video.play().catch(() => {});
        });
      } else if (video.canPlayType("application/vnd.apple.mpegurl")) {
        video.src = server;
      }
    } else {
      video.src = server;
    }

    const onPlay = () => setPlaying(true);
    const onPause = () => setPlaying(false);
    const onTime = () => setCurrentTime(video.currentTime);
    const onDuration = () => setDuration(video.duration || 0);

    video.addEventListener("play", onPlay, { signal: detached.signal });
    video.addEventListener("pause", onPause, { signal: detached.signal });
    video.addEventListener("timeupdate", onTime, { signal: detached.signal });
    video.addEventListener("durationchange", onDuration, { signal: detached.signal });

    video.play().catch(() => {});

    return () => {
      detached.abort();
      if (hlsRef.current) {
        hlsRef.current.destroy();
        hlsRef.current = null;
      }
    };
  }, [server]);

  const togglePlay = () => {
    const video = videoRef.current;
    if (!video) return;
    if (video.paused) video.play();
    else video.pause();
  };

  const seek = (seconds: number) => {
    const video = videoRef.current;
    if (!video) return;
    video.currentTime = Math.max(0, Math.min(video.currentTime + seconds, duration));
  };

  const formatTime = (s: number) => {
    const m = Math.floor(s / 60);
    const sec = Math.floor(s % 60);
    return `${m}:${sec.toString().padStart(2, "0")}`;
  };

  const toggleFullscreen = () => {
    const el = containerRef.current;
    if (!el) return;
    if (document.fullscreenElement) {
      document.exitFullscreen();
    } else {
      el.requestFullscreen();
    }
  };

  useEffect(() => {
    const onFs = () => setIsFullscreen(!!document.fullscreenElement);
    document.addEventListener("fullscreenchange", onFs);
    return () => document.removeEventListener("fullscreenchange", onFs);
  }, []);

  const showControlsTemp = () => {
    setShowControls(true);
    if (hideTimer.current !== null) clearTimeout(hideTimer.current);
    hideTimer.current = setTimeout(() => setShowControls(false), 3000);
  };

  useEffect(() => {
    showControlsTemp();
  }, []);

  return (
    <div
      ref={containerRef}
      className="absolute inset-0 bg-black z-50 flex flex-col"
      onMouseMove={showControlsTemp}
      onClick={togglePlay}
    >
      {/* Video */}
      <video ref={videoRef} className="w-full h-full object-contain" controls={false} />

      {/* Controls overlay */}
      <div
        className={`absolute inset-0 flex flex-col justify-end transition-opacity duration-300 ${
          showControls ? "opacity-100" : "opacity-0 pointer-events-none"
        }`}
      >
        {/* Gradient */}
        <div className="absolute inset-0 bg-gradient-to-t from-black/70 via-transparent to-black/30" />

        {/* Top bar */}
        <div className="relative flex items-center justify-between px-4 py-3">
          <div>
            <h2 className="text-white font-medium text-sm">{title}</h2>
            <p className="text-gray-400 text-xs">
              Episode {episode.number}
              {episode.title && ` — ${episode.title}`}
            </p>
          </div>
          <button
            onClick={(e) => {
              e.stopPropagation();
              clearPlayback();
            }}
            className="text-white hover:text-gray-300"
          >
            <X size={20} />
          </button>
        </div>

        {/* Center controls */}
        <div className="relative flex items-center justify-center gap-6 py-4">
          <button
            onClick={(e) => {
              e.stopPropagation();
              seek(-10);
            }}
            className="text-white/80 hover:text-white"
          >
            <SkipBack size={24} />
          </button>
          <button
            onClick={(e) => {
              e.stopPropagation();
              togglePlay();
            }}
            className="text-white hover:text-white/80"
          >
            {playing ? <Pause size={36} /> : <Play size={36} />}
          </button>
          <button
            onClick={(e) => {
              e.stopPropagation();
              seek(10);
            }}
            className="text-white/80 hover:text-white"
          >
            <SkipForward size={24} />
          </button>
        </div>

        {/* Bottom bar */}
        <div className="relative flex items-center gap-3 px-4 pb-4 text-xs text-white/80">
          <span>{formatTime(currentTime)}</span>
          <div
            className="flex-1 h-1 bg-white/20 rounded-full overflow-hidden cursor-pointer"
            onClick={(e) => {
              e.stopPropagation();
              const rect = e.currentTarget.getBoundingClientRect();
              const x = e.clientX - rect.left;
              const pct = x / rect.width;
              if (videoRef.current) videoRef.current.currentTime = pct * duration;
            }}
          >
            <div
              className="h-full bg-white rounded-full transition-all"
              style={{
                width: `${duration ? (currentTime / duration) * 100 : 0}%`,
              }}
            />
          </div>
          <span>{formatTime(duration)}</span>
          <button
            onClick={(e) => {
              e.stopPropagation();
              toggleFullscreen();
            }}
            className="text-white/80 hover:text-white"
          >
            {isFullscreen ? <Minimize size={16} /> : <Maximize size={16} />}
          </button>
        </div>
      </div>
    </div>
  );
}
