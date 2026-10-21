#!/bin/zsh
# Build Float and package it as dist/Float.zip for a GitHub release. No Apple Developer account needed (ad-hoc signed).
set -e
cd "$(dirname "$0")/Float"
# Build outside iCloud Drive: its extended attributes make codesign fail.
BUILD=~/Library/Caches/Float/release-build
xcodegen generate -q
xcodebuild -project Float.xcodeproj -scheme Float -configuration Release -derivedDataPath "$BUILD" -quiet build
APP="$BUILD/Build/Products/Release/Float.app"
codesign --force --deep -s - "$APP"
mkdir -p ../dist && rm -f ../dist/Float.zip
ditto -c -k --keepParent "$APP" ../dist/Float.zip
VERSION=$(/usr/libexec/PlistBuddy -c "Print :CFBundleShortVersionString" "$APP/Contents/Info.plist")
echo "Built dist/Float.zip (version $VERSION)"
shasum -a 256 ../dist/Float.zip
