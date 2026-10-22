#!/usr/bin/env bash
# Builds a universal Release app and signs it.
#
# Set KEYCHAIN to a keychain path to search and sign with that keychain (CI does this).
#
# Signing identity, in order:
#   1. $SIGN_IDENTITY if set
#   2. the "Dowlio Self Signed" certificate in a keychain
#   3. ad-hoc ("-"), for local tests only. Ad-hoc builds change identity on every build,
#      which resets macOS permissions, so never publish one.
set -euo pipefail
source "$(dirname "$0")/common.sh"

"$ROOT/scripts/bootstrap.sh"

log "Building $APP_NAME (Release, arm64 and x86_64)"
rm -rf "$BUILD_DIR/Release"
xcodebuild build \
  -project "$ROOT/Dowlio.xcodeproj" \
  -scheme Dowlio \
  -configuration Release \
  -destination "generic/platform=macOS" \
  -derivedDataPath "$BUILD_DIR/DerivedData" \
  CONFIGURATION_BUILD_DIR="$BUILD_DIR/Release" \
  ARCHS="arm64 x86_64" \
  ONLY_ACTIVE_ARCH=NO \
  -quiet

[ -d "$APP_PATH" ] || die "Build did not produce $APP_PATH"

IDENTITY="${SIGN_IDENTITY:-}"
if [ -z "$IDENTITY" ]; then
  # No -v: a self-signed certificate is untrusted, and -v hides untrusted identities.
  if security find-identity -p codesigning ${KEYCHAIN:+"$KEYCHAIN"} | grep -q "$SIGN_IDENTITY_NAME"; then
    IDENTITY="$SIGN_IDENTITY_NAME"
  else
    IDENTITY="-"
    log "warning: no \"$SIGN_IDENTITY_NAME\" certificate found. Signing ad-hoc."
  fi
fi

# Sign nested code first, then the app. Phase 1 has no nested code yet.
log "Signing with identity: $IDENTITY"
codesign --force --options runtime --timestamp=none ${KEYCHAIN:+--keychain "$KEYCHAIN"} --sign "$IDENTITY" "$APP_PATH"

log "Verifying signature"
codesign --verify --deep --strict --verbose=2 "$APP_PATH"
lipo -archs "$APP_PATH/Contents/MacOS/$APP_NAME" | sed 's/^/architectures: /'

BUILT_VERSION="$(/usr/libexec/PlistBuddy -c 'Print CFBundleShortVersionString' "$APP_PATH/Contents/Info.plist")"
if [ -n "${RELEASE_TAG:-}" ] && [ "v$BUILT_VERSION" != "$RELEASE_TAG" ]; then
  die "Tag $RELEASE_TAG does not match the app version $BUILT_VERSION in project.yml"
fi
log "Built $APP_NAME $BUILT_VERSION"
