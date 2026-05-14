# Anicat

Your anime streaming app for macOS. Search, stream, and track anime all in one place.

---

## Quick Start (2 Steps)

### Step 1: Open Terminal & Copy-Paste This

Open the **Terminal** app (press `Cmd+Space`, type `terminal`, and press Enter).

Then copy and paste **this entire line** into Terminal and press Enter:

```bash
git clone https://github.com/bonkedbythonk/anicat.git && cd anicat && ./scripts/install.sh
```

### Step 2: Enjoy!

**That's it!** The app will install everything and then **automatically open the dashboard** in your browser.

- To open it again later, just type `anicat dashboard` in your terminal.
- To use the terminal version, just type `anicat`.

---

## Features

- **Premium Dashboard:** A beautiful web interface to browse and watch.
- **Search Anime:** Find anything in a huge anime library.
- **Stream Online:** Watch episodes directly (up to 1080p).
- **Download:** Save episodes to watch offline.
- **Track Progress:** Keep your watch list in sync with AniList.
- **Simple Setup:** One command and you're ready to go.

---

## Getting Started

### First Time You Use Anicat

1. **Wait for the installer** to finish (it will open the dashboard for you).
2. **Follow the Onboarding**: A friendly guide will help you connect your AniList account (optional).
3. **Search for anime** and start watching!

### Want to Update Later?

Just run this in Terminal to get the latest features:

```bash
cd anicat && git pull && ./scripts/install.sh
```

---

## Troubleshooting

**Installation says "destination path 'anicat' already exists"?**
- This means you already have an old version of the folder.
- **To overwrite and start fresh**, run this instead:
  ```bash
  rm -rf anicat && git clone https://github.com/bonkedbythonk/anicat.git && cd anicat && ./scripts/install.sh
  ```

**Terminal says \"command not found: anicat\"?**
- This usually means your terminal needs to be \"refreshed\" after the first installation.
- **Try this**: Close your Terminal window and open a new one.
- **Still not working?** Copy and paste this line into your terminal: `source ~/.zshrc` (or `source ~/.bash_profile` if you are on an older Mac).

**Does it install Homebrew and MPV?**
- **Yes!** The installer will check if you have Homebrew and MPV. If you don't, it will ask for your permission to install them automatically so the app works perfectly.

**Videos won't play?**
- Check your internet connection.
- Make sure you have `mpv` installed (the installer usually handles this, but you can run `brew install mpv` if needed).

---

## Two Ways to Use Anicat

### **1. Web Dashboard** (Recommended)
The web dashboard is the easy, visual way to use Anicat.
- Type `anicat dashboard` in Terminal to open it.
- Search, browse, and watch visually.

### **2. Command Line**
If you like the terminal, you can use Anicat directly there too!
- Type `anicat` to see all commands.
- It's powerful, fast, and stays out of your way.

---

## Credits
Anicat is a specialized macOS fork of the [Viu](https://github.com/viu-media/viu) project, refined for a premium dashboard experience and enhanced automation.
