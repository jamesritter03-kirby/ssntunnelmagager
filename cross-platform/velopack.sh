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
PACK_TITLE="Remote Stuff CP"
PACK_AUTHORS="Remote Stuff CP"
BUNDLE_ID="com.remotestuff.desktop"
REPO="jamesritter03-kirby/ssntunnelmagager"
RELEASE_TAG="desktop-updates"

# Version defaults to the app's assembly version (keep in sync with the .csproj).
VERSION="${VERSION:-1.9.43}"

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

# vpk builds each delta by reading the prior release out of the output dir. When
# that dir is the iCloud-synced releases/ folder, materializing its (possibly
# evicted) .nupkgs taints vpk's temp .app with com.apple.FinderInfo and breaks
# codesign on macOS. Pack into a clean, non-iCloud clone instead, then copy the
# new artifacts back. cp -c uses an APFS clone (instant, no extra space).
PACK_OUT="$(mktemp -d "${TMPDIR:-/tmp}/vpkout.XXXXXX")"
cp -Rc "$OUT_ROOT/." "$PACK_OUT/" 2>/dev/null || cp -R "$OUT_ROOT/." "$PACK_OUT/"
xattr -cr "$PACK_OUT" 2>/dev/null || true

for RID in "${RIDS[@]}"; do
  echo
  echo "==> $RID"

  # Velopack wants a plain published folder (not single-file).
  PUB_DIR="$PUB_ROOT/$RID"
  PACK_DIR="$PUB_DIR"
  dotnet publish "$PROJECT" \
    -c "$CONFIG" \
    -r "$RID" \
    --self-contained true \
    -p:PublishSingleFile=false \
    -p:PublishTrimmed=false \
    -p:DebugType=none \
    -o "$PUB_DIR" \
    -v quiet

  # Strip macOS extended attributes (resource forks / Finder info / provenance)
  # that iCloud-synced folders attach — codesign rejects bundles that carry them
  # ("resource fork, Finder information, or similar detritus not allowed").
  if [[ "$RID" == osx-* ]]; then
    xattr -cr "$PUB_DIR" 2>/dev/null || true

    # Sign the native spawn-helper inside-out (before vpk signs the outer .app).
    # It's the standalone binary UnixPtyProcess execs to give ssh a controlling
    # terminal; an unsigned nested Mach-O would break a hardened/notarized build.
    if [[ -n "${SIGN_IDENTITY:-}" && -f "$PUB_DIR/spawn-helper" ]]; then
      codesign --force --timestamp --options runtime \
        --sign "$SIGN_IDENTITY" "$PUB_DIR/spawn-helper"
    fi

    # Stage into a non-iCloud temp dir before packing. iCloud re-attaches
    # com.apple.FinderInfo to freshly-created bundle files even after xattr -cr,
    # which lands on vpk's generated .app and makes its codesign fail. Packing
    # from $TMPDIR (/var/folders, not synced) avoids the race entirely.
    PACK_DIR="$(mktemp -d "${TMPDIR:-/tmp}/vpkstage.$RID.XXXXXX")"
    cp -R "$PUB_DIR/." "$PACK_DIR/"
    xattr -cr "$PACK_DIR" 2>/dev/null || true
  fi

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
    --packDir "$PACK_DIR"
    --packTitle "$PACK_TITLE"
    --packAuthors "$PACK_AUTHORS"
    --mainExe "$MAIN_EXE"
    --channel "$CHANNEL"
    --outputDir "$PACK_OUT"
  )

  # macOS-only extras: bundle id + optional signing/notarization.
  if [[ "$RID" == osx-* ]]; then
    ARGS+=(--bundleId "$BUNDLE_ID")
    if [[ -n "${SIGN_IDENTITY:-}" ]]; then
      ARGS+=(--signAppIdentity "$SIGN_IDENTITY")
      [[ -n "${NOTARY_PROFILE:-}" ]] && ARGS+=(--notaryProfile "$NOTARY_PROFILE")
    fi
  fi

  # Clear vpk's reusable work dir. It builds the .app under $TMPDIR/velopack and
  # copies files into an existing temp.N bundle without stripping that dir's own
  # xattrs, so a FinderInfo left by a prior failed run persists and keeps failing
  # codesign. Removing it forces a clean bundle every run.
  rm -rf "${TMPDIR%/}/velopack" "/tmp/velopack" 2>/dev/null || true

  if [[ -n "$DIRECTIVE" ]]; then
    vpk "$DIRECTIVE" "${ARGS[@]}"
  else
    vpk "${ARGS[@]}"
  fi
done

# Bring the freshly built feeds/packages/installers back into releases/.
cp -Rc "$PACK_OUT/." "$OUT_ROOT/" 2>/dev/null || cp -R "$PACK_OUT/." "$OUT_ROOT/"
rm -rf "$PACK_OUT"

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

  # Only upload what actually changed this run instead of the whole releases/
  # folder (which keeps every historical .nupkg locally for delta generation and
  # can be multiple GB). We push: the small feed/manifest files (always), this
  # version's new full + delta packages, and the freshly-built installers for the
  # RIDs we just packed. Old .nupkgs already on the release stay put so Velopack
  # can still build deltas from them.
  UPLOAD_FILES=()
  add_glob() { local f; for f in $1; do [[ -e "$f" ]] && UPLOAD_FILES+=("$f"); done; }

  add_glob "$OUT_ROOT/RELEASES-*"          # per-channel feed manifests
  add_glob "$OUT_ROOT/*.json"              # assets.*.json / releases.*.json feeds
  add_glob "$OUT_ROOT/*$VERSION*"          # new full + delta .nupkgs for this version
  for RID in "${RIDS[@]}"; do              # regenerated installers/portables
    add_glob "$OUT_ROOT/*$RID-Setup.exe"
    add_glob "$OUT_ROOT/*$RID-Setup.pkg"
    add_glob "$OUT_ROOT/*$RID-Portable.zip"
    add_glob "$OUT_ROOT/*$RID.AppImage"
  done

  # De-duplicate while preserving order.
  UNIQUE_FILES=()
  for f in "${UPLOAD_FILES[@]}"; do
    [[ " ${UNIQUE_FILES[*]} " == *" $f "* ]] || UNIQUE_FILES+=("$f")
  done

  if [[ "${#UNIQUE_FILES[@]}" -eq 0 ]]; then
    echo "No matching assets found to upload." >&2
    exit 1
  fi

  gh release upload "$RELEASE_TAG" "${UNIQUE_FILES[@]}" --repo "$REPO" --clobber
  echo "Uploaded ${#UNIQUE_FILES[@]} asset(s)."
fi
