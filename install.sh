#!/bin/zsh
# Build Float and install it to ~/Applications. Pass --regular to show a Dock icon (for screenshots).
set -e
cd "$(dirname "$0")/Float"
# Build outside iCloud Drive: its extended attributes make codesign fail.
BUILD=~/Library/Caches/Float/build
xcodegen generate -q
xcodebuild -project Float.xcodeproj -scheme Float -configuration Release -derivedDataPath "$BUILD" -quiet build
pkill -x "Float" 2>/dev/null || true
rm -rf ~/Applications/"Hermes Quick.app"  # the app's old name
A=~/Applications/"Float.app"
mkdir -p ~/Applications && rm -rf "$A" && cp -R "$BUILD/Build/Products/Release/Float.app" "$A"
if [[ "$1" == "--regular" ]]; then /usr/libexec/PlistBuddy -c "Set :LSUIElement false" "$A/Contents/Info.plist"; codesign -f -s - "$A"; fi
/System/Library/Frameworks/CoreServices.framework/Frameworks/LaunchServices.framework/Support/lsregister -f "$A"
open "$A"
