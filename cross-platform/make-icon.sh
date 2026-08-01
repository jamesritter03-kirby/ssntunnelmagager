#!/bin/bash
#
# Renders the cross-platform app icon and builds the assets the app + packaging use:
#   • src/RemoteStuff/Assets/AppIcon.icns   – macOS bundle icon
#   • src/RemoteStuff/Assets/AppIcon.ico    – Windows installer/app icon
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

echo "▶︎  Building AppIcon.ico…"
ICO_TMP="$(mktemp -d)"
for s in 16 24 32 48 64 128 256; do
  sips -z "$s" "$s" "$ASSETS/Icon.png" --out "$ICO_TMP/$s.png" >/dev/null
done
python3 - "$ICO_TMP" "$ASSETS/AppIcon.ico" <<'PY'
import sys, struct, os
tmp, out = sys.argv[1], sys.argv[2]
sizes = [16, 24, 32, 48, 64, 128, 256]
imgs = [(s, open(os.path.join(tmp, f"{s}.png"), "rb").read()) for s in sizes]
n = len(imgs)
offset = 6 + n * 16
entries = b""
for s, data in imgs:
    w = 0 if s >= 256 else s
    entries += struct.pack("<BBBBHHII", w, w, 0, 0, 1, 32, len(data), offset)
    offset += len(data)
with open(out, "wb") as f:
    f.write(struct.pack("<HHH", 0, 1, n))
    f.write(entries)
    for _, data in imgs:
        f.write(data)
PY
rm -rf "$ICO_TMP"

rm -rf "$ICONSET"
echo "✓  Wrote $ASSETS/AppIcon.icns, $ASSETS/AppIcon.ico and $ASSETS/Icon.png"
