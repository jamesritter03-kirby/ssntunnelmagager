#!/bin/bash
#
# Builds SSHTunnelManager and assembles a runnable "SSH Tunnel Manager.app".
#
#   ./build-app.sh           # release build
#   ./build-app.sh debug     # debug build
#
set -euo pipefail
cd "$(dirname "$0")"

CONFIG="${1:-release}"
APP_NAME="SSH Tunnel Manager"
BUNDLE="${APP_NAME}.app"
EXE="SSHTunnelManager"

echo "▶︎  Building ($CONFIG)…"
swift build -c "$CONFIG"

BIN_PATH="$(swift build -c "$CONFIG" --show-bin-path)"

echo "▶︎  Assembling ${BUNDLE}…"
rm -rf "$BUNDLE"
mkdir -p "$BUNDLE/Contents/MacOS"
mkdir -p "$BUNDLE/Contents/Resources"

cp "$BIN_PATH/$EXE" "$BUNDLE/Contents/MacOS/$EXE"
cp Info.plist "$BUNDLE/Contents/Info.plist"

# App icon (generate it with ./make-icon.sh).
if [[ -f AppIcon.icns ]]; then
    cp AppIcon.icns "$BUNDLE/Contents/Resources/AppIcon.icns"
else
    echo "⚠︎  AppIcon.icns not found — run ./make-icon.sh to generate it."
fi

# ----- Embed Sparkle.framework (auto-update) -----
SPARKLE_FW="$(find .build/artifacts -type d -name 'Sparkle.framework' -path '*macos*' 2>/dev/null | head -1)"
SP="$BUNDLE/Contents/Frameworks/Sparkle.framework"
if [[ -n "$SPARKLE_FW" ]]; then
    echo "▶︎  Embedding Sparkle.framework…"
    mkdir -p "$BUNDLE/Contents/Frameworks"
    rm -rf "$SP"
    cp -R "$SPARKLE_FW" "$SP"

    # The executable resolves @rpath/Sparkle.framework/… via this rpath.
    install_name_tool -add_rpath @executable_path/../Frameworks \
        "$BUNDLE/Contents/MacOS/$EXE" 2>/dev/null || true
else
    echo "⚠︎  Sparkle.framework not found in .build/artifacts — run 'swift build' first."
    echo "    (Auto-update will be unavailable in this build.)"
fi

# ----- Embed libRoyalVNCKit.dylib (in-app VNC viewer) -----
# RoyalVNCKit is a dynamic library; CryptoSwift and the C helpers are statically
# linked into it, so this single dylib is all we need. The executable resolves
# @rpath/libRoyalVNCKit.dylib via the @executable_path/../Frameworks rpath added
# above for Sparkle.
RVNC_DYLIB="$BIN_PATH/libRoyalVNCKit.dylib"
if [[ -f "$RVNC_DYLIB" ]]; then
    echo "▶︎  Embedding libRoyalVNCKit.dylib…"
    mkdir -p "$BUNDLE/Contents/Frameworks"
    cp "$RVNC_DYLIB" "$BUNDLE/Contents/Frameworks/"
    # Make sure the Frameworks rpath exists even if the Sparkle block was skipped
    # (a duplicate add is harmless and silently ignored).
    install_name_tool -add_rpath @executable_path/../Frameworks \
        "$BUNDLE/Contents/MacOS/$EXE" 2>/dev/null || true
else
    echo "⚠︎  libRoyalVNCKit.dylib not found in $BIN_PATH — run 'swift build' first."
    echo "    (The in-app VNC viewer will be unavailable in this build.)"
fi

# Strip detritus xattrs + ad-hoc sign (inside-out, verified). Shared with the
# packaging scripts so the DMG and update zips are signed identically.
#
# Note: on iCloud-synced folders (~/Documents) macOS may re-tag this bundle a
# moment later, which can break this signature. That's harmless for launching
# locally; make-dmg.sh / make-appcast.sh re-sign a /tmp copy for distribution.
./sign-app.sh "$BUNDLE"

echo "✓  Built ${BUNDLE}"
echo
echo "   Launch it with:"
echo "       open \"${BUNDLE}\""
echo
echo "   Or move it to /Applications:"
echo "       mv \"${BUNDLE}\" /Applications/"
