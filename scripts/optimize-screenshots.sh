#!/usr/bin/env bash
# Screenshots into the repo at a size a clone can carry.
#
# A raw retina window capture is an unoptimised PNG: the old assets/branding/detail.png
# was 2483 KB. The same frame downscaled to 1440 wide and encoded as WebP q82
# is 78 KB, and GitHub renders WebP in markdown. Twelve shots that way cost
# 784 KB -- a sixth of what the four PNGs before them did.
#
# Usage: optimize-screenshots.sh <raw-png-dir> <out-dir>
set -euo pipefail
IN_DIR="${1:?usage: optimize-screenshots.sh <raw-png-dir> <out-dir>}"
OUT_DIR="${2:?usage: optimize-screenshots.sh <raw-png-dir> <out-dir>}"
WIDTH="${WIDTH:-1440}"
Q="${Q:-82}"
mkdir -p "$OUT_DIR"
for f in "$IN_DIR"/*.png; do
    [ -e "$f" ] || continue
    name="$(basename "${f%.png}")"
    cwebp -quiet -q "$Q" -resize "$WIDTH" 0 "$f" -o "$OUT_DIR/$name.webp"
    printf '%-28s %6s KB -> %5s KB\n' "$name" \
        "$(( $(stat -f%z "$f") / 1024 ))" \
        "$(( $(stat -f%z "$OUT_DIR/$name.webp") / 1024 ))"
done
