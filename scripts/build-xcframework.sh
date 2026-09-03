#!/usr/bin/env bash
# Builds core/ for every Apple target, generates the Swift bindings from the
# freshly built library, and packages the three static libs into
# AnicatCore.xcframework.
#
# Bindings are generated in *library mode* (`--library <the .dylib>`), not from
# a .udl: the interface is declared with `#[uniffi::export]` proc-macros, so the
# compiled artifact is the only place the full interface exists. Generating
# from anything else silently produces bindings for a stale interface.
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
CORE="$ROOT/core"
OUT="$ROOT/AnicatApple"
TARGETS=(aarch64-apple-darwin aarch64-apple-ios aarch64-apple-ios-sim)

cd "$CORE"
for t in "${TARGETS[@]}"; do
  echo "==> cargo build --release --target $t"
  cargo build --release --lib --target "$t"
done

# The generator reads a cdylib, which only the host target can produce here.
HOST_DYLIB="$CORE/target/aarch64-apple-darwin/release/libanicat_core.dylib"
GEN="$CORE/target/uniffi-out"
rm -rf "$GEN" && mkdir -p "$GEN"
cargo run --release --bin uniffi-bindgen -- generate \
  --library "$HOST_DYLIB" --language swift --out-dir "$GEN" --no-format

# xcodebuild wants a `module.modulemap`, and uniffi emits
# `anicat_coreFFI.modulemap`. The header and modulemap travel in the framework
# as its Headers dir; the generated .swift is source and goes in the package.
HEADERS="$GEN/include"
mkdir -p "$HEADERS"
mv "$GEN"/*.h "$HEADERS"/
cat "$GEN"/*.modulemap > "$HEADERS/module.modulemap"
rm -f "$GEN"/*.modulemap

rm -rf "$OUT/AnicatCore.xcframework"
xcodebuild -create-xcframework \
  -library "$CORE/target/aarch64-apple-darwin/release/libanicat_core.a"  -headers "$HEADERS" \
  -library "$CORE/target/aarch64-apple-ios/release/libanicat_core.a"     -headers "$HEADERS" \
  -library "$CORE/target/aarch64-apple-ios-sim/release/libanicat_core.a" -headers "$HEADERS" \
  -output "$OUT/AnicatCore.xcframework"

mkdir -p "$OUT/Sources/AnicatCoreKit"
cp "$GEN"/*.swift "$OUT/Sources/AnicatCoreKit/"
echo "==> AnicatCore.xcframework and AnicatCoreKit bindings are up to date"
