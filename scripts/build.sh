#!/bin/zsh
# Generate the Xcode project (if needed) and build a Debug .app into ./build
set -euo pipefail
cd "$(dirname "$0")/.."
xcodegen generate --quiet
xcodebuild -project ScreenCap.xcodeproj -scheme ScreenCap -configuration Debug \
  -derivedDataPath build -destination 'platform=macOS' build "$@" | grep -E "error:|warning: unre|BUILD" || true
echo "App: $(pwd)/build/Build/Products/Debug/ScreenCap.app"
