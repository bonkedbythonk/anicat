#!/bin/bash
set -euo pipefail

# make_mpv_app.sh
# Wraps the bundled mpv binary in a minimal .app so macOS hands the player
# anicat's own Dock icon instead of the generic executable placeholder. An
# icon is the only reason this bundle exists: a bare Mach-O has no Info.plist,
# so NSApplication has nothing to read an icon from, and the alternative --
# setting it at runtime through objc_msgSend from the mpv Lua script -- was
# ~50 lines of FFI to reproduce what CFBundleIconFile does for free.
#
# The dylibs are deliberately NOT copied in. Their load commands read
# `@executable_path/lib`, which points nowhere once the executable sits two
# directories deeper, so playback.rs passes the flat resources/lib through
# DYLD_LIBRARY_PATH instead (dyld consults it ahead of the recorded install
# name). Copying 47MB of libraries in would also give verify_bundle.sh two
# versions of every library family to complain about.
#
# codesign always resolves a path inside a bundle to the bundle itself, so the
# ad-hoc signature at the end covers the whole .app, sealing Info.plist and the
# icon alongside the Mach-O. That is what verify_bundle.sh's `codesign -v` pass
# ends up checking here, so keep the bundle free of anything Tauri's resource
# copy would not reproduce byte for byte (a stray .DS_Store breaks the seal).
#
# Usage: bash scripts/make_mpv_app.sh [resources-dir]

RESOURCES_DIR="${1:-web/src-tauri/resources}"
APP="$RESOURCES_DIR/mpv.app"
ICON="$RESOURCES_DIR/mpv_icon.icns"

if [ ! -f "$RESOURCES_DIR/mpv" ]; then
    echo "make_mpv_app: no mpv binary at $RESOURCES_DIR/mpv — nothing to wrap." >&2
    exit 1
fi
if [ ! -f "$ICON" ]; then
    echo "make_mpv_app: no icon at $ICON." >&2
    exit 1
fi

# mpv reports its version through a binary that needs the flat lib dir on the
# dylib search path. Best-effort only: the plist is valid without a real one.
MPV_VERSION=$(DYLD_LIBRARY_PATH="$RESOURCES_DIR/lib" "$RESOURCES_DIR/mpv" --version 2>/dev/null \
    | head -n 1 | sed -n 's/^mpv v\([0-9.]*\).*/\1/p')
MPV_VERSION="${MPV_VERSION:-0.0.0}"

rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"

cp "$RESOURCES_DIR/mpv" "$APP/Contents/MacOS/mpv"
chmod 755 "$APP/Contents/MacOS/mpv"
cp "$ICON" "$APP/Contents/Resources/mpv.icns"

# The identifier is anicat's own, not mpv's io.mpv: LaunchServices keys its
# per-app state off the identifier, and colliding with a user's separately
# installed mpv is how one ends up showing the other's icon.
cat > "$APP/Contents/Info.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>CFBundleExecutable</key>
    <string>mpv</string>
    <key>CFBundleIconFile</key>
    <string>mpv.icns</string>
    <key>CFBundleIdentifier</key>
    <string>com.anicat.player</string>
    <key>CFBundleName</key>
    <string>Anicat Player</string>
    <key>CFBundlePackageType</key>
    <string>APPL</string>
    <key>CFBundleShortVersionString</key>
    <string>$MPV_VERSION</string>
    <key>LSMinimumSystemVersion</key>
    <string>10.15</string>
    <key>NSHighResolutionCapable</key>
    <true/>
</dict>
PLIST
echo "</plist>" >> "$APP/Contents/Info.plist"

xattr -cr "$APP" 2>/dev/null || true
codesign -s - --force "$APP/Contents/MacOS/mpv"

echo "make_mpv_app: built $APP (mpv $MPV_VERSION)"
