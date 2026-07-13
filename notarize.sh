#!/bin/bash
#
# Notarizes a signed .app or .dmg with Apple and staples the ticket.
#
#   ./notarize.sh "Remote Stuff.app"
#   ./notarize.sh "dist/Remote Stuff.dmg"
#
# Prerequisites (one-time — see ./setup-notarization.sh):
#   • A "Developer ID Application" certificate installed in your keychain.
#   • Stored notarytool credentials in a keychain profile (default name below,
#     override with $NOTARY_PROFILE).
#
# The input must already be signed with a Developer ID + Hardened Runtime +
# secure timestamp (build-app.sh / sign-app.sh do this automatically when a
# Developer ID identity is present). For an .app this zips a copy, submits it,
# waits for the result, then staples the ORIGINAL .app in place. For a .dmg it
# submits the .dmg directly and staples it.
#
set -euo pipefail
cd "$(dirname "$0")"

TARGET="${1:?usage: notarize.sh <App.app | image.dmg>}"
NOTARY_PROFILE="${NOTARY_PROFILE:-sshtm-notary}"

if [[ ! -e "$TARGET" ]]; then
    echo "✗  Not found: $TARGET" >&2
    exit 1
fi

# Sanity: the target must be Developer ID signed (not ad-hoc). Notarization of
# an ad-hoc signature always fails, so catch it early with a clear message.
AUTH="$(codesign -dvv "$TARGET" 2>&1 | grep -i 'Authority=' | head -1 || true)"
if ! echo "$AUTH" | grep -qi 'Developer ID Application'; then
    echo "✗  $TARGET is not signed with a Developer ID Application certificate." >&2
    echo "   Found: ${AUTH:-<no authority / ad-hoc>}" >&2
    echo "   Install your Developer ID cert, then re-run ./build-app.sh (or ./sign-app.sh)." >&2
    exit 1
fi

# Confirm the credential profile exists.
if ! xcrun notarytool history --keychain-profile "$NOTARY_PROFILE" >/dev/null 2>&1; then
    echo "✗  No notarytool credentials found for profile \"$NOTARY_PROFILE\"." >&2
    echo "   Run ./setup-notarization.sh first (or set \$NOTARY_PROFILE)." >&2
    exit 1
fi

EXT="${TARGET##*.}"
SUBMIT_PATH="$TARGET"
CLEANUP=""

if [[ "$EXT" == "app" ]]; then
    # notarytool needs a container: zip the app for submission.
    SUBMIT_PATH="$(mktemp -d /tmp/notarize.XXXXXX)/$(basename "${TARGET%.app}").zip"
    CLEANUP="$(dirname "$SUBMIT_PATH")"
    echo "▶︎  Zipping app for submission…"
    ditto -c -k --sequesterRsrc --keepParent "$TARGET" "$SUBMIT_PATH"
fi

echo "▶︎  Submitting to Apple notary service (profile: $NOTARY_PROFILE)…"
echo "   This can take a few minutes."
set +e
SUBMIT_OUT="$(xcrun notarytool submit "$SUBMIT_PATH" \
    --keychain-profile "$NOTARY_PROFILE" --wait 2>&1)"
SUBMIT_RC=$?
set -e
echo "$SUBMIT_OUT" | sed 's/^/     /'

# Extract the submission id for a detailed log on failure.
SUB_ID="$(echo "$SUBMIT_OUT" | awk -F'[ :]+' '/^  *id:/ {print $3; exit}')"

if [[ $SUBMIT_RC -ne 0 ]] || ! echo "$SUBMIT_OUT" | grep -qi 'status: Accepted'; then
    echo "✗  Notarization did not succeed." >&2
    if [[ -n "$SUB_ID" ]]; then
        echo "   Fetching the detailed log for $SUB_ID…" >&2
        xcrun notarytool log "$SUB_ID" --keychain-profile "$NOTARY_PROFILE" 2>&1 | sed 's/^/     /' >&2 || true
    fi
    [[ -n "$CLEANUP" ]] && rm -rf "$CLEANUP"
    exit 1
fi

# Staple the ticket to the ORIGINAL artifact (not the zip copy).
echo "▶︎  Stapling ticket to $(basename "$TARGET")…"
xcrun stapler staple "$TARGET"
xcrun stapler validate "$TARGET"

# Final Gatekeeper assessment.
echo "▶︎  Gatekeeper assessment:"
if [[ "$EXT" == "dmg" ]]; then
    spctl --assess --type open --context context:primary-signature --verbose=4 "$TARGET" 2>&1 | sed 's/^/     /' || true
else
    spctl --assess --type execute --verbose=4 "$TARGET" 2>&1 | sed 's/^/     /' || true
fi

[[ -n "$CLEANUP" ]] && rm -rf "$CLEANUP"

echo
echo "✓  Notarized and stapled: $TARGET"
