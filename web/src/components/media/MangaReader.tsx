"use client";

import { useEffect, useState, useRef, useCallback } from "react";
import { createPortal } from "react-dom";
import { X, ChevronLeft, ChevronRight, Loader2, Maximize2, Minimize2, Book, FileText, ScrollText, BookX } from "lucide-react";
import { apiOrigin, mediaApi } from "@/lib/api";
import { useSettingsStore } from "@/stores/app";

declare global {
  interface Window {
    __TAURI_INTERNALS__?: Record<string, unknown>;
  }
}

interface MangaReaderProps {
  mediaId: number;
  chapterNumber: string;
  initialPage?: number;
  onClose: () => void;
  onProgressUpdate?: (chapterNum: string) => void;
  onNavigateChapter?: (direction: "prev" | "next") => void;
  hasPrevChapter?: boolean;
  hasNextChapter?: boolean;
}

type ReadingMode = "single" | "double" | "vertical";

export default function MangaReader({ mediaId, chapterNumber, initialPage = 0, onClose, onProgressUpdate, onNavigateChapter, hasPrevChapter, hasNextChapter }: MangaReaderProps) {
  const [pages, setPages] = useState<string[]>([]);
  const [loading, setLoading] = useState(true);
  const [error, setError] = useState<string | null>(null);
  const [reloadKey, setReloadKey] = useState(0);
  const [isFullscreen, setIsFullscreen] = useState(false);
  const [currentPage, setCurrentPage] = useState(initialPage);
  const [readingMode, setReadingMode] = useState<ReadingMode>("single");
  const [readingDirection, setReadingDirection] = useState<"ltr" | "rtl">("rtl");
  const [showControls, setShowControls] = useState(true);
  const [loadedImages, setLoadedImages] = useState<Set<number>>(new Set());
  const [zoom, setZoom] = useState(1);
  // Desktop's window enforces an 800px minimum, so this can never be true
  // there — safe to gate mobile-only behavior on it without a separate
  // mobile build of this component (double-page mode, the fullscreen
  // toggle, and touch-swipe page turning all need to differ on a phone).
  const [isMobile] = useState(() => typeof window !== "undefined" && window.innerWidth < 640);

  const containerRef = useRef<HTMLDivElement>(null);
  // Tracks whether the reader put the *app window* into native fullscreen.
  // Native Tauri fullscreen does not set document.fullscreenElement, and on
  // Windows there is no system gesture to leave it — so without restoring it
  // on close the whole app gets stuck fullscreen.
  const enteredFullscreenRef = useRef(false);

  useEffect(() => {
    const savedDirection = localStorage.getItem("anicat_manga_reading_direction");
    if (savedDirection === "ltr" || savedDirection === "rtl") {
      setReadingDirection(savedDirection);
    }
    return () => {
      mediaApi.clearPlaybackStatus().catch(() => {/* ignore */});
      // Never leave the app window stuck in native fullscreen, no matter how
      // the reader closes (Escape, X, finishing, or chapter navigation).
      if (enteredFullscreenRef.current && window.__TAURI_INTERNALS__) {
        import("@tauri-apps/api/window")
          .then(({ getCurrentWindow }) => getCurrentWindow().setFullscreen(false))
          .catch(() => {/* ignore */});
      }
    };
  }, []);
  const controlsTimeoutRef = useRef<NodeJS.Timeout | null>(null);
  const lastActionRef = useRef<number>(0);

  // Load saved reading mode on mount. The per-series key wins over the
  // global one, so a webtoon remembered as vertical opens scrolling while
  // chaptered manga stays paged.
  useEffect(() => {
    const savedMode = (localStorage.getItem(`anicat_manga_mode_${mediaId}`) ||
      localStorage.getItem("anicat_manga_reading_mode")) as ReadingMode | null;
    if (savedMode === "single" || savedMode === "double" || savedMode === "vertical") {
      // A "double" preference saved from a desktop session isn't offered (or
      // usable) on a phone — fall back to single rather than rendering an
      // illegible squished two-page spread.
      setReadingMode(isMobile && savedMode === "double" ? "single" : savedMode);
    }
  }, [isMobile, mediaId]);

  // Persist mode both globally (the default for new series) and per series.
  const changeMode = (mode: ReadingMode) => {
    setReadingMode(mode);
    localStorage.setItem("anicat_manga_reading_mode", mode);
    localStorage.setItem(`anicat_manga_mode_${mediaId}`, mode);
  };

  useEffect(() => {
    const handleFullscreenChange = () => {
      const isFull = !!(
        document.fullscreenElement || 
        (document as any).webkitFullscreenElement || 
        (document as any).mozFullScreenElement || 
        (document as any).msFullscreenElement
      );
      setIsFullscreen(isFull);
    };
    
    document.addEventListener("fullscreenchange", handleFullscreenChange);
    document.addEventListener("webkitfullscreenchange", handleFullscreenChange);
    document.addEventListener("mozfullscreenchange", handleFullscreenChange);
    document.addEventListener("MSFullscreenChange", handleFullscreenChange);
    
    return () => {
      document.removeEventListener("fullscreenchange", handleFullscreenChange);
      document.removeEventListener("webkitfullscreenchange", handleFullscreenChange);
      document.removeEventListener("mozfullscreenchange", handleFullscreenChange);
      document.removeEventListener("MSFullscreenChange", handleFullscreenChange);
    };
  }, []);

  useEffect(() => {
    if (!loading && pages.length > 0) {
      localStorage.setItem(`anicat_manga_${mediaId}_${chapterNumber}_page`, currentPage.toString());
    }
  }, [currentPage, mediaId, chapterNumber, loading, pages.length]);

  useEffect(() => {
    setLoading(true);
    setError(null);
    // Reset up front: currentPage is local state that survives a chapterNumber
    // prop change (the reader stays mounted across chapter navigation), so
    // without this a jump from a longer chapter to a shorter one leaves
    // currentPage pointing past the end of the new pages array.
    setCurrentPage(initialPage);
    mediaApi.getChapterPages(mediaId, chapterNumber)
      .then(data => {
        setPages(data.thumbnails || []);
        setLoading(false);

        if (initialPage === 0) {
          const savedPage = localStorage.getItem(`anicat_manga_${mediaId}_${chapterNumber}_page`);
          if (savedPage) {
            setCurrentPage(parseInt(savedPage));
          }
        }
      })
      .catch(err => {
        console.error("Failed to load manga pages:", err);
        setError("Failed to load chapter pages. Please try again.");
        setLoading(false);
      });
  }, [mediaId, chapterNumber, initialPage, reloadKey]);

  const dataSaver = useSettingsStore((s) => s.dataSaver);

  useEffect(() => {
    if (pages.length === 0) return;
    // Low Data Mode: 2 pages ahead, loaded strictly one at a time — on a slow
    // connection six parallel image fetches delay the very page the reader is
    // turning to. Otherwise: 6 ahead in parallel, as before.
    const ahead = dataSaver ? 2 : 6;
    const nextPages = pages.slice(currentPage, currentPage + ahead);
    if (dataSaver) {
      let cancelled = false;
      const loadOne = (idx: number) => {
        if (cancelled || idx >= nextPages.length) return;
        const globalIdx = currentPage + idx;
        if (loadedImages.has(globalIdx)) {
          loadOne(idx + 1);
          return;
        }
        const img = new Image();
        img.src = getProxyUrl(nextPages[idx]);
        img.onload = () => {
          setLoadedImages(prev => new Set(prev).add(globalIdx));
          loadOne(idx + 1);
        };
        img.onerror = () => loadOne(idx + 1);
      };
      loadOne(0);
      return () => { cancelled = true; };
    }
    nextPages.forEach((src, idx) => {
      const globalIdx = currentPage + idx;
      if (!loadedImages.has(globalIdx)) {
        const img = new Image();
        img.src = getProxyUrl(src);
        img.onload = () => {
          setLoadedImages(prev => new Set(prev).add(globalIdx));
        };
      }
    });
  }, [currentPage, pages, loadedImages, dataSaver]);

  const handleNext = useCallback(() => {
    const now = Date.now();
    if (now - lastActionRef.current < 250) return; // Debounce
    lastActionRef.current = now;

    if (readingMode === "vertical") return;
    const step = readingMode === "double" ? 2 : 1;
    setCurrentPage(prev => Math.min(pages.length - 1, prev + step));
  }, [readingMode, pages.length]);

  const handlePrev = useCallback(() => {
    const now = Date.now();
    if (now - lastActionRef.current < 250) return; // Debounce
    lastActionRef.current = now;

    if (readingMode === "vertical") return;
    const step = readingMode === "double" ? 2 : 1;
    setCurrentPage(prev => Math.max(0, prev - step));
  }, [readingMode]);

  useEffect(() => {
    const handleKeyDown = (e: KeyboardEvent) => {
      switch (e.key) {
        case "ArrowRight":
          e.preventDefault();
          if (readingDirection === "rtl") {
            handlePrev();
          } else {
            handleNext();
          }
          break;
        case " ":
          e.preventDefault();
          handleNext(); // Spacebar always moves forward in standard flows
          break;
        case "ArrowLeft":
          e.preventDefault();
          if (readingDirection === "rtl") {
            handleNext();
          } else {
            handlePrev();
          }
          break;
        case "f":
        case "F":
          toggleFullscreen();
          break;
        case "Escape":
          // First Escape leaves fullscreen; a second one closes the reader.
          if (enteredFullscreenRef.current) {
            toggleFullscreen();
          } else if (!document.fullscreenElement) {
            onClose();
          }
          break;
        case "m":
        case "M":
          setReadingMode(prev => prev === "single" ? "double" : prev === "double" ? "vertical" : "single");
          break;
      }
    };

    window.addEventListener("keydown", handleKeyDown);
    return () => window.removeEventListener("keydown", handleKeyDown);
  }, [handleNext, handlePrev, onClose, readingDirection]);

  // Trackpad horizontal swipe → flip pages (single/double mode only).
  // Attached to the container element (not window) so stopPropagation
  // prevents App.tsx's window-level "swipe back" handler from also firing.
  useEffect(() => {
    const container = containerRef.current;
    if (!container || readingMode === "vertical") return;
    let accX = 0;
    let accY = 0;
    let resetTimer: ReturnType<typeof setTimeout>;

    const onWheel = (e: WheelEvent) => {
      // Always stop propagation so App.tsx's window-level back gesture
      // never accumulates deltaX while the manga reader is open.
      e.stopPropagation();

      // Trackpad pinch is reported as ctrlKey+wheel — the zoom handler
      // below owns that, don't let it accumulate into a page turn.
      if (e.ctrlKey) return;

      accX += e.deltaX;
      accY += Math.abs(e.deltaY);
      clearTimeout(resetTimer);
      resetTimer = setTimeout(() => { accX = 0; accY = 0; }, 180);

      // Require horizontal dominance so vertical scroll doesn't misfire
      if (Math.abs(accX) < 40 || Math.abs(accX) < accY * 1.5) return;
      const direction = accX > 0 ? "forward" : "back";
      accX = 0;
      accY = 0;

      if (readingDirection === "rtl") {
        if (direction === "forward") handlePrev(); else handleNext();
      } else {
        if (direction === "forward") handleNext(); else handlePrev();
      }
    };

    container.addEventListener("wheel", onWheel, { passive: true });
    return () => {
      container.removeEventListener("wheel", onWheel);
      clearTimeout(resetTimer);
    };
  }, [readingMode, readingDirection, handleNext, handlePrev]);

  // Trackpad pinch-to-zoom: browsers report this as wheel events with
  // ctrlKey set and deltaY carrying the pinch magnitude — there's no
  // separate gesture API in Chromium/WebKit for it. Must be non-passive to
  // preventDefault, otherwise the OS/webview's own page-zoom fires too.
  useEffect(() => {
    const container = containerRef.current;
    if (!container) return;
    const onPinch = (e: WheelEvent) => {
      if (!e.ctrlKey) return;
      e.preventDefault();
      setZoom((z) => Math.min(3, Math.max(1, z - e.deltaY * 0.01)));
    };
    container.addEventListener("wheel", onPinch, { passive: false });
    return () => container.removeEventListener("wheel", onPinch);
  }, []);

  // Reset zoom on page/chapter/mode change so it never carries over into
  // content the user didn't zoom.
  useEffect(() => {
    setZoom(1);
  }, [currentPage, readingMode, chapterNumber]);

  // Touch swipe → flip pages (single/double mode only). The trackpad wheel
  // handler above has no touch equivalent at all, so on a phone the only way
  // to turn pages was tapping the small left/right zones — this is the
  // primary interaction most manga reader apps rely on.
  useEffect(() => {
    if (!isMobile) return;
    const container = containerRef.current;
    if (!container || readingMode === "vertical") return;
    let startX = 0;
    let startY = 0;

    const onTouchStart = (e: TouchEvent) => {
      startX = e.touches[0].clientX;
      startY = e.touches[0].clientY;
    };
    const onTouchEnd = (e: TouchEvent) => {
      const dx = e.changedTouches[0].clientX - startX;
      const dy = Math.abs(e.changedTouches[0].clientY - startY);
      if (Math.abs(dx) < 50 || Math.abs(dx) < dy * 1.5) return;
      const direction = dx < 0 ? "forward" : "back";
      if (readingDirection === "rtl") {
        if (direction === "forward") handlePrev(); else handleNext();
      } else {
        if (direction === "forward") handleNext(); else handlePrev();
      }
    };

    container.addEventListener("touchstart", onTouchStart, { passive: true });
    container.addEventListener("touchend", onTouchEnd, { passive: true });
    return () => {
      container.removeEventListener("touchstart", onTouchStart);
      container.removeEventListener("touchend", onTouchEnd);
    };
  }, [isMobile, readingMode, readingDirection, handleNext, handlePrev]);

  const toggleFullscreen = async () => {
    try {
      if (window.__TAURI_INTERNALS__) {
        const { getCurrentWindow } = await import("@tauri-apps/api/window");
        const appWindow = getCurrentWindow();
        const current = await appWindow.isFullscreen();
        await appWindow.setFullscreen(!current);
        setIsFullscreen(!current);
        enteredFullscreenRef.current = !current;
        return;
      }
    } catch (err) {
      console.error("Native fullscreen toggle failed, falling back to browser API:", err);
    }
    // Fallback for web/development
    const element = containerRef.current as any;
    if (!element) return;
    if (!document.fullscreenElement) {
      element.requestFullscreen?.() || element.webkitRequestFullscreen?.();
    } else {
      document.exitFullscreen?.() || (document as any).webkitExitFullscreen?.();
    }
  };

  const handleFinish = () => {
    const isAtEnd = readingMode === "vertical" ? true : // Vertical mode button is at the bottom
                   (readingMode === "single" ? currentPage === pages.length - 1 : 
                    currentPage >= pages.length - 2);
    
    if (!isAtEnd) {
      console.warn("[MangaReader] handleFinish called but not at end of chapter");
      return;
    }

    // Clear saved page for this chapter since it's finished
    localStorage.removeItem(`anicat_manga_${mediaId}_${chapterNumber}_page`);

    if (onProgressUpdate) onProgressUpdate(chapterNumber);
    onClose();
  };

  // Same as handleFinish but continues straight into the next chapter instead
  // of closing the reader -- this is the primary end-of-chapter action when
  // there is a next chapter to read, since closing and re-opening from the
  // chapter list every time was the friction being fixed here.
  const handleNextChapter = () => {
    localStorage.removeItem(`anicat_manga_${mediaId}_${chapterNumber}_page`);
    if (onProgressUpdate) onProgressUpdate(chapterNumber);
    onNavigateChapter?.("next");
  };

  const handleMouseMove = (e: React.MouseEvent) => {
    if (isMobile) return;
    // Prevent scroll wheel from triggering mousemove events by checking actual movement
    if (Math.abs(e.movementX) < 2 && Math.abs(e.movementY) < 2) return;
    
    setShowControls(true);
    if (controlsTimeoutRef.current) clearTimeout(controlsTimeoutRef.current);
    controlsTimeoutRef.current = setTimeout(() => setShowControls(false), 3000);
  };

  const getProxyUrl = (url: string) => {
    return `${apiOrigin()}/api/media/manga/proxy?url=${encodeURIComponent(url)}`;
  };

  if (loading) {
    return createPortal(
      <div className="fixed inset-0 z-[200] bg-black flex flex-col items-center justify-center">
        <Loader2 className="animate-spin text-accent mb-4" size={48} />
        <p className="text-gray-400 font-medium">Loading Chapter {chapterNumber}...</p>
      </div>,
      document.body,
    );
  }

  if (error) {
    return createPortal(
      <div className="fixed inset-0 z-[200] bg-black flex flex-col items-center justify-center p-6 text-center">
        <div className="bg-red-500/10 text-red-500 p-4 rounded-xl mb-6 max-w-md border border-red-500/20">
          <p className="font-bold mb-1">Error</p>
          <p className="text-sm">{error}</p>
        </div>
        <div className="flex items-center gap-3">
          <button onClick={() => setReloadKey(k => k + 1)} className="px-6 py-2 bg-accent hover:bg-accent/90 text-white rounded-lg transition-colors font-bold">
            Try Again
          </button>
          <button onClick={onClose} className="px-6 py-2 bg-surface hover:bg-foreground/[0.03] border border-border text-foreground rounded-lg transition-colors font-bold">
            Close Reader
          </button>
        </div>
      </div>,
      document.body,
    );
  }

  // Loaded successfully but the provider returned no pages — distinct from a
  // hard error so the user knows the chapter is just unavailable, not broken.
  if (pages.length === 0) {
    return createPortal(
      <div className="fixed inset-0 z-[200] bg-black flex flex-col items-center justify-center p-6 text-center">
        <BookX className="text-muted-foreground mb-4" size={48} />
        <p className="font-bold text-white mb-1">No pages found</p>
        <p className="text-sm text-gray-400 max-w-md mb-6">
          This chapter came back empty — the source may not have it yet, or the provider may be unavailable. Try again in a moment.
        </p>
        <div className="flex items-center gap-3">
          <button onClick={() => setReloadKey(k => k + 1)} className="px-6 py-2 bg-accent hover:bg-accent/90 text-white rounded-lg transition-colors font-bold">
            Try Again
          </button>
          <button onClick={onClose} className="px-6 py-2 bg-surface hover:bg-foreground/[0.03] border border-border text-foreground rounded-lg transition-colors font-bold">
            Close Reader
          </button>
        </div>
      </div>,
      document.body,
    );
  }

  // Portaled to document.body: MediaDetail (both desktop and mobile) mounts
  // this inside an animated motion.div, whose `transform` creates a new
  // containing block for `position: fixed` descendants and a new stacking
  // context for z-index — without the portal this reader gets trapped inside
  // that wrapper's box instead of the true viewport, so sibling chrome
  // (mobile's bottom tab bar, or the phone's own status bar) paints on top of
  // it regardless of z-index.
  return createPortal(
    <div
      ref={containerRef}
      onMouseMove={handleMouseMove}
      className="fixed inset-0 z-[200] bg-[#050505] flex flex-col items-center select-none overflow-hidden transform-gpu will-change-[transform,opacity] forced-dark-container"
    >
      {/* Header Controls */}
      {isMobile ? (
        <div
          className={`fixed top-0 inset-x-0 z-50 transition-opacity duration-300 ${showControls ? "opacity-100 pointer-events-auto" : "opacity-0 pointer-events-none"}`}
          style={{ paddingTop: "env(safe-area-inset-top)" }}
        >
          <div className="flex items-center justify-between gap-2 px-3 py-2.5">
            <button onClick={onClose} className="p-2 rounded-full bg-surface border border-border text-foreground shrink-0">
              <X size={19} />
            </button>

            <div className="flex items-center gap-1.5 min-w-0">
              {onNavigateChapter && (
                <button
                  onClick={(e) => { e.stopPropagation(); onNavigateChapter("prev"); }}
                  disabled={!hasPrevChapter}
                  className="p-1.5 rounded-lg bg-surface border border-border text-foreground disabled:opacity-20"
                >
                  <ChevronLeft size={16} />
                </button>
              )}
              <p className="text-sm font-semibold text-foreground whitespace-nowrap">Ch. {chapterNumber}</p>
              {onNavigateChapter && (
                <button
                  onClick={(e) => { e.stopPropagation(); onNavigateChapter("next"); }}
                  disabled={!hasNextChapter}
                  className="p-1.5 rounded-lg bg-surface border border-border text-foreground disabled:opacity-20"
                >
                  <ChevronRight size={16} />
                </button>
              )}
            </div>

            <div className="flex items-center gap-1 bg-surface p-1 rounded-xl border border-border shrink-0">
              {readingMode !== "vertical" && (
                <button
                  onClick={() => {
                    const newDir = readingDirection === "ltr" ? "rtl" : "ltr";
                    setReadingDirection(newDir);
                    localStorage.setItem("anicat_manga_reading_direction", newDir);
                  }}
                  className="px-2 py-2 rounded-lg text-[10px] font-semibold tracking-wide text-accent uppercase"
                >
                  {readingDirection === "rtl" ? "RTL" : "LTR"}
                </button>
              )}
              <button onClick={() => changeMode("single")} className={`p-2 rounded-lg transition-all ${readingMode === "single" ? "bg-accent text-white" : "text-muted-foreground"}`}><FileText size={16} /></button>
              <button onClick={() => changeMode("vertical")} className={`p-2 rounded-lg transition-all ${readingMode === "vertical" ? "bg-accent text-white" : "text-muted-foreground"}`}><ScrollText size={16} /></button>
            </div>
          </div>
        </div>
      ) : (
        <>
          {/* Left Vertical Bar */}
          <div className={`fixed left-6 top-1/2 -translate-y-1/2 z-50 transition-opacity duration-300 ${showControls ? "opacity-100 pointer-events-auto" : "opacity-0 pointer-events-none"}`}>
            <div className="flex flex-col items-center space-y-4 bg-surface p-2 rounded-2xl border border-border">
              <button onClick={onClose} className="p-3 rounded-xl bg-foreground/[0.03] hover:bg-foreground/[0.06] text-foreground transition-all" aria-label="Close reader" title="Close Reader">
                <X size={20} />
              </button>
              
              <div className="w-6 h-px bg-border" />
              
              <div className="flex flex-col items-center py-2">
                <h2 className="text-[10px] font-bold text-accent tracking-[0.2em] [writing-mode:vertical-rl] rotate-180 uppercase">Chapter {chapterNumber}</h2>
              </div>

              <div className="flex flex-col gap-2">
                {onNavigateChapter && (
                  <button
                    onClick={(e) => { e.stopPropagation(); onNavigateChapter("prev"); }}
                    disabled={!hasPrevChapter}
                    className="p-2 rounded-lg hover:bg-foreground/[0.06] text-foreground disabled:opacity-20 disabled:cursor-not-allowed transition-all"
                    aria-label="Previous chapter" title="Previous Chapter"
                  >
                    <ChevronLeft size={16} className="rotate-90" />
                  </button>
                )}
                {onNavigateChapter && (
                  <button
                    onClick={(e) => { e.stopPropagation(); onNavigateChapter("next"); }}
                    disabled={!hasNextChapter}
                    className="p-2 rounded-lg hover:bg-foreground/[0.06] text-foreground disabled:opacity-20 disabled:cursor-not-allowed transition-all"
                    aria-label="Next chapter" title="Next Chapter"
                  >
                    <ChevronRight size={16} className="rotate-90" />
                  </button>
                )}
              </div>

              <div className="w-6 h-px bg-border" />

              {hasNextChapter ? (
                <button onClick={handleNextChapter} className="p-3 bg-accent text-white rounded-xl hover:bg-accent/90 transition-colors" aria-label="Next chapter" title="Next Chapter">
                  <ChevronRight size={20} />
                </button>
              ) : (
                <button onClick={handleFinish} className="p-3 bg-accent text-white rounded-xl hover:bg-accent/90 transition-colors" title="Finish Reading">
                  <Book size={20} />
                </button>
              )}
            </div>
          </div>

          {/* Right Vertical Bar */}
          <div className={`fixed right-6 top-1/2 -translate-y-1/2 z-50 transition-opacity duration-300 ${showControls ? "opacity-100 pointer-events-auto" : "opacity-0 pointer-events-none"}`}>
            <div className="flex flex-col items-center space-y-3 bg-surface p-1.5 rounded-2xl border border-border">
              {readingMode !== "vertical" && (
                <div className="py-3 px-1 flex flex-col items-center gap-1 border-b border-border w-full">
                  <span className="text-xs font-bold text-foreground">{currentPage + 1}</span>
                  <div className="w-4 h-px bg-border" />
                  <span className="text-[10px] font-medium text-muted-foreground">{pages.length}</span>
                </div>
              )}

              {/* Reading Direction Selector */}
              {readingMode !== "vertical" && (
                <button
                  onClick={() => {
                    const newDir = readingDirection === "ltr" ? "rtl" : "ltr";
                    setReadingDirection(newDir);
                    localStorage.setItem("anicat_manga_reading_direction", newDir);
                  }}
                  className="p-2 rounded-xl text-[10px] font-bold tracking-wider text-accent hover:bg-foreground/[0.03] transition-all"
                  aria-label="Toggle reading direction, right-to-left or left-to-right" title="Toggle Reading Direction (RTL/LTR)"
                >
                  {readingDirection === "rtl" ? "RTL" : "LTR"}
                </button>
              )}
              {readingMode !== "vertical" && <div className="w-6 h-px bg-border" />}

              <button onClick={() => changeMode("single")} className={`p-2.5 rounded-xl transition-all ${readingMode === "single" ? "bg-accent text-white" : "text-muted-foreground hover:text-foreground"}`} aria-pressed={readingMode === "single"} aria-label="Single page view" title="Single Page"><FileText size={18} /></button>
              <button onClick={() => changeMode("double")} className={`p-2.5 rounded-xl transition-all ${readingMode === "double" ? "bg-accent text-white" : "text-muted-foreground hover:text-foreground"}`} aria-pressed={readingMode === "double"} aria-label="Double page view" title="Double Page"><Book size={18} /></button>
              <button onClick={() => changeMode("vertical")} className={`p-2.5 rounded-xl transition-all ${readingMode === "vertical" ? "bg-accent text-white" : "text-muted-foreground hover:text-foreground"}`} aria-pressed={readingMode === "vertical"} aria-label="Vertical scroll view" title="Vertical Scroll"><ScrollText size={18} /></button>
              
              <div className="w-6 h-px bg-border" />
              <button
                onClick={() => toggleFullscreen()}
                className="p-2.5 rounded-xl text-muted-foreground hover:text-foreground transition-all cursor-pointer z-[60]"
                aria-label="Toggle fullscreen" title="Toggle Fullscreen"
              >
                {isFullscreen ? <Minimize2 size={18} /> : <Maximize2 size={18} />}
              </button>
            </div>
          </div>
        </>
      )}

      {/* Content Area */}
      <div 
        className={`flex-1 w-full overflow-y-auto scroll-smooth scrollbar-hide ${readingMode === "vertical" ? "" : "flex items-center justify-center"}`}
        onClick={readingMode === "vertical" ? (e) => {
          if ((e.target as HTMLElement).closest('button')) return;
          setShowControls(p => !p);
        } : undefined}
      >
        {readingMode === "vertical" ? (
          <div
            className="max-w-3xl w-full mx-auto"
            style={{ padding: "0 0 8rem 0", transform: `scale(${zoom})`, transformOrigin: "top center" }}
          >
            {pages.map((page, idx) => (
              <div key={idx} className="relative flex items-center justify-center bg-black">
                {!loadedImages.has(idx) && <Loader2 className="animate-spin text-muted-foreground/30" size={32} />}
                <img 
                  src={getProxyUrl(page)} 
                  alt={`Page ${idx + 1}`} 
                  className={`w-full h-auto block transition-opacity duration-300 ${loadedImages.has(idx) ? "opacity-100" : "opacity-0"}`}
                  style={{ display: "block" }}
                  onLoad={() => setLoadedImages(prev => new Set(prev).add(idx))}
                />
              </div>
            ))}
            <div className="pt-20 pb-10 flex justify-center">
              {hasNextChapter ? (
                <button onClick={handleNextChapter} className="flex items-center gap-2 px-12 py-4 bg-accent text-white rounded-full font-semibold text-sm shadow-2xl">
                  Next Chapter <ChevronRight size={18} />
                </button>
              ) : (
                <button onClick={handleFinish} className="px-12 py-4 bg-accent text-white rounded-full font-semibold text-sm shadow-2xl">Finish Reading</button>
              )}
            </div>
          </div>
        ) : (
          <div className="relative w-full h-full flex items-center justify-center p-4 lg:p-8">
            {/* Tap Zones: Left Zone (Next in RTL, Prev in LTR) */}
            <div 
              className={`absolute inset-y-0 left-0 w-1/4 z-10 ${readingDirection === 'rtl' ? 'cursor-e-resize' : 'cursor-w-resize'}`} 
              onClick={readingDirection === "rtl" ? handleNext : handlePrev} 
              onKeyDown={(e) => {
                if (e.key === 'Enter' || e.key === ' ') {
                  e.preventDefault();
                  if (readingDirection === "rtl") handleNext(); else handlePrev();
                }
              }}
              role="button"
              tabIndex={0}
              aria-label={readingDirection === "rtl" ? "Next page" : "Previous page"}
            />
            {/* Right Zone (Prev in RTL, Next in LTR) */}
            <div 
              className={`absolute inset-y-0 right-0 w-1/4 z-10 ${readingDirection === 'rtl' ? 'cursor-w-resize' : 'cursor-e-resize'}`} 
              onClick={readingDirection === "rtl" ? handlePrev : handleNext} 
              onKeyDown={(e) => {
                if (e.key === 'Enter' || e.key === ' ') {
                  e.preventDefault();
                  if (readingDirection === "rtl") handlePrev(); else handleNext();
                }
              }}
              role="button"
              tabIndex={0}
              aria-label={readingDirection === "rtl" ? "Previous page" : "Next page"}
            />
            {/* Center Zone */}
            <div 
              className="absolute inset-y-0 left-1/4 right-1/4 z-10 cursor-pointer" 
              onClick={(e) => {
                if ((e.target as HTMLElement).closest('button')) return;
                setShowControls(p => !p);
              }}
              onKeyDown={(e) => {
                if (e.key === 'Enter' || e.key === ' ') {
                  e.preventDefault();
                  setShowControls(p => !p);
                }
              }}
              role="button"
              tabIndex={0}
              aria-label="Toggle controls"
            />

            <div
              className={`flex items-center justify-center h-full gap-1 transition-all ${readingMode === "double" ? "w-full" : "max-w-3xl"}`}
              style={{ transform: `scale(${zoom})`, transformOrigin: "center center" }}
            >
              {readingMode === "double" ? (
                readingDirection === "rtl" ? (
                  <>
                    {/* RTL Left Box (Higher Index Page B: currentPage + 1) */}
                    <div className="flex-1 h-full flex items-center justify-end">
                      {currentPage + 1 < pages.length && (
                        <div className="relative max-h-full">
                          {!loadedImages.has(currentPage + 1) && <div className="absolute inset-0 flex items-center justify-center bg-foreground/[0.02]"><Loader2 className="animate-spin text-muted-foreground/30" size={32} /></div>}
                          <img 
                            key={pages[currentPage + 1]} 
                            src={getProxyUrl(pages[currentPage + 1])} 
                            className="transition-all duration-300 object-contain bg-black max-h-[calc(100vh-64px)]" 
                          />
                        </div>
                      )}
                    </div>
                    {/* RTL Right Box (Lower Index Page A: currentPage) */}
                    <div className="flex-1 h-full flex items-center justify-start border-l border-border">
                      <div className="relative max-h-full">
                        {!loadedImages.has(currentPage) && <div className="absolute inset-0 flex items-center justify-center bg-foreground/[0.02]"><Loader2 className="animate-spin text-muted-foreground/30" size={32} /></div>}
                        <img 
                          key={pages[currentPage]} 
                          src={getProxyUrl(pages[currentPage])} 
                          className="transition-all duration-300 object-contain bg-black max-h-[calc(100vh-64px)]" 
                        />
                      </div>
                    </div>
                  </>
                ) : (
                  <>
                    {/* LTR Left Box (Lower Index Page A: currentPage) */}
                    <div className="flex-1 h-full flex items-center justify-end">
                      <div className="relative max-h-full">
                        {!loadedImages.has(currentPage) && <div className="absolute inset-0 flex items-center justify-center bg-foreground/[0.02]"><Loader2 className="animate-spin text-muted-foreground/30" size={32} /></div>}
                        <img 
                          key={pages[currentPage]} 
                          src={getProxyUrl(pages[currentPage])} 
                          className="transition-all duration-300 object-contain bg-black max-h-[calc(100vh-64px)]" 
                        />
                      </div>
                    </div>
                    {/* LTR Right Box (Higher Index Page B: currentPage + 1) */}
                    {currentPage + 1 < pages.length && (
                      <div className="flex-1 h-full flex items-center justify-start border-l border-border">
                        <div className="relative max-h-full">
                          {!loadedImages.has(currentPage + 1) && <div className="absolute inset-0 flex items-center justify-center bg-foreground/[0.02]"><Loader2 className="animate-spin text-muted-foreground/30" size={32} /></div>}
                          <img 
                            key={pages[currentPage + 1]} 
                            src={getProxyUrl(pages[currentPage + 1])} 
                            className="transition-all duration-300 object-contain bg-black max-h-[calc(100vh-64px)]" 
                          />
                        </div>
                      </div>
                    )}
                  </>
                )
              ) : (
                <div className="relative h-full flex items-center justify-center">
                  {!loadedImages.has(currentPage) && <div className="absolute inset-0 flex items-center justify-center bg-foreground/[0.02]"><Loader2 className="animate-spin text-muted-foreground/30" size={32} /></div>}
                  <img 
                    key={pages[currentPage]} 
                    src={getProxyUrl(pages[currentPage])} 
                    className="transition-all duration-300 object-contain bg-black max-h-[calc(100vh-64px)]" 
                  />
                </div>
              )}
            </div>
          </div>
        )}
      </div>
      {/* Mobile Footer */}
      {isMobile && readingMode !== "vertical" && (
        <div className={`fixed bottom-6 inset-x-0 z-50 flex justify-center transition-opacity duration-300 ${showControls ? "opacity-100 pointer-events-auto" : "opacity-0 pointer-events-none"}`}>
          <div className="w-[calc(100%-2rem)] max-w-md bg-surface border border-border p-4 rounded-2xl flex flex-col space-y-4">
            {/* Page Slider */}
            {pages.length <= 60 ? (
              <div className="flex w-full gap-[2px]" style={{ direction: readingDirection === "rtl" ? "rtl" : "ltr" }}>
                {pages.map((_, idx) => (
                  <button
                    key={idx}
                    onClick={() => setCurrentPage(idx)}
                    className={`h-[4px] flex-1 rounded-full ${idx < currentPage ? "bg-accent" : idx === currentPage ? "bg-foreground" : "bg-foreground/20"}`}
                  />
                ))}
              </div>
            ) : (
              <input
                type="range"
                min="0"
                max={pages.length - 1}
                value={currentPage}
                onChange={(e) => setCurrentPage(parseInt(e.target.value))}
                className="w-full h-1.5 bg-foreground/10 rounded-full appearance-none accent-accent"
                style={{ direction: readingDirection === "rtl" ? "rtl" : "ltr" }}
              />
            )}
            
            <div className="flex items-center justify-between">
              <span className="text-sm font-semibold text-muted-foreground">
                {currentPage + 1} / {pages.length}
              </span>
              
              {/* Finish/Next Chapter Action */}
              {((readingMode === "single" && currentPage === pages.length - 1) ||
                (readingMode === "double" && currentPage >= pages.length - 2)) && (
                hasNextChapter ? (
                  <button onClick={handleNextChapter} className="flex items-center gap-1.5 px-4 py-2 bg-accent text-white rounded-lg font-bold text-xs animate-fade-in">
                    Next <ChevronRight size={16} />
                  </button>
                ) : (
                  <button onClick={handleFinish} className="px-4 py-2 bg-accent text-white rounded-lg font-bold text-xs animate-fade-in">Finish</button>
                )
              )}
            </div>
          </div>
        </div>
      )}
    </div>,
    document.body,
  );
}
