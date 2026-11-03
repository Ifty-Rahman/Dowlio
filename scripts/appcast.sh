#!/usr/bin/env bash
set -euo pipefail
source "$(dirname "$0")/common.sh"

[ -d "$APP_PATH" ] || die "Run scripts/build-release.sh first"
[ -n "${SPARKLE_ED_PRIVATE_KEY:-}" ] || die "SPARKLE_ED_PRIVATE_KEY is not set"
NOTES="${1:-}"

SIGN_UPDATE="$BUILD_DIR/DerivedData/SourcePackages/artifacts/sparkle/Sparkle/bin/sign_update"
[ -x "$SIGN_UPDATE" ] || die "Sparkle's sign_update isn't at $SIGN_UPDATE"

PLIST="$APP_PATH/Contents/Info.plist"
VERSION="$(/usr/libexec/PlistBuddy -c 'Print CFBundleShortVersionString' "$PLIST")"
BUILD="$(/usr/libexec/PlistBuddy -c 'Print CFBundleVersion' "$PLIST")"
MINIMUM="$(/usr/libexec/PlistBuddy -c 'Print LSMinimumSystemVersion' "$PLIST")"
ZIP_NAME="$APP_NAME-$VERSION.zip"
ZIP="$DIST_DIR/$ZIP_NAME"
[ -f "$ZIP" ] || die "Run scripts/package.sh first"

REPOSITORY="https://github.com/Ifty-Rahman/Dowlio"
URL_BASE="${DOWNLOAD_URL_BASE:-$REPOSITORY/releases/download/v$VERSION}"
SIGNATURE="$(printf '%s' "$SPARKLE_ED_PRIVATE_KEY" | "$SIGN_UPDATE" --ed-key-file - "$ZIP")"

DESCRIPTION=""
if [ -n "$NOTES" ]; then
  DESCRIPTION="      <description><![CDATA[$(cat "$NOTES")]]></description>"
fi

log "Writing $DIST_DIR/appcast.xml for $VERSION ($BUILD)"
cat > "$DIST_DIR/appcast.xml" <<XML
<?xml version="1.0" encoding="utf-8"?>
<rss version="2.0" xmlns:sparkle="http://www.andymatuschak.org/xml-namespaces/sparkle">
  <channel>
    <title>$APP_NAME</title>
    <link>$REPOSITORY</link>
    <item>
      <title>$APP_NAME $VERSION</title>
      <pubDate>$(LC_ALL=C date -u '+%a, %d %b %Y %H:%M:%S +0000')</pubDate>
      <sparkle:version>$BUILD</sparkle:version>
      <sparkle:shortVersionString>$VERSION</sparkle:shortVersionString>
      <sparkle:minimumSystemVersion>$MINIMUM</sparkle:minimumSystemVersion>
      <sparkle:fullReleaseNotesLink>$REPOSITORY/releases/tag/v$VERSION</sparkle:fullReleaseNotesLink>
$DESCRIPTION
      <enclosure url="$URL_BASE/$ZIP_NAME" type="application/octet-stream" $SIGNATURE />
    </item>
  </channel>
</rss>
XML
printf '%s' "$SPARKLE_ED_PRIVATE_KEY" | "$SIGN_UPDATE" --ed-key-file - --disable-signing-warning "$DIST_DIR/appcast.xml" >/dev/null
"$SIGN_UPDATE" --verify --ed-key-file - "$DIST_DIR/appcast.xml" <<<"$SPARKLE_ED_PRIVATE_KEY" >/dev/null || die "The signed appcast doesn't verify"
