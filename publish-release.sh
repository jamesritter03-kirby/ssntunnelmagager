#!/bin/bash
#
# Publishes an update produced by ./make-appcast.sh:
#   1. Uploads the Sparkle archives (and the installer DMG) as assets on a single
#      rolling GitHub Release tagged "updates" — a stable home for every version.
#   2. Commits & pushes docs/appcast.xml so GitHub Pages serves the new feed.
#
#   ./publish-release.sh                # commit + push the appcast now
#   DEFER_PUSH=1 ./publish-release.sh   # stage the appcast only; ship it with the
#                                       # release commit so Pages deploys just once
#
# Requires the GitHub CLI:   brew install gh   &&   gh auth login
# (If you don't have gh, the script prints the manual steps instead.)
#
set -euo pipefail
cd "$(dirname "$0")"

REPO="jamesritter03-kirby/ssntunnelmagager"
RELEASE_TAG="updates"
ARCHIVES="sparkle-updates"
DOCS_DIR="docs"
APP_NAME="Remote Stuff"
DMG_SRC="dist/${APP_NAME}.dmg"
DMG_ASSET="dist/SSH-Tunnel-Manager.dmg"   # hyphenated → clean, space-free URL (kept stable across the rename)

manual_steps() {
    cat <<EOF

Manual publish (no gh CLI):
  1. Create a GitHub Release named/tagged "${RELEASE_TAG}" on
     https://github.com/${REPO}/releases  (only needed the first time).
  2. Upload these files as assets to that release (replace existing):
$(cd "$ARCHIVES" 2>/dev/null && ls -1 *.zip *.delta 2>/dev/null | sed 's/^/        - /' || true)
$( [[ -f "$DMG_SRC" ]] && echo "        - ${DMG_SRC}  (rename to SSH-Tunnel-Manager.dmg)" )
  3. Commit & push the feed:
        git add ${DOCS_DIR}/appcast.xml && git commit -m "Publish appcast" && git push
EOF
}

# --- Preconditions -----------------------------------------------------------
if [[ ! -f "${DOCS_DIR}/appcast.xml" ]]; then
    echo "✗  ${DOCS_DIR}/appcast.xml not found. Run ./make-appcast.sh first." >&2
    exit 1
fi

if ! command -v gh >/dev/null 2>&1; then
    echo "⚠︎  GitHub CLI (gh) is not installed."
    echo "    Install it with:  brew install gh   then:  gh auth login"
    manual_steps
    exit 1
fi
if ! gh auth status >/dev/null 2>&1; then
    echo "⚠︎  gh is installed but not signed in. Run:  gh auth login"
    manual_steps
    exit 1
fi

# --- 1. Ensure the rolling release exists ------------------------------------
if ! gh release view "$RELEASE_TAG" --repo "$REPO" >/dev/null 2>&1; then
    echo "▶︎  Creating rolling release '${RELEASE_TAG}'…"
    gh release create "$RELEASE_TAG" --repo "$REPO" \
        --title "Application updates" \
        --notes "Auto-update binaries for ${APP_NAME}, consumed by Sparkle via appcast.xml. Managed by publish-release.sh — please don't delete." \
        --prerelease
fi

# --- 2. Collect + upload assets ----------------------------------------------
shopt -s nullglob
assets=( "$ARCHIVES"/*.zip "$ARCHIVES"/*.delta )
if [[ ${#assets[@]} -eq 0 ]]; then
    echo "✗  No archives in ${ARCHIVES}/. Run ./make-appcast.sh first." >&2
    exit 1
fi

# Include the installer DMG (hyphenated copy) so the website download link works.
if [[ -f "$DMG_SRC" ]]; then
    cp "$DMG_SRC" "$DMG_ASSET"
    assets+=( "$DMG_ASSET" )
fi

echo "▶︎  Uploading ${#assets[@]} asset(s) to ${REPO} (${RELEASE_TAG})…"
gh release upload "$RELEASE_TAG" "${assets[@]}" --repo "$REPO" --clobber
[[ -f "$DMG_ASSET" ]] && rm -f "$DMG_ASSET"

# --- 3. Publish the appcast via Pages ----------------------------------------
# GitHub Pages allows only one concurrent deployment, so pushing the appcast and
# the source seconds apart (as a full release does) makes the first Pages build
# fail with "Deployment failed, try again later." To avoid that spurious failure,
# a release can set DEFER_PUSH=1: we then only *stage* docs/appcast.xml and let
# the caller's single source commit & push ship it — so Pages deploys exactly
# once per release.
git add "${DOCS_DIR}/appcast.xml"
if git diff --cached --quiet; then
    echo "▶︎  ${DOCS_DIR}/appcast.xml unchanged — nothing to commit."
elif [[ "${DEFER_PUSH:-0}" == "1" ]]; then
    echo "✓  Staged ${DOCS_DIR}/appcast.xml (DEFER_PUSH=1 — not pushed)."
    echo "    Ship it with your release commit so Pages deploys once, e.g.:"
    echo "      git add -A && git commit -m \"…\" && git push"
else
    git commit -m "Publish appcast ($(date +%Y-%m-%d))" >/dev/null
    git push
    echo "✓  Pushed ${DOCS_DIR}/appcast.xml"
fi

echo
echo "✓  Published. Within a minute the feed is live at:"
echo "     https://jamesritter03-kirby.github.io/ssntunnelmagager/appcast.xml"
echo "   Existing installs will offer the update at their next check."
