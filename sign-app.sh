#!/bin/bash
#
# Signs an .app bundle (including embedded Sparkle.framework and dylibs),
# inside-out, then verifies the result.
#
#   ./sign-app.sh "path/to/Some.app"
#
# Signing identity resolution (in order):
#   1. $SIGN_IDENTITY               — explicit override (name or SHA-1 hash)
#   2. "Developer ID Application: …" — first one found in the keychain
#   3. "-"                          — ad-hoc fallback (local use only)
#
# When a real Developer ID identity is used, the bundle is signed for
# DISTRIBUTION: Hardened Runtime (--options runtime), a secure --timestamp, and
# the entitlements in entitlements.plist. That's what notarization requires.
# With the ad-hoc fallback it's just a local, launch-only signature.
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
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
ENTITLEMENTS="$SCRIPT_DIR/entitlements.plist"

# ----- Resolve the signing identity -----
IDENTITY="${SIGN_IDENTITY:-}"
if [[ -z "$IDENTITY" ]]; then
    IDENTITY="$(security find-identity -v -p codesigning 2>/dev/null \
        | awk -F'"' '/Developer ID Application/ {print $2; exit}')"
fi
[[ -z "$IDENTITY" ]] && IDENTITY="-"

if [[ "$IDENTITY" == "-" ]]; then
    DIST_SIGNING=0
    RUNTIME=()
    echo "▶︎  Signing ad-hoc (no Developer ID identity found — local use only)…"
else
    DIST_SIGNING=1
    RUNTIME=(--options runtime --timestamp)
    echo "▶︎  Signing with Developer ID identity: ${IDENTITY}"
fi

# Fail loudly for distribution signing; stay lenient for ad-hoc (a partial
# signature still launches locally).
run() {
    if [[ "$DIST_SIGNING" == "1" ]]; then
        "$@"
    else
        "$@" >/dev/null 2>&1 || true
    fi
}

# 1. Remove extended attributes that codesign rejects.
xattr -cr "$BUNDLE" 2>/dev/null || true

# 2. Sign inside-out: Sparkle helpers → framework → embedded dylibs →
#    main executable → app bundle.
SP="$BUNDLE/Contents/Frameworks/Sparkle.framework"
if [[ -d "$SP" ]]; then
    VDIR="$(cd "$SP/Versions/Current" && pwd -P)"
    # Sparkle's helper executables ship with their own entitlements; preserve
    # them while adding our identity + Hardened Runtime + timestamp.
    for nested in \
        "$VDIR/XPCServices/Downloader.xpc" \
        "$VDIR/XPCServices/Installer.xpc" \
        "$VDIR/Updater.app" \
        "$VDIR/Autoupdate"; do
        if [[ -e "$nested" ]]; then
            if [[ "$DIST_SIGNING" == "1" ]]; then
                run codesign --force --sign "$IDENTITY" ${RUNTIME[@]+"${RUNTIME[@]}"} \
                    --preserve-metadata=entitlements,requirements,flags "$nested"
            else
                run codesign --force --sign "$IDENTITY" "$nested"
            fi
        fi
    done
    run codesign --force --sign "$IDENTITY" ${RUNTIME[@]+"${RUNTIME[@]}"} "$SP"
fi

# Embedded standalone dylibs (e.g. libRoyalVNCKit.dylib), signed with our
# identity so Library Validation passes for the main executable.
if [[ -d "$BUNDLE/Contents/Frameworks" ]]; then
    while IFS= read -r dylib; do
        run codesign --force --sign "$IDENTITY" ${RUNTIME[@]+"${RUNTIME[@]}"} "$dylib"
    done < <(find "$BUNDLE/Contents/Frameworks" -maxdepth 1 -name '*.dylib' -type f)
fi

# Re-strip detritus that iCloud may have re-applied to nested files while we were
# signing them, then sign the executable and the bundle. On ~/Documents the
# provenance / FinderInfo xattrs reappear within seconds and would otherwise
# break the outer bundle seal ("resource fork … not allowed").
xattr -cr "$BUNDLE" 2>/dev/null || true
run codesign --force --sign "$IDENTITY" ${RUNTIME[@]+"${RUNTIME[@]}"} \
    "$BUNDLE/Contents/MacOS/$EXE_NAME"
xattr -cr "$BUNDLE" 2>/dev/null || true
if [[ "$DIST_SIGNING" == "1" ]]; then
    run codesign --force --sign "$IDENTITY" ${RUNTIME[@]+"${RUNTIME[@]}"} \
        --entitlements "$ENTITLEMENTS" "$BUNDLE"
else
    run codesign --force --sign "$IDENTITY" "$BUNDLE"
fi

# 3. Verify. For distribution also run the Gatekeeper assessment so problems
#    surface here rather than at notarization time.
if codesign --verify --deep --strict --verbose=2 "$BUNDLE" >/dev/null 2>&1; then
    echo "✓  Signature valid: $(basename "$BUNDLE")"
else
    echo "⚠︎  Signature verification failed for $(basename "$BUNDLE"):" >&2
    codesign --verify --deep --strict "$BUNDLE" 2>&1 | sed 's/^/     /' >&2 || true
    [[ "$DIST_SIGNING" == "1" ]] && exit 1
fi

if [[ "$DIST_SIGNING" == "1" ]]; then
    echo "▶︎  Gatekeeper assessment (an unnotarized app is expected to be rejected here until it's stapled):"
    spctl --assess --type execute --verbose=4 "$BUNDLE" 2>&1 | sed 's/^/     /' || true
fi
