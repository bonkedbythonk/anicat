import { useEffect } from "react";

export type UiStyle = "neon-abyss" | "sakura-zen" | "retro-manga";

const SAKURA_ZEN_FONT_URL =
  "https://fonts.googleapis.com/css2?family=Noto+Serif+JP:wght@400;600;700&display=swap";

const RETRO_MANGA_FONT_URL =
  "https://fonts.googleapis.com/css2?family=Bangers&family=Noto+Sans+JP:wght@400;700&display=swap";

function loadSakuraFont() {
  if (document.getElementById("font-noto-serif-jp")) return;
  const link = document.createElement("link");
  link.id = "font-noto-serif-jp";
  link.rel = "stylesheet";
  link.href = SAKURA_ZEN_FONT_URL;
  document.head.appendChild(link);
}

function loadRetroMangaFont() {
  if (document.getElementById("font-retro-manga")) return;
  const link = document.createElement("link");
  link.id = "font-retro-manga";
  link.rel = "stylesheet";
  link.href = RETRO_MANGA_FONT_URL;
  document.head.appendChild(link);
}

function applyStyle() {
  const style = (localStorage.getItem("anicat_ui_style") as UiStyle) || "neon-abyss";
  document.documentElement.setAttribute("data-style", style);
  if (style === "sakura-zen") loadSakuraFont();
  else if (style === "retro-manga") loadRetroMangaFont();
}

export function useTheme() {
  useEffect(() => {
    if (typeof window === "undefined") return;

    const mediaQuery = window.matchMedia("(prefers-color-scheme: dark)");

    const applyTheme = () => {
      const theme = localStorage.getItem("anicat_theme") || "system";
      const isDarkSystem = mediaQuery.matches;

      document.documentElement.classList.remove("light", "dark", "system");
      document.documentElement.classList.add(theme);

      if (theme === "light" || (theme === "system" && !isDarkSystem)) {
        document.documentElement.classList.add("light");
      } else {
        document.documentElement.classList.add("dark");
      }
    };

    applyTheme();
    applyStyle();

    const listener = () => {
      const theme = localStorage.getItem("anicat_theme") || "system";
      if (theme === "system") {
        document.documentElement.classList.add("theme-transition");
        applyTheme();
        setTimeout(() => {
          document.documentElement.classList.remove("theme-transition");
        }, 300);
      }
    };

    mediaQuery.addEventListener("change", listener);

    const storageListener = (e: StorageEvent) => {
      if (e.key === "anicat_theme") {
        document.documentElement.classList.add("theme-transition");
        applyTheme();
        setTimeout(() => {
          document.documentElement.classList.remove("theme-transition");
        }, 300);
      }
      if (e.key === "anicat_ui_style") {
        document.documentElement.classList.add("theme-transition");
        applyStyle();
        setTimeout(() => {
          document.documentElement.classList.remove("theme-transition");
        }, 300);
      }
    };
    window.addEventListener("storage", storageListener);

    return () => {
      mediaQuery.removeEventListener("change", listener);
      window.removeEventListener("storage", storageListener);
    };
  }, []);
}
