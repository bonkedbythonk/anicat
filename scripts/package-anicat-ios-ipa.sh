#!/usr/bin/env bash
# Builds the iPhone app and wraps it as an unsigned .ipa.
#
#   bash scripts/package-anicat-ios-ipa.sh
#
# Unsigned on purpose. Signing it would need a distribution certificate this
# project does not have, and a development one would tie every download to a
# named Apple account (DISCLAIMER.md keeps that private) while still only
# installing on the devices listed in the profile. An unsigned .ipa is what
# the sideloading tools want anyway: AltStore, Sideloadly and the rest re-sign
# it with the installing person's own Apple ID, and TrollStore installs it as
# it is.
#
# There is no route from a phone alone. Whoever installs this needs a computer
# running one of those tools, and on a free Apple ID the signature expires
# after seven days.
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
VERSION="$(tr -d '[:space:]' < "$ROOT/version.txt")"
APPLE="$ROOT/AnicatApple"
DERIVED="${ANICAT_IOS_DERIVED:-$APPLE/.build-ipa}"
IPA="$APPLE/dist/Anicat-${VERSION}-ios.ipa"

# The generated project is gitignored and regenerated, never edited. The proxy
# is baked in here the same way the macOS packaging script bakes it, because
# xcodegen has no way to read a file at build time.
( cd "$APPLE" && xcodegen generate >/dev/null )

# CODE_SIGNING_ALLOWED=NO is what makes this build without a team, and it is
# also what leaves the bundle unsigned for the re-signer downstream.
xcodebuild \
    -project "$APPLE/Anicat.xcodeproj" \
    -scheme AnicatiOS \
    -configuration Release \
    -destination 'generic/platform=iOS' \
    -derivedDataPath "$DERIVED" \
    CODE_SIGNING_ALLOWED=NO CODE_SIGNING_REQUIRED=NO CODE_SIGN_IDENTITY="" \
    build

APP="$DERIVED/Build/Products/Release-iphoneos/AnicatiOS.app"
[ -d "$APP" ] || { echo "package-anicat-ios-ipa: no app at $APP" >&2; exit 1; }

# An .ipa is a zip with the bundle under Payload/ and nothing else. The
# directory has to be named exactly Payload or every installer rejects it.
STAGE="$(mktemp -d)"
trap 'rm -rf "$STAGE"' EXIT
mkdir -p "$STAGE/Payload"
ditto "$APP" "$STAGE/Payload/AnicatiOS.app"

mkdir -p "$APPLE/dist"
rm -f "$IPA"
( cd "$STAGE" && zip -qry "$IPA" Payload )

echo "package-anicat-ios-ipa: wrote $IPA ($(du -h "$IPA" | cut -f1))"
