#!/usr/bin/env bash
# bump-version.sh — Single source of truth for version bumps.
#
# Usage:  bash scripts/bump-version.sh 4.0.1
#         bash scripts/bump-version.sh 4.1.0
#         bash scripts/bump-version.sh 5.0.0
#
# Updates version.txt (canonical), web/package.json,
# web/src-tauri/tauri.conf.json, and web/src-tauri/Cargo.toml in one shot.

set -euo pipefail

NEW_VERSION="${1:-}"

if ! echo "$NEW_VERSION" | grep -qE '^[0-9]+\.[0-9]+\.[0-9]+$'; then
    echo "Usage: $0 <MAJOR.MINOR.PATCH>"
    echo "  e.g. $0 4.0.1  (bug fix)"
    echo "       $0 4.1.0  (new feature)"
    echo "       $0 5.0.0  (breaking change)"
    exit 1
fi

PROJECT_ROOT="$(cd "$(dirname "$0")/.." && pwd)"
cd "$PROJECT_ROOT"

# Cross-platform sed in-place: macOS uses `-i ''`, Linux uses `-i`
if [[ "$OSTYPE" == "darwin"* ]]; then
    SED_INPLACE=(sed -i '')
else
    SED_INPLACE=(sed -i)
fi

# 1. Canonical source
echo "$NEW_VERSION" > version.txt
echo "[1/4] version.txt  -> $NEW_VERSION"

# 2. web/package.json
node -e "
  const p = require('./web/package.json');
  p.version = '$NEW_VERSION';
  require('fs').writeFileSync('./web/package.json', JSON.stringify(p, null, 2) + '\n');
"
echo "[2/4] web/package.json  -> $NEW_VERSION"

# 3. web/src-tauri/tauri.conf.json
node -e "
  const t = require('./web/src-tauri/tauri.conf.json');
  t.version = '$NEW_VERSION';
  require('fs').writeFileSync('./web/src-tauri/tauri.conf.json', JSON.stringify(t, null, 2) + '\n');
"
echo "[3/4] web/src-tauri/tauri.conf.json  -> $NEW_VERSION"

# 4. web/src-tauri/Cargo.toml
"${SED_INPLACE[@]}" "s/^version = .*/version = \"$NEW_VERSION\"/" web/src-tauri/Cargo.toml
echo "[4/4] web/src-tauri/Cargo.toml  -> $NEW_VERSION"

echo ""
echo "All files bumped to $NEW_VERSION."
echo "Review with: git diff"
