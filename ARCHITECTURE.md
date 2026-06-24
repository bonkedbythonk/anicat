# Anicat Architecture

Anicat is a macOS-first desktop app for streaming, reading, and tracking anime
and manga against [AniList](https://anilist.co). It is a [Tauri v2](https://v2.tauri.app)
application: a React/Vite webview talking to a Rust core, with a small Python
scraper spawned on demand.

## Layers

```
              ┌─────────────────────────────────────────┐
              │            React + Vite (webview)        │
              │   views, detail drawer, manga reader     │
              │   Zustand = UI state · TanStack = cache  │
              └───────────────────┬─────────────────────┘
                                  │ Tauri invoke() IPC
        ┌─────────────────────────┼──────────────────────────┐
        │                         │                          │
 ┌──────▼───────┐        ┌────────▼────────┐        ┌────────▼─────────┐
 │ Rust commands│        │  axum HLS proxy │        │ ScraperManager   │
 │ anilist/auth │        │ 127.0.0.1:13370 │  spawn │ (Rust)           │
 │ media/user   │        │ + /player/*     │───────▶│  Python sidecar  │
 │ playback/cfg │        │   events        │        │  anicat-scraper  │
 └──────┬───────┘        └────────┬────────┘        └────────┬─────────┘
        │                         │                          │
 ┌──────▼───────┐         CDN ◀───┘ (segments)      ┌────────▼─────────┐
 │ SQLite        │                                  │ curl_cffi +      │
 │ registry +    │                                  │ selectolax       │
 │ watch history │                                  │ 60s idle timeout │
 └──────────────┘                                   └──────────────────┘
```

### React + Vite (webview) — presentation
- **Zustand** holds transient UI state (current view, selected item, sidebar,
  notifications) across a few small stores to avoid cross-component re-renders.
- **TanStack Query** holds server state (AniList data, episode lists, user
  lists). All backend calls go through `invoke("command", …)`.
- The only HTTP the webview makes to localhost is for HLS segments, which point
  at the Rust axum proxy (`127.0.0.1:13370`).

### Rust core (Tauri commands) — data, state, playback, proxy
- **Config** — TOML at `~/Library/Application Support/anicat/config.toml`.
- **AniList client** — GraphQL over `reqwest`; OAuth token in the macOS keychain.
- **Registry** — SQLite via `rusqlite`: provider-slug mappings, watch history
  (per-episode stop position + duration), and the download queue.
- **Playback** — launches external **mpv**, controls it over an IPC socket, and
  records progress. Resume position and AniList progress come from the registry
  and the player's reported position.
- **HLS proxy** — an `axum` server that streams CDN segments to mpv/HLS.js,
  rewrites `.m3u8` playlists to route through itself, and enforces an SSRF
  domain allowlist. The same server hosts the `/player/*` endpoints the mpv Lua
  script calls back into (next/prev/progress/stop/translation).

### Python scraper sidecar — provider scraping only
- A FastAPI app in `scraper/` (`main.py`) exposing search / get / streams, with
  one provider class per file: `anineko.py`, `allanime.py`, `mangakatana.py`.
- Uses `curl_cffi` (Chrome TLS impersonation, for Cloudflare) and `selectolax`.
- Spawned on demand by the Rust `ScraperManager`, self-terminates after ~60s
  idle, and is restarted when scraping is next needed. It has its own
  `scraper/pyproject.toml` and is unrelated to any root-level Python.

## Sources of truth (state model)

| State | Owner |
|---|---|
| List status, score, list progress | **AniList** (remote) |
| Per-episode resume position, watch history, downloads, provider slugs | **SQLite registry** (local) |
| Fetched AniList/episode data for the UI | **TanStack Query** cache (frontend) |
| View, selection, overlays | **Zustand** (frontend) |

After a watch or an inline edit, the frontend reconciles its cache with AniList
via `invalidateProgressQueries()` (see `web/src/lib/events.ts`).

## mpv integration

- Rust launches mpv with `--input-ipc-server` and sends commands (load file,
  resume position, skip times, script-opts) over that socket.
- A bundled Lua script (`resources/mpv_config/scripts/anicat_ui/main.lua`)
  handles intro/outro skipping (AniSkip + chapter detection), auto-next, and
  reports playback position back to the Rust proxy's `/player/*` endpoints.
- AniSkip times are resolved in the background from the AniList → MAL id (with a
  Jikan title-search fallback) and injected into mpv once it is running.

## Build & release

- **Scraper binary** — `scripts/build_scraper.py` PyInstaller-freezes
  `scraper/main.py` into `web/src-tauri/resources/scraper-bin/anicat-scraper`,
  which is what `ScraperManager` spawns in a packaged build.
- **App** — `npm run tauri build` bundles the webview, the Rust core, the
  scraper binary, and the bundled mpv + shaders/config.
- **Versioning** — `scripts/bump-version.sh` is the single source of truth; it
  writes `version.txt`, `web/package.json`, `web/src-tauri/tauri.conf.json`, and
  `web/src-tauri/Cargo.toml`. The app reports `CARGO_PKG_VERSION` at runtime.
- **Install** — end users run the `scripts/install_macos.sh` one-liner.
