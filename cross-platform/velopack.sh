#!/usr/bin/env bash
#
# Build + package Remote Stuff auto-update releases with Velopack for
# Windows, macOS (Apple Silicon + Intel) and Linux, then optionally publish
# them to the GitHub "desktop-updates" release that the in-app updater checks.
#
# The in-app updater (Services/UpdateService.cs) reads Velopack feeds from:
#   https://github.com/jamesritter03-kirby/ssntunnelmagager  (release tag: desktop-updates)
# using one channel per runtime, so each OS/arch only ever installs its own build.
#
# Requirements:
#   • .NET 8 SDK
#   • vpk CLI, matching the Velopack NuGet version:
#       dotnet tool install -g vpk --version 1.2.0
#     (ensure ~/.dotnet/tools is on your PATH)
#   • gh CLI (only for --upload), authenticated: gh auth login
#   • For the Linux AppImage, mksquashfs must be on PATH:  brew install squashfs
#
# IMPORTANT platform rules (from Velopack):
#   • macOS packages can ONLY be built on macOS (needs codesign/xcrun/productbuild).
#   • Windows and Linux packages can be cross-built from macOS (done here via
#     `vpk [win]` / `vpk [linux]` directives).
#
# Usage:
#   ./velopack.sh                      # build+pack all platforms into releases/
#   ./velopack.sh osx-arm64 win-x64    # only the given runtime identifier(s)
#   ./velopack.sh --upload             # build+pack all, then upload to GitHub
#   VERSION=1.9.43 ./velopack.sh       # override the release version
#
# macOS signing/notarization (optional) is enabled by exporting, before running:
#   SIGN_IDENTITY="Developer ID Application: Your Name (TEAMID)"
#   NOTARY_PROFILE="the-notarytool-keychain-profile"   # optional, enables notarize
#
set -euo pipefail

cd "$(dirname "$0")"
export PATH="$PATH:$HOME/.dotnet/tools"

PROJECT="src/RemoteStuff/RemoteStuff.csproj"
CONFIG="Release"
PACK_ID="RemoteStuff"
PACK_TITLE="Remote Stuff"
PACK_AUTHORS="Remote Stuff"
BUNDLE_ID="com.remotestuff.desktop"
REPO="jamesritter03-kirby/ssntunnelmagager"
RELEASE_TAG="desktop-updates"

# Version defaults to the app's assembly version (keep in sync with the .csproj).
VERSION="${VERSION:-1.9.42}"

PUB_ROOT="pub"          # per-RID `dotnet publish` output (scratch)
OUT_ROOT="releases"     # Velopack feeds + installers to upload

# ----- Parse flags -----
UPLOAD=0
while [[ "${1:-}" == --* ]]; do
  case "$1" in
    --upload) UPLOAD=1 ;;
    *) echo "Unknown flag: $1" >&2; exit 1 ;;
  esac
  shift
done

DEFAULT_RIDS=(osx-arm64 osx-x64 win-x64 linux-x64)
if [ "$#" -gt 0 ]; then RIDS=("$@"); else RIDS=("${DEFAULT_RIDS[@]}"); fi

command -v vpk >/dev/null || { echo "vpk not found. Install: dotnet tool install -g vpk --version 1.2.0" >&2; exit 1; }

# The Linux AppImage build shells out to mksquashfs.
for _r in "${RIDS[@]}"; do
  if [[ "$_r" == linux-* ]] && ! command -v mksquashfs >/dev/null; then
    echo "mksquashfs not found (needed for the Linux AppImage). Install: brew install squashfs" >&2
    exit 1
  fi
done

echo "Packaging Remote Stuff $VERSION for: ${RIDS[*]}"
mkdir -p "$OUT_ROOT"
rm -rf "$PUB_ROOT"

for RID in "${RIDS[@]}"; do
  echo
  echo "==> $RID"

  # Velopack wants a plain published folder (not single-file).
  PUB_DIR="$PUB_ROOT/$RID"
  dotnet publish "$PROJECT" \
    -c "$CONFIG" \
    -r "$RID" \
    --self-contained true \
    -p:PublishSingleFile=false \
    -p:PublishTrimmed=false \
    -p:DebugType=none \
    -o "$PUB_DIR" \
    -v quiet

  case "$RID" in
    win-*)
      DIRECTIVE="[win]"
      MAIN_EXE="RemoteStuff.exe"
      ;;
    linux-*)
      DIRECTIVE="[linux]"
      MAIN_EXE="RemoteStuff"
      ;;
    osx-*)
      DIRECTIVE=""            # native — must run on macOS
      MAIN_EXE="RemoteStuff"
      ;;
    *)
      echo "Unsupported RID: $RID" >&2; exit 1 ;;
  esac

  # One channel per runtime so a platform never installs another's package.
  CHANNEL="$RID"

  # Assemble common pack args.
  ARGS=(pack
    --packId "$PACK_ID"
    --packVersion "$VERSION"
    --packDir "$PUB_DIR"
    --packTitle "$PACK_TITLE"
    --packAuthors "$PACK_AUTHORS"
    --mainExe "$MAIN_EXE"
    --channel "$CHANNEL"
    --outputDir "$OUT_ROOT"
  )

  # macOS-only extras: bundle id + optional signing/notarization.
  if [[ "$RID" == osx-* ]]; then
    ARGS+=(--bundleId "$BUNDLE_ID")
    if [[ -n "${SIGN_IDENTITY:-}" ]]; then
      ARGS+=(--signAppIdentity "$SIGN_IDENTITY")
      [[ -n "${NOTARY_PROFILE:-}" ]] && ARGS+=(--notaryProfile "$NOTARY_PROFILE")
    fi
  fi

  if [[ -n "$DIRECTIVE" ]]; then
    vpk "$DIRECTIVE" "${ARGS[@]}"
  else
    vpk "${ARGS[@]}"
  fi
done

echo
echo "Done. Update feeds + installers are in: $OUT_ROOT/"
ls -1 "$OUT_ROOT" | sed 's/^/    /'

if [[ "$UPLOAD" == "1" ]]; then
  echo
  echo "==> Uploading to GitHub release '$RELEASE_TAG' on $REPO"
  command -v gh >/dev/null || { echo "gh not found. Install it or run without --upload." >&2; exit 1; }

  # Ensure a non-prerelease rolling release exists for the desktop apps.
  if ! gh release view "$RELEASE_TAG" --repo "$REPO" >/dev/null 2>&1; then
    gh release create "$RELEASE_TAG" \
      --repo "$REPO" \
      --title "Remote Stuff (desktop auto-update)" \
      --notes "Velopack update feeds for the cross-platform Remote Stuff desktop app (Windows/macOS/Linux). Managed automatically by velopack.sh." \
      --latest=false
  fi

  # Upload every feed + package + installer, replacing any same-named assets.
  # Old .nupkgs are kept on the release so Velopack can build delta updates.
  gh release upload "$RELEASE_TAG" "$OUT_ROOT"/* --repo "$REPO" --clobber
  echo "Uploaded $(ls -1 "$OUT_ROOT" | wc -l | tr -d ' ') asset(s)."
fi
