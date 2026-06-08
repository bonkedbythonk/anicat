# Anicat

![Anicat Desktop](assets/branding/dashboard.png)

**A simple way to watch and track anime on your Mac or Windows PC.** Search, stream, download, and track everything in one place — with a beautiful GUI app.

---

## How to Install

### macOS

#### 1. Open Terminal

Terminal is an app that lets you install things with a text command.

- Press **Command + Space** on your keyboard
- Type **Terminal**
- Press **Enter**

The Terminal app will open — it's a black or white window where you can type commands.

#### 2. Copy and paste this one command

Click inside the Terminal window, then paste (Command + V) this line:

```bash
curl -fsSL https://raw.githubusercontent.com/bonkedbythonk/anicat/master/scripts/install_macos.sh | bash
```

Then press **Enter**. The installer will download and set up everything automatically.

> **What this does:** It downloads the latest version of Anicat from GitHub, moves it to your Applications folder, and sets it up so it works properly on your Mac.

#### 3. Open Anicat

After the install finishes:

1. Open your **Applications** folder (Finder > Applications)
2. Double-click **Anicat**
3. If Mac shows a warning, click **Open** (it's safe — the app is just not from the App Store)

---

### Windows

#### 1. Download the Installer
Go to the [GitHub Releases](https://github.com/bonkedbythonk/anicat/releases) page.

#### 2. Install Anicat
- Download the latest installer file ending with `_x64-setup.exe` (e.g. `Anicat_4.36.4_x64-setup.exe`).
- Run the installer and follow the prompt.

#### 3. Open Anicat
Once installed, launch **Anicat** from your desktop shortcut or Start Menu.

That's it! Anicat will start and you can search for anime right away.

---

## What You Can Do

| Feature | What It Does |
|---------|-------------|
| **Search & Stream** | Find any anime and start watching in one command. Multiple providers with automatic fallback. |
| **AniList Sync** | Your progress, scores, and lists sync automatically to your AniList account. |
| **Continue Watching** | Pick up where you left off. The app remembers which episode and timestamp you were on. |
| **Smart Playlist** | Personalized recommendations from your watching list, top-rated shows, and plan-to-watch. |
| **Airing Schedule** | See what's airing today and the next 7 days, with live countdowns. |
| **Skip Intro** | Automatically detect and skip openings and endings using crowdsourced AniSkip timings. |
| **Batch Download** | Download entire seasons for offline watching, with yt-dlp engine and subtitle merging. |
| **Manga Support** | Read manga chapters from MangaKatana, with progress tracking and chapter navigation. |
| **Notifications** | Get notified when a new episode of your watched show airs, directly from AniList. |
| **One-Click Updates** | Update to the latest version from Settings > Maintenance. No terminal needed after install. |
| **Built-in Player** | Watch right inside the app. HLS.js streaming with auto-quality, picture-in-picture, and keyboard shortcuts. |
| **MPV Integration** | **Highly recommended** — bundled MPV player with built-in Anime4K upscaling shaders for superior visual quality, custom ModernZ skin, and robust subtitle support. |
| **Alternative Streams** | Choose alternative servers inline with client-side sorting (Hard Sub, Soft Sub, Dub) and ultra-fast lazy resolution. |
| **macOS Native Integration** | Premium window management via application menu bar (Show Dashboard, Toggle Quick Pane) and smooth Dock reopen behavior. |

---

## Legal
Anicat is for educational and personal use only. See [DISCLAIMER.md](DISCLAIMER.md) and [SECURITY.md](SECURITY.md).

## License

[MIT](LICENSE)
