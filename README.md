# Anicat

Anicat is a media companion designed specifically for macOS that simplifies how you manage and enjoy anime and manga. It combines a beautiful, minimalist dashboard with powerful background technology to ensure your progress is always synced and your content is always ready to play.

![Anicat Dashboard](dashboard_preview.png)

## Overview

Unlike traditional websites or complex media servers, Anicat is built to be a "quiet citizen" on your Mac. It runs as a lightweight background service that starts automatically when you log in. This means you never have to worry about opening a terminal or starting a server manually—the dashboard is simply there whenever you need it.

## Key Features

### Centralized Media Dashboard
Anicat provides a single, unified interface for your entire library. The dashboard is designed with a dark, minimalist aesthetic that fits perfectly with modern macOS. You can browse your "Continue Watching" list, search for new titles, and manage your collection without ever leaving the app.

### Automatic AniList Synchronization
Your progress is precious. Anicat features bi-directional synchronization with AniList. When you finish an episode or a chapter, the app updates your AniList profile instantly. If you update your progress on your phone, Anicat sees it and reflects the change on your dashboard within seconds.

### High-Performance Manga Reader
Reading manga should be as fast as flipping pages in a book. Anicat uses a specialized backend proxy and local disk caching to ensure that manga chapters load instantly. By pre-fetching pages in the background, the reader allows you to skip forwards and backwards through a chapter with zero lag.

### Background Persistence
Anicat includes a native macOS App bundle that you can keep in your Applications folder and your Dock. Once installed, the core service runs silently in the background. It uses a negligible amount of system resources, ensuring that your Mac remains fast and responsive while Anicat waits for your next session.

### Privacy and Isolation
Privacy is a core design principle. Anicat is configured to run on your "Localhost" (127.0.0.1) only. This ensures that the service is completely invisible to other devices on your network, providing an isolated and secure environment for your media management.

## Installation Guide

The installation process is fully automated and designed to be accessible to everyone, regardless of technical experience.

### Step 1: Open the Terminal
The Terminal is a built-in macOS tool. To open it, press the Command key and the Spacebar at the same time, type "Terminal," and press Enter.

### Step 2: Run the Installer
Copy the command below, paste it into the Terminal window, and press Enter:

```bash
curl -sSL https://raw.githubusercontent.com/bonkedbythonk/anicat/main/scripts/install.sh | bash
```

### Step 3: Complete the Setup
The installer will automatically download all necessary components and configure the background service. Once you see the "Installation Complete" message, you can close the Terminal. You will now find the "Anicat Dashboard" app in your Applications folder.

## Using Anicat

### Getting Started
When you first launch the app, you will be guided through a simple onboarding process to connect your AniList account. This only needs to be done once.

### Staying Updated
Anicat features a built-in update system. When a new version is available, a subtle amber dot will appear next to the Settings icon in the sidebar. You can install the latest features and fixes directly from the Maintenance tab with a single click.

### Management
If you ever need to stop the background service or check the system health, you can use the built-in Maintenance tools in the dashboard or use the "anicat" command in your terminal.

---

Anicat is released under the UNLICENSE.
