# Anicat Architecture

Anicat is a macOS-first desktop app for streaming, reading, and tracking anime,
manga and light novels against [AniList](https://anilist.co), plus films and TV
against [TMDB](https://themoviedb.org). It is a [Tauri v2](https://v2.tauri.app)
application: a React/Vite webview talking to a Rust core, with a small Python
scraper spawned on demand.

The four media modes do not share a backend. Anime and cinema are served by the
embedded torrent engine with no scraper involvement at all; manga and light
novels are the only things that still reach the Python sidecar.

There is no mobile build. The PWA, its proxy routes and the Raspberry Pi
deployment were removed; comments still referring to "the mobile PWA" are
stale.

## Layers

```
              ┌─────────────────────────────────────────┐
              │            React + Vite (webview)        │
              │  views · detail page · manga + novel      │
              │  readers · builtin <video> player         │
              │  Zustand = UI state · TanStack = cache    │
              └───────────────────┬─────────────────────┘
                                  │ Tauri invoke() IPC
        ┌─────────────────────────┼──────────────────────────┐
        │                         │                          │
 ┌──────▼───────┐        ┌────────▼────────┐        ┌────────▼─────────┐
 │ Rust commands│        │  axum HLS proxy │        │ ScraperManager   │
 │ anilist/auth │        │ 127.0.0.1:13370 │  spawn │ (Rust)           │
 │ media/user   │        │ + /player/*     │───────▶│  Python sidecar  │
 │ cinema/novel │        │ + /torrent-     │        │  anicat-scraper  │
 │ playback/cfg │        │   stream        │        │  (manga, novels) │
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
- **`focus/`** is the spatial-navigation system (focus scopes, `useFocusable`,
  `useSpatialNavigation`) that makes the app keyboard- and remote-drivable. It
  is unit-tested; manga is deliberately not wired into it yet.
- **`components/player/AniCatPlayer.tsx`** is the in-app `<video>` player, used
  when playback isn't handed to mpv. It can only decode what WebKit can, which
  is the entire reason `proxy/remux.rs` exists.
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
  (per-episode stop position + duration), and the download queue. Every table
  keys on a bare `media_id INTEGER`, so `media_id.rs` gives each catalog its own
  band of the integer space rather than adding a source column: AniList ids are
  stored unchanged (no migration ever ran), TMDB movie and TV ids are shifted
  into two further bands on the way in and back out on the way out.
- **Playback** — launches the **bundled mpv**, controls it over an IPC socket,
  and records progress. Resume position and AniList progress come from the
  registry and the player's reported position. Auto-next reuses the same mpv via
  `loadfile … replace` rather than relaunching it.
- **HLS proxy** — an `axum` server that streams CDN segments to mpv, rewrites
  `.m3u8` playlists to route through itself, and enforces an SSRF domain
  allowlist. The same server hosts the `/player/*` endpoints the mpv Lua
  script calls back into (next/prev/progress/stop/translation), plus
  `remux.rs`'s HLS remux for the desktop builtin `<video>` player (which
  can't open the Matroska container torrent releases ship in). It binds
  `127.0.0.1:13370` — every caller is same-machine.
- **Torrent engine** (`torrent/`) — the `nyaa` provider, and the only anime
  source. Bypasses the scraper entirely; episode lists are synthesized from
  AniList counts. Candidates come from three independent indexes fired as one
  wave — SubsPlease's JSON API (curated 1080p simulcasts), AnimeTosho's JSON
  feed, and Nyaa's RSS — plus SeaDex's curated per-entry human pick, run
  concurrently alongside. Only the *later* Nyaa rounds are conditional, because
  Nyaa throttles above four concurrent queries and AnimeTosho serves one query
  at a time per client, so AnimeTosho is raced with a short grace period rather
  than waited on. `layout.rs` then decides which file inside the torrent is the
  wanted episode, reading a pack as a structure (stated season, episode,
  `SP`/`OVA` index, extras folder) and refusing rather than guessing when
  nothing places the entry inside it. Downloads run through an embedded
  `librqbit` session (lazy, warmed at startup) into a size-capped LRU cache
  under `~/Library/Caches/anicat/torrent-streams`, served to mpv via the
  proxy's `/torrent-stream` endpoint with HTTP range support so seeks
  reprioritize pieces. Before returning a URL it pre-buffers the file header,
  so a seeder-less torrent fails over to the next candidate instead of stalling
  mpv. Uploading is compiled out (librqbit `disable-upload`) — this is a
  watch-only client, never a seedbox — and downloads pause when playback stops.
  mpv gets torrent-specific flags (`--network-timeout=0`, large demuxer cache,
  `--msg-level=ffmpeg=fatal`) so a slow piece rebuffers instead of erroring.
  The provider's registry "slug", when present, is a manual search-title
  override set through the re-match UI.
- **Cinema** (`torrent/cinema.rs`, `torrent/series.rs`, `commands/cinema.rs`) —
  films and TV matched against TMDB and streamed over the same torrent engine,
  returning the same `{Page: {media, pageInfo}}` envelope the AniList commands
  do so the frontend doesn't need to know which catalog answered. Needs a TMDB
  read token in config; without one, cinema mode has no catalog.

### Python scraper sidecar — manga and light novels only
- A FastAPI app in `scraper/` (`main.py`) exposing search / get / streams, with
  one provider class per file: `mangakatana.py` for manga and `anineko.py`
  (anime, retired but kept in-tree in case it returns). Light novels have their
  own engine under `scraper/novel/` — RanobeDB, Lnori, Syosetu, Kakuyomu,
  Hameln, Royal Road, Baka-Tsuki and a generic fallback — with an EPUB builder
  and an e-reader image pipeline behind it.
- Every endpoint takes `provider` as a required parameter; there is no default,
  because the old one named a provider that no longer exists.
- Uses `curl_cffi` (Chrome TLS impersonation, for Cloudflare) and `selectolax`.
- Spawned on demand by the Rust `ScraperManager`, self-terminates after a
  30-minute idle timeout, and is restarted when scraping is next needed. It has
  its own `scraper/pyproject.toml` and is unrelated to any root-level Python.
- Nothing on the anime play path reaches it any more.

## Sources of truth (state model)

| State | Owner |
|---|---|
| List status, score, list progress | **AniList** (remote) |
| Film/TV catalog metadata | **TMDB** (remote, cached) |
| Per-episode resume position, watch history, downloads, provider slugs | **SQLite registry** (local) |
| Fetched AniList/episode data for the UI | **TanStack Query** cache (frontend) |
| View, selection, overlays | **Zustand** (frontend) |

After a watch or an inline edit, the frontend reconciles its cache with AniList
via `invalidateProgressQueries()` (see `web/src/lib/events.ts`).

## mpv integration

- Rust launches mpv with `--input-ipc-server` and sends commands (load file,
  resume position, skip times, script-opts) over that socket.
- A bundled Lua script (`resources/mpv_config/scripts/anicat_ui/main.lua`)
  handles intro/outro skipping (AniSkip + chapter detection), auto-next, the
  Ctrl+1/Ctrl+2 toggles, and reports playback position back to the Rust proxy's
  `/player/*` endpoints.
- Auto-next is polled once a second rather than driven purely by mpv events.
  Every event that could announce "this episode is over" needs mpv to *finish*
  something, and skipping to the end of a still-downloading torrent is the case
  where none of them ever does — the position says the episode ended while the
  seek that would prove it never completes. See CLAUDE.md for the measurements.
- Because auto-next reuses the running player, anything the launch path sends as
  `--script-opts` has to be re-sent on each transition: setting the `script-opts`
  property replaces the whole map rather than merging into it.
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
