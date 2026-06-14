#!/bin/bash
#
# Renders the app icon and builds AppIcon.icns.
#
#   ./make-icon.sh
#
# Edit make-icon.swift to tweak the artwork, then re-run this.
#
set -euo pipefail
cd "$(dirname "$0")"

ICONSET="AppIcon.iconset"

echo "▶︎  Rendering icon PNGs…"
rm -rf "$ICONSET"
swift make-icon.swift "$ICONSET"

echo "▶︎  Building AppIcon.icns…"
iconutil -c icns "$ICONSET" -o AppIcon.icns

rm -rf "$ICONSET"
echo "✓  Wrote AppIcon.icns"
