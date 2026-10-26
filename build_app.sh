#!/bin/bash
# Builds NotchIsland.app (a menu-bar-only app with no Dock icon).
set -euo pipefail

swift build -c release

APP="NotchIsland.app"
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS"
cp .build/release/NotchIsland "$APP/Contents/MacOS/NotchIsland"

cat > "$APP/Contents/Info.plist" <<'PLIST'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>CFBundleName</key><string>Notch Island</string>
    <key>CFBundleIdentifier</key><string>com.example.notchisland</string>
    <key>CFBundleExecutable</key><string>NotchIsland</string>
    <key>CFBundlePackageType</key><string>APPL</string>
    <key>CFBundleShortVersionString</key><string>1.1</string>
    <key>LSMinimumSystemVersion</key><string>13.0</string>
    <key>LSUIElement</key><true/>
    <key>NSHighResolutionCapable</key><true/>
    <key>NSAppleEventsUsageDescription</key>
    <string>Notch Island shows what is playing in Spotify and Music, lets you control playback, and toggles dark mode and volume from Quick Controls.</string>
    <key>NSCalendarsUsageDescription</key>
    <string>Notch Island shows your upcoming calendar events.</string>
    <key>NSCalendarsFullAccessUsageDescription</key>
    <string>Notch Island shows your upcoming calendar events.</string>
</dict>
</plist>
PLIST

codesign --force --sign - "$APP" >/dev/null 2>&1 || true
echo "Built $APP — run it with: open $APP"
