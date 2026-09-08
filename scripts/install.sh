#!/bin/zsh
# Build a Release .app, install it to /Applications (so Spotlight/Launchpad find it), and relaunch.
set -euo pipefail
cd "$(dirname "$0")/.."
xcodegen generate --quiet

signing=()
if [[ -f scripts/local.env ]]; then source scripts/local.env; fi
if [[ -n "${DEVELOPMENT_TEAM:-}" ]]; then
  signing=(DEVELOPMENT_TEAM="$DEVELOPMENT_TEAM" CODE_SIGN_STYLE=Automatic CODE_SIGN_IDENTITY="Apple Development")
fi

xcodebuild -project ScreenCap.xcodeproj -scheme ScreenCap -configuration Release \
  -derivedDataPath build -destination 'platform=macOS' build "${signing[@]}" \
  | grep -E "error:|BUILD" || true

SRC="build/Build/Products/Release/ScreenCap.app"
DEST="${INSTALL_DIR:-/Applications}/ScreenCap.app"
[[ -d "$SRC" ]] || { echo "Build failed: $SRC not found" >&2; exit 1; }

pkill -x ScreenCap 2>/dev/null || true
sleep 0.3
rm -rf "$DEST"
ditto "$SRC" "$DEST"
open "$DEST"
echo "Installed and launched: $DEST"
