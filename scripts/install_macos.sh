#!/bin/bash
set -e

# Anicat Easy macOS Installer
# This script downloads the latest release from GitHub, installs it, and bypasses Gatekeeper.
#

REPO="bonkedbythonk/anicat"
APP_NAME="Anicat.app"
INSTALL_PATH="/Applications/$APP_NAME"


echo "Step 1: Finding the latest version..."
UPDATE_BRANCH="stable"
CONFIG_FILE="$HOME/Library/Application Support/anicat/config.toml"
if [ ! -f "$CONFIG_FILE" ]; then
    CONFIG_FILE="$HOME/.config/anicat/config.toml"
fi

if [ -f "$CONFIG_FILE" ]; then
    if grep -q 'update_branch = "nightly"' "$CONFIG_FILE"; then
        UPDATE_BRANCH="nightly"
    fi
fi

if [ "$UPDATE_BRANCH" = "nightly" ]; then
    # Fetch the release tagged "nightly"
    LATEST_RELEASE=$(curl -s "https://api.github.com/repos/$REPO/releases/tags/nightly" 2>/dev/null)
else
    # Fetch the latest non-prerelease release (first in the list that isn't a prerelease)
    LATEST_RELEASE=$(curl -s "https://api.github.com/repos/$REPO/releases" | python3 -c "
import sys, json
try:
    data = json.load(sys.stdin)
    if isinstance(data, list):
        for r in data:
            if not r.get('prerelease', False) and not r.get('draft', False):
                print(json.dumps(r))
                break
except: pass
" 2>/dev/null)
fi

DOWNLOAD_URL=$(echo "$LATEST_RELEASE" | grep -o "https://github.com/bonkedbythonk/anicat/releases/download/[^\"]*\.dmg" | head -n 1)

if [ -z "$DOWNLOAD_URL" ]; then
    echo "Couldn't find a download link. The latest release might still be building."
    echo "Try again in a few minutes, or download manually from:"
    echo "  https://github.com/bonkedbythonk/anicat/releases"
    exit 1
fi

# Auto-detect nightly
if echo "$DOWNLOAD_URL" | grep -q "nightly"; then
    UPDATE_BRANCH="nightly"
fi

TMP_DMG="/tmp/anicat_latest.dmg"
echo "Step 2: Downloading... (this might take a minute)"
if [ -t 2 ]; then
    curl -L -o "$TMP_DMG" "$DOWNLOAD_URL" --progress-bar
else
    curl -L -sS -o "$TMP_DMG" "$DOWNLOAD_URL"
fi

# Clean up any stuck mounts
echo "Step 3: Preparing installation..."

# Close existing running instances first to release file locks on the app bundle and the server port
# Use osascript for graceful quit (more reliable than killall, which often fails silently)
osascript -e 'tell application "Anicat" to quit' 2>/dev/null || true
osascript -e 'tell application "Anicat Dev" to quit' 2>/dev/null || true
sleep 2
# Force-kill any remaining processes (sidecar, port holder)
killall "anicat-server" 2>/dev/null || true
lsof -ti :13370 | xargs kill -9 2>/dev/null || true
sleep 1

for volume in /Volumes/Anicat*; do
    if [ -d "$volume" ]; then
        hdiutil detach -force "$volume" 2>/dev/null || true
    fi
done

echo "Mounting DMG and copying application..."
MOUNT_POINT=$(hdiutil mount "$TMP_DMG" | tail -n 1 | awk -F '\t' '{print $3}')

if [ -d "$INSTALL_PATH" ]; then
    rm -rf "$INSTALL_PATH"
fi
cp -R "$MOUNT_POINT/$APP_NAME" "/Applications/"

# Cleanup
hdiutil detach -force "$MOUNT_POINT" 2>/dev/null || hdiutil detach "$MOUNT_POINT" 2>/dev/null || true
rm -f "$TMP_DMG"

# Remove quarantine flag recursively from the entire app bundle
xattr -r -d com.apple.quarantine "$INSTALL_PATH" 2>/dev/null || true

# Write nightly config if needed
if [ "$UPDATE_BRANCH" = "nightly" ]; then
    CONFIG_DIR="$HOME/Library/Application Support/anicat"
    CONFIG_FILE="$CONFIG_DIR/config.toml"
    mkdir -p "$CONFIG_DIR"
    if [ -f "$CONFIG_FILE" ]; then
        if grep -q '^update_branch' "$CONFIG_FILE"; then
            sed -i '' 's/^update_branch = .*/update_branch = "nightly"/' "$CONFIG_FILE"
        else
            echo 'update_branch = "nightly"' >> "$CONFIG_FILE"
        fi
    else
        cat > "$CONFIG_FILE" <<'TOML'
[general]
update_branch = "nightly"
TOML
    fi
fi

# Start Anicat
echo "Step 4: Opening Anicat..."
# We don't start the sidecar manually here, as the Tauri application's Rust core
# handles spawning and lifecycle management of its bundled anicat-server sidecar automatically.
open -a "$INSTALL_PATH"

echo ""
echo "================================="
echo "   Anicat is ready!"
echo "================================="
echo ""
echo "The app should open now."
echo "If not, open your Applications folder and click Anicat."
echo ""
echo "Enjoy watching!"
