#!/bin/bash
set -euo pipefail
PROJECT_ROOT="$(cd "$(dirname "$0")/.." && pwd)"
cd "$PROJECT_ROOT"
SDK_PATH="${FREIGHT_SDK:-/Library/Developer/CommandLineTools/SDKs/MacOSX26.5.sdk}"
BUILD_DIR="$PROJECT_ROOT/.build"
RELEASE_DIR="$PROJECT_ROOT/releases/1.0.0"
APP="$RELEASE_DIR/Маршруты доставки.app"
mkdir -p "$BUILD_DIR/module-cache" "$RELEASE_DIR" Verification
if [ ! -x Vendor/bin/vroom ]; then bash Scripts/build-solver.sh; fi
for ARCH in arm64 x86_64; do
  mkdir -p "$BUILD_DIR/$ARCH"
  xcrun swiftc -O -swift-version 5 -parse-as-library -sdk "$SDK_PATH" -target "$ARCH-apple-macos13.3" \
    -module-cache-path "$BUILD_DIR/module-cache" Sources/*.swift -o "$BUILD_DIR/$ARCH/FreightPlanner"
done
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources" "$APP/Contents/Helpers"
xcrun lipo -create "$BUILD_DIR/arm64/FreightPlanner" "$BUILD_DIR/x86_64/FreightPlanner" -output "$APP/Contents/MacOS/FreightPlanner"
cp Resources/Info.plist "$APP/Contents/Info.plist"
cp Vendor/bin/vroom "$APP/Contents/Helpers/vroom"
cp Vendor/THIRD_PARTY_NOTICES.txt "$APP/Contents/Resources/THIRD_PARTY_NOTICES.txt"
cp LICENSE "$APP/Contents/Resources/LICENSE.txt"
xcrun swift -sdk "$SDK_PATH" -module-cache-path "$BUILD_DIR/module-cache" Scripts/MakeIcon.swift "$BUILD_DIR/AppIcon.iconset"
iconutil -c icns "$BUILD_DIR/AppIcon.iconset" -o "$APP/Contents/Resources/AppIcon.icns"
SIGNER="${SIGN_IDENTITY:--}"
codesign --force --options runtime --sign "$SIGNER" --entitlements Resources/Solver.entitlements "$APP/Contents/Helpers/vroom"
codesign --force --options runtime --sign "$SIGNER" --entitlements Resources/App.entitlements "$APP"
codesign --verify --deep --strict "$APP"
plutil -lint "$APP/Contents/Info.plist"
xcrun lipo -archs "$APP/Contents/MacOS/FreightPlanner"
echo "$APP"
