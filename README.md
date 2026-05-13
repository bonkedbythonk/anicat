# Anicat

Your anime streaming app for macOS. Search, stream, and track anime all in one place.

---

## Quick Start (3 Steps)

### Step 1: Get the App

Download Anicat from GitHub:
1. Go to: https://github.com/bonkedbythonk/anicat/releases
2. Look for the latest **Anicat.dmg** file
3. Download it

### Step 2: Install

1. **Double-click** the downloaded `Anicat.dmg` file
2. **Drag** the Anicat icon to your `Applications` folder
3. Close the window

### Step 3: Launch

1. Open your `Applications` folder (or press `Cmd+Shift+A`)
2. **Double-click Anicat**
3. The app opens automatically—that's it!

---

## Features

- **Search Anime:** Find anything in a huge anime library
- **Stream Online:** Watch episodes directly (up to 1080p)
- **Download:** Save episodes to watch offline
- **Track Progress:** Keep your watch list in sync with AniList
- **Simple Interface:** Designed to be easy to use

---

## Getting Started

### First Time Setup

1. **Open Anicat** from your Applications folder
2. **Sign in with AniList** (optional) to sync your watch list
3. **Search for anime** and start watching!

---

## Troubleshooting

**App won't open?**
- Try restarting your Mac
- Make sure you have at least 2GB free disk space

**Videos won't play?**
- Check your internet connection
- Try a different video quality (Settings → Quality)

---

## For Developers & Advanced Users

If you want to modify the code or understand how it works:

### Prerequisites

You'll need:
- macOS 12 or later
- Homebrew (https://brew.sh/)

### Installation for Developers

```bash
# 1. Install dependencies
brew install mpv fzf

# 2. Clone the project
git clone https://github.com/bonkedbythonk/anicat.git
cd anicat

# 3. Install with uv (Python package manager)
curl -LsSf https://astral.sh/uv/install.sh | sh
uv tool install -e .

# 4. Run the dashboard
anicat dashboard
```

### Web Dashboard (Development)

If you want to work on the web interface:

```bash
# Start backend (keep this running)
anicat dashboard --no-browser

# In another terminal, start frontend
cd web
npm run dev

# Open http://localhost:3000 in your browser
```

---

## What You Can Do

**Search & Discover**
- Browse thousands of anime titles
- Filter by genre, season, or popularity
- Read reviews and recommendations

**Stream**
- Watch high-quality anime (up to 1080p)
- Resume where you left off
- Auto-tracking of your progress

**Download**
- Save episodes to watch offline
- Queue multiple episodes at once
- Manage your library

**Track Your List**
- Connect with AniList to sync your watch list
- Rate shows and episodes
- Keep track of completed, watching, and planned anime

---

## Settings & Customization

Open Settings to customize:
- **Playback Quality:** Choose your video quality preference
- **Download Location:** Pick where to save episodes
- **Streaming Providers:** Select your preferred anime sources
- **Theme:** Light or dark mode

---

## Need Help?

**Issues or Questions?**
- Check GitHub Issues: https://github.com/bonkedbythonk/anicat/issues
- Report a bug: Click "Report Bug" in Settings

---

## Credits
Anicat is a specialized macOS fork of the [Viu](https://github.com/viu-media/viu) project, refined for a premium dashboard experience and enhanced automation.
