import { useEffect, useContext } from "react";
import { FocusContext } from "./FocusScope";
import { useAppStore } from "@/stores/app";

export function useSpatialNavigation() {
  const scope = useContext(FocusContext);
  const activeFocusScope = useAppStore((s) => s.activeFocusScope);

  useEffect(() => {
    if (!scope) return;
    const handler = (e: KeyboardEvent) => {
      if (activeFocusScope && scope.name !== activeFocusScope) return;
      const target = e.target as HTMLElement | null;
      const inField =
        target &&
        (target.isContentEditable ||
          target.tagName === "INPUT" ||
          target.tagName === "TEXTAREA" ||
          target.tagName === "SELECT");
      if (inField) return;

      switch (e.key) {
        case "ArrowRight":
          if (scope.orientation === "horizontal" || scope.orientation === "grid") {
            e.preventDefault();
            scope.focusNext();
          }
          break;
        case "ArrowLeft":
          if (scope.orientation === "horizontal" || scope.orientation === "grid") {
            e.preventDefault();
            scope.focusPrev();
          }
          break;
        case "ArrowDown":
          e.preventDefault();
          scope.focusDown();
          break;
        case "ArrowUp":
          e.preventDefault();
          scope.focusUp();
          break;
        case "Home":
          e.preventDefault();
          scope.focusFirst();
          break;
        case "End":
          e.preventDefault();
          scope.focusLast();
          break;
      }
    };
    window.addEventListener("keydown", handler);
    return () => window.removeEventListener("keydown", handler);
  }, [scope, activeFocusScope]);
}
