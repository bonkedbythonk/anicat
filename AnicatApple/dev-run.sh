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
# Ask SwiftPM where it put the binary. Xcode 27's build system writes to
# .build/out/Products/Debug, and the old hardcoded arm64-apple-macosx/debug
# path kept a Sep 15 binary that two "deployments" of a crash fix shipped
# before anyone noticed the fix was not in it.
BIN="$(swift build --product Anicat -c debug --show-bin-path)/Anicat"
cp "$BIN" dist/Anicat.app/Contents/MacOS/Anicat
# The resource bundle too, or the binary runs against whatever art the last
# packaging run left: a Sep 11 bundle drew the retired cat watermark in a
# dev build while the shipped app drew the paw. rsync, not `cp -R`, which
# nests a second copy inside an existing bundle directory.
rsync -a --delete "$(dirname "$BIN")/AnicatApple_AnicatUI.bundle/" \
    dist/Anicat.app/Contents/Resources/AnicatApple_AnicatUI.bundle/
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
# The macOS 26 icon with its dark variant; see package-anicat-macos-app.sh.
if [ -f ../assets/branding/Assets.car ]; then
    cp ../assets/branding/Assets.car dist/Anicat.app/Contents/Resources/Assets.car
    /usr/libexec/PlistBuddy -c "Set :CFBundleIconName AppIcon" "$PLIST" 2>/dev/null \
        || /usr/libexec/PlistBuddy -c "Add :CFBundleIconName string AppIcon" "$PLIST"
fi
# Same activity types the packaged plist declares; without them Spotlight
# hits and Handoff never reach the app.
/usr/libexec/PlistBuddy -c "Delete :NSUserActivityTypes" "$PLIST" 2>/dev/null || true
/usr/libexec/PlistBuddy -c "Add :NSUserActivityTypes array" "$PLIST"
for t in com.apple.corespotlightitem com.anicat.playback com.anicat.reading; do
    /usr/libexec/PlistBuddy -c "Add :NSUserActivityTypes: string $t" "$PLIST"
done
# Signed with a real identity, not ad-hoc.
#
# TCC keys a folder grant to the app's designated requirement. Under an ad-hoc
# signature that requirement is the cdhash, which changes with every build --
# so each rebuild was a different app to the system and it asked for Downloads
# and Documents again, every single time. Signing with a development identity
# makes the requirement identifier + team, which survives rebuilds, and the
# grant is given once.
#
# The identity is auto-detected rather than written down here: it is personal
# to the machine and this file is public. `ANICAT_CODESIGN_IDENTITY` overrides.
SIGN_IDENTITY="${ANICAT_CODESIGN_IDENTITY:-}"
if [ -z "$SIGN_IDENTITY" ]; then
    SIGN_IDENTITY=$(security find-identity -v -p codesigning 2>/dev/null \
        | grep "Apple Development" | head -1 | sed -E 's/.*"(.*)"/\1/')
fi
if [ -n "$SIGN_IDENTITY" ]; then
    # Explicit identifier: without one the signature is identified by the
    # executable's name plus a hash, which is not what the bundle claims and
    # not stable either.
    codesign --force --sign "$SIGN_IDENTITY" --identifier com.anicat.app \
        --timestamp=none dist/Anicat.app >/dev/null 2>&1 \
        && echo "signed as $SIGN_IDENTITY" \
        || echo "dev-run: codesign failed; folder prompts will repeat"
else
    echo "dev-run: no signing identity found -- macOS will ask for Downloads/Documents on every build."
    echo "dev-run: set ANICAT_CODESIGN_IDENTITY, or add an Apple Development certificate."
fi

open dist/Anicat.app
