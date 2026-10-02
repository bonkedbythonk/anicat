#!/usr/bin/env bash
# Builds the Android app: the server crate for arm64 (the engine the page and
# the player talk to), then the APK around it. Needs the Android SDK with
# NDK 27 and platform 36, JDK 21, cargo-ndk and the aarch64-linux-android
# Rust target; ANDROID_HOME and JAVA_HOME are found when left unset.
#
#   bash scripts/build-android.sh          # release APK, signed with the debug key
#   bash scripts/build-android.sh debug    # debuggable, for `run-as` and WebView inspection
set -euo pipefail

root="$(cd "$(dirname "$0")/.." && pwd)"
variant="${1:-release}"
export ANDROID_HOME="${ANDROID_HOME:-$HOME/Library/Android/sdk}"
export ANDROID_NDK_HOME="${ANDROID_NDK_HOME:-$(ls -d "$ANDROID_HOME"/ndk/* | tail -1)}"
export JAVA_HOME="${JAVA_HOME:-/opt/homebrew/opt/openjdk@21/libexec/openjdk.jdk/Contents/Home}"
# Compiled in as on the Mac and Windows builds; without it Films and TV is empty.
export ANICAT_TMDB_PROXY="${ANICAT_TMDB_PROXY:-https://anicat-tmdb.anicat.workers.dev}"

libs="$root/android/app/src/main/jniLibs"
(cd "$root/server" && cargo ndk -t arm64-v8a -o "$libs" build --release --lib)

# cargo-ndk copies every cdylib the build made, and core's is the same code
# the server library already holds: 24 MB in the APK for nothing.
rm -f "$libs/arm64-v8a/libanicat_core.so"
"$ANDROID_NDK_HOME"/toolchains/llvm/prebuilt/*/bin/llvm-strip --strip-unneeded "$libs/arm64-v8a/libanicat_android.so"

task="assemble$(tr '[:lower:]' '[:upper:]' <<<"${variant:0:1}")${variant:1}"
(cd "$root/android" && ./gradlew --no-daemon "$task")
ls -lh "$root/android/app/build/outputs/apk/$variant/"*.apk
