<div align="center">
  <h1>Anicat</h1>
  <p><strong>Stream, track, and organize anime and manga — a native Tauri v2 desktop app powered by AniList.</strong></p>

  <p>
    <img src="https://img.shields.io/badge/platform-macOS%20%7C%20Windows-lightgrey?style=flat-square" alt="Platform">
    <img src="https://img.shields.io/github/v/release/bonkedbythonk/anicat?style=flat-square&label=stable" alt="Latest stable release">
    <img src="https://img.shields.io/badge/license-GPLv3-blue?style=flat-square" alt="License">
    <img src="https://img.shields.io/github/last-commit/bonkedbythonk/anicat/nightly?style=flat-square&label=nightly" alt="Last nightly commit">
  </p>

  <img src="assets/branding/dashboard.png" alt="Anicat Desktop" width="720">
</div>

---

## Features

### Streaming & Playback
- **External MPV Player** — Bundled mpv with Anime4K upscaling shaders, custom ModernZ skin, and AniSkip intro/outro skipping. Launched as a separate process with full subtitle support.
- **Embedded HLS Player** — Browser-based video player via `hls.js` with controls, seek, and fullscreen. Selectable via player type setting.
- **Stream Server Selection** — Choose between Hard Sub, Soft Sub, or Dub servers. Auto-fallback if the primary server fails.
- **HLS Proxy** — Built-in `axum` proxy rewrites `.m3u8` playlists to avoid CORS issues. Serves images and handles custom headers.
- **Discord Rich Presence** — Shows what you're watching in your Discord status (title, episode, elapsed time).
- **Playback Monitoring** — When mpv closes, progress is automatically recorded locally and synced to AniList (requires ≥60s watch time).

### Media Discovery
- **Home Dashboard** — Up to 7 configurable rows: Airing Today, Continue Watching, New for You, Smart Playlist, Trending Now, Newly Releasing, Seasonal Highlights. Hero section prioritizes content by urgency.
- **Search** — Full-text search with genre, year, score, and status filters. ANIME/MANGA toggle. Discovery feed with trending + seasonal + random picks when idle.
- **Media Detail Drawer** — Slide-in panel with synopsis, score, progress editor, status changer, episode/chapter list, character browser, related media (prequels/sequels/side stories), and recommendations.
- **Airing Schedule** — 7-day schedule view with Global or Watching Only modes. Live countdowns. Configurable 12h/24h time.

### Manga
- **Manga Home** — Dedicated homepage with Continue Reading, Want to Read, Trending, and Highly Rated rows.
- **Manga Reader** — Three reading modes (single page, double page, vertical scroll). RTL/LTR direction. Keyboard navigation. Progress syncs to AniList automatically.
- **MangaKatana Integration** — Full search, chapter listing, and page loading via the Python scraper.

### Library & Tracking
- **AniList Sync** — All progress, scores, and list status changes sync to AniList in real-time. Optimistic cache updates with rollback on errors.
- **List Views** — Five status tabs (Watching/Reading, Completed, Planning, Paused, Dropped). ANIME/MANGA toggle. Client-side pagination.
- **Inline Progress Editing** — Click the progress number in the detail drawer to edit. Also updates the local React Query cache.
- **User Profile** — AniList profile with stats dashboard (total watch time, episodes, chapters), genre breakdown bars, biography, and favorites showcase.

### Downloads
- **Background Download Queue** — Sequential worker fetches episodes via `yt-dlp` with real-time progress events. Queued items survive app restarts (SQLite persistence).
- **Offline Library Browser** — Browse completed downloads grouped by media. Play from disk, delete, retry failed items. Cover images cached for offline display.
- **Local File Playback** — If a downloaded file exists for the episode, the app plays it locally instead of streaming.

### Configuration
- **Five-Tab Settings** — General (theme, UI style, time format, homepage layout, Discord), Player (sub/dub, GPU upscaling profile), Downloads (path), Account (AniList token), Maintenance (updates, logs, provider debug tool).
- **Theme System** — Dark / Light / System (follows OS preference). Smooth transitions.
- **UI Skins** — Neon Abyss (default), Sakura Zen (serif), Retro Manga (Bangers + Japanese sans-serif). Fonts loaded dynamically from Google Fonts.
- **Config Persistence** — Settings saved to `~/.config/anicat/config.toml`. Debounced auto-save.

### Notifications & Schedule
- **AniList Notifications** — Airing, media updates, and related media notifications with cover art and timestamp. Mark all as read.
- **Live Countdowns** — Episode airing timers on the schedule view and home dashboard.

### Provider System
- **AniNeko** — Primary anime stream provider (Python scraper subprocess).
- **MangaKatana** — Manga chapter provider.
- **Provider Slug Registry** — SQLite-backed mapping from AniList IDs to provider slugs. Automatic title matching with Levenshtein distance.
- **Provider Debug** — Test any provider's response for a given anime ID + episode right from Settings.

### External Data Sources
- **AniZip** — Episode title enrichment via `api.ani.zip`.
- **Jikan (MyAnimeList)** — Filler episode detection via `api.jikan.moe`.
- **AniSkip** — Intro/outro timestamps for automatic skipping in mpv.

### Other
- **Keyboard Shortcuts** — H (Home), / (Search), L (Lists), D (Downloads), N (Notifications), 1-8 (view switching), Escape (close drawer).
- **Onboarding Wizard** — 4-step first-run flow: welcome, AniList connect, preferences, shortcuts reference.
- **Update Checker** — Compares local version to GitHub releases. Supports stable and nightly branches. Opens download page.
- **Log Viewer** — Fetch and browse app logs, open logs folder, generate debug reports.

---

## Quick Install

**macOS** — paste in Terminal:
```bash
curl -fsSL https://raw.githubusercontent.com/bonkedbythonk/anicat/master/scripts/install_macos.sh | bash
```

**Windows** — download the latest `_x64-setup.exe` from [Releases](https://github.com/bonkedbythonk/anicat/releases).

## Branches

| Branch | Use |
|--------|-----|
| `master` | Stable releases. Tested, reviewed, ready for daily use. |
| `nightly` | Latest features and fixes. May be less stable. Switch via Settings → Update Branch. |

## Building from Source

```bash
git clone https://github.com/bonkedbythonk/anicat.git
cd anicat/web
npm install
npm run tauri dev
```

Requires Rust, Node.js, and system dependencies for [Tauri v2](https://v2.tauri.app/start/prerequisites/). macOS also requires `mpv` (`brew install mpv`) for the external player.

## Dependencies

| Dependency | Purpose |
|-----------|---------|
| [AniList](https://anilist.co) | Library, tracking, search, profile data |
| [mpv](https://mpv.io) | External media player (recommended) |
| [yt-dlp](https://github.com/yt-dlp/yt-dlp) | Episode downloading |
| [Python 3](https://python.org) | Scraper subprocess (AniNeko, MangaKatana) |

## Legal

Anicat is for educational and personal use only. See [DISCLAIMER.md](DISCLAIMER.md) and [SECURITY.md](SECURITY.md).

## License

[GNU General Public License v3.0](LICENSE)
