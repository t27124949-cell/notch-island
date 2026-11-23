#!/bin/bash
# Builds NotchIsland.app (a menu-bar-only app with no Dock icon).
set -euo pipefail

swift build -c release

APP="NotchIsland.app"
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"

# Build the icon with Apple's own tools so macOS always accepts it
ICONSET="$(mktemp -d)/AppIcon.iconset"
mkdir -p "$ICONSET"
for size in 16 32 128 256 512; do
    sips -z $size $size Resources/AppIcon.png --out "$ICONSET/icon_${size}x${size}.png" >/dev/null
    double=$((size * 2))
    sips -z $double $double Resources/AppIcon.png --out "$ICONSET/icon_${size}x${size}@2x.png" >/dev/null
done
iconutil -c icns "$ICONSET" -o "$APP/Contents/Resources/AppIcon.icns"
cp .build/release/NotchIsland "$APP/Contents/MacOS/NotchIsland"

cat > "$APP/Contents/Info.plist" <<'PLIST'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>CFBundleName</key><string>Notch Island</string>
    <key>CFBundleIdentifier</key><string>io.github.t27124949-cell.notchisland</string>
    <key>CFBundleExecutable</key><string>NotchIsland</string>
    <key>CFBundleIconFile</key><string>AppIcon</string>
    <key>CFBundlePackageType</key><string>APPL</string>
    <key>CFBundleShortVersionString</key><string>1.2</string>
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

touch "$APP"
codesign --force --sign - "$APP" >/dev/null 2>&1 || true
echo "Built $APP — run it with: open $APP"
