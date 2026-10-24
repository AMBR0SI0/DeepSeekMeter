#!/bin/bash
# Builds DeepSeekMeter and wraps the binary in a .app bundle.
# Usage: ./build.sh [--native]
#   --native  build only for this machine instead of a universal binary
set -euo pipefail

cd "$(dirname "$0")"

APP="DeepSeekMeter.app"
BIN=".build/release/DeepSeekMeter"

if [[ "${1:-}" == "--native" ]]; then
    swift build -c release
else
    # One bundle that runs on Apple silicon and Intel.
    swift build -c release --arch arm64 --arch x86_64
fi

rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"

cp "$BIN" "$APP/Contents/MacOS/DeepSeekMeter"
cp Resources/AppIcon.icns "$APP/Contents/Resources/AppIcon.icns"

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
    <key>CFBundleIconFile</key>
    <string>AppIcon</string>
    <key>CFBundlePackageType</key>
    <string>APPL</string>
    <key>CFBundleShortVersionString</key>
    <string>1.0.0</string>
    <key>CFBundleVersion</key>
    <string>1</string>
    <key>LSMinimumSystemVersion</key>
    <string>14.0</string>
    <key>LSUIElement</key>
    <true/>
    <key>NSHighResolutionCapable</key>
    <true/>
</dict>
</plist>
PLIST

codesign --force --deep --sign - "$APP" 2>/dev/null || true

echo "built: $(pwd)/$APP"
