import { useEffect } from "react";
import { useAppStore } from "@/stores/app";
import type { ViewType } from "@/lib/types";

const VIEW_KEYS = [
  "home", "search", "lists", "schedule",
  "notifications", "profile", "settings", "downloads",
] as const;

const LETTER_SHORTCUTS: Record<string, ViewType> = {
  "h": "home",
  "/": "search",
  "l": "lists",
  "d": "downloads",
  "n": "notifications",
  "m": "manga",
};

export function useKeyboardShortcuts() {
  const setCurrentView = useAppStore((s) => s.setCurrentView);
  const closeDetail = useAppStore((s) => s.closeDetail);
  const selectedItem = useAppStore((s) => s.selectedItem);
  const setPaletteOpen = useAppStore((s) => s.setPaletteOpen);

  useEffect(() => {
    function navigate(view: ViewType) {
      // If a detail page is open, close it first so the view switch is
      // actually visible and the sidebar highlight stays in sync.
      if (selectedItem) closeDetail();
      setCurrentView(view);
    }

    function handleKeyDown(e: KeyboardEvent) {
      // Cmd/Ctrl+K opens the palette even while typing in an input.
      if ((e.metaKey || e.ctrlKey) && e.key.toLowerCase() === "k") {
        e.preventDefault();
        setPaletteOpen(true);
        return;
      }

      const target = e.target as HTMLElement;
      if (
        !target ||
        target.isContentEditable ||
        target.tagName === "INPUT" ||
        target.tagName === "TEXTAREA" ||
        target.tagName === "SELECT"
      ) {
        return;
      }

      if (e.key === "Escape") {
        if (selectedItem) {
          closeDetail();
        }
        return;
      }

      // '/' opens the palette (the fast path); the Search view stays
      // reachable from the sidebar for grid browsing.
      if (e.key === "/") {
        e.preventDefault();
        setPaletteOpen(true);
        return;
      }

      // Number keys for view switching
      const idx = parseInt(e.key);
      if (!isNaN(idx) && idx >= 1 && idx <= VIEW_KEYS.length && !e.metaKey && !e.ctrlKey) {
        navigate(VIEW_KEYS[idx - 1]);
        return;
      }

      // Letter shortcuts
      const shortcut = e.key.toLowerCase();
      if (LETTER_SHORTCUTS[shortcut] && !e.metaKey && !e.ctrlKey && !e.altKey) {
        e.preventDefault();
        navigate(LETTER_SHORTCUTS[shortcut]);
      }
    }

    window.addEventListener("keydown", handleKeyDown);
    return () => window.removeEventListener("keydown", handleKeyDown);
  }, [setCurrentView, selectedItem, closeDetail, setPaletteOpen]);
}
