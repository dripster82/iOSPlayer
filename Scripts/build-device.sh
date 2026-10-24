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

# Only the keychain-only build makes Xcode empty Reel.entitlements; restore it afterwards in that case.
restore() { [[ "${ENTITLEMENTS:-}" == Reel/Reel-NoiCloud.entitlements ]] && git checkout -- Reel/Reel.entitlements 2>/dev/null || true; }
trap restore EXIT

if ! xcrun devicectl list devices --timeout 10 2>/dev/null | grep -Eq "$DEVICE.*(available|connected)"; then
  echo "✗ device $DEVICE is not available to CoreDevice (unplugged, locked, untrusted, or Wi-Fi only)."
  xcrun devicectl list devices 2>/dev/null | grep "$DEVICE" || true
  exit 1
fi

# Once Xcode (signed in) has created the app-specific profile, the real entitlements (iCloud, keychain)
# sign fine; before that only the keychain-only file does.
ENTITLEMENTS=Reel/Reel-NoiCloud.entitlements
for prof in ~/Library/Developer/Xcode/UserData/Provisioning\ Profiles/*.mobileprovision; do
  if security cms -D -i "$prof" 2>/dev/null | grep -q "<string>iOS Team Provisioning Profile: uk.co.ketelle.reel</string>"; then
    ENTITLEMENTS=Reel/Reel.entitlements; break
  fi
done
echo "==> signing with $ENTITLEMENTS"
if [[ "$ENTITLEMENTS" == Reel/Reel.entitlements ]] && ! grep -q "icloud-container-identifiers" Reel/Reel.entitlements; then
  echo "✗ Reel/Reel.entitlements has lost its iCloud keys (Xcode's provisioning repair empties it)."
  echo "  Restore it:  git checkout 3ba96b7 -- Reel/Reel.entitlements   (then commit)"
  exit 1
fi

# Build for the generic iOS target: it doesn't need the device to be reachable and produces the same Debug-iphoneos app.
set -o pipefail
xcodebuild build -project Reel.xcodeproj -scheme Reel \
  -destination "generic/platform=iOS" -derivedDataPath "$DD" \
  CODE_SIGN_ENTITLEMENTS="$ENTITLEMENTS" \
  | grep -E "error:|warning:|BUILD (SUCCEEDED|FAILED)"

APP="$DD/Build/Products/Debug-iphoneos/Reel.app"
[[ -d "$APP" ]] || { echo "✗ no app at $APP"; exit 1; }
xcrun devicectl device install app --device "$DEVICE" "$APP" | grep -E "installed|rror"
echo "==> installed; launch Reel on the phone (or: xcrun devicectl device process launch --device $DEVICE uk.co.ketelle.reel)"
