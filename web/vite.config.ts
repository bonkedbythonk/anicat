import { defineConfig } from "vite";
import react from "@vitejs/plugin-react";
import tailwindcss from "@tailwindcss/vite";
import webfontDownload from "vite-plugin-webfont-dl";
import path from "path";

export default defineConfig({
  plugins: [
    react(),
    tailwindcss(),
    webfontDownload([
      "https://fonts.googleapis.com/css2?family=Inter:wght@300..700&display=swap",
    ]),
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
    // The desktop builtin player and mpv's Lua script talk to the Rust
    // backend's axum server over /player, /proxy, /mobile-hls (remux
    // segments) and /torrent-stream as same-origin paths, so iterating on
    // the frontend alone in `npm run dev` needs those forwarded to a running
    // backend — without this, those fetches fall through to Vite's own SPA
    // fallback and silently return index.html instead of real content.
    proxy: {
      "/player": {
        target: process.env.ANICAT_BACKEND ?? "http://127.0.0.1:13370",
        changeOrigin: true,
      },
      "/proxy": {
        target: process.env.ANICAT_BACKEND ?? "http://127.0.0.1:13370",
        changeOrigin: true,
      },
      "/mobile-hls": {
        target: process.env.ANICAT_BACKEND ?? "http://127.0.0.1:13370",
        changeOrigin: true,
      },
      "/torrent-stream": {
        target: process.env.ANICAT_BACKEND ?? "http://127.0.0.1:13370",
        changeOrigin: true,
      },
      // MangaReader fetches pages through /api/media/manga/proxy (see
      // proxy/server.rs) — without this, chapter images 404 into Vite's SPA
      // fallback and the reader renders blank pages in `npm run dev`.
      "/api": {
        target: process.env.ANICAT_BACKEND ?? "http://127.0.0.1:13370",
        changeOrigin: true,
      },
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
      },
    },
  },
});
