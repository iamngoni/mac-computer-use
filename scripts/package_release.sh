#!/bin/bash
# Notarize the signed app and produce Sparkle, DMG, and Homebrew artifacts.
set -euo pipefail

REPO_DIR="$(cd "$(dirname "$0")/.." && pwd)"
cd "$REPO_DIR"

: "${APPLE_ID:?APPLE_ID is required}"
: "${APPLE_TEAM_ID:?APPLE_TEAM_ID is required}"
: "${APPLE_APP_SPECIFIC_PASSWORD:?APPLE_APP_SPECIFIC_PASSWORD is required}"
: "${SPARKLE_PRIVATE_KEY:?SPARKLE_PRIVATE_KEY is required}"
: "${SPARKLE_PUBLIC_ED_KEY:?SPARKLE_PUBLIC_ED_KEY is required}"
: "${CODE_SIGN_IDENTITY:?CODE_SIGN_IDENTITY is required}"

VERSION="$(tr -d '[:space:]' < VERSION)"
TAG="${RELEASE_TAG:-v$VERSION}"
if [[ "$TAG" != "v$VERSION" ]]; then
  echo "Release tag $TAG does not match VERSION $VERSION." >&2
  exit 2
fi

DIST="$REPO_DIR/dist"
APP="$DIST/MacComputerUse.app"
ZIP="$DIST/MacComputerUse-$VERSION.zip"
DMG="$DIST/MacComputerUse-$VERSION.dmg"
FEED_URL="https://github.com/iamngoni/mac-computer-use/releases/latest/download/appcast.xml"
DOWNLOAD_PREFIX="https://github.com/iamngoni/mac-computer-use/releases/download/$TAG"

if [[ -d "$DIST" ]]; then rm -rf "$DIST"; fi
mkdir -p "$DIST"
BUILD_MODE=release \
OUTPUT_DIR="$DIST" \
BUILD_ARCHS="${BUILD_ARCHS:-arm64 x86_64}" \
SPARKLE_FEED_URL="$FEED_URL" \
./build.sh

notary_args=(
  --apple-id "$APPLE_ID"
  --team-id "$APPLE_TEAM_ID"
  --password "$APPLE_APP_SPECIFIC_PASSWORD"
  --wait
)

pre_notary_zip="$DIST/notarization-upload.zip"
ditto -c -k --sequesterRsrc --keepParent "$APP" "$pre_notary_zip"
xcrun notarytool submit "$pre_notary_zip" "${notary_args[@]}"
rm "$pre_notary_zip"
xcrun stapler staple "$APP"
xcrun stapler validate "$APP"

ditto -c -k --sequesterRsrc --keepParent "$APP" "$ZIP"

dmg_root="$(mktemp -d "${TMPDIR:-/tmp}/maccu-dmg.XXXXXX")"
trap 'rm -rf "$dmg_root"' EXIT
ditto "$APP" "$dmg_root/MacComputerUse.app"
ln -s /Applications "$dmg_root/Applications"
hdiutil create \
  -volname "Mac Computer Use" \
  -srcfolder "$dmg_root" \
  -format UDZO \
  -ov \
  "$DMG"
xcrun notarytool submit "$DMG" "${notary_args[@]}"
xcrun stapler staple "$DMG"
xcrun stapler validate "$DMG"

appcast_dir="$(mktemp -d "${TMPDIR:-/tmp}/maccu-appcast.XXXXXX")"
trap 'rm -rf "$dmg_root" "$appcast_dir"' EXIT
cp "$ZIP" "$appcast_dir/"
printf '%s' "$SPARKLE_PRIVATE_KEY" | \
  .build/artifacts/sparkle/Sparkle/bin/generate_appcast \
    --ed-key-file - \
    --download-url-prefix "$DOWNLOAD_PREFIX" \
    --link "https://github.com/iamngoni/mac-computer-use" \
    "$appcast_dir"
cp "$appcast_dir/appcast.xml" "$DIST/appcast.xml"

sha256="$(shasum -a 256 "$DMG" | awk '{print $1}')"
sed \
  -e "s/__VERSION__/$VERSION/g" \
  -e "s/__SHA256__/$sha256/g" \
  Packaging/Casks/mac-computer-use.rb.template > "$DIST/mac-computer-use.rb"

codesign --verify --deep --strict --verbose=2 "$APP"
spctl --assess --type execute --verbose=2 "$APP"
spctl --assess --type open --context context:primary-signature --verbose=2 "$DMG"
echo "Release artifacts are ready in $DIST"
