import { useEffect, useState } from "react";
import { X, Keyboard } from "lucide-react";

// Keep these in sync with the real handlers:
//   global  -> hooks/useKeyboardShortcuts.ts and App.tsx (Alt+Left)
//   reader  -> components/media/MangaReader.tsx
const GLOBAL_SHORTCUTS: { keys: string[]; label: string }[] = [
  { keys: ["1", "–", "8"], label: "Jump to a view (Home … Downloads)" },
  { keys: ["H"], label: "Home" },
  { keys: ["/"], label: "Search" },
  { keys: ["L"], label: "My Lists" },
  { keys: ["D"], label: "Downloads" },
  { keys: ["N"], label: "Notifications" },
  { keys: ["Alt", "←"], label: "Back" },
  { keys: ["Esc"], label: "Close the detail page" },
  { keys: ["?"], label: "Show this help" },
];

const READER_SHORTCUTS: { keys: string[]; label: string }[] = [
  { keys: ["→", "Space"], label: "Next page (Previous in right-to-left)" },
  { keys: ["←"], label: "Previous page (Next in right-to-left)" },
  { keys: ["F"], label: "Toggle fullscreen" },
  { keys: ["M"], label: "Cycle reading mode (single / double / scroll)" },
  { keys: ["Esc"], label: "Exit fullscreen, then close the reader" },
];

function Kbd({ children }: { children: React.ReactNode }) {
  return (
    <kbd className="inline-flex items-center justify-center min-w-[1.6rem] px-1.5 py-0.5 rounded-md bg-white/[0.08] border border-white/[0.12] text-[11px] font-semibold text-foreground">
      {children}
    </kbd>
  );
}

function Section({ title, rows }: { title: string; rows: { keys: string[]; label: string }[] }) {
  return (
    <div className="space-y-1.5">
      <p className="text-xs font-semibold text-muted-foreground uppercase tracking-wider">{title}</p>
      {rows.map((row) => (
        <div key={row.label} className="flex items-center justify-between gap-4 py-1">
          <span className="text-sm text-foreground/90">{row.label}</span>
          <span className="flex items-center gap-1 shrink-0">
            {row.keys.map((k, i) => (
              <Kbd key={i}>{k}</Kbd>
            ))}
          </span>
        </div>
      ))}
    </div>
  );
}

export function KeyboardShortcutsOverlay() {
  const [open, setOpen] = useState(false);

  useEffect(() => {
    const onKeyDown = (e: KeyboardEvent) => {
      const target = e.target as HTMLElement | null;
      const inField =
        !!target &&
        (target.isContentEditable ||
          target.tagName === "INPUT" ||
          target.tagName === "TEXTAREA" ||
          target.tagName === "SELECT");

      if (e.key === "?" && !inField) {
        e.preventDefault();
        setOpen((v) => !v);
        return;
      }
      // While open, Escape closes only this overlay — swallow it so it doesn't
      // also close an open detail page underneath.
      if (e.key === "Escape" && open) {
        e.preventDefault();
        e.stopImmediatePropagation();
        setOpen(false);
      }
    };
    // Capture phase so the Escape-swallow runs before the global bubble handler.
    window.addEventListener("keydown", onKeyDown, true);
    return () => window.removeEventListener("keydown", onKeyDown, true);
  }, [open]);

  if (!open) return null;

  return (
    <div
      className="fixed inset-0 z-[100] flex items-center justify-center bg-black/60 backdrop-blur-sm p-4"
      onClick={() => setOpen(false)}
    >
      <div
        className="w-full max-w-lg rounded-2xl bg-[#111114] border border-white/[0.1] shadow-2xl p-6 max-h-[85vh] overflow-y-auto"
        onClick={(e) => e.stopPropagation()}
      >
        <div className="flex items-center justify-between mb-5">
          <div className="flex items-center gap-2">
            <Keyboard size={18} className="text-accent" />
            <h2 className="text-base font-bold text-foreground">Keyboard shortcuts</h2>
          </div>
          <button
            onClick={() => setOpen(false)}
            aria-label="Close"
            className="p-1.5 rounded-lg hover:bg-white/[0.08] transition-colors text-muted-foreground"
          >
            <X size={16} />
          </button>
        </div>
        <div className="space-y-5">
          <Section title="Navigation" rows={GLOBAL_SHORTCUTS} />
          <Section title="Manga reader" rows={READER_SHORTCUTS} />
        </div>
      </div>
    </div>
  );
}
