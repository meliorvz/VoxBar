#!/bin/zsh
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "$0")/.." && pwd)"
APP_DIR="$ROOT_DIR/dist/VoxBar.app"
BUILD_DIR="$ROOT_DIR/.build/release"

cd "$ROOT_DIR"
swift build -c release

rm -rf "$ROOT_DIR/dist/ArticleTTSBar.app" "$APP_DIR"
mkdir -p "$APP_DIR/Contents/MacOS" "$APP_DIR/Contents/Resources"

cp "$BUILD_DIR/VoxBar" "$APP_DIR/Contents/MacOS/VoxBar"
cp "$ROOT_DIR/Support/Info.plist" "$APP_DIR/Contents/Info.plist"
if [ -d "$ROOT_DIR/Resources" ]; then
  ditto "$ROOT_DIR/Resources" "$APP_DIR/Contents/Resources"
fi
chmod +x "$APP_DIR/Contents/MacOS/VoxBar"

echo "Built $APP_DIR"
