#!/bin/zsh
set -euo pipefail

ROOT_DIR="${0:A:h:h}"
PACKAGE_DIR="$ROOT_DIR/native"
APP_DIR="$ROOT_DIR/dist/native/ViewDeck.app"
CLI_PATH="$ROOT_DIR/dist/native/viewdeck"
CONTENTS_DIR="$APP_DIR/Contents"
MACOS_DIR="$CONTENTS_DIR/MacOS"
RESOURCES_DIR="$CONTENTS_DIR/Resources"
export DEVELOPER_DIR="${DEVELOPER_DIR:-/Applications/Xcode.app/Contents/Developer}"
export CLANG_MODULE_CACHE_PATH="/private/tmp/viewdeck-native-module-cache"
export SWIFTPM_MODULECACHE_OVERRIDE="$CLANG_MODULE_CACHE_PATH"
CACHE_DIR="/private/tmp/viewdeck-native-swift-cache"

mkdir -p "$CLANG_MODULE_CACHE_PATH" "$CACHE_DIR"
swift build --package-path "$PACKAGE_DIR" --configuration release --cache-path "$CACHE_DIR" --disable-sandbox
BIN_DIR="$(swift build --package-path "$PACKAGE_DIR" --configuration release --show-bin-path --cache-path "$CACHE_DIR" --disable-sandbox)"

mkdir -p "$MACOS_DIR" "$RESOURCES_DIR"
cp "$BIN_DIR/ViewDeckNative" "$MACOS_DIR/ViewDeckNative"
cp "$BIN_DIR/viewdeck" "$CLI_PATH"
chmod +x "$CLI_PATH"
cp "$PACKAGE_DIR/Resources/Info.plist" "$CONTENTS_DIR/Info.plist"
cp "$ROOT_DIR/buildResources/icon.icns" "$RESOURCES_DIR/ViewDeck.icns"
codesign --force --sign - "$CLI_PATH"
codesign --force --deep --sign - "$APP_DIR"

echo "$APP_DIR"
echo "$CLI_PATH"
