#!/bin/bash
set -e

# This script performs a full production build of Anicat and packages it as a .dmg for macOS.
# 1. Configures the bundled mpv player
# 2. Builds the Vite frontend (which also builds the Python scraper, see below)
# 3. Bundles everything into a macOS Application and DMG using Tauri
#
# The scraper binary is NOT built here directly — `npx tauri build` below runs
# `beforeBuildCommand` (`npm run build` -> `build:scraper && tsc && vite build`),
# which invokes scripts/build_scraper.py. That script is the single source of
# truth for the PyInstaller invocation (--onedir, with stale-output cleanup);
# duplicating it here previously used --onefile and a bare `mv`, which broke
# as soon as a previous --onedir build had already left a directory at the
# destination path.

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
PROJECT_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"

echo "🏗️ Starting Full Production Build of Anicat..."

# 1. Setup Portable Companion Player
echo "🎬 Step 1: Configuring Portable Companion Player..."
bash "$SCRIPT_DIR/setup_bundled_player.sh"

# 2. Build Frontend & Tauri App
echo "💻 Step 2: Building Frontend and Bundling App..."
cd "$PROJECT_ROOT/web"

# Ensure dependencies are installed
npm install

# Run the Tauri build command
npx tauri build

echo "✨ Build Complete!"
echo "📂 Your DMG is waiting in: web/src-tauri/target/release/bundle/dmg/"
