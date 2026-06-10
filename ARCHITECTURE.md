# Anicat Architecture v5

## Boundary Map

```
                        ┌──────────────────────────────┐
                        │        React + Vite          │
                        │   (presentation, UI state)   │
                        └──────────┬───────────────────┘
                                   │ Tauri invoke() IPC
              ┌────────────────────┼────────────────────┐
              │                    │                    │
     ┌────────▼────────┐  ┌───────▼────────┐  ┌───────▼────────┐
     │  Rust Commands  │  │  Rust Proxy    │  │  Rust Scraper  │
     │  config/anilist │  │  (axum HLS)    │  │  Manager       │
     │  registry/media │  │                │  │                │
     │  user/playback  │  │                │  │                │
     └────────┬────────┘  └───────┬────────┘  └───────┬────────┘
              │                   │                    │
              │                   │           spawn ┌──▼──────────┐
              │                   │                 │ Python       │
              │                   │                 │ AniNeko      │
   ┌──────────▼──────────┐        │                 │ curl_cffi    │
   │  SQLite             │  ┌─────▼──────┐          │ selectolax   │
   │  (media registry)   │  │ CDN        │          │ 60s idle die │
   └─────────────────────┘  └────────────┘          └──────────────┘
```

## Three Layers, Three Responsibilities

### 1. Rust Core (Tauri IPC) — owns data, state, proxy
- **Config** — TOML read/write via `serde`, no Python in path
- **AniList client** — GraphQL via `reqwest` + `serde_json`, token stored in macOS keychain
- **Media registry** — SQLite (`rusqlite`), same schema, accessed directly
- **HLS proxy** — `axum` server on `127.0.0.1:13370`, `reqwest` upstream, zero-copy streaming
- **Playback tracking** — mpv IPC socket control, watch history dispatch
- **Health/updates** — version check, log delivery, app status
- **User lists/profile** — AniList mutations through the same GraphQL client

### 2. React + Vite (Tauri WebView) — owns presentation
- **Zustand** for transient UI state (selected item, current view, overlay visibility)
- **TanStack Query** for server state (AniList data, episodes, user lists)
- All backend communication via `invoke("command_name", {args})` — no `fetch()`, no HTTP to localhost for internal ops
- Only exception: HLS segments go to localhost:13370 (the Rust axum proxy, not Python)

### 3. Python Microservice — owns only AniNeko scraping
- Isolated FastAPI process, spawned on demand by Rust `ScraperManager`
- Single responsibility: search AniNeko, get anime info, resolve stream servers
- `curl_cffi` with Chrome impersonation for Cloudflare bypass
- `selectolax` for fast HTML parsing
- Idle timeout: 60 seconds after last request, then self-terminates
- Rust manager restarts it next time scraping is needed
- Communicates with Rust core via HTTP on ephemeral port (127.0.0.1:random)

## Why Each Boundary Exists

### Why Rust for data, not Python
Python's startup cost is too high for every config read, AniList query, and registry lookup. Tauri IPC `invoke()` calls are synchronous from the WebView's perspective and complete in microseconds for local operations. Rust's `serde` deserializes directly to JSON without intermediate Python objects.

### Why Rust for HLS proxy, not Python
Each episode streams ~300 segments. Python's HTTP overhead per segment (uvicorn → FastAPI → httpx → CDN) compounds into seconds of added latency per episode. Rust's `axum` + `reqwest` uses zero-copy `Bytes` streaming — the CDN response body is forwarded directly to mpv/HLS.js without allocation.

### Why Python for scraping, not Rust
Cloudflare's TLS fingerprinting requires browser-identical TLS handshakes. `curl_cffi` (Python) is the only reliable solution for this. Rust alternatives (`rquest`, `curl-rust` with impersonation) are immature and break with CF updates. Python's rapid iteration speed matters here — scraping rules change weekly.

### Why Zustand, not React Context
React Context triggers re-renders of all consumers when any value changes, even with selector patterns. Zustand uses `useStore(selector)` which only re-renders when the selected slice changes. For the selected-item detail drawer (which changes frequently), this eliminates cascading re-renders.

### Why TanStack Query, not manual fetch
Deduplication, automatic background refetching, and cache invalidation are essential for a data-heavy app. TanStack Query handles stale-while-revalidate, retry, and optimistic updates without boilerplate.

## Performance: Where the Speed Comes From

| Optimization | Before (v4) | After (v5) |
|---|---|---|
| Config read | Python FastAPI HTTP round-trip (~2ms) | Rust Tauri IPC (~0.05ms) |
| AniList query | Python serialization + anilist roundtrip | Rust direct GraphQL (no Python hop) |
| HLS segment proxy | Python uvicorn → httpx → CDN (~5ms overhead) | Rust axum → reqwest → CDN (~0.5ms overhead) |
| Navigation | Next.js router + SSR check | react-router instant client-side |
| Detail open | React Context cascade (4 contexts re-render) | Zustand selector (only detail consumers re-render) |
| App startup | Next.js SSR + Python sidecar spawn | Vite SPA + Rust direct (no Python unless scraping) |

## Startup Sequence

1. Tauri binary starts → Rust `setup()` hook
2. Rust reads config from `~/Library/Application Support/anicat/config.toml`
3. Rust opens SQLite registry
4. Rust starts axum HLS proxy on `127.0.0.1:13370`
5. Rust initializes AniList client (loads token from keychain)
6. Tauri opens WebView → Vite SPA loads
7. React calls `invoke("get_config")` → Zustand store populated
8. TanStack Query begins fetching home page data via `invoke()`
9. Python microservice is NOT started — only spawned when first scraping needed

## Provider Design (Single-Module)

```
scraper/
├── main.py          FastAPI app, health endpoint, idle timer
├── anineko.py       One class: AniNekoProvider
│   search(query)    → list[{id, title, year, type}]
│   get(id)          → {title, episodes: [{number, title, image}]}
│   streams(id, ep)  → [{server_name, url, quality}]
│   master(url)      → raw M3U8 content
└── sidecar.spec     PyInstaller spec for bundling
```

Adding a future provider means adding one file + registering it in `main.py`. No abstraction layer needed until there are 3+ providers.

## Migration Notes

### Kept from v4
- React component JSX structure (migrated, not redesigned)
- Tailwind CSS theme system (all 4 skins, light/dark, ambient)
- HLS.js player UI and controls
- mpv binary + config + shaders (Anime4K, ModernZ, AniSkip)
- Keyboard shortcuts design

### Removed from v4
- Next.js framework (SSR, file-based routing, output:export)
- Python monolithic sidecar (~8000 LOC of API/CLI/config/registry)
- AniZone scraper (dead/obsolete provider)
- Manga backend (MangaKatana scraper, Jikan API)
- Python CLI (FZF, Rofi, inquirer)
- React Context state (4 contexts → 3 Zustand stores)
- HTTP fetches to localhost for internal operations

### New in v5
- Vite build system (instant HMR, flat SPA output)
- react-router v7 (client-side routing)
- Zustand state management
- Rust backend (~2000 LOC)
- Python AniNeko microservice (~300 LOC)
- axum HLS proxy in Rust
