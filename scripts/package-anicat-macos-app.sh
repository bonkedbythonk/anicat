#!/usr/bin/env bash
# Packages the AnicatApple SwiftPM executable into a real Anicat.app bundle.
#
# libmpv, FFmpeg and their dependency closure come from MPVKit's static
# xcframeworks and are linked into the executable, so there is nothing to
# vendor: the bundle is the binary, the resource bundle and the fonts. The
# previous version of this script bundled Homebrew's libmpv and its 48
# dylibs with dylibbundler; that dependency on the build machine's Homebrew
# is gone along with the Cmpv target.
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
VERSION="$(tr -d '[:space:]' < "$ROOT/version.txt")"
# Which commit the bundle was built from, shown under Settings > Maintenance.
# Two installs in one afternoon carried the same 6.0.0 and nobody could tell
# which fixes a running copy had.
COMMIT="$(git -C "$ROOT" rev-parse --short HEAD 2>/dev/null || echo unknown)"
if [ -n "$(git -C "$ROOT" status --porcelain --untracked-files=no 2>/dev/null)" ]; then COMMIT="${COMMIT}+"; fi
BUILT_AT="$(date '+%Y-%m-%d %H:%M')"
SRC="$ROOT/AnicatApple"
CONFIG="${1:-release}"
# `install` as the second argument copies the finished bundle into
# /Applications, which is how a non-development launch finds it.
INSTALL="${2:-}"
APP="$SRC/dist/Anicat.app"
EXE_NAME="Anicat"
ICON="$ROOT/assets/branding/icon.icns"

echo "=== Building ($CONFIG) ==="
(cd "$SRC" && swift build -c "$CONFIG")

BUILD_DIR="$SRC/.build/arm64-apple-macosx/$CONFIG"
EXE_PATH="$BUILD_DIR/$EXE_NAME"
RESOURCE_BUNDLE="$BUILD_DIR/AnicatApple_AnicatUI.bundle"

if [ ! -f "$EXE_PATH" ]; then
    echo "package-anicat-macos-app: no executable at $EXE_PATH" >&2
    exit 1
fi

echo "=== Assembling bundle skeleton at $APP ==="
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"

cp "$EXE_PATH" "$APP/Contents/MacOS/$EXE_NAME"
chmod 755 "$APP/Contents/MacOS/$EXE_NAME"

cat > "$APP/Contents/Info.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>CFBundleExecutable</key>
    <string>$EXE_NAME</string>
    <key>CFBundleIdentifier</key>
    <string>com.anicat.app</string>
    <key>CFBundleName</key>
    <string>Anicat</string>
    <key>CFBundlePackageType</key>
    <string>APPL</string>
    <key>CFBundleShortVersionString</key>
    <string>${VERSION}</string>
    <key>CFBundleVersion</key>
    <string>${VERSION}</string>
    <key>CFBundleIconFile</key>
    <string>AppIcon</string>
    <key>AnicatCommit</key>
    <string>${COMMIT}</string>
    <key>AnicatBuiltAt</key>
    <string>${BUILT_AT}</string>
    <!-- How cinema mode reaches TMDB, taken from the environment at package
         time: a packaged .app has no environment of its own to read at launch.
         Prefer the proxy (services/tmdb-proxy): with it, no credential ships
         at all, and this plist is plain text that `plutil -p` prints for
         anyone who has the app. A key here is public the moment it is
         distributed -- treat it as rotatable, not secret, and set it only for
         a build with no proxy behind it. Both empty reads as "no TMDB", which
         hides cinema mode rather than shipping something credential-shaped
         and blank. -->
    <key>ANICATTMDBProxy</key>
    <string>${ANICAT_TMDB_PROXY:-}</string>
    <key>ANICATTMDBKey</key>
    <string>${ANICAT_TMDB_KEY:-}</string>
    <key>LSMinimumSystemVersion</key>
    <string>15.0</string>
    <key>NSHighResolutionCapable</key>
    <true/>
    <key>ATSApplicationFontsPath</key>
    <string>Fonts</string>
    <!-- Without this list AppKit never delivers a Spotlight hit or a Handoff
         activity to the app: the installed 6.0.0 opened to the home screen
         on every Spotlight result while dev-run.sh, which had the key, worked. -->
    <key>NSUserActivityTypes</key>
    <array>
        <string>com.apple.corespotlightitem</string>
        <string>com.anicat.playback</string>
        <string>com.anicat.reading</string>
    </array>
    <key>CFBundleURLTypes</key>
    <array>
        <dict>
            <key>CFBundleURLName</key>
            <string>Anicat</string>
            <key>CFBundleURLSchemes</key>
            <array>
                <string>anicat</string>
            </array>
        </dict>
    </array>
