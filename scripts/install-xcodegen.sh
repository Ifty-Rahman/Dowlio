#!/usr/bin/env bash
set -euo pipefail
source "$(dirname "$0")/common.sh"

VERSION="2.46.0"
SHA256="4d9e34b62172d645eed6457cac13fc222569974098ef4ee9c3368bedf0196806"
DESTINATION="${1:?Pass the folder to install XcodeGen into}"

mkdir -p "$DESTINATION"
ARCHIVE="$DESTINATION/xcodegen.zip"
curl -fsSL -o "$ARCHIVE" "https://github.com/yonaskolb/XcodeGen/releases/download/$VERSION/xcodegen.zip"
echo "$SHA256  $ARCHIVE" | shasum -a 256 -c - >/dev/null || die "XcodeGen $VERSION doesn't match its checksum"
unzip -q -o "$ARCHIVE" -d "$DESTINATION"
rm "$ARCHIVE"
log "Installed XcodeGen $VERSION in $DESTINATION/xcodegen/bin"
