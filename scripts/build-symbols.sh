#!/usr/bin/env bash
# Regenerates AnicatApple/Sources/AnicatUI/Resources/Symbols.xcassets from
# scripts/symbols/icons.swift. The catalog is generated, never hand-edited:
# change a drawing in icons.swift and run this.
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
CATALOG="$ROOT/AnicatApple/Sources/AnicatUI/Resources/Symbols.xcassets"
TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT

swiftc -O "$ROOT/scripts/symbols/icons.swift" "$ROOT/scripts/symbols/main.swift" -o "$TMP/gen"
rm -rf "$CATALOG"
mkdir -p "$CATALOG"
echo '{"info":{"author":"xcode","version":1}}' > "$CATALOG/Contents.json"
"$TMP/gen" "$CATALOG"
# actool is what rejects a malformed template; run it here so a bad drawing
# fails now rather than as a blank icon in the app.
xcrun actool "$CATALOG" --compile "$TMP" --platform macosx --minimum-deployment-target 15.0 \
    --output-format human-readable-text | grep -iE 'error|warning' && exit 1 || true
