#!/bin/bash
# Build mac-computer-use into a signed .app bundle.
set -euo pipefail
cd "$(dirname "$0")"

APP="MacComputerUse.app"
ID="com.modestnerd.mac-computer-use"
EXEC="mac-computer-use"
VERSION="0.5.0"
export MACOSX_DEPLOYMENT_TARGET="${MACOSX_DEPLOYMENT_TARGET:-13.0}"

rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS"

echo "Compiling Swift package…"
swift build -c release --product "$EXEC"
BIN_DIR="$(swift build -c release --show-bin-path)"
cp "$BIN_DIR/$EXEC" "$APP/Contents/MacOS/$EXEC"

cat > "$APP/Contents/Info.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>CFBundleName</key><string>mac-computer-use</string>
  <key>CFBundleDisplayName</key><string>Mac Computer Use</string>
  <key>CFBundleIdentifier</key><string>$ID</string>
  <key>CFBundleVersion</key><string>$VERSION</string>
  <key>CFBundleShortVersionString</key><string>$VERSION</string>
  <key>CFBundleExecutable</key><string>$EXEC</string>
  <key>CFBundlePackageType</key><string>APPL</string>
  <key>LSUIElement</key><true/>
  <key>LSMinimumSystemVersion</key><string>13.0</string>
  <key>NSAppleEventsUsageDescription</key><string>Control apps via Accessibility.</string>
</dict>
</plist>
PLIST

plutil -lint "$APP/Contents/Info.plist"

echo "Signing…"
codesign --force --deep --options runtime --sign - --identifier "$ID" "$APP" 2>/dev/null || \
codesign --force --deep --sign - --identifier "$ID" "$APP"

codesign --verify --deep --strict "$APP"
codesign -dv "$APP" 2>&1 | grep -E "Identifier|Signature" || true
echo "Built: $(pwd)/$APP/Contents/MacOS/$EXEC"
