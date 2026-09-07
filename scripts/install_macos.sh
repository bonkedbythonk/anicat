#!/bin/bash
set -e

# Anicat macOS installer. Downloads the latest release, installs it into
# /Applications and clears the quarantine flag the ad-hoc signature would
# otherwise trip over.
#
#   curl -fsSL https://raw.githubusercontent.com/bonkedbythonk/anicat/master/scripts/install_macos.sh | bash

REPO="bonkedbythonk/anicat"
APP_NAME="Anicat.app"
INSTALL_PATH="/Applications/$APP_NAME"

if [ "$(uname -m)" != "arm64" ]; then
    echo "Anicat is built for Apple silicon only; this machine reports $(uname -m)."
    echo "Build from source: https://github.com/bonkedbythonk/anicat#building-from-source"
    exit 1
fi

echo "Step 1: Finding the latest version..."
# Deliberately no python3 here. A stock macOS has no usable interpreter --
# /usr/bin/python3 is a stub that prompts for a multi-GB Xcode Command Line
# Tools install -- and this script has to work on a machine with nothing but
# Terminal. /releases/latest already excludes drafts and prereleases, so the
# asset URL can be pulled straight out with grep. Everything else this script
# uses (curl, ditto, xattr, osascript) ships with the base system.
DOWNLOAD_URL=$(curl -sSL "https://api.github.com/repos/$REPO/releases/latest" \
    | grep -o "https://github.com/$REPO/releases/download/[^\"]*macos-arm64\.zip" \
    | head -n 1)

if [ -z "$DOWNLOAD_URL" ]; then
    echo "Couldn't find a download link. The latest release might still be building."
    echo "Try again in a few minutes, or download manually from:"
    echo "  https://github.com/$REPO/releases"
    exit 1
fi

TMP_DIR="$(mktemp -d)"
trap 'rm -rf "$TMP_DIR"' EXIT
TMP_ZIP="$TMP_DIR/anicat.zip"

echo "Step 2: Downloading... (this might take a minute)"
if [ -t 2 ]; then
    curl -L -o "$TMP_ZIP" "$DOWNLOAD_URL" --progress-bar
else
    curl -L -sS -o "$TMP_ZIP" "$DOWNLOAD_URL"
fi

echo "Step 3: Installing..."
# A running copy holds its own executable open; replacing the bundle under it
# leaves a half-old app that crashes on the next window. Quit it first.
osascript -e 'tell application "Anicat" to quit' 2>/dev/null || true
sleep 2

# ditto, not unzip: unzip drops the symlinks and extended attributes inside a
# .app bundle, which breaks the signature and Gatekeeper rejects the result.
ditto -x -k "$TMP_ZIP" "$TMP_DIR/extracted"

if [ ! -d "$TMP_DIR/extracted/$APP_NAME" ]; then
    echo "The downloaded archive did not contain $APP_NAME."
    exit 1
fi

rm -rf "$INSTALL_PATH"
ditto "$TMP_DIR/extracted/$APP_NAME" "$INSTALL_PATH"

# The bundle is ad-hoc signed, not notarized, so without this macOS refuses to
# open it and offers only "Move to Trash".
xattr -r -d com.apple.quarantine "$INSTALL_PATH" 2>/dev/null || true

echo "Step 4: Opening Anicat..."
open "$INSTALL_PATH"

echo ""
echo "================================="
echo "   Anicat is ready!"
echo "================================="
echo ""
echo "The app should open now."
echo "If not, open your Applications folder and click Anicat."
echo ""
echo "Connect your AniList account from Settings to sync your library."
