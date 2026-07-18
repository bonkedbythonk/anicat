import type { RefObject } from "react";

export type FocusOrientation = "horizontal" | "vertical" | "grid";

export interface FocusableItem {
  id: string;
  ref: RefObject<HTMLElement | null>;
  disabled?: boolean;
}

export interface FocusScopeValue {
  name: string;
  orientation: FocusOrientation;
  columns: number;
  activeIndex: number;
  register: (item: FocusableItem) => number;
  unregister: (id: string) => void;
  focusItem: (index: number) => void;
  focusNext: () => void;
  focusPrev: () => void;
  focusUp: () => void;
  focusDown: () => void;
  focusFirst: () => void;
  focusLast: () => void;
}
