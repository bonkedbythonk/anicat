#!/usr/bin/env bash
# Compiles the SwiftUI Metal shaders in scripts/shaders/ into per-platform
# metallibs under AnicatUI's Shaders resource folder.
#
# Why this exists: `swift build` does not compile a `.metal` file at all --
# it is not a source type SwiftPM knows, so the file is silently skipped and
# `ShaderLibrary.bundle(.module)` finds no `ripple` function at run time. A
# metallib is platform-specific, so one is built per slice and the Swift
# side picks by `#if os` / `targetEnvironment`.
#
# Run after editing anything in scripts/shaders/. The outputs are committed:
# they are a few KB and the app scripts (dev-run, package) must not need the
# Metal toolchain.
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
SRC="$ROOT/scripts/shaders"
OUT="$ROOT/AnicatApple/Sources/AnicatUI/Resources/Shaders/metal"
mkdir -p "$OUT"
for sdk in macosx iphoneos iphonesimulator; do
  case $sdk in
    macosx) target=air64-apple-macos15.0 ;;
    iphoneos) target=air64-apple-ios18.0 ;;
    iphonesimulator) target=air64-apple-ios18.0-simulator ;;
  esac
  airs=()
  for f in "$SRC"/*.metal; do
    air="$OUT/$(basename "${f%.metal}").$sdk.air"
    xcrun -sdk "$sdk" metal -c -target "$target" "$f" -o "$air"
    airs+=("$air")
  done
  xcrun -sdk "$sdk" metallib "${airs[@]}" -o "$OUT/AnicatShaders.$sdk.metallib"
  rm -f "${airs[@]}"
  echo "==> $OUT/AnicatShaders.$sdk.metallib"
done
