#!/usr/bin/env bash
# Runs the package tests, then builds the app without signing.
set -euo pipefail
source "$(dirname "$0")/common.sh"

log "Running DowlioKit tests"
(cd "$ROOT/Packages/DowlioKit" && swift test --skip DowlioConnectTests)

log "Running Dowlio Connect server tests"
(cd "$ROOT/Packages/DowlioKit" && swift test --filter DowlioConnectTests)

log "Running Dowlio Connect tests"
(cd "$ROOT/Extension" && node --test "test/*.test.js")

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
