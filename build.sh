#!/bin/bash
# Builds build/Drafty.app (ad-hoc signed). Move it to /Applications if you want "Open at login".
set -euo pipefail
cd "$(dirname "$0")"

swift build -c release
APP=build/Drafty.app
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS"
cp .build/release/Drafty "$APP/Contents/MacOS/"
cat > "$APP/Contents/Info.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>CFBundleExecutable</key><string>Drafty</string>
    <key>CFBundleIdentifier</key><string>com.einar.drafty</string>
    <key>CFBundleName</key><string>Drafty</string>
    <key>CFBundlePackageType</key><string>APPL</string>
    <key>CFBundleShortVersionString</key><string>1.0</string>
    <key>CFBundleVersion</key><string>1</string>
    <key>LSMinimumSystemVersion</key><string>14.0</string>
    <key>LSUIElement</key><true/>
    <key>CFBundleURLTypes</key>
    <array><dict>
        <key>CFBundleURLName</key><string>com.einar.drafty</string>
        <key>CFBundleURLSchemes</key><array><string>drafty</string></array>
    </dict></array>
    <key>NSAppleEventsUsageDescription</key><string>Drafty opens Claude Code in a new terminal window.</string>
</dict>
</plist>
PLIST
codesign --force --sign - "$APP"
echo "Built $APP"
