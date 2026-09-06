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
# Where Package.swift's binaryTarget points. Keep the two in step: a stale
# copy at another path links fine and is silently a different build.
FRAMEWORKS="$OUT/Frameworks"
# SwiftPM cannot import a modulemap out of a binaryTarget directly, so the
# generated C header is also exposed as its own tiny target.
SHIM="$OUT/Sources/anicat_coreFFI"
TARGETS=(aarch64-apple-darwin aarch64-apple-ios aarch64-apple-ios-sim)

cd "$CORE"
for t in "${TARGETS[@]}"; do
  echo "==> cargo build --release --target $t"
  cargo build --release --lib --target "$t"
done

# Collapse each staticlib into one relocatable object that exports only the
# UniFFI entry points, and archive that. The app also links MPVKit's
# Libdovi, another Rust staticlib; two Rust runtimes in one link define
# `_rust_eh_personality` (and the rest of std) twice and ld refuses. With
# every symbol but `_uniffi_anicat_core_*` / `_ffi_anicat_core_*` made
# local here, our copy of std is invisible to the outer link and the two
# coexist. `ld -r` needs the platform spelled out for a relocatable output
# on current toolchains.
EXPORTS="$CORE/target/anicat_core.exports"
printf '_uniffi_anicat_core_*\n_ffi_anicat_core_*\n' > "$EXPORTS"
prelink() {
  local target="$1" platform="$2" minver="$3"
  local dir="$CORE/target/$target/release"
  local lib="$dir/libanicat_core.a"
  local obj="$dir/anicat_core_prelinked.o"
  echo "==> prelink $target"
  ld -r -arch arm64 -platform_version "$platform" "$minver" "$minver" \
     -all_load "$lib" -exported_symbols_list "$EXPORTS" -o "$obj"
  rm -f "$dir/libanicat_core_sealed.a"
  ar crs "$dir/libanicat_core_sealed.a" "$obj"
}
prelink aarch64-apple-darwin  macos          14.0
prelink aarch64-apple-ios     ios            17.0
prelink aarch64-apple-ios-sim ios-simulator  17.0

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

rm -rf "$FRAMEWORKS/AnicatCore.xcframework"
mkdir -p "$FRAMEWORKS"
xcodebuild -create-xcframework \
  -library "$CORE/target/aarch64-apple-darwin/release/libanicat_core_sealed.a"  -headers "$HEADERS" \
  -library "$CORE/target/aarch64-apple-ios/release/libanicat_core_sealed.a"     -headers "$HEADERS" \
  -library "$CORE/target/aarch64-apple-ios-sim/release/libanicat_core_sealed.a" -headers "$HEADERS" \
  -output "$FRAMEWORKS/AnicatCore.xcframework"

mkdir -p "$OUT/Sources/AnicatCoreKit" "$SHIM/include"
cp "$GEN"/*.swift "$OUT/Sources/AnicatCoreKit/"
cp "$HEADERS"/* "$SHIM/include/"
# SwiftPM refuses a target with no compilable source of its own.
[ -f "$SHIM/empty.c" ] || echo "// Placeholder: this target exists only to expose the generated UniFFI header." > "$SHIM/empty.c"
echo "==> AnicatCore.xcframework and AnicatCoreKit bindings are up to date"
