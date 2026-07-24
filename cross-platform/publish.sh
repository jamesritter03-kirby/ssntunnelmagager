#!/usr/bin/env bash
#
# Build self-contained Remote Stuff apps for macOS, Linux and Windows.
# Each output includes the .NET runtime, so end users need nothing installed.
#
# Usage:
#   ./publish.sh                       # build the default set
#   ./publish.sh osx-arm64             # build only the given runtime identifier(s)
#   ./publish.sh --sign                # build + Developer ID sign the macOS bundles
#   ./publish.sh --notarize            # build + sign + notarize + staple the macOS bundles
#   ./publish.sh --notarize osx-arm64  # flags may precede the RID list
#
# Signing/notarization only apply to the macOS (osx-*) bundles and require a
# "Developer ID Application" certificate (and, for --notarize, notarytool
# credentials — see the repo-root ./setup-notarization.sh).
#
# Packaging choices:
#   • Linux/Windows are published as a single self-contained executable.
#   • macOS is published multi-file (not single-file) so each native .dylib can
#     be individually code-signed — single-file extracts unsigned dylibs at
#     runtime, which Gatekeeper's Hardened Runtime rejects.
#
# Output goes to: cross-platform/dist/
#
set -euo pipefail

cd "$(dirname "$0")"

PROJECT="src/RemoteStuff/RemoteStuff.csproj"
OUT_ROOT="dist"
CONFIG="Release"

# ----- Parse leading flags -----
SIGN=0
NOTARIZE=0
while [[ "${1:-}" == --* ]]; do
  case "$1" in
    --sign)     SIGN=1 ;;
    --notarize) SIGN=1; NOTARIZE=1 ;;
    *) echo "Unknown flag: $1" >&2; exit 1 ;;
  esac
  shift
done

# Runtime identifiers to build when none are passed on the command line.
DEFAULT_RIDS=(osx-arm64 osx-x64 linux-x64 win-x64)

if [ "$#" -gt 0 ]; then
  RIDS=("$@")
else
  RIDS=("${DEFAULT_RIDS[@]}")
fi

# App-bundle metadata for macOS.
APP_NAME="Remote Stuff"
BUNDLE_ID="com.remotestuff.app"
VERSION="1.0.0"

echo "Publishing Remote Stuff ($CONFIG) for: ${RIDS[*]}"
[[ "$SIGN" == "1" ]] && echo "macOS bundles will be code-signed."
[[ "$NOTARIZE" == "1" ]] && echo "macOS bundles will be notarized + stapled."
rm -rf "$OUT_ROOT"
mkdir -p "$OUT_ROOT"

# macOS bundles are assembled and signed in a scratch directory that is NOT
# iCloud-synced and where the binaries are never executed. That keeps their
# com.apple.provenance xattr empty (executed/iCloud files get a non-empty one
# that codesign rejects), then the finished bundle is moved into dist/.
WORK="$(mktemp -d "${TMPDIR:-/tmp}/rs-publish.XXXXXX")"
trap 'rm -rf "$WORK"' EXIT

