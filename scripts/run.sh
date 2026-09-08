#!/bin/zsh
# Build, replace any running instance, and launch ScreenCap
set -euo pipefail
cd "$(dirname "$0")/.."
./scripts/build.sh
pkill -x ScreenCap 2>/dev/null || true
sleep 0.3
open build/Build/Products/Debug/ScreenCap.app
