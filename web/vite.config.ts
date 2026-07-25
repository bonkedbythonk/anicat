import { defineConfig } from "vite";
import react from "@vitejs/plugin-react";
import tailwindcss from "@tailwindcss/vite";
import webfontDownload from "vite-plugin-webfont-dl";
import { VitePWA } from "vite-plugin-pwa";
import path from "path";
import pkg from "./package.json";

export default defineConfig({
  // Bundled app version, compared against the server's reported version by
  // the mobile PWA to detect a stale Pi deployment.
  define: {
    __APP_VERSION__: JSON.stringify(pkg.version),
  },
  plugins: [
    react(),
    tailwindcss(),
    webfontDownload([
      "https://fonts.googleapis.com/css2?family=Inter:wght@300..700&display=swap",
    ]),
    // Scoped to mobile.html only via includeAssets/navigateFallback below —
    // the desktop entry (index.html) is a Tauri webview and has no use for
    // a service worker or install prompt.
    VitePWA({
      injectRegister: null,
      manifest: false,
      includeManifestIcons: false,
      filename: "sw.js",
      workbox: {
        globPatterns: ["mobile.html", "assets/*mobile*"],
        navigateFallback: "/mobile.html",
        runtimeCaching: [
          {
            // Data must always be fresh on a home LAN — never serve stale
            // AniList/playback state from cache.
            urlPattern: ({ url }) => url.pathname.startsWith("/mobile-api/") || url.pathname.startsWith("/player/"),
            handler: "NetworkOnly",
          },
        ],
      },
    }),
  ],
  resolve: {
    alias: {
      "@": path.resolve(__dirname, "./src"),
    },
  },
  clearScreen: false,
  server: {
    port: 1420,
    strictPort: true,
    watch: {
      ignored: ["**/src-tauri/**"],
    },
  },
  envPrefix: ["VITE_", "TAURI_"],
  build: {
    target: "esnext",
    minify: !process.env.TAURI_DEBUG ? "esbuild" : false,
    sourcemap: !!process.env.TAURI_DEBUG,
    rollupOptions: {
      input: {
        main: path.resolve(__dirname, "index.html"),
        mobile: path.resolve(__dirname, "mobile.html"),
      },
    },
  },
});
