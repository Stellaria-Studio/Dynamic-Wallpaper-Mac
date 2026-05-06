#!/bin/bash
set -e

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
SOURCE="$SCRIPT_DIR/main.swift"
PLIST="$SCRIPT_DIR/Info.plist"
ICGEN="$SCRIPT_DIR/generate_icon.swift"
APP_NAME="VideoWallpaper"
PARENT_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"

echo "🔨 Building $APP_NAME..."

# Step 1: Build WallpaperPlayer helper
echo "  Building WallpaperPlayer helper..."
bash "$SCRIPT_DIR/../WallpaperPlayer/build.sh" 2>&1 | sed 's/^/  /'

# Generate icon
ICNS="$SCRIPT_DIR/AppIcon.icns"
if [ ! -f "$ICNS" ]; then
    echo "  Generating app icon..."
    bash "$SCRIPT_DIR/make_icon.sh"
fi

# Create .app bundle in parent directory
APP_DIR="$PARENT_DIR/$APP_NAME.app"
MACOS_DIR="$APP_DIR/Contents/MacOS"
RES_DIR="$APP_DIR/Contents/Resources"

rm -rf "$APP_DIR"
mkdir -p "$MACOS_DIR" "$RES_DIR"

# Copy Info.plist
cp "$PLIST" "$APP_DIR/Contents/"

# Copy icon
cp "$ICNS" "$RES_DIR/"

# Copy WallpaperPlayer helper into bundle
HELPER_SRC="$PARENT_DIR/WallpaperPlayer.app"
if [ -d "$HELPER_SRC" ]; then
    echo "  Bundling WallpaperPlayer helper..."
    cp -R "$HELPER_SRC" "$RES_DIR/"
fi

# Collect all Swift source files (exclude standalone tools)
SOURCES=()
for f in "$SCRIPT_DIR"/*.swift; do
    case "$(basename "$f")" in
        generate_icon.swift) ;;  # skip standalone icon generator
        *) SOURCES+=("$f") ;;
    esac
done

# Compile
swiftc \
    -o "$MACOS_DIR/$APP_NAME" \
    "${SOURCES[@]}" \
    -framework Cocoa \
    -framework AVFoundation \
    -framework AVKit \
    -framework IOKit \
    -framework ScreenCaptureKit \
    -O \
    -whole-module-optimization

echo ""
echo "✅ 构建成功: $APP_DIR"
echo ""
echo "📦 $APP_DIR"
echo ""
echo "使用方法:"
echo "  1. 双击打开 $APP_NAME.app"
echo "  2. 将视频放入旁边「壁纸素材」文件夹"
echo "  3. 应用会自动检测并轮换播放"
echo ""
echo "项目结构:"
echo "  WallpaperApp/   — 源代码"
echo "  VideoWallpaper.app — 编译好的应用"
echo "  壁纸素材/       — 放入你的视频文件"
