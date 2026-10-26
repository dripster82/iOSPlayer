#!/bin/zsh
# Frames a raw simulator screenshot the App Store way: a dark canvas at the exact size App Store
# Connect wants, a short caption in white at the top, and the screenshot below it with rounded
# corners. The caption is rendered first and measured, so a two-line caption pushes the picture
# down rather than running into it. Needs ImageMagick (brew install imagemagick).
#
# Usage: Scripts/app-store-screenshot.sh <in.png> <out.png> <WxH> "<caption>"
set -euo pipefail
IN="$1"; OUT="$2"; SIZE="$3"; CAPTION="$4"
W="${SIZE%x*}"; H="${SIZE#*x}"
FONT="Helvetica-Bold"; POINT=$(( W / 17 ))
TOP=$(( H * 35 / 1000 ))          # space above the caption
GAP=$(( H * 25 / 1000 ))          # between caption and picture
PW=$(( W * 90 / 100 ))
RADIUS=$(( W / 40 ))
TMP="$(mktemp -d)"; trap 'rm -rf "$TMP"' EXIT

magick -background none -fill white -font "$FONT" -pointsize "$POINT" -size "$(( W * 86 / 100 ))x" -gravity center \
  caption:"$CAPTION" -trim +repage "$TMP/caption.png"
CH=$(magick identify -format "%h" "$TMP/caption.png")
BAND=$(( TOP + CH + GAP ))
PH=$(( H - BAND ))                # the picture runs off the bottom edge, as on Apple's own pages

magick "$IN" -resize "${PW}x" \
  \( +clone -alpha extract -draw "fill black polygon 0,0 0,$RADIUS $RADIUS,0 fill white circle $RADIUS,$RADIUS $RADIUS,0" \
     \( +clone -flip \) -compose Multiply -composite \( +clone -flop \) -compose Multiply -composite \) \
  -alpha off -compose CopyOpacity -composite "$TMP/picture.png"

magick -size "${W}x${H}" xc:'#0B0B0F' \
  "$TMP/caption.png" -gravity north -geometry "+0+$TOP" -composite \
  "$TMP/picture.png" -gravity north -geometry "+0+$BAND" -composite \
  -alpha off -strip "PNG24:$OUT"
