#!/bin/bash
#
# Manages the Sparkle EdDSA signing keys used to authenticate updates.
#
#   ./make-keys.sh            # create the key pair if missing, print the public key
#   ./make-keys.sh -p         # just print the existing public key (for Info.plist)
#   ./make-keys.sh -x key.txt # export the PRIVATE key for safe backup, then store offline
#
# The PRIVATE key is stored in your login Keychain. Back it up somewhere safe:
# if you lose it you can no longer sign updates that existing installs will accept.
# The PUBLIC key goes in Info.plist as SUPublicEDKey (already set).
#
set -euo pipefail
cd "$(dirname "$0")"

TOOLS="$(dirname "$(find .build/artifacts -type f -name generate_keys 2>/dev/null | head -1)")"
if [[ -z "$TOOLS" || ! -x "$TOOLS/generate_keys" ]]; then
    echo "✗  generate_keys not found. Run 'swift build' first so SPM fetches Sparkle." >&2
    exit 1
fi

exec "$TOOLS/generate_keys" "$@"
