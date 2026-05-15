# Anicat

**The specialized media companion for macOS.**  
Stream anime, read manga, and track progress with zero friction.

[![Platform](https://img.shields.io/badge/Platform-macOS-silver?style=flat-square&logo=apple)](https://github.com/bonkedbythonk/anicat)
[![Interface](https://img.shields.io/badge/Interface-Web_%2F_TUI-amber?style=flat-square)](https://github.com/bonkedbythonk/anicat)
[![Sync](https://img.shields.io/badge/Sync-AniList-blue?style=flat-square)](https://github.com/bonkedbythonk/anicat)

Anicat is a production-ready media dashboard designed for the modern macOS experience. It bridges the gap between streaming sources and AniList, all within a minimalist dashboard that operates silently in the background.

![Anicat Dashboard Preview](dashboard_preview.png)

## Installation

Anicat can be installed via a single command. The script automatically manages system dependencies (mpv, ffmpeg, chafa), configures the background service, and creates a native macOS App bundle.

```bash
curl -sSL https://raw.githubusercontent.com/bonkedbythonk/anicat/main/scripts/install.sh | bash
```

## Key Features

### macOS Native Persistence
- **Silent Service**: Runs as a macOS LaunchAgent, starting automatically upon login with minimal system impact.
- **Application Bundle**: Installs as "Anicat Dashboard.app" for a native presence in the Applications folder and Dock.
- **Stealth Mode**: Locked to 127.0.0.1 (Localhost) by default for total network isolation and privacy.

### High-Performance Manga Reader
- **Turbo Proxy**: Bypasses provider throttling and hotlink blocks for high-speed page delivery.
- **Persistent Disk Cache**: Implements local caching and predictive pre-fetching for instantaneous navigation through chapters.
- **Advanced Layouts**: Full support for Single Page, Double Page, and Vertical reading modes.

### Seamless Media Streaming
- **1080p Playback**: Integrated MPV support with optimized streaming buffers and high-quality rendering.
- **Bi-Directional Sync**: Real-time AniList progress tracking. Watch status is updated instantly upon playback.
- **Offline Registry**: Maintains a local metadata database for library persistence and offline progress tracking.

## Usage

Once installed, the dashboard is controlled via the web interface or the command-line utility.

- **Dashboard**: Launch the "Anicat Dashboard" application from your `/Applications` folder.
- **Update System**: A visual indicator in the sidebar notifies you of new versions. Updates are installed with a single click from Settings > Maintenance.
- **CLI Commands**:
  - `anicat dashboard` — Manage the server process.
  - `anicat status` — Report health and connectivity.
  - `anicat stop` — Terminate all background processes.

## Privacy

Anicat is designed to be a private, local-first utility. No telemetry or analytics are collected. All data remains on your local machine, and external communication is limited strictly to media providers and AniList API calls.

---

Released under the [UNLICENSE](LICENSE). Built for the macOS community.
