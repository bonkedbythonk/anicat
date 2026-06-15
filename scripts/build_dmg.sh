#!/bin/bash
set -e

# This script performs a full production build of Anicat and packages it as a .dmg for macOS.
# 1. Builds the Python scraper as a standalone PyInstaller binary
# 2. Builds the Vite frontend
# 3. Bundles everything into a macOS Application and DMG using Tauri

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
PROJECT_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"

echo "🏗️ Starting Full Production Build of Anicat..."

# 1. Build Python scraper binary via PyInstaller
echo "📡 Step 1: Building Standalone Python Scraper..."
cd "$PROJECT_ROOT/scraper"
uv run pyinstaller --onefile --name anicat-scraper \
  --hidden-import curl_cffi \
  --hidden-import selectolax \
  --collect-all curl_cffi \
  --collect-all selectolax \
  main.py
mkdir -p "$PROJECT_ROOT/web/src-tauri/resources/scraper-bin"
mv dist/anicat-scraper "$PROJECT_ROOT/web/src-tauri/resources/scraper-bin/"
cd "$PROJECT_ROOT"

# 2. Setup Portable Companion Player
echo "🎬 Step 2: Configuring Portable Companion Player..."
bash "$SCRIPT_DIR/setup_bundled_player.sh"

# 3. Build Frontend & Tauri App
echo "💻 Step 3: Building Frontend and Bundling App..."
cd "$PROJECT_ROOT/web"

# Ensure dependencies are installed
npm install

# Run the Tauri build command
npx tauri build

echo "✨ Build Complete!"
echo "📂 Your DMG is waiting in: web/src-tauri/target/release/bundle/dmg/"
