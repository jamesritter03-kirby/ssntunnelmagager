#!/bin/bash
#
# Packages "Remote Stuff.app" into a shareable zip for another
# Apple Silicon Mac.
#
#   ./package-dist.sh
#
# Produces:  dist/Remote Stuff (Apple Silicon).zip
#
# Note: the app is ad-hoc signed (not notarized — that requires a paid Apple
# Developer account). On the receiving Mac, macOS Gatekeeper will quarantine it,
# so the recipient must clear the quarantine flag once (see the bundled
# "READ ME FIRST.txt", or the instructions printed below).
#
set -euo pipefail
cd "$(dirname "$0")"

APP_NAME="Remote Stuff"
BUNDLE="${APP_NAME}.app"
ZIP_NAME="${APP_NAME} (Apple Silicon).zip"
DIST_DIR="dist"
# Folder that becomes the top level inside the zip (holds the app + readme).
STAGE_DIR="${DIST_DIR}/${APP_NAME}"

# 1. Build + assemble + ad-hoc sign the arm64 .app
./build-app.sh release

# 2. Confirm it really is an Apple Silicon (arm64) binary
ARCH="$(lipo -archs "${BUNDLE}/Contents/MacOS/SSHTunnelManager" 2>/dev/null || echo unknown)"
echo "▶︎  Binary architecture: ${ARCH}"
if [[ "$ARCH" != *arm64* ]]; then
    echo "✗  Expected an arm64 binary but found: ${ARCH}" >&2
    exit 1
fi

# 3. Stage the app + a recipient readme, then zip the staging folder
echo "▶︎  Staging files…"
rm -rf "$STAGE_DIR"
mkdir -p "$STAGE_DIR"
cp -R "$BUNDLE" "$STAGE_DIR/"

cat > "${STAGE_DIR}/READ ME FIRST.txt" <<'EOF'
Remote Stuff — first launch on a new Mac
========================================

Requirements: an Apple Silicon Mac (M1 or newer), macOS 13 or later.

Because this app isn't notarized with a paid Apple Developer ID, macOS
quarantines it after you copy it. Opening it the first time (no Terminal needed):

  1. Drag "Remote Stuff.app" into your Applications folder.
  2. Right-click (or Control-click) the app -> Open -> Open.
  3. If macOS still refuses, open System Settings -> Privacy & Security,
     scroll down, and click "Open Anyway", then confirm.

After this one-time approval, the app opens with a normal double-click.

Your saved profiles live in:
  ~/Library/Application Support/SSHTunnelManager/profiles.json
EOF

echo "▶︎  Creating ${DIST_DIR}/${ZIP_NAME}…"
rm -f "${DIST_DIR}/${ZIP_NAME}"
# ditto preserves the bundle structure, symlinks and signature correctly.
# Zipping the staging folder bundles the app + readme together under one folder.
( cd "$DIST_DIR" && ditto -c -k --sequesterRsrc --keepParent "$APP_NAME" "$ZIP_NAME" )
rm -rf "$STAGE_DIR"

SIZE="$(du -h "${DIST_DIR}/${ZIP_NAME}" | cut -f1 | tr -d ' ')"

echo
echo "✓  Created: ${DIST_DIR}/${ZIP_NAME}  (${SIZE})"
echo
echo "   Send that .zip to the other Apple Silicon Mac. There, tell them to:"
echo
echo "       1. Unzip it and move \"${BUNDLE}\" to /Applications"
echo "       2. Run once in Terminal:"
echo "            xattr -dr com.apple.quarantine \"/Applications/${BUNDLE}\""
echo "       3. Double-click to launch."
echo
echo "   (These steps are also in the bundled \"READ ME FIRST.txt\".)"
