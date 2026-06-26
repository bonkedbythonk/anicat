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
};

export function useKeyboardShortcuts() {
  const setCurrentView = useAppStore((s) => s.setCurrentView);
  const closeDetail = useAppStore((s) => s.closeDetail);
  const selectedItem = useAppStore((s) => s.selectedItem);

  useEffect(() => {
    function handleKeyDown(e: KeyboardEvent) {
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

      // Prevent browser find for '/' key
      if (e.key === "/") {
        e.preventDefault();
        setCurrentView("search");
        return;
      }

      // Number keys for view switching
      const idx = parseInt(e.key);
      if (!isNaN(idx) && idx >= 1 && idx <= VIEW_KEYS.length && !e.metaKey && !e.ctrlKey) {
        const view = VIEW_KEYS[idx - 1];
        setCurrentView(view);
        return;
      }

      // Letter shortcuts
      const shortcut = e.key.toLowerCase();
      if (LETTER_SHORTCUTS[shortcut] && !e.metaKey && !e.ctrlKey && !e.altKey) {
        e.preventDefault();
        setCurrentView(LETTER_SHORTCUTS[shortcut]);
      }
    }

    window.addEventListener("keydown", handleKeyDown);
    return () => window.removeEventListener("keydown", handleKeyDown);
  }, [setCurrentView, selectedItem, closeDetail]);
}
