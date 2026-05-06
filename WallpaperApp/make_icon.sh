#!/bin/bash
set -e

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
ICON_DIR="$SCRIPT_DIR/Icon.iconset"
GENERATOR="$SCRIPT_DIR/generate_icon.swift"
TEMP_1024="$SCRIPT_DIR/.icon_1024.png"

rm -rf "$ICON_DIR" "$TEMP_1024"
mkdir -p "$ICON_DIR"

# Generate 1024x1024 PNG
swift "$GENERATOR" "$TEMP_1024" 2>/dev/null

# Resize to all required sizes
sips -z 16 16   "$TEMP_1024" --out "$ICON_DIR/icon_16x16.png"      &>/dev/null
sips -z 32 32   "$TEMP_1024" --out "$ICON_DIR/icon_16x16@2x.png"   &>/dev/null
sips -z 32 32   "$TEMP_1024" --out "$ICON_DIR/icon_32x32.png"      &>/dev/null
sips -z 64 64   "$TEMP_1024" --out "$ICON_DIR/icon_32x32@2x.png"   &>/dev/null
sips -z 128 128 "$TEMP_1024" --out "$ICON_DIR/icon_128x128.png"    &>/dev/null
sips -z 256 256 "$TEMP_1024" --out "$ICON_DIR/icon_128x128@2x.png" &>/dev/null
sips -z 256 256 "$TEMP_1024" --out "$ICON_DIR/icon_256x256.png"    &>/dev/null
sips -z 512 512 "$TEMP_1024" --out "$ICON_DIR/icon_256x256@2x.png" &>/dev/null
sips -z 512 512 "$TEMP_1024" --out "$ICON_DIR/icon_512x512.png"    &>/dev/null
cp "$TEMP_1024" "$ICON_DIR/icon_512x512@2x.png"

rm -f "$TEMP_1024"

# Create .icns
ICNS_PATH="$SCRIPT_DIR/AppIcon.icns"
iconutil -c icns "$ICON_DIR" -o "$ICNS_PATH"

rm -rf "$ICON_DIR"

echo "Done: $ICNS_PATH"
