import { createContext, useCallback, useMemo, useRef, useState, type ReactNode, type ElementType, type HTMLAttributes } from "react";
import { useAppStore } from "@/stores/app";
import type { FocusOrientation, FocusScopeValue, FocusableItem } from "./types";

export const FocusContext = createContext<FocusScopeValue | null>(null);

export interface FocusScopeProps extends HTMLAttributes<HTMLElement> {
  name: string;
  orientation?: FocusOrientation;
  columns?: number;
  children: ReactNode;
  as?: ElementType;
  onFocus?: (e?: any) => void;
}

export function FocusScope({
  name,
  orientation = "vertical",
  columns = 1,
  children,
  role,
  className,
  onFocus,
  as: Component = "div",
  ...props
}: FocusScopeProps) {
  const itemsRef = useRef<FocusableItem[]>([]);
  const [activeIndex, setActiveIndex] = useState(0);
  const activeIndexRef = useRef(0);
  const [version, setVersion] = useState(0);
  const setActiveFocusScope = useAppStore((s) => s.setActiveFocusScope);

  const updateActiveIndex = useCallback((newIndex: number) => {
    activeIndexRef.current = newIndex;
    setActiveIndex(newIndex);
  }, []);

  const handleScopeFocus = useCallback(() => {
    setActiveFocusScope(name);
    onFocus?.();
  }, [name, onFocus, setActiveFocusScope]);

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
    updateActiveIndex(finalIndex);
    const el = items[finalIndex]?.ref.current;
    if (el && typeof el.focus === "function" && !items[finalIndex]?.disabled) {
      el.focus({ preventScroll: true });
      if (typeof el.scrollIntoView === "function") {
        el.scrollIntoView({ block: "nearest", inline: "nearest" });
      }
    }
  }, [findNextEnabled, updateActiveIndex]);

  const sortItems = useCallback(() => {
    const items = itemsRef.current;
    const currentActiveId = items[activeIndexRef.current]?.id;
    items.sort((a, b) => {
      if (!a.ref.current || !b.ref.current) return 0;
      const pos = a.ref.current.compareDocumentPosition(b.ref.current);
      if (pos & Node.DOCUMENT_POSITION_FOLLOWING) return -1;
      if (pos & Node.DOCUMENT_POSITION_PRECEDING) return 1;
      return 0;
    });
    if (currentActiveId) {
      const newActiveIndex = items.findIndex((i) => i.id === currentActiveId);
      if (newActiveIndex >= 0 && newActiveIndex !== activeIndexRef.current) {
        updateActiveIndex(newActiveIndex);
      }
    }
  }, [updateActiveIndex]);

  const register = useCallback((item: FocusableItem) => {
    const items = itemsRef.current;
    const existing = items.findIndex((i) => i.id === item.id);
    if (existing >= 0) {
      items[existing] = item;
    } else {
      items.push(item);
    }
    sortItems();
    bumpVersion();
    return items.findIndex((i) => i.id === item.id);
  }, [sortItems, bumpVersion]);

  const unregister = useCallback((id: string) => {
    const prevId = itemsRef.current[activeIndexRef.current]?.id;
    itemsRef.current = itemsRef.current.filter((i) => i.id !== id);
    sortItems();
    
    const newLength = itemsRef.current.length;
    if (newLength === 0) {
      updateActiveIndex(0);
    } else {
      const newIndex = itemsRef.current.findIndex((i) => i.id === prevId);
      if (newIndex >= 0) {
        updateActiveIndex(newIndex);
      } else {
        updateActiveIndex(Math.min(activeIndexRef.current, newLength - 1));
      }
    }
    bumpVersion();
  }, [sortItems, updateActiveIndex, bumpVersion]);

  const focusNext = useCallback(() => {
    const next = findNextEnabled(activeIndex + 1, 1);
    if (next >= 0) { focusItem(next); return true; }
    return false;
  }, [activeIndex, findNextEnabled, focusItem]);

  const focusPrev = useCallback(() => {
    const prev = findNextEnabled(activeIndex - 1, -1);
    if (prev >= 0) { focusItem(prev); return true; }
    return false;
  }, [activeIndex, findNextEnabled, focusItem]);

  const focusUp = useCallback(() => {
    if (orientation !== "grid") {
      return focusPrev();
    }
    const next = activeIndex - columns;
    if (next >= 0) {
      const enabled = findNextEnabled(next, 1);
      if (enabled >= 0) { focusItem(enabled); return true; }
    }
    return false;
  }, [activeIndex, columns, findNextEnabled, focusItem, focusPrev, orientation]);

  const focusDown = useCallback(() => {
    if (orientation !== "grid") {
      return focusNext();
    }
    const next = activeIndex + columns;
    if (next < itemsRef.current.length) {
      const enabled = findNextEnabled(next, 1);
      if (enabled >= 0) { focusItem(enabled); return true; }
    }
    return false;
  }, [activeIndex, columns, findNextEnabled, focusItem, focusNext, orientation]);

  const focusFirst = useCallback(() => {
    const first = findNextEnabled(0, 1);
    if (first >= 0) { focusItem(first); return true; }
    return false;
  }, [findNextEnabled, focusItem]);

  const focusLast = useCallback(() => {
    const last = findNextEnabled(itemsRef.current.length - 1, -1);
    if (last >= 0) { focusItem(last); return true; }
    return false;
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
      <Component
        role={role}
        className={className}
        onFocus={handleScopeFocus}
        data-focus-scope={name}
        {...props}
      >
        {children}
      </Component>
    </FocusContext.Provider>
  );
}