for RID in "${RIDS[@]}"; do
  echo
  echo "==> $RID"

  # macOS is multi-file so dylibs stay individually signable; others single-file.
  if [[ "$RID" == osx-* ]]; then
    SINGLE_FILE=false
    OUT_DIR="$WORK/$RID"
  else
    SINGLE_FILE=true
    OUT_DIR="$OUT_ROOT/$RID"
  fi

  dotnet publish "$PROJECT" \
    -c "$CONFIG" \
    -r "$RID" \
    --self-contained true \
    -p:PublishSingleFile=$SINGLE_FILE \
    -p:IncludeNativeLibrariesForSelfExtract=true \
    -p:IncludeAllContentForSelfExtract=true \
    -p:EnableCompressionInSingleFile=true \
    -p:PublishTrimmed=false \
    -p:DebugType=none \
    -o "$OUT_DIR" \
    -v quiet

  case "$RID" in
    osx-*)
      # Assemble the .app in the scratch dir (never executed → signable).
      APP_DIR="$WORK/$APP_NAME ($RID).app"
      rm -rf "$APP_DIR"
      mkdir -p "$APP_DIR/Contents/MacOS" "$APP_DIR/Contents/Resources"

      # Move every published file into the bundle (binary + native side files).
      cp -R "$OUT_DIR/." "$APP_DIR/Contents/MacOS/"
      chmod +x "$APP_DIR/Contents/MacOS/RemoteStuff"

      # Copy the app icon if one exists.
      if [ -f "src/RemoteStuff/Assets/AppIcon.icns" ]; then
        cp "src/RemoteStuff/Assets/AppIcon.icns" "$APP_DIR/Contents/Resources/AppIcon.icns"
        ICON_LINE="<key>CFBundleIconFile</key><string>AppIcon</string>"
      else
        ICON_LINE=""
      fi

      cat > "$APP_DIR/Contents/Info.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>CFBundleName</key><string>$APP_NAME</string>
    <key>CFBundleDisplayName</key><string>$APP_NAME</string>
    <key>CFBundleIdentifier</key><string>$BUNDLE_ID</string>
    <key>CFBundleVersion</key><string>$VERSION</string>
    <key>CFBundleShortVersionString</key><string>$VERSION</string>
    <key>CFBundlePackageType</key><string>APPL</string>
    <key>CFBundleExecutable</key><string>RemoteStuff</string>
    <key>LSMinimumSystemVersion</key><string>11.0</string>
    <key>NSHighResolutionCapable</key><true/>
    $ICON_LINE
</dict>
</plist>
PLIST

      if [[ "$NOTARIZE" == "1" ]]; then
        ./sign-mac.sh --notarize "$APP_DIR"
      elif [[ "$SIGN" == "1" ]]; then
        ./sign-mac.sh "$APP_DIR"
      fi

      # While the bundle is still in the clean scratch dir (never executed, not
      # iCloud-synced), zip it as the distributable artifact. This preserves the
      # signature/staple exactly and avoids the FinderInfo detritus that iCloud
      # injects into directories under ~/Documents.
      if [[ "$SIGN" == "1" || "$NOTARIZE" == "1" ]]; then
        ZIP_OUT="$OUT_ROOT/$APP_NAME ($RID).zip"
        rm -f "$ZIP_OUT"
        ditto -c -k --sequesterRsrc --keepParent "$APP_DIR" "$ZIP_OUT"
        echo "    zipped:  $ZIP_OUT"
      fi

      # Move the finished bundle into dist/ for convenience (double-clickable).
      FINAL="$OUT_ROOT/$APP_NAME ($RID).app"
      rm -rf "$FINAL"
      mv "$APP_DIR" "$FINAL"

      # iCloud stamps com.apple.FinderInfo/provenance xattrs on directories moved
      # into ~/Documents, which trip `codesign --verify --strict` on this local
      # copy (but not the signature itself, and not the pristine .zip above).
      # Strip ONLY those names — never com.apple.cs.*, which hold the managed
      # .dll signatures. iCloud may re-add FinderInfo; the .zip is the reliable
      # artifact to distribute.
      if [[ "$SIGN" == "1" || "$NOTARIZE" == "1" ]]; then
        xattr -dr com.apple.FinderInfo "$FINAL" 2>/dev/null || true
        xattr -dr com.apple.provenance "$FINAL" 2>/dev/null || true
      fi
      echo "    bundled: $FINAL"
      ;;
    win-*)
      echo "    exe: $OUT_DIR/RemoteStuff.exe"
      ;;
    *)
      chmod +x "$OUT_DIR/RemoteStuff" 2>/dev/null || true
      echo "    binary: $OUT_DIR/RemoteStuff"
      ;;
  esac
done

echo
echo "Done. Artifacts are in: $OUT_ROOT/"
