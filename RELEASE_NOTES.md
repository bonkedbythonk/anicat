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

Do not use the 5.x app's own Update button for this one. It will find the
disk image and install it, but it copies the new app *over* the old bundle
instead of replacing it, so the retired app's files stay inside -- measured at
245 MB against 102 MB, with `codesign` then reporting the bundle's seal
invalid. Open the `.dmg` from this page and drag Anicat to Applications
yourself instead; that replaces the app cleanly. The 5.x app is retired either
way and nothing further is coming for it.

**The one-line installer is the easiest way in.** Paste this into Terminal:

```bash
curl -fsSL https://raw.githubusercontent.com/bonkedbythonk/anicat/master/scripts/install_macos.sh | bash
```

It downloads this release, installs it and opens it, and clears the quarantine
flag on the way so macOS does not block the app. Installing the `.dmg` by hand
works too, but then macOS refuses to open it once and you have to click Open
Anyway at the bottom of System Settings > Privacy & Security. Right-clicking
the app and choosing Open does *not* work any more -- Apple removed that
shortcut in Sequoia.

There is nothing to uninstall first. Both versions are called Anicat, carry
the same bundle identifier and install to `/Applications/Anicat.app`, so 6.0.0
replaces the 5.x app in place. What it does not replace is the 5.x data, and
the retired web view's cache alone is around 90 MB. To see what is left and
move it to the Trash:

```bash
curl -fsSLO https://raw.githubusercontent.com/bonkedbythonk/anicat/master/scripts/cleanup_legacy_macos.sh
bash cleanup_legacy_macos.sh
```

It lists everything with its size and asks before moving anything, and it
leaves your token, your 6.0.0 library and your downloads alone.

Local-only data does not carry over. The engine uses a new database
(`registry.sqlite`) and does not read the 5.x `registry.db`, so the local
watch log, saved downloads, per-title audio and subtitle preferences, and
manual search-title overrides start empty. The old `registry.db`,
`registry.json` and `covers/` in that folder are unused by 6.0.0 and can be
deleted. Leave `config.toml` alone — 6.0.0 still keeps your token there.

### What is new

- **Playback in-window.** libmpv renders into the app's own Metal layer at
  the display's refresh rate — no second window, no browser video element.
  Anime4K upscaling, AniSkip intro and outro skip, resume position, a corner
  mini-player, and auto-next with the following episode resolved at 75% of
  the current one.
- **Faster starts.** Candidates from SubsPlease, AnimeTosho, Nyaa and SeaDex
  are gathered in one wave rather than in phases, the best two are raced, and
  the release that won an episode is remembered and tried first next time.
  Measured resolve time: 2750ms cold, 955ms for a remembered release, 798ms
  from a complete cached file.
- **Films and TV** — the TMDB catalog plays as well as browses. A film is
  matched on title and year and an episode on SxxEyy, neither of which the
  anime search has a notion of, so they take their own path into the same
  player.
- **Manga reader** — single page, two-page spread, vertical scroll, RTL and
  LTR, with MangaDex first and MangaKatana filling in titles MangaDex has
  matched but cannot serve.
- **Light novel reader** for official volumes and for Syosetu web novels,
  with typography controls and per-chapter progress. A volume can be kept for
  offline reading and exported as an EPUB.
- **Downloads and History** — keep an episode for offline playback, with a
  local watch log you can open, prune or clear.
- **Continuity** — Handoff of playback and reading between Macs, and Bonjour
  discovery of other instances.
- **Keyboard-driven** — a command palette, shortcuts for every view, and a
  built-in cheat sheet on `?`.

Full feature list in the [README](https://github.com/bonkedbythonk/anicat#features).

### Known limits

- Apple silicon only, macOS 15 or later. There is no Intel build.
- Light novels come from one source for official volumes and Syosetu for web
  novels; other novel sites are not ported yet.
- macOS only for now. An iPhone build exists, with a phone layout of its own,
  but it is not part of this release: an iPhone installs apps from outside the
  App Store only through a sideloading tool on a computer, and on a free Apple
  ID the result stops working after a week.
