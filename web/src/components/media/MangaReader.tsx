"use client";

import { useEffect, useState, useRef, useCallback } from "react";
import { createPortal } from "react-dom";
import { X, ChevronLeft, ChevronRight, Loader2, Maximize2, Minimize2, Book, FileText, ScrollText, BookX } from "lucide-react";
import { apiOrigin, mediaApi } from "@/lib/api";

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

  // Load reading direction preference on mount and clear presence on unmount
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

  // Load saved reading mode on mount
  useEffect(() => {
    const savedMode = localStorage.getItem("anicat_manga_reading_mode") as ReadingMode | null;
    if (savedMode === "single" || savedMode === "double" || savedMode === "vertical") {
      // A "double" preference saved from a desktop session isn't offered (or
      // usable) on a phone — fall back to single rather than rendering an
      // illegible squished two-page spread.
      setReadingMode(isMobile && savedMode === "double" ? "single" : savedMode);
    }
  }, [isMobile]);

  // Sync fullscreen state with browser
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

  // Persist current page
  useEffect(() => {
    if (!loading && pages.length > 0) {
      localStorage.setItem(`anicat_manga_${mediaId}_${chapterNumber}_page`, currentPage.toString());
    }
  }, [currentPage, mediaId, chapterNumber, loading, pages.length]);

  useEffect(() => {
    setLoading(true);
    setError(null);
    mediaApi.getChapterPages(mediaId, chapterNumber)
      .then(data => {
        setPages(data.thumbnails || []);
        setLoading(false);
        
        // Restore saved page if not provided in props
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

  // Pre-load next pages logic
  useEffect(() => {
    if (pages.length > 0) {
      const nextPages = pages.slice(currentPage, currentPage + 6);
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
    }
  }, [currentPage, pages, loadedImages]);

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

  const handleMouseMove = () => {
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
          <button onClick={onClose} className="px-6 py-2 bg-white/10 hover:bg-white/20 text-white rounded-lg transition-colors font-bold">
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
          <button onClick={onClose} className="px-6 py-2 bg-white/10 hover:bg-white/20 text-white rounded-lg transition-colors font-bold">
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
      onTouchStart={isMobile ? handleMouseMove : undefined}
      className="fixed inset-0 z-[200] bg-[#050505] flex flex-col items-center select-none overflow-hidden transform-gpu will-change-[transform,opacity] forced-dark-container"
    >
      {/* Header Controls */}
      {isMobile ? (
        <div
          className={`fixed top-0 inset-x-0 z-50 bg-gradient-to-b from-black/95 to-transparent transition-opacity duration-300 ${showControls ? "opacity-100 pointer-events-auto" : "opacity-0 pointer-events-none"}`}
          style={{ paddingTop: "env(safe-area-inset-top)" }}
        >
          <div className="flex items-center justify-between gap-2 px-3 py-2.5">
            <button onClick={onClose} className="p-2 rounded-full bg-white/5 text-white shrink-0">
              <X size={19} />
            </button>

            <div className="flex items-center gap-1.5 min-w-0">
              {onNavigateChapter && (
                <button
                  onClick={(e) => { e.stopPropagation(); onNavigateChapter("prev"); }}
                  disabled={!hasPrevChapter}
                  className="p-1.5 rounded-lg bg-white/5 text-white disabled:opacity-20"
                >
                  <ChevronLeft size={16} />
                </button>
              )}
              <p className="text-sm font-black text-white whitespace-nowrap">Ch. {chapterNumber}</p>
              {onNavigateChapter && (
                <button
                  onClick={(e) => { e.stopPropagation(); onNavigateChapter("next"); }}
                  disabled={!hasNextChapter}
                  className="p-1.5 rounded-lg bg-white/5 text-white disabled:opacity-20"
                >
                  <ChevronRight size={16} />
                </button>
              )}
            </div>

            <div className="flex items-center gap-1 bg-black/60 backdrop-blur-xl p-1 rounded-xl border border-white/10 shrink-0">
              {readingMode !== "vertical" && (
                <button
                  onClick={() => {
                    const newDir = readingDirection === "ltr" ? "rtl" : "ltr";
                    setReadingDirection(newDir);
                    localStorage.setItem("anicat_manga_reading_direction", newDir);
                  }}
                  className="px-2 py-2 rounded-lg text-[10px] font-black tracking-wide text-accent uppercase"
                >
                  {readingDirection === "rtl" ? "RTL" : "LTR"}
                </button>
              )}
              <button onClick={() => { setReadingMode("single"); localStorage.setItem("anicat_manga_reading_mode", "single"); }} className={`p-2 rounded-lg transition-all ${readingMode === "single" ? "bg-accent text-white" : "text-gray-500"}`}><FileText size={16} /></button>
              <button onClick={() => { setReadingMode("vertical"); localStorage.setItem("anicat_manga_reading_mode", "vertical"); }} className={`p-2 rounded-lg transition-all ${readingMode === "vertical" ? "bg-accent text-white" : "text-gray-500"}`}><ScrollText size={16} /></button>
            </div>
          </div>
        </div>
      ) : (
        <div className={`fixed top-0 inset-x-0 z-50 bg-gradient-to-b from-black/95 to-transparent p-6 transition-opacity duration-300 ${showControls ? "opacity-100 pointer-events-auto" : "opacity-0 pointer-events-none"}`}>
          <div className="max-w-7xl mx-auto flex items-center justify-between">
            <div className="flex items-center space-x-6">
              <button onClick={onClose} className="p-3 rounded-xl bg-white/5 hover:bg-white/10 text-white transition-all border border-white/5">
                <X size={20} />
              </button>
              <div>
                <h2 className="text-xs font-bold text-accent uppercase tracking-[0.2em] mb-1">Chapter</h2>
                <div className="flex items-center space-x-2">
                  {onNavigateChapter && (
                    <button
                      onClick={(e) => { e.stopPropagation(); onNavigateChapter("prev"); }}
                      disabled={!hasPrevChapter}
                      className="p-1.5 rounded-lg bg-white/5 hover:bg-white/10 text-white disabled:opacity-20 disabled:cursor-not-allowed transition-all"
                      title="Previous Chapter"
                    >
                      <ChevronLeft size={16} />
                    </button>
                  )}
                  <p className="text-xl font-black text-white">{chapterNumber}</p>
                  {onNavigateChapter && (
                    <button
                      onClick={(e) => { e.stopPropagation(); onNavigateChapter("next"); }}
                      disabled={!hasNextChapter}
                      className="p-1.5 rounded-lg bg-white/5 hover:bg-white/10 text-white disabled:opacity-20 disabled:cursor-not-allowed transition-all"
                      title="Next Chapter"
                    >
                      <ChevronRight size={16} />
                    </button>
                  )}
                </div>
              </div>
            </div>

            <div className="flex items-center space-x-3 bg-black/60 backdrop-blur-xl p-1.5 rounded-2xl border border-white/10 shadow-2xl">
              {/* Reading Direction Selector */}
              {readingMode !== "vertical" && (
                <button
                  onClick={() => {
                    const newDir = readingDirection === "ltr" ? "rtl" : "ltr";
                    setReadingDirection(newDir);
                    localStorage.setItem("anicat_manga_reading_direction", newDir);
                  }}
                  className="px-3.5 py-2.5 rounded-xl text-[10px] font-black tracking-widest text-accent hover:bg-white/5 transition-all uppercase cursor-pointer"
                  title="Toggle Reading Direction (RTL/LTR)"
                >
                  {readingDirection === "rtl" ? "RTL" : "LTR"}
                </button>
              )}
              {readingMode !== "vertical" && <div className="w-px h-6 bg-white/10" />}

              <button onClick={() => { setReadingMode("single"); localStorage.setItem("anicat_manga_reading_mode", "single"); }} className={`p-2.5 rounded-xl transition-all ${readingMode === "single" ? "bg-accent text-white" : "text-gray-500 hover:text-white"}`}><FileText size={18} /></button>
              <button onClick={() => { setReadingMode("double"); localStorage.setItem("anicat_manga_reading_mode", "double"); }} className={`p-2.5 rounded-xl transition-all ${readingMode === "double" ? "bg-accent text-white" : "text-gray-500 hover:text-white"}`}><Book size={18} /></button>
              <button onClick={() => { setReadingMode("vertical"); localStorage.setItem("anicat_manga_reading_mode", "vertical"); }} className={`p-2.5 rounded-xl transition-all ${readingMode === "vertical" ? "bg-accent text-white" : "text-gray-500 hover:text-white"}`}><ScrollText size={18} /></button>
              {/* Fullscreen toggle is meaningless once the PWA is already running
                  standalone (no browser chrome to hide), and iOS Safari's
                  requestFullscreen support for arbitrary elements is unreliable. */}
              <div className="w-px h-6 bg-white/10 mx-1" />
              <button
                onClick={() => {
                  toggleFullscreen();
                }}
                className="p-2.5 rounded-xl text-gray-500 hover:text-white transition-all cursor-pointer z-[60]"
              >
                {isFullscreen ? <Minimize2 size={18} /> : <Maximize2 size={18} />}
              </button>
            </div>
          </div>
        </div>
      )}

      {/* Content Area */}
      <div className={`flex-1 w-full overflow-y-auto scroll-smooth scrollbar-hide ${readingMode === "vertical" ? "" : "flex items-center justify-center"}`}>
        {readingMode === "vertical" ? (
          <div className="max-w-3xl w-full mx-auto" style={{ padding: "0 0 8rem 0" }}>
            {pages.map((page, idx) => (
              <div key={idx} className="relative flex items-center justify-center bg-black">
                {!loadedImages.has(idx) && <Loader2 className="animate-spin text-white/10" size={32} />}
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
              <button onClick={handleFinish} className="px-12 py-4 bg-accent text-white rounded-full font-black text-sm shadow-2xl">Finish Reading</button>
            </div>
          </div>
        ) : (
          <div className="relative w-full h-full flex items-center justify-center p-4 lg:p-8">
            {/* Tap Zones: Left Zone (Next in RTL, Prev in LTR) */}
            <div 
              className={`absolute inset-y-0 left-0 w-1/4 z-10 ${readingDirection === 'rtl' ? 'cursor-e-resize' : 'cursor-w-resize'}`} 
              onClick={readingDirection === "rtl" ? handleNext : handlePrev} 
            />
            {/* Right Zone (Prev in RTL, Next in LTR) */}
            <div 
              className={`absolute inset-y-0 right-0 w-1/4 z-10 ${readingDirection === 'rtl' ? 'cursor-w-resize' : 'cursor-e-resize'}`} 
              onClick={readingDirection === "rtl" ? handlePrev : handleNext} 
            />

            <div className={`flex items-center justify-center h-full gap-1 transition-all ${readingMode === "double" ? "w-full" : "max-w-3xl"}`}>
              {readingMode === "double" ? (
                readingDirection === "rtl" ? (
                  <>
                    {/* RTL Left Box (Higher Index Page B: currentPage + 1) */}
                    <div className="flex-1 h-full flex items-center justify-end">
                      {currentPage + 1 < pages.length && (
                        <div className="relative max-h-full">
                          {!loadedImages.has(currentPage + 1) && <div className="absolute inset-0 flex items-center justify-center bg-white/[0.02]"><Loader2 className="animate-spin text-white/10" size={32} /></div>}
                          <img 
                            key={pages[currentPage + 1]} 
                            src={getProxyUrl(pages[currentPage + 1])} 
                            className="transition-all duration-300 object-contain bg-black shadow-2xl max-h-[calc(100vh-64px)]" 
                          />
                        </div>
                      )}
                    </div>
                    {/* RTL Right Box (Lower Index Page A: currentPage) */}
                    <div className="flex-1 h-full flex items-center justify-start border-l border-white/5">
                      <div className="relative max-h-full">
                        {!loadedImages.has(currentPage) && <div className="absolute inset-0 flex items-center justify-center bg-white/[0.02]"><Loader2 className="animate-spin text-white/10" size={32} /></div>}
                        <img 
                          key={pages[currentPage]} 
                          src={getProxyUrl(pages[currentPage])} 
                          className="transition-all duration-300 object-contain bg-black shadow-2xl max-h-[calc(100vh-64px)]" 
                        />
                      </div>
                    </div>
                  </>
                ) : (
                  <>
                    {/* LTR Left Box (Lower Index Page A: currentPage) */}
                    <div className="flex-1 h-full flex items-center justify-end">
                      <div className="relative max-h-full">
                        {!loadedImages.has(currentPage) && <div className="absolute inset-0 flex items-center justify-center bg-white/[0.02]"><Loader2 className="animate-spin text-white/10" size={32} /></div>}
                        <img 
                          key={pages[currentPage]} 
                          src={getProxyUrl(pages[currentPage])} 
                          className="transition-all duration-300 object-contain bg-black shadow-2xl max-h-[calc(100vh-64px)]" 
                        />
                      </div>
                    </div>
                    {/* LTR Right Box (Higher Index Page B: currentPage + 1) */}
                    {currentPage + 1 < pages.length && (
                      <div className="flex-1 h-full flex items-center justify-start border-l border-white/5">
                        <div className="relative max-h-full">
                          {!loadedImages.has(currentPage + 1) && <div className="absolute inset-0 flex items-center justify-center bg-white/[0.02]"><Loader2 className="animate-spin text-white/10" size={32} /></div>}
                          <img 
                            key={pages[currentPage + 1]} 
                            src={getProxyUrl(pages[currentPage + 1])} 
                            className="transition-all duration-300 object-contain bg-black shadow-2xl max-h-[calc(100vh-64px)]" 
                          />
                        </div>
                      </div>
                    )}
                  </>
                )
              ) : (
                <div className="relative h-full flex items-center justify-center">
                  {!loadedImages.has(currentPage) && <div className="absolute inset-0 flex items-center justify-center bg-white/[0.02]"><Loader2 className="animate-spin text-white/10" size={32} /></div>}
                  <img 
                    key={pages[currentPage]} 
                    src={getProxyUrl(pages[currentPage])} 
                    className="transition-all duration-300 object-contain bg-black shadow-2xl max-h-[calc(100vh-64px)]" 
                  />
                </div>
              )}
            </div>
          </div>
        )}
      </div>

      {/* Footer */}
      {readingMode !== "vertical" && (
        <div className={`fixed bottom-0 inset-x-0 z-50 bg-gradient-to-t from-black/95 to-transparent p-8 transition-opacity duration-300 ${showControls ? "opacity-100 pointer-events-auto" : "opacity-0 pointer-events-none"}`}>
          <div className="max-w-5xl mx-auto flex flex-col space-y-6">
            {/* In RTL, the range slider is visually reversed to match page numbering right-to-left */}
            <input 
              type="range" 
              min="0" 
              max={pages.length - 1} 
              value={currentPage} 
              onChange={(e) => setCurrentPage(parseInt(e.target.value))} 
              className="w-full h-1.5 bg-white/10 rounded-full appearance-none cursor-pointer accent-accent transform-gpu"
              style={{ direction: readingDirection === "rtl" ? "rtl" : "ltr" }}
            />
            <div className="flex items-center justify-between">
              <div className="flex items-center space-x-4">
                <button 
                  onClick={readingDirection === "rtl" ? handleNext : handlePrev} 
                  disabled={readingDirection === "rtl" ? currentPage >= pages.length - (readingMode === "double" ? 2 : 1) : currentPage === 0} 
                  className="p-3 rounded-xl bg-white/5 hover:bg-white/10 text-white disabled:opacity-20 cursor-pointer"
                  title={readingDirection === "rtl" ? "Next Page" : "Previous Page"}
                >
                  <ChevronLeft size={24} />
                </button>
                <button 
                  onClick={readingDirection === "rtl" ? handlePrev : handleNext} 
                  disabled={readingDirection === "rtl" ? currentPage === 0 : currentPage >= pages.length - (readingMode === "double" ? 2 : 1)} 
                  className="p-3 rounded-xl bg-white/5 hover:bg-white/10 text-white disabled:opacity-20 cursor-pointer"
                  title={readingDirection === "rtl" ? "Previous Page" : "Next Page"}
                >
                  <ChevronRight size={24} />
                </button>
                <div className="text-sm font-black text-white/40 tabular-nums">
                  <span className="text-white">
                    {readingDirection === "rtl" && readingMode === "double" && currentPage + 1 < pages.length 
                      ? `${currentPage + 2}-${currentPage + 1}` 
                      : (readingMode === "double" && currentPage + 1 < pages.length 
                          ? `${currentPage + 1}-${currentPage + 2}` 
                          : `${currentPage + 1}`)}
                  </span> / {pages.length}
                </div>
              </div>
              {((readingMode === "single" && currentPage === pages.length - 1) || 
                (readingMode === "double" && currentPage >= pages.length - 2)) && (
                <button onClick={handleFinish} className="px-10 py-3.5 bg-accent text-white rounded-2xl font-black text-sm shadow-2xl animate-fade-in cursor-pointer">Finish Reading</button>
              )}
            </div>
          </div>
        </div>
      )}
    </div>,
    document.body,
  );
}
