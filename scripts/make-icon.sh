#!/bin/zsh
# Renders the app icon and menu bar glyph from logos/export/*.svg (needs rsvg-convert: brew install librsvg).
set -euo pipefail
cd "$(dirname "$0")/.."
SET=build/AppIcon.iconset
rm -rf "$SET"; mkdir -p "$SET" Resources
for s in 16 32 128 256 512; do
  rsvg-convert -w $s -h $s logos/export/logo.svg -o "$SET/icon_${s}x${s}.png"
  rsvg-convert -w $((s*2)) -h $((s*2)) logos/export/logo.svg -o "$SET/icon_${s}x${s}@2x.png"
done
iconutil -c icns "$SET" -o Resources/AppIcon.icns
rsvg-convert -w 1024 -h 1024 logos/export/logo.svg -o Resources/AppIcon-1024.png
rsvg-convert -f pdf logos/export/menubar.svg -o Resources/MenuIcon.pdf   # template image, tinted by macOS
echo "wrote Resources/AppIcon.icns, Resources/MenuIcon.pdf"
