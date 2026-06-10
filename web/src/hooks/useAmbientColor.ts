import { useCallback } from "react";

export function useAmbientColor() {
  const setAmbient = useCallback((hex: string) => {
    document.documentElement.style.setProperty(
      "--ambient-color",
      hex
    );
  }, []);

  const resetAmbient = useCallback(() => {
    document.documentElement.style.setProperty(
      "--ambient-color",
      "rgba(139, 92, 246, 0.08)"
    );
  }, []);

  return { setAmbient, resetAmbient };
}
