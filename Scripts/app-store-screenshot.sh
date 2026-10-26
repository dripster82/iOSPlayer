#!/bin/zsh
# Frames a raw simulator screenshot the App Store way: a dark canvas at the exact size App Store
# Connect wants, a short caption in white at the top, and the screenshot below it with rounded
# corners. Needs ImageMagick (brew install imagemagick).
#
# Usage: Scripts/app-store-screenshot.sh <in.png> <out.png> <WxH> "<caption>"
set -euo pipefail
IN="$1"; OUT="$2"; SIZE="$3"; CAPTION="$4"
W="${SIZE%x*}"; H="${SIZE#*x}"
# Caption band is ~11% of the height; the picture takes the rest at 90% width, rounded.
BAND=$(( H * 11 / 100 ))
PW=$(( W * 90 / 100 ))
PH=$(( H - BAND - H * 2 / 100 ))
FONT="Helvetica-Bold"; POINT=$(( W / 16 ))
RADIUS=$(( W / 40 ))
magick "$IN" -resize "${PW}x${PH}" \
  \( +clone -alpha extract -draw "fill black polygon 0,0 0,$RADIUS $RADIUS,0 fill white circle $RADIUS,$RADIUS $RADIUS,0" \
     \( +clone -flip \) -compose Multiply -composite \( +clone -flop \) -compose Multiply -composite \) \
  -alpha off -compose CopyOpacity -composite \
  miff:- | magick -size "${W}x${H}" xc:'#0B0B0F' \
  \( -background none -fill white -font "$FONT" -pointsize "$POINT" -size "$(( W * 86 / 100 ))x" -gravity center caption:"$CAPTION" \) \
  -gravity north -geometry "+0+$(( BAND / 4 ))" -composite \
  \( miff:- \) -gravity north -geometry "+0+$BAND" -composite \
  -alpha off -strip "PNG24:$OUT"
