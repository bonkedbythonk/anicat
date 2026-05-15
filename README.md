# Anicat

A specialized media companion for macOS focused on anime and manga management. Anicat provides a local-first dashboard to stream content, track progress via AniList, and manage reading with an emphasis on performance and network privacy.

## Features

- **macOS Integration**: Runs as a persistent LaunchAgent background service. Includes a native App bundle for the macOS Dock.
- **Local-Only Operation**: Server binds to `127.0.0.1` for maximum privacy and isolation from the local network.
- **Manga Performance**: Implements a high-speed backend proxy with persistent disk caching to eliminate provider throttling.
- **AniList Synchronization**: Bi-directional real-time sync with AniList for progress and media status.
- **Modular Dashboard**: A minimalist PWA interface for media management and system maintenance.

## Installation

Anicat can be installed via a single command. The installer manages system dependencies (mpv, ffmpeg, chafa) and configures the background service.

```bash
curl -sSL https://raw.githubusercontent.com/bonkedbythonk/anicat/main/scripts/install.sh | bash
```

## Usage

Once installed, the dashboard is accessible via the **Anicat Dashboard** application in your Applications folder.

### Commands
- **anicat dashboard**: Manages the server lifecycle.
- **anicat stop**: Terminates all background services.
- **anicat status**: Provides health and connectivity reports.

### Maintenance
Updates are delivered via the **Settings > Maintenance** tab in the dashboard. A visual indicator in the sidebar notifies you when a new version is available. The update process is handled silently in the background.

## Architecture

Anicat is built with a Python backend (FastAPI) and a Next.js frontend. It uses a local registry for metadata persistence, allowing for offline access to your media library and progress history.

---

Released under the UNLICENSE.
