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
 │ anilist/auth │        │ 0.0.0.0:13370   │  spawn │ (Rust)           │
 │ media/user   │        │ + /player/* +   │───────▶│  Python sidecar  │
 │ playback/cfg │        │  /mobile-api/*  │        │  anicat-scraper  │
 └──────┬───────┘        └────────┬────────┘        └────────┬─────────┘
        │                         │                          │
 ┌──────▼───────┐         CDN ◀───┘ (segments)      ┌────────▼─────────┐
 │ SQLite        │                                  │ curl_cffi +      │
 │ registry +    │                                  │ selectolax       │
 │ watch history │                                  │ 30min idle timeout│
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
- **AniList client** — GraphQL over `reqwest`; OAuth token stored in plaintext in
  `config.toml` (a keychain-backed version was tried and reverted — unsigned,
  frequently-rebuilt macOS builds re-prompt for keychain access on every
  launch since the code signature changes each build, which made it
  impractical).
- **Registry** — SQLite via `rusqlite`: provider-slug mappings, watch history
  (per-episode stop position + duration), and the download queue.
- **Playback** — launches external **mpv**, controls it over an IPC socket, and
  records progress. Resume position and AniList progress come from the registry
  and the player's reported position.
- **HLS proxy** — an `axum` server that streams CDN segments to mpv, rewrites
  `.m3u8` playlists to route through itself, and enforces an SSRF domain
  allowlist. The same server hosts the `/player/*` endpoints the mpv Lua
  script calls back into (next/prev/progress/stop/translation), and — since
  the mobile PWA below — the `/mobile-api/*` JSON endpoints and the PWA's
  static files. It binds `0.0.0.0:13370` (not just loopback) so LAN devices
  can reach it.
- **Torrent engine** (`torrent/`) — the "nyaa" provider. Bypasses the scraper
  entirely: searches SubsPlease's JSON API first (curated 1080p simulcasts),
  then Nyaa's RSS (English-translated category, seeder-sorted) with
  season-aware title matching and episode parsing of release names; batch
  torrents are supported by selecting the matching episode file inside them.
  Downloads with an embedded `librqbit` session (lazy — no DHT/listeners until
  first use) into a size-capped LRU cache under `~/Library/Caches/anicat/
  torrent-streams`, and serves the in-progress file to mpv via the proxy's
  `/torrent-stream` endpoint with HTTP range support (seeks reprioritize
  pieces). Before returning the URL it pre-buffers the file header, so a
  seeder-less torrent fails over to the next candidate instead of stalling
  mpv. Uploading is compiled out (librqbit `disable-upload`) — this is a
  watch-only client, never a seedbox — and the download is paused when
  playback stops. mpv gets torrent-specific flags (`--network-timeout=0`,
  large demuxer cache, `--msg-level=ffmpeg=fatal`) so a slow piece rebuffers
  instead of erroring. librqbit's `tracing` output is captured by an
  otherwise-silent subscriber installed in `run()` so its peer/DHT churn
  doesn't reach the console. The provider's "slug" in the registry, when
  present, is a manual search-title override set through the re-match UI.

### Python scraper sidecar — provider scraping only
- A FastAPI app in `scraper/` (`main.py`) exposing search / get / streams, with
  one provider class per file: `anineko.py`, `mkissa.py`, `mangakatana.py`.
  `mkissa` is retained here but is no longer a selectable provider — it was
  removed from the UI and configs migrate off it, while the scraper stays
  in-tree in case it's brought back.
- Uses `curl_cffi` (Chrome TLS impersonation, for Cloudflare) and `selectolax`.
- Spawned on demand by the Rust `ScraperManager`, self-terminates after 120s
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

## Mobile PWA (LAN access)

Anicat can be reached from a phone on the same Wi-Fi while the desktop app is
running — no separate server, no Raspberry Pi, no downloads support.

- **Access gate** — a PIN set in Settings → Phone Access, off by default. The
  token a phone holds is derived from the PIN plus a per-install secret
  (`proxy/secret.rs`, stored beside `registry.db` at 0600) and recomputed on
  every request; there's no server-side session store, so changing the PIN
  instantly invalidates old tokens. The secret is what stops the token from
  being a reversible hash of a short numeric PIN — everything else about the
  gate is deliberately not hardened security, since the threat model is "keep a
  parent from stumbling in by accident," not "withstand an attacker already on
  the LAN." Requests from loopback (i.e. mpv's own Lua script) skip the check
  entirely so the existing desktop flow is unaffected.
- **Backend** — `web/src-tauri/src/proxy/mobile_api.rs` and `mobile_auth.rs`,
  nested into the same axum server as the HLS proxy. Most handlers are thin
  wrappers that call the existing `#[tauri::command]` functions directly via
  `app_handle.state::<AppState>()` — no business logic is duplicated between
  the desktop IPC surface and the phone's HTTP surface. Playback is the one
  real difference: instead of launching mpv, `/mobile-api/playback/resolve`
  resolves the stream the same way and hands back a `/proxy?url=...` URL a
  plain `<video>` tag can play directly (iOS Safari has native HLS support,
  no hls.js needed). The download queue is intentionally not exposed here.
- **Frontend** — a second Vite entry (`web/mobile.html` → `web/src/mobile/`),
  installable as a PWA. `web/src/lib/transport.ts` is a drop-in replacement
  for Tauri's `invoke()` that detects which context it's running in
  (`window.__TAURI_INTERNALS__`) and either calls the real IPC or `fetch()`s
  the equivalent `/mobile-api/*` route — so the shared data layer
  (`lib/api.ts`) and most view components need no changes to work in either
  shell. The mobile shell itself (nav, headers, Home/Search/Lists/Media
  Detail presentation) is purpose-built rather than reusing desktop's layout
  — it's designed to feel like a phone-native app, not a shrunk dashboard.
- **Known limitation** — `AppState.current_playback` is a single
  process-global, not per-session, so simultaneous desktop mpv playback and
  phone playback would clobber each other's progress state. Not solved;
  accepted as an edge case for personal/home use.

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
