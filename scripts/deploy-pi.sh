#!/bin/bash
set -e

# Deploy the current checked-out commit to the headless Pi server: builds the
# arm64 anicat-server binary (native compile inside a Debian arm64 Docker
# container -- see PI_SETUP.md for why this can't happen directly on the Pi 3),
# builds the mobile PWA's static bundle, and pushes both to the Pi in one go.
#
# The desktop app's own release (scripts/release.sh, CI tag builds) does NOT
# touch the Pi at all -- these are two separate deploy targets sharing the
# same web/src-tauri and web/src source, and nothing keeps them in sync
# automatically. Run this after any change you want the Pi to pick up.
#
# Usage:
#   bash scripts/deploy-pi.sh [pi-hostname]     # default: anicatpi.local
#
# Prerequisites:
#   - Docker Desktop running
#   - SSH access to the Pi as the `pi` user (passwordless / agent-forwarded)
#   - The Pi already set up per PI_SETUP.md (systemd unit, /opt/anicat layout)

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
PROJECT_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
PI_HOST="${1:-anicatpi.local}"
BUILD_OUT="/tmp/anicat-docker-output"

echo "=============================="
echo "  Anicat Pi Deploy"
echo "  Target: pi@${PI_HOST}"
echo "=============================="
echo ""

echo "[1/4] Checking Pi is reachable..."
if ! ssh -o ConnectTimeout=8 -o BatchMode=yes "pi@${PI_HOST}" 'true' 2>/dev/null; then
    echo "ERROR: can't reach pi@${PI_HOST} over SSH. Check Tailscale/network and try again."
    exit 1
fi

echo "[2/4] Building anicat-server (arm64, inside Docker)..."
mkdir -p "$BUILD_OUT"
rm -f "$BUILD_OUT/anicat-server"
docker run --rm --platform linux/arm64 \
    -v "$PROJECT_ROOT":/work:ro \
    -v "$BUILD_OUT":/output \
    -w /build \
    rust:1-bookworm \
    bash -c "
        set -e
        apt-get update && apt-get install -y --no-install-recommends \
            pkg-config libwebkit2gtk-4.1-dev libgtk-3-dev libsoup-3.0-dev \
            libjavascriptcoregtk-4.1-dev git &&
        git config --global --add safe.directory '*' &&
        git clone /work /build &&
        cd web/src-tauri &&
        touch resources/mpv resources/mpv.exe &&
        mkdir -p resources/lib && touch resources/lib/.gitkeep &&
        mkdir -p resources/scraper-bin/anicat-scraper/_internal &&
        touch resources/scraper-bin/anicat-scraper/anicat-scraper &&
        touch resources/scraper-bin/anicat-scraper/_internal/.gitkeep &&
        cargo build --release --bin anicat-server &&
        cp target/release/anicat-server /output/
    "

if [[ ! -f "$BUILD_OUT/anicat-server" ]]; then
    echo "ERROR: build did not produce $BUILD_OUT/anicat-server"
    exit 1
fi

echo ""
echo "[3/4] Building mobile PWA static bundle..."
(cd "$PROJECT_ROOT/web" && npx vite build)

echo ""
echo "[4/4] Deploying to the Pi..."
scp "$BUILD_OUT/anicat-server" "pi@${PI_HOST}:/tmp/anicat-server"
rsync -az --delete "$PROJECT_ROOT/web/dist/" "pi@${PI_HOST}:/opt/anicat/mobile-dist/"
ssh "pi@${PI_HOST}" '
    set -e
    # The Pi runs the Python scraper from source (PI_SETUP.md step 4), not from
    # the frozen sidecar the desktop bundles -- the Docker build above only
    # touches a placeholder scraper-bin to satisfy the Rust build. So shipping
    # the binary alone leaves scraper/*.py pinned at whatever commit was last
    # pulled by hand, and provider fixes that landed weeks ago stay unapplied
    # while the version banner reports everything as current. Sync it here.
    #
    # This is a deploy clone, not a working checkout, so anything divergent is
    # almost certainly a stray file rather than intentional work -- but stash
    # it (with -u, to catch untracked) instead of discarding, so a hand-edit
    # made while debugging on the Pi stays recoverable via `git stash list`.
    cd /opt/anicat/src
    if [ -n "$(git status --porcelain)" ]; then
        git stash push -u -m "deploy-pi autostash $(date +%Y%m%d-%H%M%S)" >/dev/null
        echo "  scraper: stashed local changes ($(git stash list | head -1 | cut -d: -f1))"
    fi
    git fetch --quiet origin
    git merge --ff-only --quiet origin/master
    echo "  scraper: $(git log -1 --format=%h)"

    sudo mv /tmp/anicat-server /opt/anicat/bin/anicat-server
    sudo chmod +x /opt/anicat/bin/anicat-server
    sudo systemctl restart anicat.service
    sleep 3
    echo "  service: $(systemctl is-active anicat.service)"
    echo "  health:  $(curl -s -o /dev/null -w "%{http_code}" http://127.0.0.1:13370/health)"
'

echo ""
echo "==================================="
echo "  Pi deploy complete."
echo "==================================="
