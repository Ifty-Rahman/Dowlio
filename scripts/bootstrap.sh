#!/usr/bin/env bash
# Generates Dowlio.xcodeproj from project.yml.
set -euo pipefail
source "$(dirname "$0")/common.sh"

command -v xcodegen >/dev/null || die "xcodegen is missing. Run: brew install xcodegen"
cd "$ROOT"
log "Generating Dowlio.xcodeproj"
xcodegen generate --quiet
