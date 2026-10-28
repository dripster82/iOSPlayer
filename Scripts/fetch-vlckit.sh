#!/bin/zsh
# Fetch VideoLAN's official VLCKit 4 binary (LGPL 2.1 build) into Packages/ReelKit/Vendor/.
# VLCKit 4 is still a prerelease (4.0.0aNN on download.videolan.org/pub/cocoapods/unstable); it is
# the first VLCKit with Picture in Picture, which is why Reel moved off MobileVLCKit 3.7.3.
# The archive is ~520 MB and covers every Apple platform; only the two iOS slices are kept
# (~140 MB on disk once dSYMs are stripped). The xcframework stays OUT of git; run this once per checkout before opening
# Reel.xcodeproj. Pinned by version + sha256.
#
# Usage: Scripts/fetch-vlckit.sh
#        VLCKIT_ARCHIVE=/path/to/VLCKit-4.0.0a19-....tar.xz Scripts/fetch-vlckit.sh   # reuse a download
set -euo pipefail

VERSION="4.0.0a19-d7597c1706-85a537d69"
URL="https://download.videolan.org/pub/cocoapods/unstable/VLCKit-$VERSION.tar.xz"

SHA256="1172078a43150af202c31feb62db3d6687f242d3aa048cce1b899f51c4f14142"

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
DEST="$ROOT/Packages/ReelKit/Vendor"
FRAMEWORK="VLCKit.xcframework"

if [[ -d "$DEST/$FRAMEWORK" ]]; then
  echo "VLCKit already present at $DEST — delete it to re-fetch."
  exit 0
fi

WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT

if [[ -n "${VLCKIT_ARCHIVE:-}" && -f "$VLCKIT_ARCHIVE" ]]; then
  echo "==> using local archive $VLCKIT_ARCHIVE"
  ARCHIVE="$VLCKIT_ARCHIVE"
else
  echo "==> downloading VLCKit $VERSION (~520 MB)"
  curl -fL --progress-bar -o "$WORK/vlckit.tar.xz" "$URL"
  ARCHIVE="$WORK/vlckit.tar.xz"
fi
ACTUAL="$(shasum -a 256 "$ARCHIVE" | cut -d' ' -f1)"
if [[ -n "$SHA256" && "$ACTUAL" != "$SHA256" ]]; then
  echo "✗ checksum mismatch — refusing to install"; exit 1
fi
echo "    sha256 $ACTUAL"

echo "==> extracting"
tar xf "$ARCHIVE" -C "$WORK"
SRC="$(find "$WORK" -maxdepth 2 -name "$FRAMEWORK" -print -quit)"
[[ -n "$SRC" ]] || { echo "✗ $FRAMEWORK not found in archive"; ls -R "$WORK" | head -40; exit 1; }

mkdir -p "$DEST"
# Stale MobileVLCKit 3.x from an older checkout would otherwise sit next to the new framework.
rm -rf "$DEST/MobileVLCKit.xcframework"
cp -R "$SRC" "$DEST/"
cp "$(dirname "$SRC")/COPYING.txt" "$DEST/" 2>/dev/null || true   # LGPL 2.1 text (shipped in Settings → Licences)

# Keep only the iOS device + simulator slices. The device slice keeps its dSYM (about 170 MB) so
# App Store uploads carry VLCKit's symbols and crash reports symbolicate VLC frames; the simulator
# slice's symbols are dropped. Info.plist is rewritten to match: Xcode refuses an xcframework whose
# plist points at missing paths ("Missing path ... DebugSymbolsPath").
/usr/bin/python3 - "$DEST/$FRAMEWORK" <<'PY'
import plistlib, shutil, sys, os
root = sys.argv[1]
plist = os.path.join(root, "Info.plist")
d = plistlib.load(open(plist, "rb"))
keep = []
for lib in d["AvailableLibraries"]:
    if lib["SupportedPlatform"] == "ios":
        if lib.get("SupportedPlatformVariant") == "simulator":
            lib.pop("DebugSymbolsPath", None)
            shutil.rmtree(os.path.join(root, lib["LibraryIdentifier"], "dSYMs"), ignore_errors=True)
        keep.append(lib)
    else:
        shutil.rmtree(os.path.join(root, lib["LibraryIdentifier"]), ignore_errors=True)
d["AvailableLibraries"] = keep
plistlib.dump(d, open(plist, "wb"))
PY

echo "==> installed $DEST/$FRAMEWORK"
ls "$DEST/$FRAMEWORK"
file "$DEST/$FRAMEWORK/ios-arm64/VLCKit.framework/VLCKit"
