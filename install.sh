#!/bin/zsh
# Build Float and install it to ~/Applications. Pass --regular to show a Dock icon (for screenshots).
set -e
cd "$(dirname "$0")/Float"
if ! xcodebuild -version >/dev/null 2>&1; then
  echo "Float needs Xcode 26 or later to build. Install it from the App Store, open it once, then run this again." >&2
  echo "(Prefer not to install Xcode? Download the prebuilt Float.zip from the Releases page instead.)" >&2
  exit 1
fi
if ! command -v xcodegen >/dev/null 2>&1; then
  command -v brew >/dev/null 2>&1 || { echo "Float needs XcodeGen to build. Install Homebrew (https://brew.sh), then run this again." >&2; exit 1; }
  echo "Installing XcodeGen with Homebrew…"; brew install xcodegen
fi
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
