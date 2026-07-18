import { useContext, useEffect, useId, useRef, useState } from "react";
import { FocusContext } from "./FocusScope";

interface UseFocusableOptions {
  disabled?: boolean;
}

export function useFocusable<T extends HTMLElement>(options: UseFocusableOptions = {}) {
  const ref = useRef<T>(null);
  const id = useId();
  const scope = useContext(FocusContext);
  const scopeRef = useRef(scope);
  scopeRef.current = scope;
  const [isFocused, setIsFocused] = useState(false);
  const [index, setIndex] = useState(-1);
  const { disabled = false } = options;

  useEffect(() => {
    const s = scopeRef.current;
    if (!s) return;
    s.register({ id, ref, disabled });
    const el = ref.current;
    const handleFocus = () => {
      setIsFocused(true);
      const idx = s.getIndex(id);
      if (idx >= 0) s.focusItem(idx);
    };
    const handleBlur = () => setIsFocused(false);
    el?.addEventListener("focus", handleFocus);
    el?.addEventListener("blur", handleBlur);
    return () => {
      s.unregister(id);
      el?.removeEventListener("focus", handleFocus);
      el?.removeEventListener("blur", handleBlur);
    };
  }, [id, disabled]);

  useEffect(() => {
    const s = scopeRef.current;
    if (!s) return;
    setIndex(s.getIndex(id));
  }, [id, scope?.version, scope?.activeIndex]);

  const tabIndex = scope && index >= 0 ? (scope.activeIndex === index ? 0 : -1) : 0;

  return { ref, isFocused, tabIndex };
}
