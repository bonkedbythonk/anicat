#!/usr/bin/env bash
# bump-version.sh — Single source of truth for version bumps.
#
# Usage:  bash scripts/bump-version.sh 5.9.0
#
# Updates version.txt (canonical) and core/Cargo.toml. The .app packaging
# scripts read version.txt at build time, so nothing under AnicatApple/
# needs touching.

set -euo pipefail

NEW_VERSION="${1:-}"

if ! echo "$NEW_VERSION" | grep -qE '^[0-9]+\.[0-9]+\.[0-9]+$'; then
    echo "Usage: $0 <MAJOR.MINOR.PATCH>"
    echo "  e.g. $0 5.8.1  (bug fix)"
    echo "       $0 5.9.0  (new feature)"
    echo "       $0 6.0.0  (breaking change)"
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

echo "$NEW_VERSION" > version.txt
echo "[1/2] version.txt  -> $NEW_VERSION"

# Only the first `version =` line: dependency tables further down also
# carry the key.
"${SED_INPLACE[@]}" "0,/^version = .*/s//version = \"$NEW_VERSION\"/" core/Cargo.toml
echo "[2/2] core/Cargo.toml  -> $NEW_VERSION"

echo ""
echo "All files bumped to $NEW_VERSION."
echo "Review with: git diff"
