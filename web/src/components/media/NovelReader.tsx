import { useState, useEffect, useRef } from "react";
import { motion, AnimatePresence } from "framer-motion";
import { ArrowLeft, ChevronLeft, ChevronRight, List, Settings, BookOpen, Loader2 } from "lucide-react";
import { novelApi } from "@/lib/api";
import type { NovelChapterItem } from "@/lib/types";

interface NovelReaderProps {
  title: string;
  author?: string;
  slug: string;
  /** Page that carries this volume's text. Without it there is nothing to read. */
  volumeUrl?: string;
  volumeTitle?: string;
  initialChapterIndex?: number;
  onClose: () => void;
}

type ReaderTheme = "dark" | "light" | "sepia" | "eink";

// A volume opens with covers, colour inserts and a title page — all images, no
// prose. Skip to the first section that reads like writing.
const PROSE_ENTRY = /(prologue|epilogue|afterword|chapter|part)\s*\d*/i;

function firstProseIndex(list: NovelChapterItem[]): number {
  return list.find((c) => PROSE_ENTRY.test(c.title || ""))?.index ?? list[0]?.index ?? 1;
}

export function NovelReader({
  title,
  author,
  slug,
  volumeUrl,
  volumeTitle,
  initialChapterIndex,
  onClose,
}: NovelReaderProps) {
  const [chapters, setChapters] = useState<NovelChapterItem[]>([]);
  const [currentChapterIndex, setCurrentChapterIndex] = useState<number>(initialChapterIndex ?? 1);
  const [currentChapter, setCurrentChapter] = useState<NovelChapterItem | null>(null);
  const [isLoading, setIsLoading] = useState<boolean>(true);
  const [error, setError] = useState<string | null>(null);
  const [fontSize, setFontSize] = useState<number>(18);
  const [fontFamily, setFontFamily] = useState<"serif" | "sans">("serif");
  const [theme, setTheme] = useState<ReaderTheme>("dark");
  const [showToc, setShowToc] = useState<boolean>(false);
  const [showSettings, setShowSettings] = useState<boolean>(false);

  const contentRef = useRef<HTMLDivElement>(null);

  // The volume page carries its own table of contents; load it once per volume.
  useEffect(() => {
    let isCancelled = false;

    if (!volumeUrl) {
      setChapters([]);
      setCurrentChapter(null);
      setIsLoading(false);
      setError("No readable text source is available for this volume.");
      return;
    }

    setIsLoading(true);
    setError(null);

    novelApi
      .getNovelToc(volumeUrl, volumeTitle)
      .then((toc) => {
        if (isCancelled) return;
        const list = toc.chapters ?? [];
        setChapters(list);
        if (list.length === 0) {
          setIsLoading(false);
          setError("This volume has no chapters listed at the source.");
        } else if (initialChapterIndex) {
          setCurrentChapterIndex(Math.min(Math.max(initialChapterIndex, 1), list.length));
        } else {
          setCurrentChapterIndex(firstProseIndex(list));
        }
      })
      .catch((err) => {
        if (isCancelled) return;
        console.error("Failed to load novel table of contents:", err);
        setChapters([]);
        setIsLoading(false);
        setError(String(err));
      });

    return () => {
      isCancelled = true;
    };
  }, [volumeUrl, volumeTitle, initialChapterIndex]);

  useEffect(() => {
    let isCancelled = false;

    const activeCh = chapters.find((c) => c.index === currentChapterIndex);
    if (!activeCh?.url) return;

    setIsLoading(true);
    setError(null);

    novelApi
      .getNovelChapter(slug, String(currentChapterIndex), activeCh.url)
      .then((data) => {
        if (isCancelled) return;
        setCurrentChapter(data);
        setIsLoading(false);
        if (contentRef.current) {
          contentRef.current.scrollTop = 0;
        }
      })
      .catch((err) => {
        if (isCancelled) return;
        console.error("Failed to load novel chapter:", err);
        setCurrentChapter(null);
        setIsLoading(false);
        setError(String(err));
      });

    return () => {
      isCancelled = true;
    };
  }, [slug, currentChapterIndex, chapters]);

  // Keyboard navigation
  useEffect(() => {
    const handleKeyDown = (e: KeyboardEvent) => {
      if (e.key === "Escape") {
        if (showToc) setShowToc(false);
        else if (showSettings) setShowSettings(false);
        else onClose();
      } else if (e.key === "ArrowLeft" || e.key === "[") {
        if (currentChapterIndex > 1) setCurrentChapterIndex((prev) => prev - 1);
      } else if (e.key === "ArrowRight" || e.key === "]") {
        if (currentChapterIndex < chapters.length) {
          setCurrentChapterIndex((prev) => prev + 1);
        }
      }
    };
    window.addEventListener("keydown", handleKeyDown);
    return () => window.removeEventListener("keydown", handleKeyDown);
  }, [onClose, showToc, showSettings, currentChapterIndex, chapters.length]);

  const themeClasses: Record<ReaderTheme, { bg: string; text: string; header: string; card: string }> = {
    dark: {
      bg: "bg-[#0d0d0f]",
      text: "text-[#d4d4d8]",
      header: "bg-[#141418]/90 border-border/40",
      card: "bg-[#1a1a22] border-border/60",
    },
    light: {
      bg: "bg-[#fcfcfc]",
      text: "text-[#18181b]",
      header: "bg-[#f4f4f5]/90 border-[#e4e4e7]",
      card: "bg-[#ffffff] border-[#e4e4e7]",
    },
    sepia: {
      bg: "bg-[#f4ecd8]",
      text: "text-[#433422]",
      header: "bg-[#ebe0c8]/90 border-[#ded1b6]",
      card: "bg-[#f9f4e8] border-[#ded1b6]",
    },
    eink: {
      bg: "bg-[#ffffff]",
      text: "text-[#000000]",
      header: "bg-[#ffffff] border-[#000000]",
      card: "bg-[#ffffff] border-[#000000]",
    },
  };

  const currentTheme = themeClasses[theme];

  return (
    <div className={`fixed inset-0 z-50 flex flex-col ${currentTheme.bg} ${currentTheme.text} transition-colors duration-200 select-text`}>
      {/* Top Navigation Bar */}
      <header className={`flex items-center justify-between px-4 py-3 border-b backdrop-blur-md z-20 ${currentTheme.header}`}>
        <div className="flex items-center gap-3">
          <button
            onClick={onClose}
            className="flex items-center gap-1.5 text-xs font-medium px-2.5 py-1.5 rounded-md hover:bg-black/10 transition-colors cursor-pointer"
            title="Exit Reader (Esc)"
          >
            <ArrowLeft size={16} />
            <span className="hidden sm:inline">Back</span>
          </button>
          <div className="h-4 w-[1px] bg-current opacity-20" />
          <div className="max-w-[280px] sm:max-w-md truncate">
            <h1 className="text-xs font-bold truncate">{title}</h1>
            {author && <p className="text-[11px] opacity-70 truncate">By {author}</p>}
          </div>
        </div>

        <div className="flex items-center gap-1 sm:gap-2">
          {chapters.length > 0 && (
            <button
              onClick={() => setShowToc(!showToc)}
              className={`flex items-center gap-1.5 px-2.5 py-1.5 rounded-md text-xs font-medium transition-colors cursor-pointer ${
                showToc ? "bg-accent text-accent-foreground" : "hover:bg-black/10"
              }`}
              title="Table of Contents"
            >
              <List size={15} />
              <span className="hidden sm:inline">Chapters ({chapters.length})</span>
            </button>
          )}

          <button
            onClick={() => setShowSettings(!showSettings)}
            className={`p-2 rounded-md transition-colors cursor-pointer ${
              showSettings ? "bg-accent text-accent-foreground" : "hover:bg-black/10"
            }`}
            title="Reader Display Settings"
          >
            <Settings size={16} />
          </button>
        </div>
      </header>

      {/* Settings Popover */}
      {showSettings && (
        <div className={`absolute top-14 right-4 z-30 w-72 rounded-xl p-4 shadow-2xl border ${currentTheme.card} backdrop-blur-md`}>
          <h3 className="text-xs font-bold uppercase tracking-wider mb-3 opacity-80">Display Options</h3>

          {/* Theme selection */}
          <div className="mb-4">
            <label className="block text-[11px] font-mono opacity-70 mb-1.5">Theme</label>
            <div className="grid grid-cols-4 gap-1.5 text-xs font-medium">
              {(["dark", "light", "sepia", "eink"] as ReaderTheme[]).map((t) => (
                <button
                  key={t}
                  onClick={() => setTheme(t)}
                  className={`py-1.5 rounded-md border text-center capitalize cursor-pointer transition-all ${
                    theme === t ? "border-accent font-bold" : "border-transparent opacity-70 hover:opacity-100"
                  }`}
                  style={{
                    backgroundColor:
                      t === "dark" ? "#18181b" : t === "light" ? "#f4f4f5" : t === "sepia" ? "#ebdcb9" : "#ffffff",
                    color: t === "dark" ? "#fafafa" : "#18181b",
                  }}
                >
                  {t}
                </button>
              ))}
            </div>
          </div>

          {/* Font family */}
          <div className="mb-4">
            <label className="block text-[11px] font-mono opacity-70 mb-1.5">Font Style</label>
            <div className="grid grid-cols-2 gap-2">
              <button
                onClick={() => setFontFamily("serif")}
                className={`py-1.5 px-3 rounded-md border text-xs font-serif text-center cursor-pointer ${
                  fontFamily === "serif" ? "border-accent bg-accent/15" : "border-border/40 opacity-70"
                }`}
              >
                Serif (Book)
              </button>
              <button
                onClick={() => setFontFamily("sans")}
                className={`py-1.5 px-3 rounded-md border text-xs font-sans text-center cursor-pointer ${
                  fontFamily === "sans" ? "border-accent bg-accent/15" : "border-border/40 opacity-70"
                }`}
              >
                Sans-Serif
              </button>
            </div>
          </div>

          {/* Font Size */}
          <div>
            <div className="flex justify-between items-center text-[11px] font-mono opacity-70 mb-1.5">
              <span>Font Size</span>
              <span>{fontSize}px</span>
            </div>
            <div className="flex items-center gap-2">
              <button
                onClick={() => setFontSize((f) => Math.max(14, f - 2))}
                className="w-8 h-8 rounded border border-border/50 flex items-center justify-center font-bold hover:bg-black/10 cursor-pointer"
              >
                A-
              </button>
              <input
                type="range"
                min={14}
                max={32}
                step={2}
                value={fontSize}
                onChange={(e) => setFontSize(Number(e.target.value))}
                className="flex-1 accent-accent"
              />
              <button
                onClick={() => setFontSize((f) => Math.min(32, f + 2))}
                className="w-8 h-8 rounded border border-border/50 flex items-center justify-center font-bold hover:bg-black/10 cursor-pointer"
              >
                A+
              </button>
            </div>
          </div>
        </div>
      )}

      {/* Main Reader Layout */}
      <div className="flex-1 flex overflow-hidden relative">
        {/* Table of Contents Drawer */}
        <AnimatePresence>
          {showToc && (
            <motion.aside
              initial={{ x: -300, opacity: 0 }}
              animate={{ x: 0, opacity: 1 }}
              exit={{ x: -300, opacity: 0 }}
              className={`w-80 h-full border-r overflow-y-auto z-10 shrink-0 ${currentTheme.card}`}
            >
              <div className="p-4 border-b border-border/40 sticky top-0 backdrop-blur-md">
                <h2 className="text-xs font-bold uppercase tracking-wider">Table of Contents</h2>
              </div>
              <div className="p-2 space-y-1">
                {chapters.map((ch) => (
                  <button
                    key={ch.index}
                    onClick={() => {
                      setCurrentChapterIndex(ch.index);
                      setShowToc(false);
                    }}
                    className={`w-full text-left px-3 py-2 rounded-md text-xs transition-colors cursor-pointer line-clamp-1 ${
                      ch.index === currentChapterIndex
                        ? "bg-accent text-accent-foreground font-semibold"
                        : "opacity-75 hover:opacity-100 hover:bg-black/5"
                    }`}
                  >
                    {ch.title || `Chapter ${ch.index}`}
                  </button>
                ))}
              </div>
            </motion.aside>
          )}
        </AnimatePresence>

        {/* Reader Content Body */}
        <div ref={contentRef} className="flex-1 overflow-y-auto px-4 py-8 sm:py-12 scrollbar-thin">
          <div className="max-w-[760px] mx-auto">
            {isLoading ? (
              <div className="flex flex-col items-center justify-center py-32 gap-3 opacity-60">
                <Loader2 className="animate-spin text-accent" size={32} />
                <p className="meta-mono text-xs">Loading Chapter {currentChapterIndex}...</p>
              </div>
            ) : currentChapter ? (
              <article
                className={`prose ${fontFamily === "serif" ? "font-serif" : "font-sans"} leading-relaxed`}
                style={{ fontSize: `${fontSize}px` }}
              >
                <header className="mb-8 pb-4 border-b border-current/20 text-center">
                  <span className="text-[11px] meta-mono uppercase tracking-widest opacity-60 block mb-1">
                    {currentChapter.volume_name || volumeTitle || title}
                  </span>
                  <h2 className="text-2xl font-bold tracking-tight">
                    {chapters.find((c) => c.index === currentChapterIndex)?.title ||
                      currentChapter.title ||
                      `Chapter ${currentChapterIndex}`}
                  </h2>
                </header>

                <div
                  className="novel-content space-y-4"
                  dangerouslySetInnerHTML={{
                    __html: currentChapter.content_html || `<p>${currentChapter.content_text || ""}</p>`,
                  }}
                />
              </article>
            ) : (
              <div className="text-center py-20">
                <BookOpen size={28} className="mx-auto mb-3 opacity-40" />
                <p className="text-sm font-semibold">No chapter text</p>
                <p className="meta-mono text-xs opacity-60 mt-1 max-w-md mx-auto break-words">
                  {error || "The source returned nothing for this chapter."}
                </p>
              </div>
            )}

            {/* Bottom Chapter Navigation Controls */}
            {!isLoading && chapters.length > 0 && (
              <nav className="flex items-center justify-between mt-16 pt-6 border-t border-current/20">
                <button
                  onClick={() => setCurrentChapterIndex((idx) => Math.max(1, idx - 1))}
                  disabled={currentChapterIndex <= 1}
                  className="flex items-center gap-2 px-4 py-2 rounded-lg border border-current/30 text-xs font-semibold disabled:opacity-30 hover:bg-black/5 transition-colors cursor-pointer"
                >
                  <ChevronLeft size={16} />
                  <span>Previous Chapter</span>
                </button>

                <span className="meta-mono text-xs opacity-70">
                  Chapter {currentChapterIndex} {chapters.length > 0 && `of ${chapters.length}`}
                </span>

                <button
                  onClick={() => setCurrentChapterIndex((idx) => idx + 1)}
                  disabled={chapters.length > 0 && currentChapterIndex >= chapters.length}
                  className="flex items-center gap-2 px-4 py-2 rounded-lg border border-current/30 text-xs font-semibold disabled:opacity-30 hover:bg-black/5 transition-colors cursor-pointer"
                >
                  <span>Next Chapter</span>
                  <ChevronRight size={16} />
                </button>
              </nav>
            )}
          </div>
        </div>
      </div>
    </div>
  );
}
