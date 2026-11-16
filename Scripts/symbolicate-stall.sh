#!/bin/zsh
# Resolve the "Image+0xOFFSET" frames in Reel's stall-profile log lines against the device's system
# symbols that Xcode copied to this Mac (~/Library/Developer/Xcode/iOS DeviceSupport/<model os>/Symbols).
#
# Usage: Scripts/symbolicate-stall.sh <reel.log> ["iPad8,11 26.6.2 (23G90)"]
# Prints every distinct Image+0xOFFSET seen in [main] lines with its symbol, most frequent first.
set -euo pipefail
LOG="$1"
SUPPORT="${2:-$(ls -d "$HOME/Library/Developer/Xcode/iOS DeviceSupport/"iPad* | tail -1 | xargs -I{} basename "{}")}"
SYMS="$HOME/Library/Developer/Xcode/iOS DeviceSupport/$SUPPORT/Symbols"
[[ -d "$SYMS" ]] || { echo "no symbols at $SYMS"; exit 1; }
grep "\[main\]" "$LOG" | grep -oE "[A-Za-z0-9_.]+\+0x[0-9a-f]+" | sort | uniq -c | sort -rn | while read -r count frame; do
  image="${frame%%+0x*}"; off="0x${frame##*+0x}"
  file=$(find "$SYMS/System/Library/Frameworks" "$SYMS/System/Library/PrivateFrameworks" "$SYMS/usr/lib" -name "$image" -type f 2>/dev/null | head -1)
  if [[ -n "$file" ]]; then
    sym=$(xcrun atos -arch arm64e -o "$file" --offset "$off" 2>/dev/null | head -1)
  else
    sym="(no symbol file for $image)"
  fi
  printf "%5d  %-40s %s\n" "$count" "$frame" "$sym"
done
