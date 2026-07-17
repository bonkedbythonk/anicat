#!/bin/bash
# Daily backup of the Pi's registry.db (friends' watch history -- the only
# irreplaceable data) and config.toml. Keeps the 14 most recent of each.
# Installed to /opt/anicat/bin/ by scripts/pi/install-pi-timers.sh; triggered
# by anicat-backup.timer.
#
# Uses Python's sqlite3.backup() (safe against a live writer) instead of a
# plain cp, since the server may be mid-transaction.
#
# Note this protects against corruption and bad migrations, not SD card
# death -- pull /opt/anicat/backups off the Pi occasionally, e.g.:
#   rsync -az pi@anicatpi.local:/opt/anicat/backups/ ~/anicat-pi-backups/

set -e

SRC_DIR=/home/pi/.config/anicat
DEST=/opt/anicat/backups
STAMP=$(date +%Y%m%d-%H%M)

mkdir -p "$DEST"

python3 - "$SRC_DIR/registry.db" "$DEST/registry-$STAMP.db" <<'EOF'
import sqlite3
import sys

src = sqlite3.connect(sys.argv[1])
dst = sqlite3.connect(sys.argv[2])
with dst:
    src.backup(dst)
dst.close()
src.close()
EOF

cp "$SRC_DIR/config.toml" "$DEST/config-$STAMP.toml"

ls -1t "$DEST"/registry-*.db | tail -n +15 | xargs -r rm
ls -1t "$DEST"/config-*.toml | tail -n +15 | xargs -r rm

echo "backup ok: $DEST/registry-$STAMP.db ($(du -h "$DEST/registry-$STAMP.db" | cut -f1))"
