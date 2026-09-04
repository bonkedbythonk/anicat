#!/usr/bin/env bash
# Packages the AnicatApple SwiftPM executable into a real Anicat.app bundle
# with libmpv and its full dependency closure vendored in-bundle, so the app
# runs without Homebrew installed and without silently falling back to
# /opt/homebrew at runtime.
#
# AnicatApple links libmpv in-process (Cmpv/render API), unlike the Tauri
# build's subprocess mpv.app (scripts/make_mpv_app.sh) — that cask binary
# ships no libmpv.dylib at all, only the standalone app, so it can't be
# reused here. This vendors the Homebrew *formula* build of mpv instead,
# whose libmpv.dylib pulls in 48 dylibs via absolute Cellar paths.
#
# Requires: `brew install mpv dylibbundler` on the build machine.
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
SRC="$ROOT/AnicatApple"
CONFIG="${1:-release}"
APP="$SRC/dist/Anicat.app"
EXE_NAME="Anicat"

if ! command -v dylibbundler >/dev/null; then
    echo "package-anicat-macos-app: dylibbundler not found — brew install dylibbundler" >&2
    exit 1
fi

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
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources" "$APP/Contents/Frameworks"

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
    <string>1.0.0</string>
    <key>LSMinimumSystemVersion</key>
    <string>14.0</string>
    <key>NSHighResolutionCapable</key>
    <true/>
</dict>
</plist>
PLIST

echo "=== Vendoring libmpv's dependency closure ==="
# -od: overwrite existing deps in the bundle. -b: fix the main binary too.
# -p: rewrite every LC_LOAD_DYLIB/LC_ID_DYLIB to this literal path — dyld
# resolves @executable_path itself, so no LC_RPATH command is needed.
#
# dylibbundler ad-hoc-signs the executable itself as its last step, via
# `codesign --deep`. Run before the resource bundle is copied in: `--deep`
# on a bundle with one more top-level dir than Contents/ reads it as
# "unsealed contents present in the bundle root" and fails (harmlessly —
# the dylib rewrite above already landed) every time. The real, final
# signature is applied after everything is in place, below.
set +e
dylibbundler -od -b \
    -x "$APP/Contents/MacOS/$EXE_NAME" \
    -d "$APP/Contents/Frameworks" \
    -p "@executable_path/../Frameworks" \
    -s /opt/homebrew/lib \
    -s /opt/homebrew/opt/mpv/lib
set -e

# dylibbundler rewrites every distinct pre-existing LC_RPATH (the Swift
# toolchain leaves several — @loader_path, /usr/lib/swift, the Xcode
# toolchain's own swift-6.2 path) to the same new value, one -rpath call
# per original entry, so the same "@executable_path/../Frameworks/" ends up
# repeated on both the executable and libmpv itself. dyld refuses to load a
# binary with a duplicate LC_RPATH at all (not a warning — the process exits
# immediately, no crash log, just "duplicate LC_RPATH" lines on stderr).
# Collapse every Mach-O in the bundle down to a single copy of it.
for macho in "$APP/Contents/MacOS/$EXE_NAME" "$APP/Contents/Frameworks/"*.dylib; do
    count=$(otool -l "$macho" | grep -A2 "cmd LC_RPATH" | grep -c "@executable_path/../Frameworks/" || true)
    while [ "$count" -gt 1 ]; do
        install_name_tool -delete_rpath "@executable_path/../Frameworks/" "$macho"
        count=$((count - 1))
    done
    if [ "$count" -eq 0 ]; then
        install_name_tool -add_rpath "@executable_path/../Frameworks/" "$macho"
    fi
done

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

echo "=== Codesigning frameworks and executable (ad-hoc) ==="
xattr -cr "$APP" 2>/dev/null || true
find "$APP/Contents/Frameworks" -name "*.dylib" -exec codesign -s - --force {} \;
codesign -s - --force "$APP/Contents/MacOS/$EXE_NAME"
codesign -s - --force "$APP"

echo "=== Verifying no remaining Homebrew references ==="
LEFTOVER=$(find "$APP" -type f \( -perm +111 -o -name "*.dylib" \) -exec otool -L {} + | grep -c /opt/homebrew || true)
if [ "$LEFTOVER" -ne 0 ]; then
    echo "package-anicat-macos-app: $LEFTOVER references to /opt/homebrew remain — bundling incomplete" >&2
    find "$APP" -type f \( -perm +111 -o -name "*.dylib" \) -exec otool -L {} + | grep /opt/homebrew || true
    exit 1
fi

echo "package-anicat-macos-app: built $APP with $(find "$APP/Contents/Frameworks" -name '*.dylib' | wc -l | tr -d ' ') vendored dylibs, zero Homebrew references"
