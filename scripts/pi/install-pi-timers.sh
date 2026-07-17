#!/bin/bash
# Installs/updates the smoke-test and backup timers on the Pi. Run from the
# repo root on your Mac:
#   bash scripts/pi/install-pi-timers.sh [pi-hostname]   # default: anicatpi.local
#
# Idempotent -- rerun after editing any of the scripts/units in scripts/pi/.
# Also ships scraper/smoke_test.py so the Pi's clone doesn't need a git pull.
#
# No push alerting -- check results with:
#   ssh pi@anicatpi.local 'journalctl -u anicat-smoke.service -n 20'

set -e

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
PROJECT_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"
PI_HOST="${1:-anicatpi.local}"

echo "[1/3] Copying files to pi@${PI_HOST}..."
scp -q \
    "$SCRIPT_DIR/anicat-smoke.sh" \
    "$SCRIPT_DIR/anicat-backup.sh" \
    "$SCRIPT_DIR/anicat-smoke.service" \
    "$SCRIPT_DIR/anicat-smoke.timer" \
    "$SCRIPT_DIR/anicat-backup.service" \
    "$SCRIPT_DIR/anicat-backup.timer" \
    "pi@${PI_HOST}:/tmp/"
scp -q "$PROJECT_ROOT/scraper/smoke_test.py" "pi@${PI_HOST}:/tmp/smoke_test.py"

echo "[2/3] Installing on the Pi..."
ssh "pi@${PI_HOST}" '
    set -e
    sudo install -m 755 /tmp/anicat-smoke.sh /tmp/anicat-backup.sh /opt/anicat/bin/
    sudo install -m 644 /tmp/anicat-smoke.service /tmp/anicat-smoke.timer \
        /tmp/anicat-backup.service /tmp/anicat-backup.timer /etc/systemd/system/
    sudo install -m 644 -o pi /tmp/smoke_test.py /opt/anicat/src/scraper/smoke_test.py
    rm -f /tmp/anicat-smoke.* /tmp/anicat-backup.* /tmp/smoke_test.py
    sudo systemctl daemon-reload
    sudo systemctl enable --now anicat-smoke.timer anicat-backup.timer
'

echo "[3/3] Done. Timers:"
ssh "pi@${PI_HOST}" 'systemctl list-timers anicat-smoke.timer anicat-backup.timer --no-pager | head -5'
