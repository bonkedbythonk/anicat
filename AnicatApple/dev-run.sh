#!/bin/bash
# Rebuild Anicat and relaunch it via the dev .app bundle.
#
# Running the bare `swift build` binary directly doesn't work for anything
# that needs Cmd+Tab/Dock presence: without a real .app's Info.plist, AppKit
# treats the process as background-only. dist/Anicat.app carries that
# Info.plist, so copy the freshly built binary into it and `open` the bundle
# instead of the raw executable.
set -euo pipefail
cd "$(dirname "$0")"

swift build --product Anicat -c debug

pkill -f "dist/Anicat.app/Contents/MacOS/Anicat" 2>/dev/null || true
cp .build/arm64-apple-macosx/debug/Anicat dist/Anicat.app/Contents/MacOS/Anicat
# The bundle's Info.plist was written once by a packaging run and never
# touched again, so Settings > Maintenance kept reporting whatever version
# that run had (1.0.0, for months). Stamp it from version.txt every run.
VERSION="$(tr -d '[:space:]' < ../version.txt)"
PLIST=dist/Anicat.app/Contents/Info.plist
/usr/libexec/PlistBuddy -c "Set :CFBundleShortVersionString $VERSION" "$PLIST" 2>/dev/null \
    || /usr/libexec/PlistBuddy -c "Add :CFBundleShortVersionString string $VERSION" "$PLIST"
/usr/libexec/PlistBuddy -c "Set :CFBundleVersion $VERSION" "$PLIST" 2>/dev/null \
    || /usr/libexec/PlistBuddy -c "Add :CFBundleVersion string $VERSION" "$PLIST"
# `anicat://` URL scheme. Deleted first, then rebuilt: `Add` on a key that
# already exists exits non-zero, and this script runs under `set -e` on every
# rebuild, so an incremental Add would abort the run the second time.
/usr/libexec/PlistBuddy -c "Delete :CFBundleURLTypes" "$PLIST" 2>/dev/null || true
/usr/libexec/PlistBuddy -c "Add :CFBundleURLTypes array" "$PLIST"
/usr/libexec/PlistBuddy -c "Add :CFBundleURLTypes:0 dict" "$PLIST"
/usr/libexec/PlistBuddy -c "Add :CFBundleURLTypes:0:CFBundleURLName string Anicat" "$PLIST"
/usr/libexec/PlistBuddy -c "Add :CFBundleURLTypes:0:CFBundleURLSchemes array" "$PLIST"
/usr/libexec/PlistBuddy -c "Add :CFBundleURLTypes:0:CFBundleURLSchemes:0 string anicat" "$PLIST"
# Same icon as the packaged app, so the dev copy is not the generic icon
# in the Dock and Cmd-Tab.
ICON=../assets/branding/icon.icns
if [ -f "$ICON" ]; then
    mkdir -p dist/Anicat.app/Contents/Resources
    cp "$ICON" dist/Anicat.app/Contents/Resources/AppIcon.icns
    /usr/libexec/PlistBuddy -c "Set :CFBundleIconFile AppIcon" "$PLIST" 2>/dev/null \
        || /usr/libexec/PlistBuddy -c "Add :CFBundleIconFile string AppIcon" "$PLIST"
fi
open dist/Anicat.app
