import { useContext, useEffect, useId, useRef, useState } from "react";
import { FocusContext } from "./FocusScope";

interface UseFocusableOptions {
  disabled?: boolean;
}

export function useFocusable<T extends HTMLElement>(options: UseFocusableOptions = {}) {
  const ref = useRef<T>(null);
  const id = useId();
  const scope = useContext(FocusContext);
  const [isFocused, setIsFocused] = useState(false);
  const [index, setIndex] = useState<number | null>(null);
  const { disabled = false } = options;

  useEffect(() => {
    if (!scope) return;
    const idx = scope.register({ id, ref, disabled });
    setIndex(idx);
    const el = ref.current;
    const handleFocus = () => {
      setIsFocused(true);
      scope.focusItem(idx);
    };
    const handleBlur = () => setIsFocused(false);
    el?.addEventListener("focus", handleFocus);
    el?.addEventListener("blur", handleBlur);
    return () => {
      scope.unregister(id);
      el?.removeEventListener("focus", handleFocus);
      el?.removeEventListener("blur", handleBlur);
    };
  }, [scope, id, disabled]);

  const tabIndex = scope && index !== null ? (scope.activeIndex === index ? 0 : -1) : 0;

  return { ref, isFocused, tabIndex };
}
