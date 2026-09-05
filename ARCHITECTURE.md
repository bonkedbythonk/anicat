# Anicat Architecture

Anicat is a native Apple app for streaming, reading, and tracking anime, manga
and light novels against [AniList](https://anilist.co), with films and TV
against [TMDB](https://themoviedb.org) on the way. It is a Swift package
(`AnicatApple/`) over a headless Rust engine (`core/`), joined by
[UniFFI](https://mozilla.github.io/uniffi-rs/). Video plays through libmpv
inside the process.

The Tauri/React app that preceded it was removed in September 2026. The Python
scraper in `scraper/` served that app; nothing in the current build spawns it.

Today only the macOS product builds. `Package.swift` declares iOS 17 and the
xcframework carries iOS slices, but `AnicatUI` depends on AppKit directly (13
unguarded imports, an `NSOpenGLView` player), so the iPhone build is future
work rather than a second target.

## Layers

```
 ┌──────────────────────────────────────────────────────────────┐
 │  AnicatApple  (Swift package)                                 │
 │                                                              │
 │  Anicat          the executable; window, menu bar, Handoff   │
 │  AnicatUI        SwiftUI views, AppModel, player chrome,     │
 │                  caches, design system, continuity           │
 │  Cmpv            libmpv shim  (links /opt/homebrew/opt/mpv)  │
 │  AnicatCoreKit   generated Swift bindings + Sendable shims   │
 └───────────────┬────────────────────────────┬─────────────────┘
                 │ UniFFI (sync + async calls) │ libmpv render API
 ┌───────────────▼────────────────────┐   ┌───▼──────────────────┐
 │  core  (Rust, staticlib)           │   │  libmpv (OpenGL,     │
 │                                    │   │  hwdec, Anime4K      │
 │  ffi.rs      AnicatEngine surface  │   │  glsl-shaders)       │
 │  catalog/    AniList, TMDB, cache  │   └───▲──────────────────┘
 │  reader/     MangaDex, MangaKatana │       │ HTTP range reads
 │              Syosetu               │       │ (loopback, OS port)
 │  torrent/    search, layout,       │   ┌───┴──────────────────┐
 │              librqbit session,  ───┼──▶│  torrent/stream.rs   │
 │              seadex, cinema        │   │  range server        │
 │  db/         SQLite registry       │   └──────────────────────┘
 │  discord.rs  Rich Presence         │
 └───────────────┬────────────────────┘
                 │
      ~/Library/Application Support/Anicat/
        registry.sqlite     torrent-streams/
```

### Swift package

- **`AppModel`** (`Models/AppModel.swift`) is the single `@Observable` hub:
  engine lifetime, navigation with a detail history and forward stack,
  home/library/search state, playback orchestration, progress recording.
  Views read from it; nothing else owns state.
- **Caches** (`HomeCache`, `DetailCache`) are render-then-refresh disk
  snapshots under `~/Library/Caches`. The home screen paints from the last
  snapshot before the engine has finished constructing, then refreshes
  without the loading scrim.
- **Player** (`Player/`) renders through libmpv's render API into an
  `NSOpenGLView` (libmpv's public API exposes OpenGL, not Metal, on macOS).
  `PlayerController` is the observable state; `PlayerView` is the chrome,
  fitted to the video's letterboxed rect as reported by the render view
  itself. Intro/outro skip (AniSkip by MyAnimeList id), auto-next and the 85%
  watched line are driven by a position poll in
  `AppModel.handlePlaybackPositionChange`, because mpv's end-of-file events
  never fire when a torrent's tail pieces have not arrived.
- **Continuity** (`Continuity/`): Handoff via `NSUserActivity` for playback
  and reading, Bonjour discovery of other instances, Keychain storage of the
  AniList token.
- **Design system** (`DesignSystem/`): `SumiTheme` ("Ink & Index"), bundled
  Geist and IBM Plex Mono, `CachedAsyncImage` (decodes at display size off
  the main actor), an FPS and main-thread-stall HUD.

### Rust engine

`lib.rs`: everything that decides *what to play and where it comes from*
lives here, and nothing here knows there is a UI.

- **`ffi.rs`** declares `AnicatEngine` with `#[uniffi::export]` proc-macros.
  The compiled library is the only complete description of the interface,
  which is why `scripts/build-xcframework.sh` generates bindings in library
  mode from the built `.dylib` rather than from a `.udl`.
- **`catalog/`** — AniList over GraphQL, TMDB over REST, and an in-memory TTL
  cache keyed per call. An AniList outage is reported with an
  `anilist_down:` prefix so the UI can show its banner instead of a generic
  error.
- **`media.rs`** — `MediaKey(catalog, id)`. The Tauri build shifted TMDB ids
  into numeric bands inside one `i64`; the pair is now explicit and a new
  catalog is a new enum variant.
- **`db/`** — rusqlite registry: watch history (per-episode stop position and
  duration), provider slugs, local library, per-title prefs. Numbered,
  idempotent `user_version` migrations.
- **`reader/`** — MangaDex over its public REST API first; MangaKatana as an
  HTML fallback for titles MangaDex has matched but has nothing readable
  under. Syosetu for web novels.
- **`torrent/`** — the anime source. Candidates come from three independent
  indexes fired as one wave (SubsPlease, AnimeTosho, Nyaa RSS) plus SeaDex's
  curated per-entry pick. `layout.rs` decides which file inside a pack is the
  wanted episode and refuses rather than guesses. Downloads run through an
  embedded `librqbit` session into a size-capped LRU cache and are served to
  mpv by `stream.rs`, a loopback HTTP range server whose port the OS assigns
  and `stream_port()` reports. Uploading is compiled out. `cinema.rs` and
  `series.rs` (TMDB-matched films and TV) are in the crate but
  `resolve_stream` refuses non-AniList requests until the TMDB detail path is
  wired.
- **`discord.rs`** — Rich Presence.

## Sources of truth

| State | Owner |
|---|---|
| List status, score, list progress | AniList (remote) |
| Film/TV catalog metadata | TMDB (remote, cached) |
| Per-episode resume position, watch history, provider slugs, local library | SQLite registry (local) |
| Home and detail snapshots | `~/Library/Caches` (disposable) |
| Preferences | `UserDefaults`, `anicat_*` keys |
| AniList token | local Keychain |
| Navigation, selection, overlays | `AppModel` (in memory) |

## Build

- `bash scripts/build-xcframework.sh` compiles `core/` for
  `aarch64-apple-darwin`, `aarch64-apple-ios` and `aarch64-apple-ios-sim`,
  generates the Swift bindings, and assembles
  `AnicatApple/Frameworks/AnicatCore.xcframework`. Re-run after any change to
  `core/src/ffi.rs`.
- `cd AnicatApple && swift build --product Anicat` builds the app;
  `AnicatApple/dev-run.sh` copies the binary into `dist/Anicat.app` and opens
  it, which is what gives the process Dock and Cmd-Tab presence.
- `scripts/package-anicat-macos-app.sh` produces a distributable `.app` with
  libmpv's dylib closure vendored in. `scripts/bump-version.sh` writes
  `version.txt` and `core/Cargo.toml`; the packaging scripts stamp the bundle
  version from `version.txt`.
