# Anicat

Anicat is a production-ready media companion for macOS. It provides a centralized dashboard to stream anime, read manga, and track progress via AniList, all within a minimalist environment that operates silently in the background.

![Anicat Dashboard](dashboard_preview.png)

## How it Works

Anicat is designed as a **Silent Engine**. Unlike typical apps, it is split into two parts:

1.  **The Server (The Brain)**: When you install Anicat, it sets up a macOS "LaunchAgent." This means the core logic starts automatically when you log in to your Mac. It stays hidden, uses almost zero resources, and handles all your AniList syncing and manga caching behind the scenes.
2.  **The Dashboard (The Remote)**: The "Anicat Dashboard" app in your Applications folder is your way to talk to the brain. It opens the web interface where you actually watch and read.

By separating these, Anicat can keep tracking your progress and checking for updates even when the dashboard window is closed.

## Installation

Anicat is installed via a single command that manages system dependencies (mpv, ffmpeg, chafa), configures the background service, and creates the native App bundle.

```bash
curl -sSL https://raw.githubusercontent.com/bonkedbythonk/anicat/main/scripts/install.sh | bash
```

## Features

- **macOS Native Persistence**: Operates as a background service that survives restarts and terminal closures.
- **Stealth Privacy**: Bound to 127.0.0.1 (Localhost), making it invisible to other devices on your Wi-Fi.
- **Manga Turbo-Mode**: High-speed image proxying with local disk caching for instantaneous navigation.
- **AniList Real-time Sync**: Progress is updated on AniList the microsecond it changes in Anicat.
- **Automated Updates**: A sidebar indicator notifies you of new versions; updates are installed with a single click.

## Command Line Interface (Advanced)

While most users will only ever use the Dashboard app, the `anicat` command provides deep control over the system:

- `anicat status`: Displays the current health, version, and connectivity of the background server.
- `anicat stop`: Safely terminates the background server. Use this if you want to completely shut down Anicat.
- `anicat dashboard`: Manually starts the server. (Note: The App bundle does this for you automatically).
- `anicat login`: Manually trigger the AniList authentication flow.

## Maintenance and Updates

Anicat is designed to be self-sustaining. When an update is pushed, an amber notification dot will appear in the dashboard sidebar. 

Clicking **Install Update** in the Maintenance settings will:
1.  Stash your local configuration safely.
2.  Pull the latest code from GitHub.
3.  Rebuild the dashboard.
4.  Restart the background service automatically.

## Technical Details

- **Language**: Python (Backend), Next.js (Frontend)
- **Database**: SQLite-based local registry (found in `~/Library/Application Support/anicat`)
- **Persistence**: macOS LaunchAgent (`~/Library/LaunchAgents/com.bonkedbythonk.anicat.plist`)
- **Network**: Only listens on Port 8000 (Localhost only).

---

Released under the [UNLICENSE](LICENSE). Built for the macOS community.
