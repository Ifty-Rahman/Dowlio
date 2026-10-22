#!/usr/bin/env bash
# Packs the built app into a DMG and a ZIP, with SHA-256 sums, in dist/.
set -euo pipefail
source "$(dirname "$0")/common.sh"

[ -d "$APP_PATH" ] || die "Run scripts/build-release.sh first"

VERSION="$(/usr/libexec/PlistBuddy -c 'Print CFBundleShortVersionString' "$APP_PATH/Contents/Info.plist")"
DMG="$DIST_DIR/$APP_NAME-$VERSION.dmg"
ZIP="$DIST_DIR/$APP_NAME-$VERSION.zip"

rm -rf "$DIST_DIR"
mkdir -p "$DIST_DIR"

log "Creating $ZIP"
ditto -c -k --keepParent "$APP_PATH" "$ZIP"

log "Creating $DMG"
STAGING="$(mktemp -d)"
trap 'rm -rf "$STAGING"' EXIT
cp -R "$APP_PATH" "$STAGING/"
ln -s /Applications "$STAGING/Applications"
hdiutil create -volname "$APP_NAME" -srcfolder "$STAGING" -ov -format UDZO "$DMG" >/dev/null

log "Writing checksums"
(cd "$DIST_DIR" && shasum -a 256 "$(basename "$DMG")" "$(basename "$ZIP")" > SHA256SUMS.txt)
cat "$DIST_DIR/SHA256SUMS.txt"
