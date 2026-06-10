import { useEffect } from "react";
import { useAppStore } from "@/stores/app";

const VIEW_KEYS = [
  "home", "search", "library", "lists", "schedule",
  "notifications", "profile", "settings", "downloads",
] as const;

export function useKeyboardShortcuts() {
  const setCurrentView = useAppStore((s) => s.setCurrentView);
  const openDetail = useAppStore((s) => s.openDetail);
  const closeDetail = useAppStore((s) => s.closeDetail);
  const selectedItem = useAppStore((s) => s.selectedItem);

  useEffect(() => {
    function handleKeyDown(e: KeyboardEvent) {
      if (e.target instanceof HTMLInputElement || e.target instanceof HTMLTextAreaElement) {
        return;
      }

      if (e.key === "Escape") {
        if (selectedItem) {
          closeDetail();
        }
        return;
      }

      // Number keys for view switching
      const idx = parseInt(e.key);
      if (!isNaN(idx) && idx >= 1 && idx <= VIEW_KEYS.length && !e.metaKey && !e.ctrlKey) {
        const view = VIEW_KEYS[idx - 1];
        setCurrentView(view);
      }
    }

    window.addEventListener("keydown", handleKeyDown);
    return () => window.removeEventListener("keydown", handleKeyDown);
  }, [setCurrentView, selectedItem, closeDetail]);
}
