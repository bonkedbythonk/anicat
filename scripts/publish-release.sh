#!/usr/bin/env bash
# Publishes the current version as a GitHub release: builds the release
# bundle, zips it, and creates the release with notes from RELEASE_NOTES.md
# if that file exists, otherwise from the commits since the previous tag.
#
#   bash scripts/publish-release.sh            # draft release
#   bash scripts/publish-release.sh --publish  # public release
#
# The bundle is ad-hoc signed and not notarized; the notes carry the
# right-click Open instruction for that reason. Never run this while an
# Anicat is playing: the package step rebuilds dist/Anicat.app underneath a
# copy launched from there.
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
VERSION="$(tr -d '[:space:]' < "$ROOT/version.txt")"
TAG="v$VERSION"
ZIP="$ROOT/AnicatApple/dist/Anicat-${VERSION}-macos-arm64.zip"
DRAFT="--draft"
[ "${1:-}" = "--publish" ] && DRAFT=""

if git -C "$ROOT" rev-parse "$TAG" >/dev/null 2>&1; then
    echo "publish-release: tag $TAG already exists; bump version.txt first (scripts/bump-version.sh)" >&2
    exit 1
fi

# Ad-hoc, never the machine's own identity. The package script auto-detects an
# "Apple Development" certificate when none is given, and that signature carries
# the developer's name, email and Team ID into a zip anybody can `codesign -dv`.
# A development certificate also expires in a year and is not a distribution
# certificate, so it buys the download nothing in exchange.
ANICAT_CODESIGN_IDENTITY="-" bash "$ROOT/scripts/package-anicat-macos-app.sh" release zip

NOTES="$(mktemp)"
if [ -f "$ROOT/RELEASE_NOTES.md" ]; then
    # Committed notes satisfy this -f check forever, so without the heading
    # match the next version ships the previous version's notes verbatim.
    if ! head -1 "$ROOT/RELEASE_NOTES.md" | grep -q "$VERSION"; then
        echo "publish-release: RELEASE_NOTES.md heading is not $VERSION; rewrite it or delete it to fall back to the commit log" >&2
        exit 1
    fi
    cat "$ROOT/RELEASE_NOTES.md" > "$NOTES"
else
    # --match 'v*': the newest tag by topology is `legacy/tauri`, so a bare
    # describe made the generated notes span the entire Swift rewrite.
    PREV="$(git -C "$ROOT" describe --tags --abbrev=0 --match 'v*' 2>/dev/null || true)"
    {
        echo "## Anicat $VERSION"
        echo
        echo "Native macOS build (Apple silicon, macOS 15 or later)."
        echo
        echo "### Changes"
        echo
        if [ -n "$PREV" ]; then
            git -C "$ROOT" log --no-merges --pretty='- %s' "$PREV..HEAD" | grep -vE '^- (docs|ci|build|chore|test)' || true
        else
            git -C "$ROOT" log --no-merges --pretty='- %s' -50
        fi
    } > "$NOTES"
fi
{
    echo
    echo "### Install"
    echo
    echo "Unzip, move Anicat.app to /Applications. The build is ad-hoc signed, not notarized:"
    echo "right-click the app and choose Open the first time, or run"
    echo '`xattr -dr com.apple.quarantine /Applications/Anicat.app`.'
} >> "$NOTES"

git -C "$ROOT" tag -a "$TAG" -m "Anicat $VERSION"
git -C "$ROOT" push origin "$TAG"
gh release create "$TAG" "$ZIP" --title "Anicat $VERSION" --notes-file "$NOTES" $DRAFT
rm -f "$NOTES"
echo "publish-release: $TAG ${DRAFT:+(draft) }created"
