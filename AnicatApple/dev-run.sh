#!/bin/bash
# Rebuild Anicat and relaunch it via the dev .app bundle.
#
# Running the bare `swift build` binary directly doesn't work for anything
# that needs Cmd+Tab/Dock presence: without a real .app's Info.plist, AppKit
# treats the process as background-only. dist/Anicat.app carries that
# Info.plist, so copy the freshly built binary into it and `open` the bundle
# instead of the raw executable.
set -euo pipefail
cd "$(dirname "$0")"

swift build --product Anicat -c debug

pkill -f "dist/Anicat.app/Contents/MacOS/Anicat" 2>/dev/null || true
cp .build/arm64-apple-macosx/debug/Anicat dist/Anicat.app/Contents/MacOS/Anicat
open dist/Anicat.app
