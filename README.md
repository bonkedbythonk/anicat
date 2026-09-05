<div align="center">
  <img src="assets/branding/logo.png" alt="Anicat" width="140">
  <h1>Anicat</h1>
  <p><strong>Watch, read, and track anime, manga, light novels and film — a native desktop app powered by AniList.</strong></p>

  <p>
    <img src="https://img.shields.io/github/v/release/bonkedbythonk/anicat?style=flat-square&label=latest" alt="Latest Release">
    <img src="https://img.shields.io/badge/platform-macOS-lightgrey?style=flat-square" alt="Platform">
    <img src="https://img.shields.io/badge/license-GPLv3-blue?style=flat-square" alt="License">
  </p>

  <img src="assets/branding/dashboard.png" alt="Anicat home screen" width="720">
</div>

---

Anicat is a native macOS app for AniList users who want to watch, read, and track without touching a browser. It is a SwiftUI app over a Rust engine, with libmpv rendering video inside the window, an embedded torrent engine for anime, and full two-way AniList sync so your library, progress and scores stay current automatically.

It covers four kinds of media, and they do not share a backend:

| Mode | Catalog | Source | State |
|---|---|---|---|
| Anime | AniList | Torrents, streamed while they download | working |
| Manga | AniList | MangaDex, MangaKatana fallback | working |
| Light novels | AniList | Syosetu | early |
| Film and TV | TMDB | Torrents | catalog only, playback not wired yet |

The app was rewritten from Tauri/React to Swift in 2026. An iPhone build is the goal of that rewrite; today only the macOS product compiles.

> **Disclaimer:** Anicat hosts zero content — it scrapes publicly accessible third-party sites and streams from public torrent swarms. It is for educational and personal use only, and use is at your own risk under your local laws. The developer has no affiliation with any content provider and is not responsible for how the app is used. See [DISCLAIMER.md](DISCLAIMER.md) for the full text.

---

## Table of Contents

- [Install](#install)
- [First-run Setup](#first-run-setup)
- [Features](#features)
- [Screenshots](#screenshots)
- [Building from Source](#building-from-source)
- [Dependencies](#dependencies)
- [Legal](#legal)
- [License](#license)

---

## Install

There is no packaged release of the native app yet. The DMGs on the
[Releases page](https://github.com/bonkedbythonk/anicat/releases) and the
`install_macos.sh` one-liner install the retired Tauri version. Build from
source (below) until a release of the Swift app exists.

---

## First-run Setup

On first launch, Anicat walks you through setup automatically:

1. Pick a theme and configure basic preferences.
2. Connect your AniList account: Settings opens the AniList authorization page in your browser, and you paste the redirect URL (or the token in it) back into the app. The token is stored in the local Keychain.
3. Your library loads and the home screen populates.

AniList is only used for tracking. Playback and the episode list do not require an account.

Cinema mode is catalogued by TMDB and needs a TMDB read access token in Settings. Its playback path is not wired into the Swift build yet.

---

## Features

- **Up Next** — A single "continue where you left off" queue across every show in progress, plus a "Pick for me" random-episode button.
- **Playback** — libmpv rendering inside the window: Anime4K upscaling, AniSkip intro/outro skip, sub/dub preference, resume position, auto-next, a corner mini-player so the rest of the app stays usable, and a sideways mode for a screen turned on its side. Anime streams straight from the swarm while it downloads, with candidates gathered from SubsPlease, AnimeTosho, Nyaa and SeaDex in one pass and the best two raced against each other.
- **Manga Reader** — Single page, double page and vertical scroll, RTL/LTR, tap zones for page turns, and AniList progress sync.
- **Light Novels** — In-app reader for Syosetu web novels.
- **AniList Sync** — Progress, scores and list status. Progress is reported continuously while you watch, and an episode registers as watched once playback passes 85%. Inline editing from the detail page.
- **Detail navigation** — Browser-style back and forward through relations and recommendations, with the poster morphing from the card you opened.
- **Downloads** — Keep an episode's torrent for offline playback, tracked in the Downloads view.
- **Schedule** — 7-day airing calendar, with a toggle between everything airing and just your watching list.
- **Discovery** — Customizable home layout, and search with genre, year and score filters.
- **Handoff** — Playback and reading hand off between Macs signed into the same Apple ID.
- **Discord Rich Presence** — Shows what you are watching in your Discord status.
- **Themes** — Ink & Index (default), Sakura Zen, Retro Manga.
- **Keyboard-driven** — A command palette and shortcuts for every view, with a built-in cheat sheet (`?`).

---

## Screenshots

<div align="center">
  <img src="assets/branding/dashboard.png" alt="Home screen" width="720">
  <br><br>
  <img src="assets/branding/detail.png" alt="Anime detail page" width="720">
  <br><br>
  <img src="assets/branding/manga.png" alt="Manga reader" width="720">
</div>

---

## Building from Source

**Prerequisites:**

- macOS 14 or later on Apple silicon, with Xcode's command line tools (Swift 6)
- [Rust](https://rustup.rs/) stable, with the Apple targets: `rustup target add aarch64-apple-darwin aarch64-apple-ios aarch64-apple-ios-sim`
- [mpv](https://mpv.io) from Homebrew: `brew install mpv` (the package links `/opt/homebrew/opt/mpv/lib`)

```bash
git clone https://github.com/bonkedbythonk/anicat.git
cd anicat

# Compile the Rust engine for every Apple target and generate the Swift
# bindings. Once after cloning, and again after any change to core/src/ffi.rs.
bash scripts/build-xcframework.sh

# Build and run
cd AnicatApple
swift build --product Anicat
bash dev-run.sh        # copies the binary into dist/Anicat.app and opens it
```

Useful while working on it:

```bash
cd AnicatApple && swift test
cd core && cargo test --lib && cargo clippy --lib --tests -- -D warnings
```

`scripts/package-anicat-macos-app.sh` produces a standalone `.app` with libmpv's dependencies vendored in.

---

## Dependencies

| Dependency | Purpose |
|---|---|
| [AniList](https://anilist.co) | Library, tracking, search, profile data for anime, manga and novels |
| [TMDB](https://themoviedb.org) | Catalog for film and TV |
| [mpv](https://mpv.io) | Media playback, linked as libmpv |
| [librqbit](https://github.com/ikatson/rqbit) | Embedded torrent engine |
| [MangaDex](https://mangadex.org), [MangaKatana](https://mangakatana.com) | Manga chapters |
| [Syosetu](https://syosetu.com) | Web novels |
| [AniSkip](https://api.aniskip.com) | Intro and outro timestamps |
| [UniFFI](https://mozilla.github.io/uniffi-rs/) | Rust to Swift bindings |

---

## Legal

Anicat is for educational and personal use only. See [DISCLAIMER.md](DISCLAIMER.md) and [SECURITY.md](SECURITY.md).

## License

[GNU General Public License v3.0](LICENSE)
