<div align="center">
  <img src="assets/branding/logo.png" alt="Anicat" width="140">
  <h1>Anicat</h1>
  <p><strong>Watch, read, and track anime, manga, light novels and film — a native desktop app powered by AniList.</strong></p>

  <p>
    <img src="https://img.shields.io/github/v/release/bonkedbythonk/anicat?style=flat-square&label=latest" alt="Latest Release">
    <img src="https://img.shields.io/badge/platform-macOS%20%7C%20Windows-lightgrey?style=flat-square" alt="Platform">
    <img src="https://img.shields.io/badge/license-GPLv3-blue?style=flat-square" alt="License">
  </p>

  <img src="assets/branding/dashboard.png" alt="Anicat home screen" width="720">
</div>

---

Anicat is a native desktop app for AniList users who want to watch, read, and track without touching a browser. It wraps a React/Tauri frontend around a bundled mpv for video playback, an embedded torrent engine for anime and film, a Python sidecar that scrapes manga and light novels, and a full two-way AniList sync — so your library, progress, and scores stay current automatically.

It covers four kinds of media, and they do not share a backend:

| Mode | Catalog | Source |
|---|---|---|
| Anime | AniList | Torrents, streamed while they download |
| Manga | AniList | MangaKatana |
| Light novels | RanobeDB and friends | Web-novel sources, exportable as EPUB |
| Film and TV | TMDB | Torrents, streamed while they download |

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

---

## Install

### macOS

The DMG is unsigned, and modern macOS blocks unsigned apps outright ("Apple could not verify... this app may contain malware") with no right-click-to-open bypass — the install script below handles this for you, which is why it's the recommended path.

Open **Terminal** on your Mac (press <kbd>⌘ Cmd</kbd> + <kbd>Space</kbd>, type **Terminal**, and press <kbd>Enter</kbd>), then paste and run the following command:

```bash
curl -fsSL https://raw.githubusercontent.com/bonkedbythonk/anicat/master/scripts/install_macos.sh | bash
```

If you'd rather download the `.dmg` manually from the [Releases page](https://github.com/bonkedbythonk/anicat/releases/latest), copy `Anicat.app` to `/Applications`, then open **Terminal** and clear the quarantine flag yourself:

```bash
xattr -r -d com.apple.quarantine /Applications/Anicat.app
```

### Windows

Download the latest `Anicat_*_x64-setup.exe` from the [Releases page](https://github.com/bonkedbythonk/anicat/releases/latest) and run it. Windows SmartScreen may warn about an unknown publisher — click **More info → Run anyway**.

---

## First-run Setup

On first launch, Anicat walks you through setup automatically:

1. Pick a theme and configure basic preferences.
2. Connect your AniList account — the app opens a browser window to authorize, then redirects back.
3. Your library loads and the home screen populates.

AniList is only used for tracking. Playback and the episode list do not require an account.

Cinema mode is the one exception: films and TV are catalogued by TMDB, so it stays empty until you paste a TMDB read access token into Settings.

---

## Features

- **Up Next** — A single "continue where you left off" queue across every show in progress, plus a "Pick for me" random-episode button for when you can't decide.
- **Stream & Playback** — A bundled mpv with Anime4K upscaling and AniSkip (intro/outro skip), plus a builtin `<video>` player for when you would rather stay in the app. Anime and film stream straight from the swarm while they download — no waiting for the file to finish — with candidates gathered from SubsPlease, AnimeTosho, Nyaa and SeaDex in one pass and the best two raced against each other. Sub/dub selection, resume position, auto-next into the following episode.
- **Light Novels** — Read in-app, or export a volume as an EPUB tuned for your e-reader: page size, grayscale, image quality and spread splitting are all configurable.
- **Cinema** — Films and TV matched against TMDB and streamed the same way, with a release picker when you want to choose yourself. Needs a TMDB read token.
- **Trailers** — View a title's trailer directly from the detail page.
- **Manga Reader** — Three viewing modes (single page, double page, vertical scroll), RTL/LTR support, trackpad swipe navigation, vertical sidebars for unobstructive desktop reading, and AniList progress sync.
- **AniList Sync** — Full library sync: progress, scores, list status. Watched episodes register automatically when mpv closes. Inline editing from the detail page.
- **Download Queue** — Background episode downloader via yt-dlp with real-time progress. Downloaded episodes play directly from the app.
- **Schedule** — 7-day airing calendar filtered to your watching list.
- **Discovery** — Customizable home layout (show/hide rows: trending, seasonal, airing today, continue watching, smart picks). Search with genre, year, and score filters.
- **Discord Rich Presence** — Shows what you are watching in your Discord status.
- **Themes** — Four UI styles: Neon Abyss (default), Sakura Zen (serif), Retro Manga, and Ink & Index.
- **Keyboard-driven** — Shortcuts for navigating every view, with a built-in cheat sheet (`?`).
- **Self-updating** — Checks for new releases and installs updates in place, no manual reinstall.

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

- [Rust](https://rustup.rs/) stable toolchain
- [Node.js](https://nodejs.org/) 18+
- [uv](https://docs.astral.sh/uv/) — Python environment manager for the scraper sidecar
- [ffmpeg](https://ffmpeg.org) — used to remux releases for the builtin player
- Tauri v2 system dependencies — see [Prerequisites](https://v2.tauri.app/start/prerequisites/)

mpv is **bundled** rather than installed system-wide, but its binaries are not in the repository. `scripts/setup_bundled_player.sh` fetches and configures the portable build into `web/src-tauri/resources/`; run it once after cloning.

```bash
git clone https://github.com/bonkedbythonk/anicat.git
cd anicat

# Fetch and configure the bundled mpv (once)
bash scripts/setup_bundled_player.sh

# The scraper is its own project, with its own pyproject.toml
cd scraper && uv sync && cd ..

# Install frontend dependencies and run in dev mode
cd web
npm install
npm run tauri dev
```

Useful while working on it:

```bash
cd web && npx tsc --noEmit && npm test        # frontend
cd web/src-tauri && cargo test --lib && cargo clippy --lib --tests
cd scraper && uv run python -m pytest tests/ -q
```

The dev build uses the Python scraper source files directly. The production build (`npm run tauri build`) freezes them into a standalone binary via PyInstaller.

---

## Dependencies

| Dependency | Purpose |
|---|---|
| [AniList](https://anilist.co) | Library, tracking, search, profile data for anime, manga and novels |
| [TMDB](https://themoviedb.org) | Catalog for film and TV |
| [mpv](https://mpv.io) | Media player, bundled with the app |
| [librqbit](https://github.com/ikatson/rqbit) | Embedded torrent engine |
| [ffmpeg](https://ffmpeg.org) | Remuxing releases for the builtin player |
| [yt-dlp](https://github.com/yt-dlp/yt-dlp) | Episode downloading |
| [Python 3](https://python.org) | Scraper sidecar runtime (build only) |

---

## Legal

Anicat is for educational and personal use only. See [DISCLAIMER.md](DISCLAIMER.md) and [SECURITY.md](SECURITY.md).

## License

[GNU General Public License v3.0](LICENSE)
