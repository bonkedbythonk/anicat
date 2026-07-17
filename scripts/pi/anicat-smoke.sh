#!/bin/bash
# Runs the scraper smoke test. Installed to /opt/anicat/bin/ on the Pi by
# scripts/pi/install-pi-timers.sh; triggered daily by anicat-smoke.timer.
#
# No push alerting -- ntfy.sh iOS delivery proved unreliable. Check results
# manually via: ssh pi@anicatpi.local 'journalctl -u anicat-smoke.service -n 20'
# or: systemctl status anicat-smoke.timer (shows last run result).

UV=/home/pi/.local/bin/uv

cd /opt/anicat/src/scraper || exit 1

timeout 900 "$UV" run python smoke_test.py
exit $?
