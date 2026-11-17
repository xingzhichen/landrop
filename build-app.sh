#!/bin/bash
set -euo pipefail
ROOT="$(cd "$(dirname "$0")" && pwd)"
cd "$ROOT"
mkdir -p "$ROOT/.build/ModuleCache" "$ROOT/.tmp" "$ROOT/.build/swiftpm-cache"
export CLANG_MODULE_CACHE_PATH="$ROOT/.build/ModuleCache"
export SWIFT_MODULE_CACHE_PATH="$ROOT/.build/ModuleCache"
export TMPDIR="$ROOT/.tmp/"
swift build --disable-sandbox --cache-path "$ROOT/.build/swiftpm-cache" -c release
APP="$ROOT/dist/LanDrop.app"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp "$ROOT/.build/release/LanDrop" "$APP/Contents/MacOS/LanDrop"
cp "$ROOT/Resources/Info.plist" "$APP/Contents/Info.plist"
cp "$ROOT/Resources/LanDrop.icns" "$APP/Contents/Resources/LanDrop.icns"
chmod +x "$APP/Contents/MacOS/LanDrop"
# Sign locally so macOS recognizes a coherent application bundle.
codesign --force --sign - "$APP" >/dev/null
echo "Built $APP"
