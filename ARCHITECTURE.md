# Anicat Architecture

Anicat is a native Apple app for streaming, reading, and tracking anime, manga
and light novels against [AniList](https://anilist.co), with films and TV
against [TMDB](https://themoviedb.org) on the way. It is a Swift package
(`AnicatApple/`) over a headless Rust engine (`core/`), joined by
[UniFFI](https://mozilla.github.io/uniffi-rs/). Video plays through libmpv
inside the process.

The Tauri/React app that preceded it, and the Python scraper that served it,
were removed in September 2026; the `legacy/tauri` tag marks their last commit.

`Package.swift` declares macOS 15 and iOS 18. Both products build: the macOS
app through SwiftPM plus `scripts/package-anicat-macos-app.sh`, and the iPhone
app through the `AnicatApple/project.yml` target that `xcodegen` generates.
AppKit and UIKit differences live in `DesignSystem/Platform.swift` and a few
`#if os` islands. The phone is not the Mac's layout on a smaller screen:
`RootTabView` gives it a tab bar and its own shelves, where the Mac has a
200pt rail. Only the macOS build is released; there is no distributed `.ipa`.

CI builds both on `macos-26`. The runner's Xcode is load-bearing rather than
incidental: on `macos-15` the older Swift refuses main-actor writes inside
`queue: .main` callbacks that the newer one accepts, and `glassEffect` is
absent from its SDK whatever `if #available` says.

## Layers

```
 ┌──────────────────────────────────────────────────────────────┐
 │  AnicatApple  (Swift package)                                 │
 │                                                              │
 │  Anicat          the executable; window, menu bar, Handoff   │
 │  AnicatUI        SwiftUI views, AppModel, player chrome,     │
 │                  caches, design system, continuity           │
 │  MPVKit-GPL      libmpv + FFmpeg, static xcframeworks         │
 │  AnicatCoreKit   generated Swift bindings + Sendable shims   │
 └───────────────┬────────────────────────────┬─────────────────┘
                 │ UniFFI (sync + async calls) │ wid = CAMetalLayer
 ┌───────────────▼────────────────────┐   ┌───▼──────────────────┐
 │  core  (Rust, staticlib)           │   │  libmpv gpu-next,    │
 │                                    │   │  Vulkan via MoltenVK │
 │  ffi.rs      AnicatEngine surface  │   │  hwdec, Anime4K      │
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
        registry.sqlite   catalog-cache.sqlite   torrent-streams/
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
- **Player** (`Player/`): mpv draws into a `CAMetalLayer` we hand it as
  `wid`, through `gpu-next` over Vulkan on MoltenVK (MPVKit's `moltenvk`
  context). No render context or render thread of ours; the OpenGL render
  API path remains as an escape hatch behind `anicat_render_backend`.
  `PlayerController` is the observable state; `PlayerView` is the chrome,
  fitted to the video's letterboxed rect as reported by the render view
  itself. Intro/outro skip (AniSkip by MyAnimeList id), auto-next and the 85%
  watched line are driven by a position poll in
  `AppModel.handlePlaybackPositionChange`, because mpv's end-of-file events
  never fire when a torrent's tail pieces have not arrived.
- **Continuity** (`Continuity/`): Handoff via `NSUserActivity` for playback
  and reading, Bonjour discovery of other instances, Keychain storage of the
  AniList token.
- **Design system** (`DesignSystem/`): `SumiTheme` tokens resolved through
  `ThemeStore` (Ink & Index, Paper, OLED, follow system; `ThemedRoot`
  reroots the tree on a switch), bundled Geist and IBM Plex Mono,
  `CachedAsyncImage` (decodes at display size off the main actor),
  `MotionPolicy` (springs that collapse to fades under Reduce Motion),
  `SoundDesign` (synthesised feedback sounds and haptics, off by default),
  an FPS and main-thread-stall HUD.
- **Scrolling** (`DesignSystem/ResponsiveScrollingPatch.swift`,
  `ScrollEventTap.swift`): SwiftUI's `HostingScrollView` opts out of
  AppKit's responsive scrolling and scrolls at every second refresh, so the
  class flag is flipped at launch and vertical pages run at 120 Hz;
  horizontal shelves are moved to a runtime subclass that stays on the old
  path. Responsive scrolling keeps trackpad events off local `NSEvent`
  monitors, so the swipe-back tracker and hover suppression read a
  listen-only CGEvent tap instead. `FullScreenGuard` serialises fullscreen
  toggles so two inside one transition cannot wedge the window.
- **System** (`System/`): `anicat://` deep links (`DeepLink`), App Intents
  (compiled, but Shortcuts lists them only once an Xcode target runs the
  metadata extractor), new-episode and download notifications with a dock badge, all routed
  through `AppModel.handleDeepLink`.
- **People and studios** (`Models/AppModel+People.swift`, `PersonPageView`):
  character, staff, thread and studio pages render inside the content
  column on a stack above the detail page; Escape, swipe back and the mouse
  back button pop it before the page beneath.
- **Readers** (`MangaReaderView`, `SyosetuReaderView`, `AppModel+Reader`):
  single, spread (RTL/LTR, cover offset) and webtoon modes, next-chapter
  preload at 70%, AniList chapter progress on finish; the novel reader keeps
  typography, chapter navigation and a per-chapter position.
- **Player extras** (`Player/`): OP/ED chapters from the file become skip
  windows ahead of AniSkip; a next-episode card fronts auto-next with a
  cancel; `AmbientGlow` samples the frame ten times a second through
  `screenshot-raw` on mpv's event-loop thread, downscales to 64 px and
  lights each letterbox bar with the band of picture it touches, backing
  off when a sample runs over 30 ms; `KeyboardBacklightDimmer` fades the
  keyboard through the private `KeyboardBrightnessClient` during night
  playback; audio and subtitle picks are remembered per title in the
  registry. After a resize the coordinator flips the aspect override and
  back, because mpv's MoltenVK context reads the drawable size only on a
  video reconfigure.

### Rust engine

`lib.rs`: everything that decides *what to play and where it comes from*
lives here, and nothing here knows there is a UI.

- **`ffi.rs`** declares `AnicatEngine` with `#[uniffi::export]` proc-macros.
  The compiled library is the only complete description of the interface,
  which is why `scripts/build-xcframework.sh` generates bindings in library
  mode from the built `.dylib` rather than from a `.udl`.
- **`catalog/`** — AniList over GraphQL, TMDB over REST, and a TTL cache
  keyed per call that writes through to `catalog-cache.sqlite` and reloads
  on launch. A 403 whose message says the API is disabled is reported with
  an `anilist_down:` prefix so the UI can show its banner; every other
  GraphQL error keeps its own message. Also: the airing schedule for the
  calendar, per-viewer recommendations (seeds from the viewer's lists, one
  batched request), studio detail, trailer fields, and a Jikan lookup that
  fills a missing MyAnimeList id so AniSkip still fires.
- **`catalog/cinema.rs`** — cinema mode's TMDB reads: eight home rows, film
  and series search run concurrently, detail, and a season's episodes, all
  answering in the same `MediaItem` the AniList path returns so nothing
  downstream learns which catalog a title came from. `TmdbClient` reaches
  TMDB one of two ways: through a proxy that holds the key
  (`services/tmdb-proxy`, a Cloudflare Worker — the only arrangement where a
  key shipped to every install cannot be read back out of the app), or
  directly with a key of its own, which is what a viewer's own key in
  Settings does. A 429 parks every caller for the `Retry-After` it names.
- **`media.rs`** — `MediaKey(catalog, id)`. The Tauri build shifted TMDB ids
  into numeric bands inside one `i64`; the pair is now explicit and a new
  catalog is a new enum variant.
- **`db/`** — rusqlite registry: watch history (per-episode stop position and
  duration), provider slugs, local library, per-title prefs, remembered
  releases, per-title audio and subtitle picks, and the aggregation behind
  the Stats page (hours, streaks, per-day counts). Numbered, idempotent
  `user_version` migrations.
- **`reader/`** — MangaDex over its public REST API first; MangaKatana as an
  HTML fallback for titles MangaDex has matched but has nothing readable
  under, and as the fill for a sparse feed (a licensed title keeps only its
  newest simulpub chapters on MangaDex; the rest of the run is merged in
  from MangaKatana, deduplicated by chapter number). Syosetu for web novels.
- **`torrent/`** — the anime source. Candidates come from three independent
  indexes fired as one wave (SubsPlease, AnimeTosho, Nyaa RSS) plus SeaDex's
  curated per-entry pick. `layout.rs` decides which file inside a pack is the
  wanted episode and refuses rather than guesses. Downloads run through an
  embedded `librqbit` session into a size-capped LRU cache and are served to
  mpv by `stream.rs`, a loopback HTTP range server whose port the OS assigns
  and `stream_port()` reports. The cache sweep steps over the torrent a
  player is reading and the one just resolved, whatever their age. When no
  release names the wanted episode, `search.rs` samples the numbers the
  groups use and re-runs at the franchise's absolute number if a contiguous
  run matches the aired count (Bleach TYBW's fourth cour ships episode 1
  as 41). Uploading is compiled out. `cinema.rs` (films, matched on release
  year) and `series.rs` (TV, matched on `SxxEyy`) are reached by
  `resolve_cinema_stream`, which converts the absolute episode number the
  registry keys on into a season and episode against TMDB's season map, and
  refuses an episode past the end of it rather than resolving a real, wrong
  file.
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
