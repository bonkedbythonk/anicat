<div align="center">
  <h1>Anicat</h1>
  <p><strong>Watch, track, and organize your anime — all in one native desktop app.</strong></p>

  <!-- Badges -->
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

| | |
|---|---|
| **Stream & Search** | Find any anime and stream instantly. Multiple providers with automatic fallback. |
| **AniList Sync** | Progress, scores, and lists sync automatically to your AniList account. |
| **Continue Watching** | Pick up where you left off — the app remembers your episode and timestamp. |
| **Schedule** | See what's airing today and the next 7 days with live countdowns. |
| **Manga Support** | Read chapters, track progress, and sync to AniList. |
| **MPV Player** | Bundled MPV with Anime4K upscaling shaders and custom ModernZ skin. |
| **Download Queue** | Download episodes for offline watching. |
| **Notifications** | Get notified when a new episode of your tracked show airs. |
| **Nightly Builds** | Early-access features from the `nightly` branch. |

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
cd anicat
cd web
npm install
npm run tauri dev
```

Requires Rust, Node.js, and system dependencies for [Tauri v2](https://v2.tauri.app/start/prerequisites/).

## Legal

Anicat is for educational and personal use only. See [DISCLAIMER.md](DISCLAIMER.md) and [SECURITY.md](SECURITY.md).

## License

[GNU General Public License v3.0](LICENSE)
