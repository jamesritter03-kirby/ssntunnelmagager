#!/bin/bash
#
# Builds a drag-to-Applications disk image:  dist/Remote Stuff.dmg
#
#   ./make-dmg.sh
#
# The DMG opens to a window where you drag the app onto an Applications
# shortcut — the classic macOS install experience.
#
# Note: the app is ad-hoc signed (not notarized — that needs a paid Apple
# Developer account). The FIRST time it's opened on another Mac, the user
# right-clicks the app -> Open -> Open (no Terminal required). After that,
# a normal double-click works.
#
set -euo pipefail
cd "$(dirname "$0")"

APP_NAME="Remote Stuff"
BUNDLE="${APP_NAME}.app"
VOL_NAME="${APP_NAME}"
DIST_DIR="dist"
DMG_PATH="${DIST_DIR}/${APP_NAME}.dmg"
RW_DMG="${DIST_DIR}/_rw.dmg"
STAGE="$(mktemp -d "${TMPDIR:-/tmp}/sshtm-stage.XXXXXX")"   # outside iCloud so signing sticks
BG_DIR="${STAGE}/.background"
BG_PNG="${BG_DIR}/background.png"

# 1. Build + assemble + ad-hoc sign the arm64 .app
./build-app.sh release

# 2. Confirm Apple Silicon binary
ARCH="$(lipo -archs "${BUNDLE}/Contents/MacOS/SSHTunnelManager" 2>/dev/null || echo unknown)"
echo "▶︎  Binary architecture: ${ARCH}"
[[ "$ARCH" == *arm64* ]] || { echo "✗  Expected arm64 but got: ${ARCH}" >&2; exit 1; }

# 3. Stage the app + Applications shortcut (+ background)
echo "▶︎  Staging disk image contents (outside iCloud)…"
mkdir -p "$BG_DIR"
cp -R "$BUNDLE" "$STAGE/"
# Re-strip xattrs + re-sign the staged copy in case iCloud re-tagged the source.
./sign-app.sh "$STAGE/$BUNDLE"
ln -s /Applications "$STAGE/Applications"

HAVE_BG=0
if swift dmg-background.swift "$BG_PNG" >/dev/null 2>&1; then
    HAVE_BG=1
    echo "▶︎  Generated window background."
else
    rm -rf "$BG_DIR"
    echo "▶︎  (Background generation skipped — using a plain window.)"
fi

# 4. Create a temporary read-write image we can lay out in Finder
echo "▶︎  Creating read-write image…"
mkdir -p "$DIST_DIR"
rm -f "$RW_DMG" "$DMG_PATH"
hdiutil create -srcfolder "$STAGE" -volname "$VOL_NAME" -fs HFS+ \
    -format UDRW -ov "$RW_DMG" >/dev/null

MOUNT_DIR="$(mktemp -d /tmp/sshtm-dmg.XXXXXX)"
hdiutil attach "$RW_DMG" -mountpoint "$MOUNT_DIR" -nobrowse -noautoopen >/dev/null
trap 'hdiutil detach "$MOUNT_DIR" >/dev/null 2>&1 || hdiutil detach "$MOUNT_DIR" -force >/dev/null 2>&1 || true' EXIT

# 5. Best-effort pretty layout via Finder (icon positions + background).
#    If Finder automation isn't permitted, the DMG still works as a plain
#    window containing the app + the Applications shortcut.
BG_CLAUSE=""
if [[ "$HAVE_BG" == "1" ]]; then
    BG_CLAUSE='try
            set background picture of vo to file ".background:background.png"
        end try'
fi

if osascript >/dev/null 2>&1 <<EOF
tell application "Finder"
    tell disk "$VOL_NAME"
        open
        set current view of container window to icon view
        set toolbar visible of container window to false
        set statusbar visible of container window to false
        set the bounds of container window to {200, 120, 800, 520}
        set vo to the icon view options of container window
        set arrangement of vo to not arranged
        set icon size of vo to 120
        ${BG_CLAUSE}
        set position of item "${BUNDLE}" of container window to {160, 195}
        set position of item "Applications" of container window to {440, 195}
        update without registering applications
        delay 1
        close
    end tell
end tell
EOF
then
    echo "▶︎  Applied window layout."
else
    echo "▶︎  (Finder layout skipped — DMG will use the default window.)"
fi

sync
hdiutil detach "$MOUNT_DIR" >/dev/null 2>&1 || hdiutil detach "$MOUNT_DIR" -force >/dev/null 2>&1
trap - EXIT

# 6. Convert to a compressed, read-only DMG for distribution
echo "▶︎  Compressing final DMG…"
hdiutil convert "$RW_DMG" -format UDZO -imagekey zlib-level=9 -ov -o "$DMG_PATH" >/dev/null
rm -f "$RW_DMG"
rm -rf "$STAGE" "$MOUNT_DIR"

SIZE="$(du -h "$DMG_PATH" | cut -f1 | tr -d ' ')"
echo
echo "✓  Created: ${DMG_PATH}  (${SIZE})"
echo
echo "   Send that .dmg to the other Apple Silicon Mac. There:"
echo "     1. Double-click the .dmg, then drag the app onto Applications."
echo "     2. First launch only: right-click the app in Applications -> Open -> Open."
echo "        If macOS still blocks it: System Settings -> Privacy & Security ->"
echo "        'Open Anyway'. No Terminal needed; afterwards just double-click."
