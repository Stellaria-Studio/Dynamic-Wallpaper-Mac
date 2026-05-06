#!/bin/bash
set -e

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
PARENT_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"
APP_NAME="WallpaperPlayer"

echo "🔧 Building $APP_NAME helper..."

APP_DIR="$PARENT_DIR/$APP_NAME.app"
MACOS_DIR="$APP_DIR/Contents/MacOS"

rm -rf "$APP_DIR"
mkdir -p "$MACOS_DIR"

cp "$SCRIPT_DIR/Info.plist" "$APP_DIR/Contents/"

swiftc \
    -o "$MACOS_DIR/$APP_NAME" \
    "$SCRIPT_DIR/main.swift" \
    -framework Cocoa \
    -framework AVFoundation \
    -O \
    -whole-module-optimization

echo "✅ Helper built: $APP_DIR"
