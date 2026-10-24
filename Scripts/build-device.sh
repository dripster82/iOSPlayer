#!/bin/zsh
# Build and install a Debug build on the paired iPhone WITHOUT iCloud entitlements.
#
# Needed until the App ID uk.co.ketelle.reel has the iCloud capability (HANDOVER.md §3.2), which only
# Xcode with a signed-in Apple ID can set up. Until then Xcode's wildcard team profile can't satisfy
# Reel/Reel.entitlements, so we sign with Reel/Reel-NoiCloud.entitlements (keychain group only).
#
# Xcode also *rewrites* Reel/Reel.entitlements to an empty <dict/> on every such build, so this script
# restores it from git afterwards.
#
# Usage: Scripts/build-device.sh [device-id]   (default: Paul's iPhone 17 Pro Max)
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
DEVICE="${1:-D83F0EFF-F81B-5BDF-ADC5-09FC08796658}"
DD="${DERIVED_DATA:-$ROOT/DerivedData}"   # gitignored

cd "$ROOT"
[[ -d Packages/ReelKit/Vendor/MobileVLCKit.xcframework ]] || Scripts/fetch-vlckit.sh
[[ -d Reel.xcodeproj ]] || xcodegen generate

restore() { git checkout -- Reel/Reel.entitlements 2>/dev/null || true; }
trap restore EXIT

xcodebuild build -project Reel.xcodeproj -scheme Reel \
  -destination "id=$DEVICE" -derivedDataPath "$DD" \
  CODE_SIGN_ENTITLEMENTS=Reel/Reel-NoiCloud.entitlements \
  | grep -E "error:|warning:|BUILD (SUCCEEDED|FAILED)" || true

APP="$DD/Build/Products/Debug-iphoneos/Reel.app"
[[ -d "$APP" ]] || { echo "✗ no app at $APP"; exit 1; }
xcrun devicectl device install app --device "$DEVICE" "$APP" | grep -E "installed|rror" || true
echo "==> installed; unlock the phone and launch Reel (or: xcrun devicectl device process launch --device $DEVICE uk.co.ketelle.reel)"
