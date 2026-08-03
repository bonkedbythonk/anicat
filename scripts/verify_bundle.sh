#!/bin/bash
set -uo pipefail

# verify_bundle.sh — static checks for the class of bug behind "mpv
# installation is invalid on a fresh Mac". None of this needs a second
# machine or a VM: it walks every Mach-O in a built .app and checks the
# properties that actually caused that class of failure in the past.
#
# Checks, per Mach-O file found under Contents/Resources:
#   1. No *dependency* load command points at /opt/homebrew or /usr/local.
#      (LC_ID_DYLIB — the file's own install name — is not a dependency and
#      is intentionally ignored; see otool -L's first output line.)
#   2. codesign -v passes (catches a signature invalidated by rewriting
#      load commands after the file left Homebrew).
#   3. No library "family" (same base name before the version number, e.g.
#      libavcodec) has more than one version present — a stale duplicate
#      left behind by a `cp -R` onto an existing lib/ that never cleared it.
#
# Usage:
#   bash scripts/verify_bundle.sh [path/to/Anicat.app]
# Defaults to the most recently built .app under web/src-tauri/target/*/bundle/macos/.

APP_PATH="${1:-}"

if [ -z "$APP_PATH" ]; then
    APP_PATH=$(find web/src-tauri/target -maxdepth 4 -type d -name "*.app" -path "*/bundle/macos/*" -print0 2>/dev/null \
        | xargs -0 ls -dt 2>/dev/null | head -n 1)
fi

if [ -z "$APP_PATH" ] || [ ! -d "$APP_PATH" ]; then
    echo "No .app bundle found. Build one first (npm run tauri build) or pass a path explicitly."
    exit 1
fi

echo "Verifying: $APP_PATH"
echo ""

RESOURCES_DIR="$APP_PATH/Contents/Resources/resources"
if [ ! -d "$RESOURCES_DIR" ]; then
    echo "No Contents/Resources/resources directory — nothing to check."
    exit 1
fi

FAIL=0

# ── 1 & 2: homebrew-path dependencies + signature validity ─────────────────

MACHO_FILES=()
while IFS= read -r -d '' f; do
    if file "$f" 2>/dev/null | grep -q "Mach-O"; then
        MACHO_FILES+=("$f")
    fi
done < <(find "$RESOURCES_DIR" -type f -print0)

echo "=== Checking ${#MACHO_FILES[@]} Mach-O files for homebrew-path dependencies ==="
for f in "${MACHO_FILES[@]}"; do
    # otool -L's own header line ("path:") is never a dependency, and for a
    # dylib the very next line is its own LC_ID_DYLIB install name — also
    # not a dependency, just how the library identifies itself, and the
    # reason it still carries /opt/homebrew even after being copied out of
    # Homebrew. Get that install name via `otool -D` (empty for executables,
    # which have no LC_ID_DYLIB) and exclude it before checking what's left.
    SELF_ID=$(otool -D "$f" 2>/dev/null | tail -n +2 | xargs)
    ALL_DEPS=$(otool -L "$f" 2>/dev/null | tail -n +2)
    if [ -n "$SELF_ID" ]; then
        ALL_DEPS=$(echo "$ALL_DEPS" | grep -v -F "$SELF_ID")
    fi
    BAD_DEPS=$(echo "$ALL_DEPS" | grep -E "/opt/homebrew|/usr/local/(opt|Cellar|lib)" || true)
    if [ -n "$BAD_DEPS" ]; then
        echo "FAIL  ${f#$APP_PATH/}"
        echo "$BAD_DEPS" | sed 's/^/        /'
        FAIL=1
    fi
done
[ "$FAIL" -eq 0 ] && echo "  ok — no dependency resolves outside the bundle"
echo ""

echo "=== Checking code signatures ==="
SIG_FAIL=0
for f in "${MACHO_FILES[@]}"; do
    if ! codesign -v "$f" >/dev/null 2>&1; then
        echo "FAIL  ${f#$APP_PATH/}: invalid or missing signature"
        SIG_FAIL=1
        FAIL=1
    fi
done
[ "$SIG_FAIL" -eq 0 ] && echo "  ok — every Mach-O has a valid signature"
echo ""

# ── 3: duplicate library versions ───────────────────────────────────────

echo "=== Checking for duplicate library versions in resources/lib ==="
LIB_DIR="$RESOURCES_DIR/lib"
DUP_FAIL=0
if [ -d "$LIB_DIR" ]; then
    # Strip only the single trailing version segment (libavcodec.62.dylib ->
    # libavcodec.dylib) to get a family name — not every trailing digit run,
    # which would eat part of the real name: libx264.165.dylib and
    # libx265.216.dylib are two different codecs, not two versions of one
    # library, and a greedier strip collapsed both down to "libx". Bucket by
    # the *exact* stripped string, not by re-globbing the directory with it
    # as a prefix — libb2.1.dylib strips to "libb2.dylib", and a prefix glob
    # for "libb*.dylib" would wrongly also match the unrelated libbluray.*.
    # No associative arrays: macOS ships bash 3.2, which doesn't have them.
    # "family<TAB>filename" pairs, sorted so same-family lines are adjacent,
    # is the 3.2-compatible way to group.
    DUP_OUTPUT=$(find "$LIB_DIR" -maxdepth 1 -name "*.dylib" -exec basename {} \; 2>/dev/null \
        | while IFS= read -r fname; do
              family=$(echo "$fname" | sed -E 's/\.[0-9]+\.dylib$/.dylib/')
              printf '%s\t%s\n' "$family" "$fname"
          done \
        | sort \
        | awk -F'\t' '
            $1 != prev_family && prev_family != "" {
                if (count > 1) { printf "FAIL  multiple versions of %s present:\n%s", prev_family, buf }
                buf = ""; count = 0
            }
            { prev_family = $1; buf = buf "        " $2 "\n"; count++ }
            END { if (count > 1) printf "FAIL  multiple versions of %s present:\n%s", prev_family, buf }
        ')
    if [ -n "$DUP_OUTPUT" ]; then
        echo "$DUP_OUTPUT"
        DUP_FAIL=1
        FAIL=1
    fi
fi
[ "$DUP_FAIL" -eq 0 ] && echo "  ok — one version of each library"
echo ""

if [ "$FAIL" -ne 0 ]; then
    echo "verify_bundle.sh: FAILED"
    exit 1
fi
echo "verify_bundle.sh: all checks passed"
