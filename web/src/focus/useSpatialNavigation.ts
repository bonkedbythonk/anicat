import { useEffect, useContext } from "react";
import { FocusContext } from "./FocusScope";
import { useAppStore } from "@/stores/app";

export function useSpatialNavigation() {
  const scope = useContext(FocusContext);
  const activeFocusScope = useAppStore((s) => s.activeFocusScope);

  const jumpToNextScope = (direction: "up" | "down" | "left" | "right") => {
    const activeEl = document.activeElement as HTMLElement;
    if (!activeEl) return;
    const currentRect = activeEl.getBoundingClientRect();
    const allScopes = Array.from(document.querySelectorAll("[data-focus-scope]"));
    const currentScopeEl = activeEl.closest("[data-focus-scope]");
    const currentModal = activeEl.closest('[role="dialog"], [aria-modal="true"], .modal');
    
    // If we're inside a modal, only jump to scopes within that modal.
    // If we're not, don't jump into scopes that are inside modals.
    const scopes = currentModal
      ? allScopes.filter((s) => currentModal.contains(s))
      : allScopes.filter((s) => !s.closest('[role="dialog"], [aria-modal="true"], .modal'));
    
    let bestScope = null;
    let bestDistance = Infinity;

    for (const scope of scopes) {
      if (scope === currentScopeEl) continue;
      
      const target = scope.querySelector('[tabindex="0"]') || scope.querySelector('button:not(:disabled), a[href], input:not(:disabled), select:not(:disabled), [tabindex="-1"]');
      if (!target) continue;

      const rect = scope.getBoundingClientRect();
      
      const currentCenter = { x: currentRect.left + currentRect.width / 2, y: currentRect.top + currentRect.height / 2 };
      const rectCenter = { x: rect.left + rect.width / 2, y: rect.top + rect.height / 2 };

      let isValidDirection = false;
      let primaryDist = 0;
      let secondaryDist = 0;

      // Add a small 10px buffer to handle overlaps
      if (direction === "right" && rect.left >= currentRect.right - 10) {
        isValidDirection = true;
        primaryDist = rect.left - currentRect.right;
        secondaryDist = Math.abs(currentCenter.y - rectCenter.y);
      } else if (direction === "left" && rect.right <= currentRect.left + 10) {
        isValidDirection = true;
        primaryDist = currentRect.left - rect.right;
        secondaryDist = Math.abs(currentCenter.y - rectCenter.y);
      } else if (direction === "down" && rect.top >= currentRect.bottom - 10) {
        isValidDirection = true;
        primaryDist = rect.top - currentRect.bottom;
        secondaryDist = Math.abs(currentCenter.x - rectCenter.x);
      } else if (direction === "up" && rect.bottom <= currentRect.top + 10) {
        isValidDirection = true;
        primaryDist = currentRect.top - rect.bottom;
        secondaryDist = Math.abs(currentCenter.x - rectCenter.x);
      }

      if (isValidDirection) {
        // Prioritize alignment, penalize off-axis distance heavily
        const distance = primaryDist + secondaryDist * 3;
        if (distance < bestDistance) {
          bestDistance = distance;
          bestScope = scope;
        }
      }
    }

    if (bestScope) {
      const target = bestScope.querySelector('[tabindex="0"]') || bestScope.querySelector('button:not(:disabled), a[href], input:not(:disabled), select:not(:disabled), [tabindex="-1"]');
      if (target) {
        (target as HTMLElement).focus();
      }
    }
  };

  useEffect(() => {
    if (!scope) return;
    const handler = (e: KeyboardEvent) => {
      if (activeFocusScope && scope.name !== activeFocusScope) return;
      const target = e.target as HTMLElement | null;
      let inField = false;
      if (target) {
        if (target.isContentEditable || target.tagName === "INPUT" || target.tagName === "TEXTAREA") {
          inField = true;
        } else if (target.tagName === "SELECT") {
          if (e.key === "ArrowUp" || e.key === "ArrowDown") {
            inField = true;
          }
        }
      }
      if (inField) return;

      // If focus is lost (e.g. after page navigation) and the user presses an arrow key,
      // intercept the press and restore focus to the last active item in the current scope
      // rather than performing a wild spatial jump from the document body.
      if (!document.activeElement || document.activeElement === document.body) {
        if (["ArrowUp", "ArrowDown", "ArrowLeft", "ArrowRight"].includes(e.key)) {
          e.preventDefault();
          scope.focusItem(scope.activeIndex);
          return;
        }
      }

      switch (e.key) {
        case "ArrowRight":
          if (scope.orientation === "horizontal" || scope.orientation === "grid") {
            e.preventDefault();
            if (!scope.focusNext()) jumpToNextScope("right");
          } else if (scope.orientation === "vertical") {
            e.preventDefault();
            jumpToNextScope("right");
          }
          break;
        case "ArrowLeft":
          if (scope.orientation === "horizontal" || scope.orientation === "grid") {
            e.preventDefault();
            if (!scope.focusPrev()) jumpToNextScope("left");
          } else if (scope.orientation === "vertical") {
            e.preventDefault();
            jumpToNextScope("left");
          }
          break;
        case "ArrowDown":
          e.preventDefault();
          if (scope.orientation === "vertical" || scope.orientation === "grid") {
            if (!scope.focusDown()) jumpToNextScope("down");
          } else if (scope.orientation === "horizontal") {
            jumpToNextScope("down");
          }
          break;
        case "ArrowUp":
          e.preventDefault();
          if (scope.orientation === "vertical" || scope.orientation === "grid") {
            if (!scope.focusUp()) jumpToNextScope("up");
          } else if (scope.orientation === "horizontal") {
            jumpToNextScope("up");
          }
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
