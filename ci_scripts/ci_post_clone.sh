#!/bin/zsh
# Xcode Cloud runs this right after cloning. The repository holds no Xcode project (XcodeGen makes
# it from project.yml), no VLCKit (fetched by Scripts/fetch-vlckit.sh) and no API keys
# (Secrets.xcconfig is git-ignored), so all three are recreated here before Xcode looks for them.
#
# Keys come from the workflow's environment variables (Workflow → Environment → Environment
# Variables, marked secret): REEL_TMDB_KEY, REEL_FANART_KEY, REEL_OPENSUBTITLES_KEY. A missing
# one leaves that service without a built-in key, as on any machine.
set -euo pipefail
cd "${CI_PRIMARY_REPOSITORY_PATH:-$(cd "$(dirname "$0")/.." && pwd)}"

echo "==> XcodeGen"
if ! command -v xcodegen >/dev/null; then
  brew install xcodegen
fi

echo "==> Secrets.xcconfig from the workflow environment"
cat > Secrets.xcconfig <<SECRETS
REEL_TMDB_KEY = ${REEL_TMDB_KEY:-}
REEL_FANART_KEY = ${REEL_FANART_KEY:-}
REEL_OPENSUBTITLES_KEY = ${REEL_OPENSUBTITLES_KEY:-}
SECRETS
for k in REEL_TMDB_KEY REEL_FANART_KEY REEL_OPENSUBTITLES_KEY; do
  [[ -n "${(P)k:-}" ]] && echo "    $k: set" || echo "    $k: EMPTY (add it to the workflow's environment variables)"
done

echo "==> VLCKit"
Scripts/fetch-vlckit.sh

echo "==> Reel.xcodeproj"
xcodegen generate
ls Reel.xcodeproj/project.pbxproj >/dev/null && echo "    generated"
