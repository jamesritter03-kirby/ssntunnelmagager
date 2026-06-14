#!/bin/bash
#
# Strips disallowed extended attributes and applies an ad-hoc code signature to
# an .app bundle (including any embedded Sparkle.framework), inside-out, then
# verifies the result.
#
#   ./sign-app.sh "path/to/Some.app"
#
# Why the xattr strip: on iCloud-synced folders (e.g. ~/Documents) macOS adds
# com.apple.FinderInfo / com.apple.provenance / fileprovider tags to files,
# which makes codesign fail with "resource fork, Finder information, or similar
# detritus not allowed". Packaging scripts call this on a /tmp copy so the
# distributed app can't be re-tagged by iCloud after signing.
#
set -euo pipefail

BUNDLE="${1:?usage: sign-app.sh <App.app>}"
EXE_NAME="$(/usr/libexec/PlistBuddy -c 'Print CFBundleExecutable' "$BUNDLE/Contents/Info.plist")"

# 1. Remove extended attributes that codesign rejects.
xattr -cr "$BUNDLE" 2>/dev/null || true

# 2. Sign inside-out: Sparkle helpers → framework → main executable → app bundle.
SP="$BUNDLE/Contents/Frameworks/Sparkle.framework"
if [[ -d "$SP" ]]; then
    VDIR="$(cd "$SP/Versions/Current" && pwd -P)"
    for nested in \
        "$VDIR/XPCServices/Downloader.xpc" \
        "$VDIR/XPCServices/Installer.xpc" \
        "$VDIR/Updater.app" \
        "$VDIR/Autoupdate"; do
        [[ -e "$nested" ]] && codesign --force --sign - "$nested" >/dev/null 2>&1 || true
    done
    codesign --force --sign - "$SP" >/dev/null 2>&1 || true
fi
codesign --force --sign - "$BUNDLE/Contents/MacOS/$EXE_NAME" >/dev/null 2>&1 || true
codesign --force --sign - "$BUNDLE" >/dev/null 2>&1 || true

# 3. Verify (warn but don't abort callers — a failure still leaves a launchable app).
if codesign --verify --deep --strict "$BUNDLE" >/dev/null 2>&1; then
    echo "✓  Signature valid: $(basename "$BUNDLE")"
else
    echo "⚠︎  Signature verification failed for $(basename "$BUNDLE"):" >&2
    codesign --verify --deep --strict "$BUNDLE" 2>&1 | sed 's/^/     /' >&2 || true
fi
