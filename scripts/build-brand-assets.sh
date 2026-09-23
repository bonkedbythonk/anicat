#!/usr/bin/env bash
# Renders every Anicat icon and logo from assets/branding/paw.svg.
#
# Why this exists: the icons used to be hand-exported rasters, and the macOS
# icon (assets/branding/icon.icns, installed by package-anicat-macos-app.sh)
# and the iPhone icon (AppIcon.xcassets, compiled by actool through
# project.yml) are two separate files. Nothing kept them the same art, and a
# comment in project.yml claimed they could not drift. One vector and one
# script that writes both is what actually stops it.
#
# Colours are Ink & Index: Aizome Indigo on washi paper for the
# light side, the dark-mode indigo on sumi ink for the dark side. No other
# colour belongs in the mark (the One Accent Rule).
#
# Run after editing paw.svg or a colour below. The outputs are committed, so
# the app scripts never need these tools. Needs rsvg-convert (Homebrew
# librsvg), iconutil and tiffutil (macOS), and Xcode 26's actool for the
# Icon Composer icon.
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
BRAND="$ROOT/assets/branding"
IMAGES="$ROOT/AnicatApple/Sources/AnicatUI/Resources/Images"
APPICON="$ROOT/AnicatApple/Sources/AnicatUI/Resources/AppIcon.xcassets/AppIcon.appiconset"
command -v rsvg-convert >/dev/null || { echo "build-brand-assets: needs rsvg-convert (brew install librsvg)" >&2; exit 1; }

INDIGO="#33617f"       # Aizome Indigo, light
INDIGO_DARK="#8fb8dc"  # Aizome Indigo, dark
WASHI="#f1ece2"        # washi paper
SUMI="#161310"         # sumi ink

TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT

# The shapes inside <g id="paw">, without the wrapper.
PAW="$(sed -n '/<g id="paw">/,/<\/g>/p' "$BRAND/paw.svg" | sed '1d;$d')"

# The paw's bounding box in paw.svg is x 195-829, y 214-806, so its centre
# is (512, 510). Every placement scales about that point.
placed() { # fill scale
  printf '<g fill="%s" transform="translate(512 512) scale(%s) translate(-512 -510)">%s</g>' "$1" "$2" "$PAW"
}

# Square, full-bleed: iOS masks the corners itself.
full_bleed() { # out bg fill scale
  cat > "$TMP/s.svg" <<EOF
<svg xmlns="http://www.w3.org/2000/svg" viewBox="0 0 1024 1024">
<rect width="1024" height="1024" fill="$2"/>$(placed "$3" "$4")
</svg>
EOF
  rsvg-convert -w 1024 -h 1024 "$TMP/s.svg" -o "$1"
}

# The macOS icon grid: an 824pt plate inset 100pt, 185pt corners, a soft
# shadow under it. A full-bleed square is what the Dock drew before, as a
# flat tile with no depth next to every other app.
mac_plate() { # out size
  cat > "$TMP/m.svg" <<EOF
<svg xmlns="http://www.w3.org/2000/svg" viewBox="0 0 1024 1024">
<defs><filter id="sh" x="-20%" y="-20%" width="140%" height="140%"><feGaussianBlur stdDeviation="14"/></filter></defs>
<rect x="100" y="112" width="824" height="824" rx="185" fill="#000" opacity="0.28" filter="url(#sh)"/>
<rect x="100" y="100" width="824" height="824" rx="185" fill="$WASHI"/>
<rect x="100.5" y="100.5" width="823" height="823" rx="184.5" fill="none" stroke="#26221b" stroke-opacity="0.12"/>
$(placed "$INDIGO" 0.82)
</svg>
EOF
  rsvg-convert -w "$2" -h "$2" "$TMP/m.svg" -o "$1"
}

# Transparent, cropped to the paw with a little air.
cropped() { # out fill width height [viewBox]
  cat > "$TMP/c.svg" <<EOF
<svg xmlns="http://www.w3.org/2000/svg" viewBox="${5:-180 200 664 620}">
<g fill="$2">$PAW</g>
</svg>
EOF
  rsvg-convert -w "$3" -h "$4" "$TMP/c.svg" -o "$1"
}

# macOS app icon.
ICONSET="$TMP/AppIcon.iconset"
mkdir -p "$ICONSET"
for size in 16 32 128 256 512; do
  mac_plate "$ICONSET/icon_${size}x${size}.png" "$size"
  mac_plate "$ICONSET/icon_${size}x${size}@2x.png" "$((size * 2))"
done
iconutil -c icns "$ICONSET" -o "$BRAND/icon.icns"

