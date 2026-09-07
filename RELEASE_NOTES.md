## Anicat 6.0.0

Anicat is now a native macOS app. The Tauri/React app that every release up
to 5.8.0 shipped has been replaced by a SwiftUI and AppKit front end over a
headless Rust engine, joined by UniFFI, with libmpv drawn straight into the
window through Metal. This is a rewrite, not an update: there is no web view
and no sidecar process left in the app.

### Upgrading from 5.x

Your AniList account carries over — the app reads the token the 5.x build
left in `~/Library/Application Support/Anicat/config.toml`, and your library,
progress and scores come back from AniList itself on first sync.

Local-only data does not carry over. The engine uses a new database
(`registry.sqlite`) and does not read the 5.x `registry.db`, so the local
watch log, saved downloads, per-title audio and subtitle preferences, and
manual search-title overrides start empty. The old `registry.db`,
`registry.json`, `config.toml` and `covers/` in that folder are unused by
6.0.0 and can be deleted once you have signed in.

### What is new

- **Playback in-window.** libmpv renders into the app's own Metal layer at
  the display's refresh rate — no second window, no browser video element.
  Anime4K upscaling, AniSkip intro and outro skip, resume position, a corner
  mini-player, and auto-next with the following episode resolved at 75% of
  the current one.
- **Faster starts.** Candidates from SubsPlease, AnimeTosho, Nyaa and SeaDex
  are gathered in one wave rather than in phases, the best two are raced, and
  the release that won an episode is remembered and tried first next time.
  Measured start-to-picture: 2750ms cold, 955ms for a remembered release,
  798ms from a complete cached file.
- **Manga reader** — single page, two-page spread, vertical scroll, RTL and
  LTR, with MangaDex first and MangaKatana filling in titles MangaDex has
  matched but cannot serve.
- **Light novel reader** for Syosetu web novels, with typography controls and
  per-chapter progress.
- **Downloads and History** — keep an episode for offline playback, with a
  local watch log you can open, prune or clear.
- **Continuity** — Handoff of playback and reading between Macs, and Bonjour
  discovery of other instances.
- **Keyboard-driven** — a command palette, shortcuts for every view, and a
  built-in cheat sheet on `?`.

Full feature list in the [README](https://github.com/bonkedbythonk/anicat#features).

### Known limits

- Apple silicon only, macOS 14 or later. There is no Intel build.
- Film and TV are catalog-only: TMDB browsing works, playback is not wired up.
- Light novels are Syosetu only.
- No iPhone build yet. The shared views compile for iOS, but there is no iOS
  app target and the layout is still the desktop one.
