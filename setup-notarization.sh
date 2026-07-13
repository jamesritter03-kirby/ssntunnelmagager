#!/bin/bash
#
# One-time setup for Apple notarization credentials.
#
#   ./setup-notarization.sh
#
# Stores your notary credentials in a named keychain profile (default
# "sshtm-notary") so notarize.sh can submit non-interactively. You only run
# this once per machine (or when your credentials change).
#
# You can authenticate two ways:
#
#   A) App Store Connect API key (recommended — no password, survives 2FA):
#        Create a key at https://appstoreconnect.apple.com/access/integrations/api
#        (role: "Developer" is enough for notarization). Download the .p8 ONCE.
#        You'll need: the Key ID, the Issuer ID (UUID at the top of that page),
#        and the path to the downloaded AuthKey_XXXXXXXX.p8.
#
#   B) Apple ID + app-specific password:
#        Create an app-specific password at https://account.apple.com (Sign-In &
#        Security → App-Specific Passwords). You'll need your Apple ID email,
#        that password, and your 10-character Team ID.
#
set -euo pipefail

PROFILE="${NOTARY_PROFILE:-sshtm-notary}"

echo "This stores notarization credentials in keychain profile: \"$PROFILE\""
echo
echo "Choose authentication method:"
echo "  1) App Store Connect API key (.p8)   [recommended]"
echo "  2) Apple ID + app-specific password"
printf "Enter 1 or 2: "
read -r CHOICE

case "$CHOICE" in
    1)
        printf "Path to AuthKey_XXXXXXXX.p8: "; read -r KEYPATH
        KEYPATH="${KEYPATH/#\~/$HOME}"
        printf "Key ID (e.g. ABC123DEFG): "; read -r KEYID
        printf "Issuer ID (UUID): "; read -r ISSUER
        if [[ ! -f "$KEYPATH" ]]; then
            echo "✗  Key file not found: $KEYPATH" >&2
            exit 1
        fi
        xcrun notarytool store-credentials "$PROFILE" \
            --key "$KEYPATH" --key-id "$KEYID" --issuer "$ISSUER"
        ;;
    2)
        printf "Apple ID email: "; read -r APPLEID
        printf "Team ID (10 chars): "; read -r TEAMID
        printf "App-specific password: "; read -rs APPPW; echo
        xcrun notarytool store-credentials "$PROFILE" \
            --apple-id "$APPLEID" --team-id "$TEAMID" --password "$APPPW"
        ;;
    *)
        echo "✗  Invalid choice." >&2
        exit 1
        ;;
esac

echo
echo "▶︎  Verifying credentials by fetching your notarization history…"
if xcrun notarytool history --keychain-profile "$PROFILE" >/dev/null 2>&1; then
    echo "✓  Credentials stored and working (profile: \"$PROFILE\")."
    echo "   You can now run ./notarize.sh, or ./make-dmg.sh will notarize automatically."
else
    echo "⚠︎  Stored, but a test call failed. Double-check the values and re-run." >&2
    exit 1
fi
