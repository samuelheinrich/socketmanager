#!/bin/bash
set -euo pipefail
PROJECT_DIR="$(cd "$(dirname "$0")/../.." && pwd)"
APP_PATH="$PROJECT_DIR/dist/Socket Manager.app"
swift build --package-path "$PROJECT_DIR/macos" -c release
BIN_DIR="$(swift build --package-path "$PROJECT_DIR/macos" -c release --show-bin-path)"
mkdir -p "$APP_PATH/Contents/MacOS" "$APP_PATH/Contents/Resources"
cp "$BIN_DIR/SocketManager" "$APP_PATH/Contents/MacOS/SocketManager"
cp "$PROJECT_DIR/macos/Resources/Info.plist" "$APP_PATH/Contents/Info.plist"
ICON_DIR="$(mktemp -d)"
trap 'rm -rf "$ICON_DIR"' EXIT
"$BIN_DIR/SocketManager" --export-icon "$ICON_DIR"
iconutil --convert icns "$ICON_DIR/AppIcon.iconset" --output "$APP_PATH/Contents/Resources/AppIcon.icns"
cp "$ICON_DIR/AppIcon.iconset/icon_512x512.png" "$PROJECT_DIR/dist/socketmanager-logo.png"
/usr/bin/plutil -lint "$APP_PATH/Contents/Info.plist"
# Ad-hoc signing for local use. Set SIGNING_IDENTITY to a Developer ID certificate for distribution.
/usr/bin/codesign --force --options runtime --sign "${SIGNING_IDENTITY:--}" "$APP_PATH"
/usr/bin/codesign --verify --strict "$APP_PATH"
printf 'App gebaut: %s\n' "$APP_PATH"