</dict>
</plist>
PLIST

# Without the icns and CFBundleIconFile the Dock and Finder show the
# generic application icon; the previous script never copied it.
if [ -f "$ICON" ]; then
    cp "$ICON" "$APP/Contents/Resources/AppIcon.icns"
else
    echo "package-anicat-macos-app: warning: no icon at $ICON" >&2
fi

if [ -d "$SRC/Sources/AnicatUI/Resources/Fonts" ]; then
    mkdir -p "$APP/Contents/Resources/Fonts"
    cp -R "$SRC/Sources/AnicatUI/Resources/Fonts/"* "$APP/Contents/Resources/Fonts/"
fi

# Contents/Resources is the only place codesign accepts extra content —
# anything loose at the bundle root (sibling of Contents/) fails signing
# with "unsealed contents present in the bundle root". Anime4KPreset's
# resolveDefaultBundle() checks this exact path before falling back to the
# SwiftPM-generated Bundle.module accessor.
if [ -d "$RESOURCE_BUNDLE" ]; then
    cp -R "$RESOURCE_BUNDLE" "$APP/Contents/Resources/AnicatApple_AnicatUI.bundle"
else
    echo "package-anicat-macos-app: warning: no resource bundle at $RESOURCE_BUNDLE — Anime4K shaders will be missing" >&2
fi

echo "=== Codesigning executable (ad-hoc) ==="
xattr -cr "$APP" 2>/dev/null || true
codesign -s - --force "$APP/Contents/MacOS/$EXE_NAME"
codesign -s - --force "$APP"

echo "=== Verifying no remaining Homebrew references ==="
LEFTOVER=$(find "$APP" -type f \( -perm +111 -o -name "*.dylib" \) -exec otool -L {} + | grep -c /opt/homebrew || true)
if [ "$LEFTOVER" -ne 0 ]; then
    echo "package-anicat-macos-app: $LEFTOVER references to /opt/homebrew remain — bundling incomplete" >&2
    find "$APP" -type f \( -perm +111 -o -name "*.dylib" \) -exec otool -L {} + | grep /opt/homebrew || true
    exit 1
fi

echo "package-anicat-macos-app: built $APP, zero Homebrew references"

# `zip` as the second argument writes the release archive next to the
# bundle. ditto with --keepParent is what Finder's Compress does; a plain
# `zip -r` drops the resource forks and the app arrives with a broken
# signature.
if [ "$INSTALL" = "zip" ]; then
    ZIP="$SRC/dist/Anicat-${VERSION}-macos-arm64.zip"
    rm -f "$ZIP"
    ditto -c -k --keepParent "$APP" "$ZIP"
    echo "package-anicat-macos-app: wrote $ZIP ($(du -h "$ZIP" | cut -f1))"
fi

if [ "$INSTALL" = "install" ]; then
    DEST="/Applications/Anicat.app"
    echo "=== Installing to $DEST ==="
    # A running copy keeps its old code pages, and a replaced binary under
    # a running process is killed with "Code Signature Invalid".
    pkill -x "$EXE_NAME" 2>/dev/null || true
    rm -rf "$DEST"
    ditto "$APP" "$DEST"
    # Finder caches icons per bundle path; touching the bundle after the
    # copy is what makes it re-read the new icns.
    touch "$DEST"
    echo "package-anicat-macos-app: installed $DEST (version $VERSION)"
fi
