"use client";

import { useEffect } from "react";

type ViewName = "home" | "search" | "lists" | "downloads" | "library" | "settings" | "notifications" | "profile";

interface UseKeyboardShortcutsOptions {
  onNavigate: (view: ViewName) => void;
  onCloseDetail: () => void;
  onToggleHelp: () => void;
}

export default function useKeyboardShortcuts({
  onNavigate,
  onCloseDetail,
  onToggleHelp,
}: UseKeyboardShortcutsOptions) {
  useEffect(() => {
    function handleKeyDown(e: KeyboardEvent) {
      // Don't intercept when typing in inputs
      const tag = (e.target as HTMLElement)?.tagName;
      if (tag === "INPUT" || tag === "TEXTAREA" || tag === "SELECT") return;

      switch (e.key) {
        case "/":
          e.preventDefault();
          onNavigate("search");
          break;
        case "Escape":
          onCloseDetail();
          break;
        case "h":
          onNavigate("home");
          break;
        case "n":
          onNavigate("notifications");
          break;
        case "l":
          onNavigate("lists");
          break;
        case "d":
          onNavigate("downloads");
          break;
        case "?":
          e.preventDefault();
          onToggleHelp();
          break;
      }
    }

    window.addEventListener("keydown", handleKeyDown);
    return () => window.removeEventListener("keydown", handleKeyDown);
  }, [onNavigate, onCloseDetail, onToggleHelp]);
}
