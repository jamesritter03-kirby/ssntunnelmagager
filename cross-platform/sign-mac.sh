#!/usr/bin/env bash
#
# Code-sign (and optionally notarize + staple) a published Remote Stuff .app
# bundle for macOS distribution.
#
#   ./sign-mac.sh "dist/Remote Stuff (osx-arm64).app"            # sign only
#   ./sign-mac.sh --notarize "dist/Remote Stuff (osx-arm64).app" # sign + notarize + staple
#
# Signing identity resolution (in order):
#   1. $SIGN_IDENTITY               — explicit override (name or SHA-1 hash)
#   2. "Developer ID Application: …" — first one found in the keychain
#
# Notarization uses a stored notarytool keychain profile (see the repo-root
# ./setup-notarization.sh). Override its name with $NOTARY_PROFILE
# (default: sshtm-notary).
#
# This signs inside-out: every Mach-O file (native .dylib/.so and the apphost)
# gets a Developer ID signature with Hardened Runtime + a secure timestamp, then
# the bundle is sealed with RemoteStuff.entitlements. That combination is what
# Apple notarization requires for a self-contained .NET app.
#
set -euo pipefail
cd "$(dirname "$0")"

NOTARIZE=0
if [[ "${1:-}" == "--notarize" ]]; then
    NOTARIZE=1
    shift
fi

BUNDLE="${1:?usage: sign-mac.sh [--notarize] <App.app>}"
[[ -d "$BUNDLE" ]] || { echo "✗  Not a bundle: $BUNDLE" >&2; exit 1; }

ENTITLEMENTS="$(pwd)/RemoteStuff.entitlements"
EXE_NAME="$(/usr/libexec/PlistBuddy -c 'Print CFBundleExecutable' "$BUNDLE/Contents/Info.plist")"
MACOS_DIR="$BUNDLE/Contents/MacOS"

# ----- Resolve the signing identity -----
IDENTITY="${SIGN_IDENTITY:-}"
if [[ -z "$IDENTITY" ]]; then
    IDENTITY="$(security find-identity -v -p codesigning 2>/dev/null \
        | awk -F'"' '/Developer ID Application/ {print $2; exit}')"
fi
if [[ -z "$IDENTITY" ]]; then
    echo "✗  No 'Developer ID Application' identity found in the keychain." >&2
    echo "   Set \$SIGN_IDENTITY, or install your Developer ID certificate." >&2
    exit 1
fi
echo "▶︎  Signing with Developer ID identity: $IDENTITY"

# 1. Strip extended attributes codesign rejects (iCloud/Finder detritus).
xattr -cr "$BUNDLE" 2>/dev/null || true

# 2. Sign every Mach-O file inside-out: native libraries first, then the apphost.
#    Managed .dll files are plain assemblies (not Mach-O) and are left untouched.
#
# codesign rejects files carrying a non-empty com.apple.provenance xattr (macOS
# stamps executables that have already been run, and on iCloud-synced folders
# like ~/Documents it can't be stripped in place) with "resource fork, Finder
# information, or similar detritus not allowed". Signing a fresh copy on a new
# inode and moving that signed file into place sidesteps it entirely.
sign_macho() {
    local f="$1"; shift  # any remaining args are extra codesign flags
    local perm t
    perm="$(stat -f '%Lp' "$f")"
    t="$(mktemp "${f}.XXXXXX")"
    cp "$f" "$t"
    xattr -c "$t" 2>/dev/null || true
    codesign --force --sign "$IDENTITY" --options runtime --timestamp "$@" "$t"
    chmod "$perm" "$t"
    mv -f "$t" "$f"
}

echo "▶︎  Signing bundle contents…"
# codesign treats every loose file in Contents/MacOS (native .dylib/.so, managed
# .dll, and even .json config files) as nested code that must carry its own
# signature, or the bundle seal fails with "code object is not signed at all".
# Sign them all inside-out; codesign embeds Mach-O signatures and stores generic
# ones in com.apple.cs.* xattrs. The apphost is signed last, with entitlements.
while IFS= read -r f; do
    [[ "$f" == "$MACOS_DIR/$EXE_NAME" ]] && continue
    sign_macho "$f"
done < <(find "$MACOS_DIR" -type f)

# 3. Sign the main executable with entitlements + Hardened Runtime.
echo "▶︎  Signing apphost…"
sign_macho "$MACOS_DIR/$EXE_NAME" --entitlements "$ENTITLEMENTS"

# 4. Seal the outer bundle with the same entitlements.
#    NOTE: do NOT run `xattr -cr` here — managed .dll signatures are stored in
#    com.apple.cs.* extended attributes, and clearing them would strip those
#    signatures and break the seal ("code object is not signed at all").
echo "▶︎  Sealing bundle…"
codesign --force --sign "$IDENTITY" --options runtime --timestamp \
    --entitlements "$ENTITLEMENTS" "$BUNDLE"

# 5. Verify.
if codesign --verify --deep --strict --verbose=2 "$BUNDLE" >/dev/null 2>&1; then
    echo "✓  Signature valid: $(basename "$BUNDLE")"
else
    echo "✗  Signature verification failed:" >&2
    codesign --verify --deep --strict "$BUNDLE" 2>&1 | sed 's/^/     /' >&2 || true
    exit 1
fi

if [[ "$NOTARIZE" == "0" ]]; then
    echo
    echo "Signed. To notarize + staple, re-run with --notarize (needs notarytool credentials)."
    exit 0
fi

# ----- Notarize + staple -----
NOTARY_PROFILE="${NOTARY_PROFILE:-sshtm-notary}"
if ! xcrun notarytool history --keychain-profile "$NOTARY_PROFILE" >/dev/null 2>&1; then
    echo "✗  No notarytool credentials for profile \"$NOTARY_PROFILE\"." >&2
    echo "   Run the repo-root ./setup-notarization.sh first (or set \$NOTARY_PROFILE)." >&2
    exit 1
fi

ZIP="$(mktemp -d /tmp/rs-notarize.XXXXXX)/$(basename "${BUNDLE%.app}").zip"
echo "▶︎  Zipping app for submission…"
ditto -c -k --sequesterRsrc --keepParent "$BUNDLE" "$ZIP"

echo "▶︎  Submitting to Apple notary service (profile: $NOTARY_PROFILE)…"
echo "   This can take a few minutes."
set +e
SUBMIT_OUT="$(xcrun notarytool submit "$ZIP" --keychain-profile "$NOTARY_PROFILE" --wait 2>&1)"
SUBMIT_RC=$?
set -e
echo "$SUBMIT_OUT" | sed 's/^/     /'
SUB_ID="$(echo "$SUBMIT_OUT" | awk -F'[ :]+' '/^  *id:/ {print $3; exit}')"

if [[ $SUBMIT_RC -ne 0 ]] || ! echo "$SUBMIT_OUT" | grep -qi 'status: Accepted'; then
    echo "✗  Notarization did not succeed." >&2
    if [[ -n "$SUB_ID" ]]; then
        xcrun notarytool log "$SUB_ID" --keychain-profile "$NOTARY_PROFILE" 2>&1 | sed 's/^/     /' >&2 || true
    fi
    rm -rf "$(dirname "$ZIP")"
    exit 1
fi

echo "▶︎  Stapling ticket…"
xcrun stapler staple "$BUNDLE"
xcrun stapler validate "$BUNDLE"
spctl --assess --type execute --verbose=4 "$BUNDLE" 2>&1 | sed 's/^/     /' || true
rm -rf "$(dirname "$ZIP")"

echo
echo "✓  Signed, notarized and stapled: $BUNDLE"
