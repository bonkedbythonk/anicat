#!/bin/bash
set -e

# Removes what the 5.x (Tauri/React) Anicat left behind after upgrading to the
# native 6.x app.
#
#   curl -fsSL https://raw.githubusercontent.com/bonkedbythonk/anicat/master/scripts/cleanup_legacy_macos.sh | bash
#
# There is no "uninstall the old version" step to run before installing 6.x:
# both builds are named Anicat, both are signed com.anicat.app and both live at
# /Applications/Anicat.app, so the installer overwrites the old bundle. Only the
# old *data* survives, and this script trashes it.
#
# Everything goes to ~/.Trash, never rm -rf. registry.db holds the 5.x watch
# log, which 6.x does not import; a user who deletes it and then wants it back
# has to be able to get it back.

APP_SUPPORT="$HOME/Library/Application Support/Anicat"
TRASH="$HOME/.Trash"

# config.toml and config.json carry the AniList token and 6.x still reads both
# (iCloudSyncService falls back to the TOML the Tauri build wrote), so they are
# not on this list. Neither are registry.sqlite, catalog-cache.sqlite,
# torrent-streams/ or offline-manga/, which are the current app's own state.
CANDIDATES=(
    "$APP_SUPPORT/registry.db"
    "$APP_SUPPORT/registry.db-shm"
    "$APP_SUPPORT/registry.db-wal"
    "$APP_SUPPORT/registry.json"
    "$APP_SUPPORT/covers"
    "$APP_SUPPORT/.registry"
    "$APP_SUPPORT/mpv.sock"
    # 6.x keeps these two in ~/Library/Caches/Anicat instead; a copy still in
    # Application Support is from a build before that move and is never read.
    "$APP_SUPPORT/home-cache.json"
    "$APP_SUPPORT/detail-cache"
    # The web view the 5.x app rendered its whole UI in. 6.x has no web view.
    # Only the WebKit subfolder: Cache.db beside it is the URL cache, and the
    # new app shares the bundle id, so it is live.
    "$HOME/Library/Caches/com.anicat.app/WebKit"
    "$HOME/Library/WebKit/com.anicat.app"
    "$HOME/Library/HTTPStorages/com.anicat.app"
    "$HOME/Library/Saved Application State/com.anicat.app.savedState"
)

FOUND=()
for path in "${CANDIDATES[@]}"; do
    [ -e "$path" ] && FOUND+=("$path")
done

# A copy dragged to ~/Applications is not the one the installer replaces, so it
# keeps launching the old app and looks like the upgrade did nothing.
STRAY_APP=""
if [ -d "$HOME/Applications/Anicat.app" ]; then
    STRAY_APP="$HOME/Applications/Anicat.app"
    FOUND+=("$STRAY_APP")
fi

if [ ${#FOUND[@]} -eq 0 ]; then
    echo "Nothing from the old version is left. You are all set."
    exit 0
fi

echo ""
echo "Leftovers from the old (5.x) Anicat:"
echo ""
for path in "${FOUND[@]}"; do
    SIZE="$(du -sh "$path" 2>/dev/null | cut -f1)"
    echo "  ${SIZE:-?}	${path/#$HOME/~}"
done
TOTAL="$(du -sch "${FOUND[@]}" 2>/dev/null | tail -1 | cut -f1)"
echo ""
echo "Total: ${TOTAL:-unknown}"
echo ""
echo "Your AniList account, your current library and anything you have"
echo "downloaded in the new app are NOT in this list and are not touched."
if [ -n "$STRAY_APP" ]; then
    echo "The copy in ~/Applications is the old app: the installer replaces /Applications/Anicat.app only."
fi
echo "Everything above moves to the Trash, so you can put it back."
echo ""

# `read` from a terminal, not from stdin: this script is meant to be piped from
# curl, and stdin is the script itself there, so a plain `read` consumes the
# rest of the file and answers itself.
printf "Move it all to the Trash? [y/N] "
if ! { read -r REPLY < /dev/tty; } 2>/dev/null; then
    echo ""
    echo "No terminal to ask on. Download this script and run it directly:"
    echo "  curl -fsSLO https://raw.githubusercontent.com/bonkedbythonk/anicat/master/scripts/cleanup_legacy_macos.sh"
    echo "  bash cleanup_legacy_macos.sh"
    exit 1
fi
case "$REPLY" in
    y|Y|yes|YES) ;;
    *) echo "Nothing was moved."; exit 0 ;;
esac

osascript -e 'tell application "Anicat" to quit' 2>/dev/null || true

MOVED=0
for path in "${FOUND[@]}"; do
    BASE="$(basename "$path")"
    DEST="$TRASH/$BASE"
    # Two Anicat folders in the Trash from two runs would collide and the second
    # mv would fail the whole script under `set -e`.
    if [ -e "$DEST" ]; then
        DEST="$TRASH/$BASE-$(date +%Y%m%d%H%M%S)"
    fi
    if mv "$path" "$DEST" 2>/dev/null; then
        MOVED=$((MOVED + 1))
    else
        echo "Could not move ${path/#$HOME/~} - skipped."
    fi
done

echo ""
echo "Done: $MOVED item(s) moved to the Trash."
echo "Empty the Trash when you are sure you do not want any of it back."
