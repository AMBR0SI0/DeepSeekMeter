#!/bin/bash
# Builds DeepSeekMeter and wraps the binary in a .app bundle.
set -euo pipefail

cd "$(dirname "$0")"

APP="DeepSeekMeter.app"
BIN=".build/release/DeepSeekMeter"

swift build -c release

rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"

cp "$BIN" "$APP/Contents/MacOS/DeepSeekMeter"

cat > "$APP/Contents/Info.plist" <<'PLIST'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>CFBundleName</key>
    <string>DeepSeek Meter</string>
    <key>CFBundleDisplayName</key>
    <string>DeepSeek Meter</string>
    <key>CFBundleIdentifier</key>
    <string>com.deepak.deepseekmeter</string>
    <key>CFBundleExecutable</key>
    <string>DeepSeekMeter</string>
    <key>CFBundlePackageType</key>
    <string>APPL</string>
    <key>CFBundleShortVersionString</key>
    <string>1.0</string>
    <key>CFBundleVersion</key>
    <string>1</string>
    <key>LSMinimumSystemVersion</key>
    <string>14.0</string>
    <key>LSUIElement</key>
    <true/>
    <key>NSHighResolutionCapable</key>
    <true/>
    <key>NSSupportsAutomaticGraphicsSwitching</key>
    <true/>
</dict>
</plist>
PLIST

codesign --force --deep --sign - "$APP" 2>/dev/null || true

echo "built: $(pwd)/$APP"
