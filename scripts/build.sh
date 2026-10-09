#!/bin/bash
set -euo pipefail
PROJECT_DIR="$(cd "$(dirname "$0")/.." && pwd)"
APP_DIR="$PROJECT_DIR/build/Herdr Pixel Dungeon.app"
mkdir -p "$APP_DIR/Contents/MacOS" "$APP_DIR/Contents/Resources"
xcrun swiftc -swift-version 5 -O -target "$(uname -m)-apple-macosx13.0" \
  "$PROJECT_DIR"/Sources/*.swift -o "$APP_DIR/Contents/MacOS/HerdrPixelDungeon" \
  -framework Cocoa -framework SwiftUI -framework SpriteKit
cp "$PROJECT_DIR/Resources/Info.plist" "$APP_DIR/Contents/Info.plist"
ditto "$PROJECT_DIR/Resources/Sprites" "$APP_DIR/Contents/Resources/Sprites"
ditto "$PROJECT_DIR/Resources/Licenses" "$APP_DIR/Contents/Resources/Licenses"
cp "$PROJECT_DIR/LICENSE" "$APP_DIR/Contents/Resources/Licenses/APP-MIT.txt"
cp "$PROJECT_DIR/NOTICE.md" "$APP_DIR/Contents/Resources/Licenses/NOTICE.md"
codesign --force --deep --sign - "$APP_DIR"
echo "Built: $APP_DIR"
