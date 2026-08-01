#!/bin/bash
#
# Renders the cross-platform app icon and builds the assets the app + packaging use:
#   • src/RemoteStuff/Assets/AppIcon.icns   – macOS bundle icon
#   • src/RemoteStuff/Assets/Icon.png       – Avalonia window icon (all platforms)
#
#   ./make-icon.sh
#
# Edit make-icon.swift to tweak the artwork, then re-run this.
#
set -euo pipefail
cd "$(dirname "$0")"

ASSETS="src/RemoteStuff/Assets"
ICONSET="AppIcon.iconset"
mkdir -p "$ASSETS"

echo "▶︎  Rendering icon PNGs…"
rm -rf "$ICONSET"
swift make-icon.swift "$ICONSET"

echo "▶︎  Building AppIcon.icns…"
iconutil -c icns "$ICONSET" -o "$ASSETS/AppIcon.icns"

echo "▶︎  Writing window Icon.png…"
cp "$ICONSET/icon_512x512@2x.png" "$ASSETS/Icon.png"

rm -rf "$ICONSET"
echo "✓  Wrote $ASSETS/AppIcon.icns and $ASSETS/Icon.png"
