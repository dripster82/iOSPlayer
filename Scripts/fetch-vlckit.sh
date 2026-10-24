#!/bin/zsh
# Fetch VideoLAN's official MobileVLCKit binary (LGPL 2.1 build) into Packages/ReelKit/Vendor/.
# The xcframework is ~260 MB compressed and is kept OUT of git; run this once per checkout
# before opening Reel.xcodeproj. Pinned by version + sha256.
#
# Usage: Scripts/fetch-vlckit.sh
set -euo pipefail

VERSION="3.7.3-319ed2c0-79128878"
URL="https://download.videolan.org/pub/cocoapods/prod/MobileVLCKit-$VERSION.tar.xz"

SHA256="0d04059906962ddc9a7bd1ebaa12e1f9ae85eb2466116a97a2f46886dd27a0a9"

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
DEST="$ROOT/Packages/ReelKit/Vendor"

if [[ -d "$DEST/MobileVLCKit.xcframework" ]]; then
  echo "MobileVLCKit already present at $DEST — delete it to re-fetch."
  exit 0
fi

WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT

echo "==> downloading MobileVLCKit $VERSION (~260 MB)"
curl -fL --progress-bar -o "$WORK/vlckit.tar.xz" "$URL"
ACTUAL="$(shasum -a 256 "$WORK/vlckit.tar.xz" | cut -d' ' -f1)"
if [[ -n "$SHA256" && "$ACTUAL" != "$SHA256" ]]; then
  echo "✗ checksum mismatch — refusing to install"; exit 1
fi
echo "    sha256 $ACTUAL"

echo "==> extracting"
tar xf "$WORK/vlckit.tar.xz" -C "$WORK"
SRC="$(find "$WORK" -maxdepth 2 -name 'MobileVLCKit.xcframework' -print -quit)"
[[ -n "$SRC" ]] || { echo "✗ MobileVLCKit.xcframework not found in archive"; ls -R "$WORK" | head -40; exit 1; }

mkdir -p "$DEST"
cp -R "$SRC" "$DEST/"
cp "$(dirname "$SRC")/COPYING.txt" "$DEST/" 2>/dev/null || true   # LGPL 2.1 text (shipped in Settings → Licences)
# Drop the debug symbols (~hundreds of MB) and the Info.plist keys that point at them,
# otherwise Xcode refuses the xcframework with "Missing path ... DebugSymbolsPath".
find "$DEST/MobileVLCKit.xcframework" -name dSYMs -type d -prune -exec rm -rf {} +
/usr/bin/python3 - "$DEST/MobileVLCKit.xcframework/Info.plist" <<'PY'
import plistlib, sys
p = sys.argv[1]
d = plistlib.load(open(p, "rb"))
for lib in d["AvailableLibraries"]:
    lib.pop("DebugSymbolsPath", None)
plistlib.dump(d, open(p, "wb"))
PY

echo "==> installed $DEST/MobileVLCKit.xcframework"
ls "$DEST/MobileVLCKit.xcframework"
