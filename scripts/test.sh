#!/usr/bin/env bash
# Runs the package tests, then builds the app without signing.
set -euo pipefail
source "$(dirname "$0")/common.sh"

log "Running DowlioKit tests"
(cd "$ROOT/Packages/DowlioKit" && swift test)

"$ROOT/scripts/bootstrap.sh"

log "Building the app"
xcodebuild build \
  -project "$ROOT/Dowlio.xcodeproj" \
  -scheme Dowlio \
  -configuration Debug \
  -destination "platform=macOS" \
  -derivedDataPath "$BUILD_DIR/DerivedData" \
  -quiet
log "Tests and build passed"
