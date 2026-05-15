# Anicat

Anicat is a media companion for macOS designed for anime and manga management. It provides a centralized dashboard to stream content, track progress via AniList, and manage local reading with a focus on performance and minimalist design.

![Anicat Dashboard](dashboard_preview.png)

## Features

- **macOS Native Service**: Runs as a persistent LaunchAgent background service with a native App bundle for Dock integration.
- **Privacy Focused**: Network isolation via 127.0.0.1 (Localhost) binding ensures the service is invisible to external devices.
- **Manga Optimization**: High-speed backend proxy with persistent disk caching and predictive pre-fetching for instantaneous navigation.
- **Real-time Synchronization**: Bi-directional AniList sync for automated progress tracking across devices.
- **Lightweight Architecture**: Optimized for low CPU and memory footprint while maintaining persistent availability.
- **Automated Maintenance**: Integrated update system with background fetch and one-click installation.

## Installation

Anicat can be installed via a single command. The installer automatically manages system dependencies (mpv, ffmpeg, chafa) and initializes the background service.

```bash
curl -sSL https://raw.githubusercontent.com/bonkedbythonk/anicat/main/scripts/install.sh | bash
```

## Usage

### Dashboard
The primary interface is the **Anicat Dashboard** application, located in the `/Applications` folder. Launching the app opens the web-based PWA in your default browser.

### Command Line Interface
Anicat includes a global command-line utility for advanced management:

- `anicat dashboard`: Start or stop the server.
- `anicat status`: View system health and connectivity reports.
- `anicat stop`: Terminate all background processes.

### Updates
A visual indicator in the sidebar notifies the user when an update is available. Updates can be installed via the **Settings > Maintenance** tab, which handles the build process and service restart automatically.

## Tech Stack

- **Backend**: Python (FastAPI), Uvicorn
- **Frontend**: Next.js (React), Tailwind CSS, Lucide Icons
- **Persistence**: SQLite-based local registry
- **Background**: macOS LaunchAgent

## License

Anicat is released under the UNLICENSE. For more information, please refer to the [LICENSE](LICENSE) file.
