#!/bin/bash
#
# Builds a release and produces a SIGNED Sparkle appcast so existing installs
# can auto-update.
#
#   ./make-appcast.sh
#
# What it does:
#   1. Builds "Remote Stuff.app" (via build-app.sh).
#   2. Zips it into  sparkle-updates/SSH-Tunnel-Manager-<version>.zip
#   3. Runs Sparkle's generate_appcast, which signs every archive in that
#      folder with your EdDSA private key (stored in your login Keychain by
#      ./make-keys or generate_keys) and writes  sparkle-updates/appcast.xml
#
# Releasing an update:
#   * Bump CFBundleVersion (and CFBundleShortVersionString) in Info.plist FIRST.
#     Sparkle compares CFBundleVersion to decide if an update is available.
#   * Run this script.
#   * Upload the CONTENTS of sparkle-updates/ (appcast.xml + the .zip files,
#     including any generated *.delta files) to the location your app's
#     SUFeedURL points at. Keep older .zip/.delta files so Sparkle can build
#     smaller delta updates.
#
set -euo pipefail
cd "$(dirname "$0")"

source ./notarize-lib.sh

APP_NAME="Remote Stuff"
BUNDLE="${APP_NAME}.app"
ARCHIVES="sparkle-updates"

# Where the update .zip/.delta files are hosted. They live as assets on a single
# rolling GitHub Release tagged 'updates', which gives every version a stable URL
# under one constant prefix. Override with the DOWNLOAD_URL_PREFIX env var.
DOWNLOAD_URL_PREFIX="${DOWNLOAD_URL_PREFIX:-https://github.com/jamesritter03-kirby/ssntunnelmagager/releases/download/updates/}"

# GitHub Pages serves this folder (main branch /docs); appcast.xml is copied here.
DOCS_DIR="docs"

# Locate Sparkle's CLI tools (downloaded by SPM under .build/artifacts).
TOOLS="$(dirname "$(find .build/artifacts -type f -name generate_appcast 2>/dev/null | head -1)")"
if [[ -z "$TOOLS" || ! -x "$TOOLS/generate_appcast" ]]; then
    echo "✗  generate_appcast not found. Run 'swift build' first so SPM fetches Sparkle." >&2
    exit 1
fi

# 1. Build the signed .app
./build-app.sh release

# 2. Read the version and zip the app (Sparkle-recommended ditto flags)
VERSION="$(/usr/libexec/PlistBuddy -c 'Print CFBundleShortVersionString' Info.plist)"
BUILD="$(/usr/libexec/PlistBuddy -c 'Print CFBundleVersion' Info.plist)"
mkdir -p "$ARCHIVES"
ZIP="${ARCHIVES}/SSH-Tunnel-Manager-${VERSION}-${BUILD}.zip"
echo "▶︎  Zipping ${BUNDLE} → ${ZIP}"
rm -f "$ZIP"
# Stage + re-sign in /tmp (outside iCloud) so the archived app is cleanly signed.
STAGE="$(mktemp -d "${TMPDIR:-/tmp}/sshtm-appcast.XXXXXX")"
cp -R "$BUNDLE" "$STAGE/$BUNDLE"
./sign-app.sh "$STAGE/$BUNDLE"
# Notarize + staple the archived app so Sparkle-delivered updates pass Gatekeeper
# offline (no-op for local/ad-hoc builds without credentials).
maybe_notarize "$STAGE/$BUNDLE"
ditto -c -k --sequesterRsrc --keepParent "$STAGE/$BUNDLE" "$ZIP"
rm -rf "$STAGE"

# 3. Generate + sign the appcast for every archive in the folder
echo "▶︎  Generating signed appcast…"
"$TOOLS/generate_appcast" --download-url-prefix "$DOWNLOAD_URL_PREFIX" "$ARCHIVES"

# 4. Publish the appcast into docs/ (served by GitHub Pages)
mkdir -p "$DOCS_DIR"
cp "${ARCHIVES}/appcast.xml" "${DOCS_DIR}/appcast.xml"

echo
echo "✓  Wrote ${DOCS_DIR}/appcast.xml  (version ${VERSION}, build ${BUILD})"
echo
echo "   Next — publish it:"
echo "     • Automatic:  ./publish-release.sh   (needs the gh CLI; uploads the"
echo "                   archives to the 'updates' release + pushes docs/appcast.xml)"
echo "     • Manual:     upload ${ARCHIVES}/*.zip (+ any *.delta) to the 'updates'"
echo "                   GitHub Release, then commit & push docs/appcast.xml."
echo
echo "   Existing installs see the update at their next check, or via the app"
echo "   menu → Check for Updates…"
