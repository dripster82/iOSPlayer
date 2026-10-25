#!/bin/zsh
# Creates an empty Secrets.xcconfig from the example when none exists, so a fresh clone builds
# (without built-in keys) and `xcodegen generate` never fails on the missing file.
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
[[ -f "$ROOT/Secrets.xcconfig" ]] || cp "$ROOT/Secrets.example.xcconfig" "$ROOT/Secrets.xcconfig"
