#!/bin/bash
# Build mac-computer-use into a locally or Developer ID signed app bundle.
set -euo pipefail

REPO_DIR="$(cd "$(dirname "$0")" && pwd)"
cd "$REPO_DIR"

APP_NAME="MacComputerUse.app"
BUNDLE_ID="com.modestnerd.mac-computer-use"
EXECUTABLE="mac-computer-use"
VERSION="$(tr -d '[:space:]' < VERSION)"
BUILD_MODE="${BUILD_MODE:-local}"
OUTPUT_DIR="${OUTPUT_DIR:-$REPO_DIR}"
APP="$OUTPUT_DIR/$APP_NAME"
SIGNING_IDENTITY="${CODE_SIGN_IDENTITY:--}"
BUILD_ARCHS="${BUILD_ARCHS:-$(uname -m)}"
export MACOSX_DEPLOYMENT_TARGET="${MACOSX_DEPLOYMENT_TARGET:-13.0}"

if [[ ! "$VERSION" =~ ^[0-9]+\.[0-9]+\.[0-9]+$ ]]; then
  echo "VERSION must contain three numeric components." >&2
  exit 2
fi
if [[ "$BUILD_MODE" != "local" && "$BUILD_MODE" != "release" ]]; then
  echo "BUILD_MODE must be local or release." >&2
  exit 2
fi
if [[ "$BUILD_MODE" == "release" ]]; then
  : "${SPARKLE_PUBLIC_ED_KEY:?SPARKLE_PUBLIC_ED_KEY is required for release builds}"
  : "${SPARKLE_FEED_URL:?SPARKLE_FEED_URL is required for release builds}"
  if [[ "$SIGNING_IDENTITY" == "-" ]]; then
    echo "CODE_SIGN_IDENTITY must be a Developer ID Application identity for release builds." >&2
    exit 2
  fi
fi

mkdir -p "$OUTPUT_DIR"
if [[ -e "$APP" ]]; then
  rm -rf "$APP"
fi
mkdir -p \
  "$APP/Contents/MacOS" \
  "$APP/Contents/Frameworks" \
  "$APP/Contents/Resources/Licenses" \
  "$APP/Contents/Resources/VirtualCursor"

echo "Compiling Swift package for: $BUILD_ARCHS"
binary_paths=()
framework_path=""
for arch in $BUILD_ARCHS; do
  swift build \
    -c release \
    --arch "$arch" \
    --product "$EXECUTABLE" \
    -Xswiftc -warnings-as-errors
  bin_dir="$(swift build -c release --arch "$arch" --show-bin-path)"
  binary_paths+=("$bin_dir/$EXECUTABLE")
  if [[ -z "$framework_path" ]]; then
    framework_path="$bin_dir/Sparkle.framework"
  fi
done

if [[ ${#binary_paths[@]} -eq 1 ]]; then
  cp "${binary_paths[0]}" "$APP/Contents/MacOS/$EXECUTABLE"
else
  lipo -create "${binary_paths[@]}" -output "$APP/Contents/MacOS/$EXECUTABLE"
fi
ditto "$framework_path" "$APP/Contents/Frameworks/Sparkle.framework"
cp .build/checkouts/Sparkle/LICENSE "$APP/Contents/Resources/Licenses/Sparkle-LICENSE.txt"
cp THIRD_PARTY_NOTICES.md "$APP/Contents/Resources/THIRD_PARTY_NOTICES.md"

if ! otool -l "$APP/Contents/MacOS/$EXECUTABLE" | grep -A2 LC_RPATH | grep -q '@executable_path/../Frameworks'; then
  install_name_tool -add_rpath '@executable_path/../Frameworks' "$APP/Contents/MacOS/$EXECUTABLE"
fi

echo "Packaging virtual cursor assets"
for asset in \
  cursor-pointer.png cursor-pointer@2x.png cursor-pointer@3x.png \
  cursor-pulse.png cursor-pulse@2x.png cursor-pulse@3x.png; do
  cp "Assets/VirtualCursor/$asset" "$APP/Contents/Resources/VirtualCursor/$asset"
done

sparkle_configuration=""
if [[ "$BUILD_MODE" == "release" ]]; then
  sparkle_configuration=$(cat <<PLIST
  <key>SUFeedURL</key><string>$SPARKLE_FEED_URL</string>
  <key>SUPublicEDKey</key><string>$SPARKLE_PUBLIC_ED_KEY</string>
  <key>SUEnableAutomaticChecks</key><true/>
  <key>SUAutomaticallyUpdate</key><true/>
  <key>SUScheduledCheckInterval</key><integer>86400</integer>
PLIST
)
fi

cat > "$APP/Contents/Info.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>CFBundleName</key><string>Mac Computer Use</string>
  <key>CFBundleDisplayName</key><string>Mac Computer Use</string>
  <key>CFBundleIdentifier</key><string>$BUNDLE_ID</string>
  <key>CFBundleVersion</key><string>$VERSION</string>
  <key>CFBundleShortVersionString</key><string>$VERSION</string>
  <key>CFBundleExecutable</key><string>$EXECUTABLE</string>
  <key>CFBundlePackageType</key><string>APPL</string>
  <key>LSUIElement</key><true/>
  <key>LSMinimumSystemVersion</key><string>13.0</string>
  <key>NSAppleEventsUsageDescription</key><string>Mac Computer Use needs permission to navigate supported browsers on your behalf.</string>
  <key>NSScreenCaptureUsageDescription</key><string>Mac Computer Use captures the app window selected by your MCP client.</string>
$sparkle_configuration
</dict>
</plist>
PLIST

plutil -lint "$APP/Contents/Info.plist"

sign_target() {
  local target="$1"
  local preserve_entitlements="${2:-}"
  local codesign_args=(--force)
  if [[ "$BUILD_MODE" == "release" ]]; then
    codesign_args+=(--options runtime --timestamp --sign "$SIGNING_IDENTITY")
    if [[ -n "${SIGNING_KEYCHAIN:-}" ]]; then
      codesign_args+=(--keychain "$SIGNING_KEYCHAIN")
    fi
  else
    codesign_args+=(--timestamp=none --sign -)
  fi
  if [[ "$preserve_entitlements" == "preserve-entitlements" ]]; then
    codesign_args+=(--preserve-metadata=entitlements)
  fi
  codesign "${codesign_args[@]}" "$target"
}

echo "Signing nested Sparkle services and app"
SPARKLE="$APP/Contents/Frameworks/Sparkle.framework"
sign_target "$SPARKLE/Versions/B/XPCServices/Installer.xpc"
sign_target "$SPARKLE/Versions/B/XPCServices/Downloader.xpc" preserve-entitlements
sign_target "$SPARKLE/Versions/B/Autoupdate"
sign_target "$SPARKLE/Versions/B/Updater.app"
sign_target "$SPARKLE"
sign_target "$APP"

codesign --verify --deep --strict --verbose=2 "$APP"
test "$(defaults read "$APP/Contents/Info" CFBundleIdentifier)" = "$BUNDLE_ID"
test "$(defaults read "$APP/Contents/Info" CFBundleExecutable)" = "$EXECUTABLE"

echo "Built $APP ($VERSION, $BUILD_MODE)"
