#!/bin/zsh
# Generate the Xcode project (if needed) and build a Debug .app into ./build
set -euo pipefail
cd "$(dirname "$0")/.."
xcodegen generate --quiet

# Optional real-team signing (keeps TCC permissions stable across rebuilds); default is ad-hoc.
signing=()
if [[ -f scripts/local.env ]]; then
  source scripts/local.env
fi
if [[ -n "${DEVELOPMENT_TEAM:-}" ]]; then
  signing=(DEVELOPMENT_TEAM="$DEVELOPMENT_TEAM" CODE_SIGN_STYLE=Automatic CODE_SIGN_IDENTITY="Apple Development")
fi

xcodebuild -project ScreenCap.xcodeproj -scheme ScreenCap -configuration Debug \
  -derivedDataPath build -destination 'platform=macOS' build "${signing[@]}" "$@" \
  | grep -E "error:|warning: unre|BUILD" || true
echo "App: $(pwd)/build/Build/Products/Debug/ScreenCap.app"
