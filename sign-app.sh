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

# Sign any standalone dylibs we embed (e.g. libRoyalVNCKit.dylib) before the
# main executable so the inside-out order holds.
if [[ -d "$BUNDLE/Contents/Frameworks" ]]; then
    while IFS= read -r dylib; do
        codesign --force --sign - "$dylib" >/dev/null 2>&1 || true
    done < <(find "$BUNDLE/Contents/Frameworks" -maxdepth 1 -name '*.dylib' -type f)
fi

# Re-strip detritus that iCloud may have re-applied to nested files while we were
# signing them, then sign the executable and the bundle back-to-back. On
# ~/Documents the provenance / FinderInfo xattrs reappear within seconds and
# would otherwise break the outer bundle seal ("resource fork … not allowed").
xattr -cr "$BUNDLE" 2>/dev/null || true
codesign --force --sign - "$BUNDLE/Contents/MacOS/$EXE_NAME" >/dev/null 2>&1 || true
xattr -cr "$BUNDLE" 2>/dev/null || true
codesign --force --sign - "$BUNDLE" >/dev/null 2>&1 || true

# 3. Verify (warn but don't abort callers — a failure still leaves a launchable app).
if codesign --verify --deep --strict "$BUNDLE" >/dev/null 2>&1; then
    echo "✓  Signature valid: $(basename "$BUNDLE")"
else
    echo "⚠︎  Signature verification failed for $(basename "$BUNDLE"):" >&2
    codesign --verify --deep --strict "$BUNDLE" 2>&1 | sed 's/^/     /' >&2 || true
fi
