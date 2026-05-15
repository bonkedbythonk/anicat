# Anicat

Anicat is a media companion for macOS designed for anime and manga management. It provides a centralized dashboard to stream content, track progress via AniList, and manage local reading with a focus on performance and minimalist design.

![Anicat Dashboard](dashboard_preview.png)

## Features

- **macOS Native Service**: Runs as a persistent LaunchAgent background service with a native App bundle for Dock integration.
- **Privacy Focused**: Network isolation via 127.0.0.1 (Localhost) binding ensures the service is invisible to external devices.
- **High-Speed Manga**: Backend image proxy with persistent disk caching for instantaneous page navigation.
- **Real-time Synchronization**: Bi-directional AniList sync for automated progress tracking across devices.
- **Advanced Playback**: Native MPV integration supporting custom shaders, subtitle selection, and multi-track audio.
- **Automated Maintenance**: Integrated update system with background fetch and one-click installation.

## Keyboard Shortcuts

### Video Player (MPV)
- `Space`: Play / Pause
- `F`: Toggle Fullscreen
- `Shift + N`: Skip to Next Episode
- `Shift + P`: Return to Previous Episode
- `Left / Right`: Seek backwards/forwards (5 seconds)
- `Up / Down`: Volume control
- `[` / `]`: Adjust playback speed
- `J`: Cycle through subtitles
- `#`: Cycle through audio tracks
- `Q`: Quit player and save progress

### Manga Reader
- `Left / Right`: Previous / Next page
- `F`: Toggle Fullscreen
- `S`: Single Page mode
- `D`: Double Page mode
- `V`: Vertical (Long-strip) mode
- `Esc`: Close reader

## Installation

Anicat can be installed via a single command. The installer automatically manages system dependencies (mpv, ffmpeg, chafa) and initializes the background service.

```bash
curl -sSL https://raw.githubusercontent.com/bonkedbythonk/anicat/main/scripts/install.sh | bash
```

## Usage

### Dashboard
The primary interface is the **Anicat Dashboard** application, located in the `/Applications` folder. Launching the app opens the web-based interface in your default browser.

### Command Line Interface
Anicat includes a global command-line utility for advanced management:
- `anicat status`: View system health and connectivity reports.
- `anicat stop`: Terminate all background processes.
- `anicat dashboard`: Start the server manually.

## Tech Stack

- **Backend**: Python (FastAPI), Uvicorn
- **Frontend**: Next.js (React), Tailwind CSS
- **Playback**: MPV (Native)
- **Persistence**: SQLite-based local registry

## License

Anicat is released under the UNLICENSE.
