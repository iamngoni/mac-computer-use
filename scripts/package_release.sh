#!/bin/bash
# Notarize the signed app and produce Sparkle, DMG, and Homebrew artifacts.
set -euo pipefail

REPO_DIR="$(cd "$(dirname "$0")/.." && pwd)"
cd "$REPO_DIR"

# CI passes every credential in the environment. On a Mac that already holds
# them, NOTARY_KEYCHAIN_PROFILE names a `notarytool store-credentials`
# profile, the Sparkle key comes from the login keychain (`generate_keys`),
# and build.sh finds the Developer ID identity itself.
SPARKLE_BIN="$REPO_DIR/.build/artifacts/sparkle/Sparkle/bin"
if [[ -n "${NOTARY_KEYCHAIN_PROFILE:-}" ]]; then
  notary_args=(--keychain-profile "$NOTARY_KEYCHAIN_PROFILE" --wait)
else
  : "${APPLE_ID:?APPLE_ID or NOTARY_KEYCHAIN_PROFILE is required}"
  : "${APPLE_TEAM_ID:?APPLE_TEAM_ID is required}"
  : "${APPLE_APP_SPECIFIC_PASSWORD:?APPLE_APP_SPECIFIC_PASSWORD is required}"
  notary_args=(
    --apple-id "$APPLE_ID"
    --team-id "$APPLE_TEAM_ID"
    --password "$APPLE_APP_SPECIFIC_PASSWORD"
    --wait
  )
fi
if [[ ! -x "$SPARKLE_BIN/generate_appcast" ]]; then
  swift package resolve
fi
if [[ -z "${SPARKLE_PUBLIC_ED_KEY:-}" ]]; then
  if [[ -n "${SPARKLE_PRIVATE_KEY:-}" ]]; then
    echo "SPARKLE_PUBLIC_ED_KEY is required with SPARKLE_PRIVATE_KEY." >&2
    exit 2
  fi
  SPARKLE_PUBLIC_ED_KEY="$("$SPARKLE_BIN/generate_keys" -p)" || {
    echo "No Sparkle key in the login keychain. Run $SPARKLE_BIN/generate_keys once." >&2
    exit 2
  }
fi
export SPARKLE_PUBLIC_ED_KEY

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
# The trailing slash matters: generate_appcast resolves file names against it.
DOWNLOAD_PREFIX="https://github.com/iamngoni/mac-computer-use/releases/download/$TAG/"

if [[ -d "$DIST" ]]; then rm -rf "$DIST"; fi
mkdir -p "$DIST"
BUILD_MODE=release \
OUTPUT_DIR="$DIST" \
BUILD_ARCHS="${BUILD_ARCHS:-arm64 x86_64}" \
SPARKLE_FEED_URL="$FEED_URL" \
./build.sh

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
# Sign the disk image with the identity that signed the app, so Gatekeeper
# can assess the DMG itself and not only the stapled ticket.
signing_identity="$(codesign -dvv "$APP" 2>&1 | sed -n 's/^Authority=\(Developer ID Application: .*\)$/\1/p' | head -n 1)"
dmg_sign_args=(--force --timestamp --sign "$signing_identity")
if [[ -n "${SIGNING_KEYCHAIN:-}" ]]; then
  dmg_sign_args+=(--keychain "$SIGNING_KEYCHAIN")
fi
codesign "${dmg_sign_args[@]}" "$DMG"
xcrun notarytool submit "$DMG" "${notary_args[@]}"
xcrun stapler staple "$DMG"
xcrun stapler validate "$DMG"

appcast_dir="$(mktemp -d "${TMPDIR:-/tmp}/maccu-appcast.XXXXXX")"
trap 'rm -rf "$dmg_root" "$appcast_dir"' EXIT
cp "$ZIP" "$appcast_dir/"
appcast_args=(
  --download-url-prefix "$DOWNLOAD_PREFIX"
  --link "https://github.com/iamngoni/mac-computer-use"
)
if [[ -n "${SPARKLE_PRIVATE_KEY:-}" ]]; then
  printf '%s' "$SPARKLE_PRIVATE_KEY" | \
    "$SPARKLE_BIN/generate_appcast" --ed-key-file - "${appcast_args[@]}" "$appcast_dir"
else
  "$SPARKLE_BIN/generate_appcast" "${appcast_args[@]}" "$appcast_dir"
fi
cp "$appcast_dir/appcast.xml" "$DIST/appcast.xml"
grep -Fq "url=\"${DOWNLOAD_PREFIX}MacComputerUse-$VERSION.zip\"" "$DIST/appcast.xml" || {
  echo "appcast.xml does not point at ${DOWNLOAD_PREFIX}MacComputerUse-$VERSION.zip" >&2
  exit 1
}

sha256="$(shasum -a 256 "$DMG" | awk '{print $1}')"
sed \
  -e "s/__VERSION__/$VERSION/g" \
  -e "s/__SHA256__/$sha256/g" \
  Packaging/Casks/mac-computer-use.rb.template > "$DIST/mac-computer-use.rb"

codesign --verify --deep --strict --verbose=2 "$APP"
spctl --assess --type execute --verbose=2 "$APP"
spctl --assess --type open --context context:primary-signature --verbose=2 "$DMG"
echo "Release artifacts are ready in $DIST"