# macOS 26 icon, as an Icon Composer document compiled to Assets.car. The
# icns above is only what macOS 15 reads: 26 derives a dark icon from a
# plain icns by blacking the plate and keeping the light-mode paw colour,
# and the indigo paw nearly vanished on it. This gives dark mode its own
# pair. No fill of our own: the document leaves the background to macOS,
# which draws its standard light or dark plate (and the glass and tinted
# styles) under the paw, so the icon sits with the system's own. actool's own icns is not used: it stops at 256px, soft at Dock size
# on 15. The .icon folder is committed so it also opens in Icon Composer.
# Its canvas is the plate itself, not the 1024 square around the icns plate,
# so the same share of the plate needs a larger scale: 1.0 here is about 62%
# of the plate, as 0.82 of the 824pt icns plate is.
DOC="$BRAND/AppIcon.icon"
rm -rf "$DOC"
mkdir -p "$DOC/Assets"
printf '<svg xmlns="http://www.w3.org/2000/svg" viewBox="0 0 1024 1024">%s</svg>\n' "$(placed "$INDIGO" 1.0)" > "$DOC/Assets/paw.svg"
srgb() { # "#rrggbb" -> Icon Composer's srgb:r,g,b,a
  printf 'srgb:%.5f,%.5f,%.5f,1.00000' \
    "$(bc -l <<< "$((16#${1:1:2}))/255")" "$(bc -l <<< "$((16#${1:3:2}))/255")" "$(bc -l <<< "$((16#${1:5:2}))/255")"
}
cat > "$DOC/icon.json" <<EOF
{
  "groups" : [
    {
      "layers" : [
        {
          "image-name" : "paw.svg",
          "name" : "paw",
          "fill-specializations" : [
            { "value" : { "solid" : "$(srgb "$INDIGO")" } },
            { "appearance" : "dark", "value" : { "solid" : "$(srgb "$INDIGO_DARK")" } }
          ]
        }
      ],
      "name" : "paw",
      "shadow" : { "kind" : "neutral", "opacity" : 0.4 },
      "specular" : false,
      "translucency" : { "enabled" : false, "value" : 0.5 }
    }
  ],
  "supported-platforms" : { "squares" : "shared" }
}
EOF
xcrun actool "$DOC" --compile "$TMP" --app-icon AppIcon --platform macosx \
  --minimum-deployment-target 15.0 --output-partial-info-plist "$TMP/icon.plist" >/dev/null
cp "$TMP/Assets.car" "$BRAND/Assets.car"

# iPhone app icon: light, dark and tinted appearances (iOS 18).
full_bleed "$APPICON/anicat-1024.png" "$WASHI" "$INDIGO" 0.95
full_bleed "$APPICON/anicat-1024-dark.png" "$SUMI" "$INDIGO_DARK" 0.95
# Tinted icons are read for luminance only; the system supplies the colour.
full_bleed "$APPICON/anicat-1024-tinted.png" "#000000" "#ffffff" 0.95

# Menu bar template: black on clear, AppKit tints it. Sizes match the old
# 16x15 art so BrandAssets' representation sizes stay right.
cropped "$IMAGES/anicat_menu_icon.png" "#000000" 16 15
cropped "$IMAGES/anicat_menu_icon@2x.png" "#000000" 32 30
cropped "$IMAGES/anicat_menu_icon@3x.png" "#000000" 48 45
tiffutil -cathidpicheck "$IMAGES/anicat_menu_icon.png" "$IMAGES/anicat_menu_icon@2x.png" \
  -out "$IMAGES/anicat_menu_icon.tiff" >/dev/null
cropped "$IMAGES/tray_icon.png" "#000000" 32 30

# Sidebar and onboarding mark. SidebarView grayscales it and draws it at 10%,
# so the fill only matters as a luminance. Callers size it by height (80pt in
# the rail), and the paw is wider than the sitting cat it replaced: cropped
# tight it put 3464pt2 of ink in the rail against the cat's 1676, twice the
# weight. The air baked in here (the paw at 70% of the canvas, so half the
# area) brings it back to the cat's weight without touching the rail layout.
cropped "$IMAGES/anicat_logo.png" "$INDIGO" 514 480 "37.5 67 949 886"

# README logo, one per GitHub theme: light indigo disappears on GitHub's dark
# background.
cropped "$BRAND/logo.png" "$INDIGO" 514 480
cropped "$BRAND/logo-dark.png" "$INDIGO_DARK" 514 480

# Discord's `anicat` asset, uploaded by hand in the Developer Portal. Clear
# ground: Discord draws it on its own card, as the corner badge and as the
# large image for a title with no cover, and a filled square showed as a tile
# pasted on that card. The paw fills more of the canvas than on the app icon
# because Discord crops the badge to a circle at badge size. The dark-mode
# indigo, because Discord's card is dark by default.
cat > "$TMP/d.svg" <<EOF
<svg xmlns="http://www.w3.org/2000/svg" viewBox="0 0 1024 1024">$(placed "$INDIGO_DARK" 1.05)</svg>
EOF
rsvg-convert -w 1024 -h 1024 "$TMP/d.svg" -o "$BRAND/discord_rich_presence.png"

echo "==> brand assets written from $BRAND/paw.svg"
