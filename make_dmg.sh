#!/bin/sh
# Builds NotchIsland.app and packs it into NotchIsland.dmg (drag the app onto Applications).
set -e
cd "$(dirname "$0")"
./build_app.sh
rm -rf dmg_stage NotchIsland.dmg
mkdir dmg_stage
cp -R NotchIsland.app dmg_stage/
ln -s /Applications dmg_stage/Applications
hdiutil create -volname "Notch Island" -srcfolder dmg_stage -ov -format UDZO NotchIsland.dmg
rm -rf dmg_stage
echo ""
echo "Done: NotchIsland.dmg"
echo "SHA-256 (needed for the Homebrew cask):"
shasum -a 256 NotchIsland.dmg
