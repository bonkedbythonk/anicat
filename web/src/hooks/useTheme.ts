import { useState, useEffect } from "react";

type Theme = "dark" | "light" | "system";

export function useTheme(): { theme: Theme; setTheme: (t: Theme) => void } {
  const [theme, setTheme] = useState<Theme>(() => {
    const stored = localStorage.getItem("anicat-theme");
    if (stored === "dark" || stored === "light") return stored;
    return "dark";
  });

  useEffect(() => {
    localStorage.setItem("anicat-theme", theme);
    document.documentElement.classList.toggle("light", theme === "light");
  }, [theme]);

  return { theme, setTheme };
}
