#!/bin/zsh
# Build Hermes Quick and install it to ~/Applications. Pass --regular to show a Dock icon (for screenshots).
set -e
cd "$(dirname "$0")/HermesQuick"
# Build outside iCloud Drive: its extended attributes make codesign fail.
BUILD=~/Library/Caches/HermesQuick/build
xcodegen generate -q
xcodebuild -project HermesQuick.xcodeproj -scheme HermesQuick -configuration Release -derivedDataPath "$BUILD" -quiet build
pkill -x "Hermes Quick" 2>/dev/null || true
A=~/Applications/"Hermes Quick.app"
mkdir -p ~/Applications && rm -rf "$A" && cp -R "$BUILD/Build/Products/Release/Hermes Quick.app" "$A"
if [[ "$1" == "--regular" ]]; then /usr/libexec/PlistBuddy -c "Set :LSUIElement false" "$A/Contents/Info.plist"; codesign -f -s - "$A"; fi
/System/Library/Frameworks/CoreServices.framework/Frameworks/LaunchServices.framework/Support/lsregister -f "$A"
open "$A"
