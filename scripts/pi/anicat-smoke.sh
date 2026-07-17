#!/bin/bash
# Runs the scraper smoke test and pushes a ntfy.sh alert if anything failed.
# Installed to /opt/anicat/bin/ on the Pi by scripts/pi/install-pi-timers.sh;
# triggered daily by anicat-smoke.timer.
#
# The ntfy topic is read from /opt/anicat/ntfy-topic (a single line). Subscribe
# to it in the ntfy app or at https://ntfy.sh/<topic> to receive alerts.

NTFY_TOPIC_FILE=/opt/anicat/ntfy-topic
UV=/home/pi/.local/bin/uv

cd /opt/anicat/src/scraper || exit 1

OUT=$(timeout 900 "$UV" run python smoke_test.py 2>&1)
STATUS=$?
echo "$OUT"

if [ $STATUS -ne 0 ]; then
    TOPIC=$(cat "$NTFY_TOPIC_FILE" 2>/dev/null)
    if [ -n "$TOPIC" ]; then
        SUMMARY=$(echo "$OUT" | grep -E '^(OK|FAIL)' | head -20)
        [ -z "$SUMMARY" ] && SUMMARY="smoke test crashed before producing results (exit $STATUS)"
        curl -s -m 20 \
            -H "Title: anicat provider smoke test failed" \
            -H "Priority: high" \
            -d "$SUMMARY" \
            "https://ntfy.sh/$TOPIC" >/dev/null
    fi
fi

exit $STATUS
