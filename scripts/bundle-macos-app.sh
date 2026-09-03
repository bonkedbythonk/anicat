#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
APP_DIR="$ROOT/AniCat.app"
BIN="$ROOT/AnicatApple/.build/debug/Anicat"
RESOURCES="$ROOT/AnicatApple/.build/debug/AnicatApple_AnicatUI.bundle"
ICON="$ROOT/web/src-tauri/icons/icon.icns"

echo "==> Building Anicat executable..."
cd "$ROOT/AnicatApple"
swift build

echo "==> Creating macOS App Bundle at $APP_DIR..."
rm -rf "$APP_DIR"
mkdir -p "$APP_DIR/Contents/MacOS"
mkdir -p "$APP_DIR/Contents/Resources"

cp "$BIN" "$APP_DIR/Contents/MacOS/Anicat"
chmod +x "$APP_DIR/Contents/MacOS/Anicat"

if [ -f "$ICON" ]; then
    cp "$ICON" "$APP_DIR/Contents/Resources/AppIcon.icns"
fi

if [ -d "$RESOURCES" ]; then
    cp -R "$RESOURCES" "$APP_DIR/Contents/Resources/"
fi

cat << 'EOF' > "$APP_DIR/Contents/Info.plist"
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>CFBundleExecutable</key>
    <string>Anicat</string>
    <key>CFBundleIdentifier</key>
    <string>com.anicat.desktop</string>
    <key>CFBundleName</key>
    <string>AniCat</string>
    <key>CFBundleDisplayName</key>
    <string>AniCat</string>
    <key>CFBundleIconFile</key>
    <string>AppIcon</string>
    <key>CFBundlePackageType</key>
    <string>APPL</string>
    <key>CFBundleShortVersionString</key>
    <string>1.0.0</string>
    <key>CFBundleVersion</key>
    <string>1</string>
    <key>LSMinimumSystemVersion</key>
    <string>14.0</string>
    <key>NSHighResolutionCapable</key>
    <true/>
    <!-- The Ink & Index skin is dark-only; without this the bundle inherits
         the system appearance and SumiTheme's dynamic colours resolve to the
         washi-paper light palette on a Mac set to Light. -->
    <key>NSRequiresAquaSystemAppearance</key>
    <false/>
</dict>
</plist>
EOF

echo "APPL????" > "$APP_DIR/Contents/PkgInfo"

echo "==> Successfully created $APP_DIR"
