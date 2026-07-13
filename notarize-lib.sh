#!/bin/bash
#
# Sourced helper — provides maybe_notarize().
#
#   source "$(dirname "$0")/notarize-lib.sh"
#   maybe_notarize "Some.app"      # or a .dmg
#
# Runs ./notarize.sh ONLY when both are true:
#   • a Developer ID Application identity is available (or $SIGN_IDENTITY set), and
#   • notary credentials exist for $NOTARY_PROFILE (default "sshtm-notary").
#
# Otherwise it prints a short note and returns 0, so local/ad-hoc builds keep
# working unchanged. Set SKIP_NOTARIZE=1 to force-skip even when configured.

maybe_notarize() {
    local target="$1"
    local here; here="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
    local profile="${NOTARY_PROFILE:-sshtm-notary}"

    if [[ "${SKIP_NOTARIZE:-0}" == "1" ]]; then
        echo "▶︎  SKIP_NOTARIZE=1 — not notarizing $(basename "$target")."
        return 0
    fi

    local have_id=0
    [[ -n "${SIGN_IDENTITY:-}" ]] && have_id=1
    if security find-identity -v -p codesigning 2>/dev/null \
        | grep -q 'Developer ID Application'; then
        have_id=1
    fi
    if [[ "$have_id" != "1" ]]; then
        echo "▶︎  No Developer ID identity — skipping notarization of $(basename "$target") (ad-hoc build)."
        return 0
    fi

    if ! xcrun notarytool history --keychain-profile "$profile" >/dev/null 2>&1; then
        echo "▶︎  No notary credentials for profile \"$profile\" — skipping notarization." >&2
        echo "    Run ./setup-notarization.sh to enable it." >&2
        return 0
    fi

    "$here/notarize.sh" "$target"
}
