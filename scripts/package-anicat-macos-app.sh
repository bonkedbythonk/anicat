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
# ANICAT_VERSION overrides version.txt for a build that is not a release: the
# nightly workflow stamps X.Y.(Z+1)-nightly.<UTC timestamp> so a nightly ranks
# above the stable release it follows and below the next one.
VERSION="${ANICAT_VERSION:-$(tr -d '[:space:]' < "$ROOT/version.txt")}"
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
ICON_CAR="$ROOT/assets/branding/Assets.car"

echo "=== Building ($CONFIG) ==="
(cd "$SRC" && swift build -c "$CONFIG")

# Asked of SwiftPM, never spelled out: Xcode 27's SwiftPM builds into
# .build/out/Products/Release and leaves .build/arm64-apple-macosx empty, so
# the hardcoded triple path packaged nothing ("no executable at ...") while
# `swift build` reported success.
BUILD_DIR="$(cd "$SRC" && swift build -c "$CONFIG" --show-bin-path)"
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
    <!-- The full version, -nightly.N included, so About, the log header and
         a copied bug report all say a nightly is one. CFBundleVersion stays
         numeric: LaunchServices orders bundles by it. -->
    <key>CFBundleShortVersionString</key>
    <string>${VERSION}</string>
    <key>CFBundleVersion</key>
    <string>${VERSION%%-*}</string>
    <key>CFBundleIconFile</key>
    <string>AppIcon</string>
    <key>CFBundleIconName</key>
    <string>AppIcon</string>
    <key>AnicatCommit</key>
    <string>${COMMIT}</string>
    <key>AnicatBuiltAt</key>
    <string>${BUILT_AT}</string>
    <!-- How cinema mode reaches TMDB: a packaged .app has no environment of
         its own to read at launch, so it is written in here. The proxy
         (services/tmdb-proxy) is the default rather than an export the
         packager has to remember, because forgetting it is silent -- both
         shipped 6.0.0 bundles carry an empty key and an empty proxy, and the
         only symptom is that cinema mode is not there. With the proxy no
         credential ships at all, which matters because this plist is plain
         text that `plutil -p` prints for anyone who has the app. A key here
         is public the moment it is distributed -- treat it as rotatable, not
         secret, and set ANICAT_TMDB_KEY only for a build with no proxy. -->
    <key>ANICATTMDBProxy</key>
    <string>${ANICAT_TMDB_PROXY:-https://anicat-tmdb.anicat.workers.dev}</string>
    <key>ANICATTMDBKey</key>
    <string>${ANICAT_TMDB_KEY:-}</string>
    <!-- Play on TV browses for Chromecasts and serves the stream to one.
         Without these macOS's local network check fails both silently:
         the TV list stays empty and nothing logs why. -->
    <key>NSLocalNetworkUsageDescription</key>
    <string>Anicat finds TVs and other Anicat instances on your network, and streams to the TV you pick.</string>
    <key>NSBonjourServices</key>
    <array>
        <string>_googlecast._tcp</string>
        <string>_anicat-stream._tcp</string>
    </array>
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
# macOS 26 reads CFBundleIconName out of Assets.car and ignores the icns.
# Without it the system derives its own dark icon from the light one: a
# black plate under the light-mode indigo paw, which all but disappears.
if [ -f "$ICON_CAR" ]; then
    cp "$ICON_CAR" "$APP/Contents/Resources/Assets.car"
fi

if [ -d "$SRC/Sources/AnicatUI/Resources/Fonts" ]; then
    mkdir -p "$APP/Contents/Resources/Fonts"
    cp -R "$SRC/Sources/AnicatUI/Resources/Fonts/"* "$APP/Contents/Resources/Fonts/"
fi

# The Update now button runs the copy that shipped with the build, not
# whatever sits on master at the moment of the click.
cp "$ROOT/scripts/install_macos.sh" "$APP/Contents/Resources/install_macos.sh"

# Contents/Resources is the only place codesign accepts extra content —
# anything loose at the bundle root (sibling of Contents/) fails signing
# with "unsealed contents present in the bundle root". Anime4KPreset's
# resolveDefaultBundle() checks this exact path before falling back to the
# SwiftPM-generated Bundle.module accessor.
if [ -d "$RESOURCE_BUNDLE" ]; then
    cp -R "$RESOURCE_BUNDLE" "$APP/Contents/Resources/AnicatApple_AnicatUI.bundle"
else
    # Not just missing shaders: Theme, BrandAssets, SidebarView and
    # TMDBAttribution all read straight from Bundle.module, whose generated
    # accessor fatalErrors the moment it can't find this bundle -- so a
    # package built without it doesn't run with degraded art, it crashes on
    # launch. Shipping that is worse than failing the build here.
    echo "package-anicat-macos-app: no resource bundle at $RESOURCE_BUNDLE — this app would crash on launch" >&2
    exit 1
fi

# Xcode 26's SwiftPM (the macos-26 runner) copies Symbols.xcassets into a flat
# resource bundle uncompiled and writes no Info.plist; the 1.1.1 nightlies
# shipped that way and every Image(anicat:) drew nothing. Xcode 27 compiles
# the catalog itself, so this only runs on the older toolchain. Bundle lookup
# needs both the Assets.car and an Info.plist: with the car alone the probe
# still found no symbol.
PACKAGED_RB="$APP/Contents/Resources/AnicatApple_AnicatUI.bundle"
if [ -d "$PACKAGED_RB/Symbols.xcassets" ]; then
    echo "=== Compiling Symbols.xcassets (SwiftPM left it raw) ==="
    xcrun actool "$PACKAGED_RB/Symbols.xcassets" --compile "$PACKAGED_RB" \
        --platform macosx --minimum-deployment-target 15.0 \
        --output-partial-info-plist "$BUILD_DIR/symbols-partial.plist" \
        --errors --warnings
    if [ ! -f "$PACKAGED_RB/Assets.car" ]; then
        echo "package-anicat-macos-app: actool produced no Assets.car; every icon would be blank" >&2
        exit 1
    fi
    rm -rf "$PACKAGED_RB/Symbols.xcassets"
    if [ ! -f "$PACKAGED_RB/Info.plist" ]; then
        plutil -create xml1 "$PACKAGED_RB/Info.plist"
        plutil -insert CFBundleIdentifier -string anicatapple.AnicatUI.resources "$PACKAGED_RB/Info.plist"
    fi
fi

# Shortcuts and Siri list an app's App Intents only from
# Contents/Resources/Metadata.appintents, which Xcode's ExtractAppIntentsMetadata
# step writes and `swift build` never does: the intents compiled into every
# build and Shortcuts showed none of them. This is that step's invocation,
# copied from the iOS xcodebuild log, run on AnicatUI (where the intents live)
# straight into the app. One pass rather than Xcode's module-then-app pair:
# the app pass drops the AppShortcutsProvider when it sits in a dependency
# (the iOS app's extract.actionsdata has "autoShortcuts": []).
# It needs the compiler's .swiftconstvalues, which Xcode 27's SwiftPM emits
# and the older native build system (Xcode 26, the CI runner) does not; there
# the bundle ships without intents, as every build did before this.
UI_OBJ="$BUILD_DIR/../../Intermediates.noindex/AnicatApple.build/$(basename "$BUILD_DIR")/AnicatUI-t.build/Objects-normal/arm64"
if [ -f "$UI_OBJ/AnicatUI-OutputFileMap.json" ]; then
    # .build is shared by every worktree, so these intermediates belong to
    # whichever tree built last; refuse to describe another tree's intents.
    if ! grep -qx "$SRC/Sources/AnicatUI/System/AnicatAppIntents.swift" "$UI_OBJ/AnicatUI.SwiftFileList"; then
        echo "package-anicat-macos-app: AnicatUI intermediates are not from $SRC (another worktree built since)" >&2
        exit 1
    fi
    echo "=== Extracting App Intents metadata ==="
    # From the output file map, not a glob: the directory also holds stale
    # .swiftconstvalues for files that no longer exist (174 files, 173 sources).
    jq -r '.[]."const-values" // empty' "$UI_OBJ/AnicatUI-OutputFileMap.json" > "$BUILD_DIR/AnicatUI.SwiftConstValuesFileList"
    xcrun appintentsmetadataprocessor \
        --toolchain-dir "$(xcode-select -p)/Toolchains/XcodeDefault.xctoolchain" \
        --module-name AnicatUI --bundle-identifier com.anicat.app \
        --sdk-root "$(xcrun --sdk macosx --show-sdk-path)" \
        --xcode-version "$(xcodebuild -version | awk '/Build version/ {print $3}')" \
        --platform-family macOS --deployment-target 15.0 --target-triple arm64-apple-macos15.0 \
        --output "$APP/Contents/Resources" --binary-file "$APP/Contents/MacOS/$EXE_NAME" \
        --source-file-list "$UI_OBJ/AnicatUI.SwiftFileList" \
        --swift-const-vals-list "$BUILD_DIR/AnicatUI.SwiftConstValuesFileList" \
        --force --compile-time-extraction --deployment-aware-processing --no-app-shortcuts-localization
    if [ ! -f "$APP/Contents/Resources/Metadata.appintents/extract.actionsdata" ]; then
        echo "package-anicat-macos-app: appintentsmetadataprocessor wrote no Metadata.appintents" >&2
        exit 1
    fi
else
    echo "package-anicat-macos-app: warning: no .swiftconstvalues from this SwiftPM; Shortcuts will not list Anicat's intents" >&2
fi

# Ad-hoc unless told otherwise. macOS keys the privacy database to the code
# signature, and an ad-hoc one gets a fresh cdhash on every build -- so every
# rebuild looked like a different app and re-asked for Documents and
# Downloads. Signing with a real identity gives a designated requirement that
# survives rebuilds and the prompts stop.
#
# From the environment rather than written here, exactly like
# ANICAT_DEVELOPMENT_TEAM in project.yml: an identity string carries the
# developer's name, email and personal team, and this repo is deliberately
# pseudonymous (see DISCLAIMER.md). Unset, this behaves as it always did, so
# CI and a fresh clone need no change.
#
#   security find-identity -v -p codesigning     # to find yours
#   export ANICAT_CODESIGN_IDENTITY="Apple Development: you@example.com (XXXXXXXXXX)"
SIGN_IDENTITY="${ANICAT_CODESIGN_IDENTITY:-}"
if [ -z "$SIGN_IDENTITY" ]; then
    # Auto-detected rather than written down: the identity is personal to the
    # machine and this file is public. Falls back to ad-hoc, which still runs
    # but re-asks for folder access after every build.
    SIGN_IDENTITY=$(security find-identity -v -p codesigning 2>/dev/null \
        | grep "Apple Development" | head -1 | sed -E 's/.*"(.*)"/\1/')
fi
SIGN_IDENTITY="${SIGN_IDENTITY:--}"
if [ "$SIGN_IDENTITY" = "-" ]; then
    echo "=== Codesigning executable (ad-hoc) ==="
    echo "package-anicat-macos-app: ad-hoc signed; macOS will re-ask for folder access after every build."
    echo "package-anicat-macos-app: set ANICAT_CODESIGN_IDENTITY to a stable identity to stop that."
else
    echo "=== Codesigning executable ($SIGN_IDENTITY) ==="
fi
xattr -cr "$APP" 2>/dev/null || true
codesign -s "$SIGN_IDENTITY" --force "$APP/Contents/MacOS/$EXE_NAME"
# Explicit identifier: without one the signature is identified by the
# executable's name plus a hash, which is neither what the bundle claims nor
# stable across builds -- and TCC keys its folder grants on exactly that.
codesign -s "$SIGN_IDENTITY" --force --identifier com.anicat.app "$APP"

echo "=== Verifying no remaining Homebrew references ==="
LEFTOVER=$(find "$APP" -type f \( -perm +111 -o -name "*.dylib" \) -exec otool -L {} + | grep -c /opt/homebrew || true)
if [ "$LEFTOVER" -ne 0 ]; then
    echo "package-anicat-macos-app: $LEFTOVER references to /opt/homebrew remain — bundling incomplete" >&2
    find "$APP" -type f \( -perm +111 -o -name "*.dylib" \) -exec otool -L {} + | grep /opt/homebrew || true
    exit 1
fi

# Stock MPVKit's libavfilter has no loudnorm. With it missing the player's
# `af=lavfi=[loudnorm...]` fails to build the chain and every episode plays in
# silence, with nothing in the UI saying why, so a bundle linked against the
# stock framework must not ship. The filter's own name is a C string on a line
# of its own; our Swift literal containing "loudnorm" is a longer string and
# does not match -x. Counted rather than `grep -q`: -q quits at the first
# match, `strings` takes SIGPIPE, and under pipefail that reads as a miss on a
# binary that has the filter (the first version of this check refused exactly
# that).
if [ "$(strings -a "$APP/Contents/MacOS/Anicat" | grep -cx loudnorm || true)" -lt 1 ]; then
    echo "package-anicat-macos-app: libavfilter in this build has no loudnorm; the normalize-audio filter would play silence. Use the MPVKit fork, not stock 1.0.0." >&2
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

# `dmg` writes the drag-to-Applications disk image beside the zip. It is the
# format a first-time downloader expects: a window with the app and an
# Applications alias, rather than an archive whose contents they have to know
# to move. UDZO is the compressed read-only format; an unspecified `hdiutil
# create` leaves a read-write image that mounts writable and can be edited
# after the fact.
if [ "$INSTALL" = "dmg" ]; then
    DMG="$SRC/dist/Anicat-${VERSION}-macos-arm64.dmg"
    STAGE="$(mktemp -d)"
    trap 'rm -rf "$STAGE"' EXIT
    ditto "$APP" "$STAGE/Anicat.app"
    # The alias is what makes the drag land in /Applications rather than
    # wherever the volume happens to be; without it the window is one icon
    # and no instruction.
    ln -s /Applications "$STAGE/Applications"
    rm -f "$DMG"
    hdiutil create -quiet -volname "Anicat" -srcfolder "$STAGE" -ov -format UDZO "$DMG"
    rm -rf "$STAGE"
    trap - EXIT
    echo "package-anicat-macos-app: wrote $DMG ($(du -h "$DMG" | cut -f1))"
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
