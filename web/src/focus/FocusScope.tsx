import { createContext, useCallback, useMemo, useRef, useState, type ReactNode } from "react";
import type { FocusOrientation, FocusScopeValue, FocusableItem } from "./types";

export const FocusContext = createContext<FocusScopeValue | null>(null);

interface FocusScopeProps {
  name: string;
  orientation?: FocusOrientation;
  columns?: number;
  children: ReactNode;
  role?: string;
  className?: string;
  onFocus?: () => void;
}

export function FocusScope({
  name,
  orientation = "vertical",
  columns = 1,
  children,
  role,
  className,
  onFocus,
}: FocusScopeProps) {
  const itemsRef = useRef<FocusableItem[]>([]);
  const [activeIndex, setActiveIndex] = useState(0);

  const focusItem = useCallback((index: number) => {
    const items = itemsRef.current;
    const clamped = Math.max(0, Math.min(index, items.length - 1));
    setActiveIndex(clamped);
    const el = items[clamped]?.ref.current;
    if (el && typeof el.focus === "function") {
      el.focus({ preventScroll: true });
      if (typeof el.scrollIntoView === "function") {
        el.scrollIntoView({ block: "nearest", inline: "nearest" });
      }
    }
  }, []);

  const register = useCallback((item: FocusableItem) => {
    const items = itemsRef.current;
    const existing = items.findIndex((i) => i.id === item.id);
    if (existing >= 0) {
      items[existing] = item;
      return existing;
    }
    items.push(item);
    return items.length - 1;
  }, []);

  const unregister = useCallback((id: string) => {
    itemsRef.current = itemsRef.current.filter((i) => i.id !== id);
    setActiveIndex((prev) => Math.min(prev, Math.max(0, itemsRef.current.length - 1)));
  }, []);

  const focusNext = useCallback(() => {
    focusItem(activeIndex + 1);
  }, [activeIndex, focusItem]);

  const focusPrev = useCallback(() => {
    focusItem(activeIndex - 1);
  }, [activeIndex, focusItem]);

  const focusUp = useCallback(() => {
    if (orientation !== "grid") {
      focusPrev();
      return;
    }
    const next = activeIndex - columns;
    if (next >= 0) focusItem(next);
  }, [activeIndex, columns, focusItem, focusPrev, orientation]);

  const focusDown = useCallback(() => {
    if (orientation !== "grid") {
      focusNext();
      return;
    }
    const next = activeIndex + columns;
    if (next < itemsRef.current.length) focusItem(next);
  }, [activeIndex, columns, focusItem, focusNext, orientation]);

  const focusFirst = useCallback(() => focusItem(0), [focusItem]);
  const focusLast = useCallback(() => focusItem(itemsRef.current.length - 1), [focusItem]);

  const value = useMemo<FocusScopeValue>(
    () => ({
      name,
      orientation,
      columns,
      activeIndex,
      register,
      unregister,
      focusItem,
      focusNext,
      focusPrev,
      focusUp,
      focusDown,
      focusFirst,
      focusLast,
    }),
    [name, orientation, columns, activeIndex, register, unregister, focusItem, focusNext, focusPrev, focusUp, focusDown, focusFirst, focusLast]
  );

  return (
    <FocusContext.Provider value={value}>
      <div
        role={role}
        className={className}
        onFocus={onFocus}
        data-focus-scope={name}
      >
        {children}
      </div>
    </FocusContext.Provider>
  );
}
