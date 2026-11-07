#!/bin/bash
set -euo pipefail
PROJECT_ROOT="$(cd "$(dirname "$0")/.." && pwd)"
cd "$PROJECT_ROOT"
RELEASE_DIR="$PROJECT_ROOT/releases/1.1.0"
STAGE="$PROJECT_ROOT/.build/dmg-stage"
APP="$RELEASE_DIR/Маршруты доставки.app"
DMG="$RELEASE_DIR/ANODHAS-Delivery-Routes-1.1.0.dmg"
test -d "$APP"
mkdir -p "$STAGE"
ditto "$APP" "$STAGE/Маршруты доставки.app"
if [ ! -L "$STAGE/Applications" ]; then ln -s /Applications "$STAGE/Applications"; fi
cp README.md "$STAGE/Инструкция.md"
codesign --verify --deep --strict "$STAGE/Маршруты доставки.app"
hdiutil create -volname 'ANODHAS Маршруты доставки' -srcfolder "$STAGE" -format UDZO -ov "$DMG"
hdiutil verify "$DMG"
(cd "$RELEASE_DIR" && shasum -a 256 ANODHAS-Delivery-Routes-1.1.0.dmg > SHA256SUMS.txt)
echo "$DMG"
