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
  const [version, setVersion] = useState(0);

  const bumpVersion = useCallback(() => setVersion((v) => v + 1), []);

  const getIndex = useCallback((id: string) => {
    return itemsRef.current.findIndex((i) => i.id === id);
  }, []);

  const findNextEnabled = useCallback((start: number, direction: 1 | -1) => {
    const items = itemsRef.current;
    if (items.length === 0) return -1;
    let index = start;
    for (let i = 0; i < items.length; i++) {
      if (index < 0 || index >= items.length) return -1;
      if (!items[index]?.disabled) return index;
      index += direction;
    }
    return -1;
  }, []);

  const focusItem = useCallback((index: number) => {
    const items = itemsRef.current;
    const clamped = Math.max(0, Math.min(index, items.length - 1));
    const target = findNextEnabled(clamped, 1);
    const finalIndex = target >= 0 ? target : clamped;
    setActiveIndex(finalIndex);
    const el = items[finalIndex]?.ref.current;
    if (el && typeof el.focus === "function" && !items[finalIndex]?.disabled) {
      el.focus({ preventScroll: true });
      if (typeof el.scrollIntoView === "function") {
        el.scrollIntoView({ block: "nearest", inline: "nearest" });
      }
    }
  }, [findNextEnabled]);

  const register = useCallback((item: FocusableItem) => {
    const items = itemsRef.current;
    const existing = items.findIndex((i) => i.id === item.id);
    if (existing >= 0) {
      items[existing] = item;
      bumpVersion();
      return existing;
    }
    items.push(item);
    bumpVersion();
    return items.length - 1;
  }, [bumpVersion]);

  const unregister = useCallback((id: string) => {
    const prevIndex = itemsRef.current.findIndex((i) => i.id === id);
    itemsRef.current = itemsRef.current.filter((i) => i.id !== id);
    setActiveIndex((prev) => {
      const nextLength = itemsRef.current.length;
      if (nextLength === 0) return 0;
      const next = Math.min(prev, nextLength - 1);
      if (prevIndex >= 0 && prev > prevIndex) {
        return Math.max(0, prev - 1);
      }
      return next;
    });
    bumpVersion();
  }, [bumpVersion]);

  const focusNext = useCallback(() => {
    const next = findNextEnabled(activeIndex + 1, 1);
    if (next >= 0) focusItem(next);
  }, [activeIndex, findNextEnabled, focusItem]);

  const focusPrev = useCallback(() => {
    const prev = findNextEnabled(activeIndex - 1, -1);
    if (prev >= 0) focusItem(prev);
  }, [activeIndex, findNextEnabled, focusItem]);

  const focusUp = useCallback(() => {
    if (orientation !== "grid") {
      focusPrev();
      return;
    }
    const next = activeIndex - columns;
    if (next >= 0) {
      const enabled = findNextEnabled(next, 1);
      if (enabled >= 0) focusItem(enabled);
    }
  }, [activeIndex, columns, findNextEnabled, focusItem, focusPrev, orientation]);

  const focusDown = useCallback(() => {
    if (orientation !== "grid") {
      focusNext();
      return;
    }
    const next = activeIndex + columns;
    if (next < itemsRef.current.length) {
      const enabled = findNextEnabled(next, 1);
      if (enabled >= 0) focusItem(enabled);
    }
  }, [activeIndex, columns, findNextEnabled, focusItem, focusNext, orientation]);

  const focusFirst = useCallback(() => {
    const first = findNextEnabled(0, 1);
    if (first >= 0) focusItem(first);
  }, [findNextEnabled, focusItem]);

  const focusLast = useCallback(() => {
    const last = findNextEnabled(itemsRef.current.length - 1, -1);
    if (last >= 0) focusItem(last);
  }, [findNextEnabled, focusItem]);

  const value = useMemo<FocusScopeValue>(
    () => ({
      name,
      orientation,
      columns,
      activeIndex,
      version,
      register,
      unregister,
      getIndex,
      focusItem,
      focusNext,
      focusPrev,
      focusUp,
      focusDown,
      focusFirst,
      focusLast,
    }),
    [name, orientation, columns, activeIndex, version, register, unregister, getIndex, focusItem, focusNext, focusPrev, focusUp, focusDown, focusFirst, focusLast]
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
