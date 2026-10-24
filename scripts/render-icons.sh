#!/usr/bin/env bash
# Renders the app icon set and the menu bar icon into App/Assets.xcassets.
# Sizes from 64 px up come from Flow's icon art. The 16 and 32 px icons and the menu bar icon are
# drawn by scripts/icons/render.swift. Run it after changing either, then commit the images.
set -euo pipefail
source "$(dirname "$0")/common.sh"

FLOW_ICON="${FLOW_ICON:-$ROOT/apps/Flow.app/Contents/Resources/AppIcon.icns}"
[[ -f "$FLOW_ICON" ]] || die "Flow's icon is missing at $FLOW_ICON. Set FLOW_ICON to its path."

ASSETS="$ROOT/App/Assets.xcassets"
APP_ICON="$ASSETS/AppIcon.appiconset"
MENU_BAR="$ASSETS/MenuBarIcon.imageset"
WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT
mkdir -p "$APP_ICON" "$MENU_BAR"

log "Taking Flow's art for 64 px and up"
iconutil -c iconset "$FLOW_ICON" -o "$WORK/flow.iconset"
for name in icon_32x32@2x icon_128x128 icon_128x128@2x icon_256x256 icon_256x256@2x icon_512x512 icon_512x512@2x; do
  cp "$WORK/flow.iconset/$name.png" "$APP_ICON/$name.png"
done

log "Drawing the small icons and the menu bar icon"
swift "$ROOT/scripts/icons/render.swift" "$APP_ICON" "$MENU_BAR"

cat > "$APP_ICON/Contents.json" <<'JSON'
{
  "images" : [
    { "filename" : "icon_16x16.png", "idiom" : "mac", "scale" : "1x", "size" : "16x16" },
    { "filename" : "icon_16x16@2x.png", "idiom" : "mac", "scale" : "2x", "size" : "16x16" },
    { "filename" : "icon_32x32.png", "idiom" : "mac", "scale" : "1x", "size" : "32x32" },
    { "filename" : "icon_32x32@2x.png", "idiom" : "mac", "scale" : "2x", "size" : "32x32" },
    { "filename" : "icon_128x128.png", "idiom" : "mac", "scale" : "1x", "size" : "128x128" },
    { "filename" : "icon_128x128@2x.png", "idiom" : "mac", "scale" : "2x", "size" : "128x128" },
    { "filename" : "icon_256x256.png", "idiom" : "mac", "scale" : "1x", "size" : "256x256" },
    { "filename" : "icon_256x256@2x.png", "idiom" : "mac", "scale" : "2x", "size" : "256x256" },
    { "filename" : "icon_512x512.png", "idiom" : "mac", "scale" : "1x", "size" : "512x512" },
    { "filename" : "icon_512x512@2x.png", "idiom" : "mac", "scale" : "2x", "size" : "512x512" }
  ],
  "info" : { "author" : "xcode", "version" : 1 }
}
JSON

cat > "$MENU_BAR/Contents.json" <<'JSON'
{
  "images" : [
    { "filename" : "menubar.png", "idiom" : "mac", "scale" : "1x" },
    { "filename" : "menubar@2x.png", "idiom" : "mac", "scale" : "2x" }
  ],
  "info" : { "author" : "xcode", "version" : 1 },
  "properties" : { "template-rendering-intent" : "template" }
}
JSON
log "Icons are in $ASSETS"
