#!/usr/bin/env bash
# 从 branding/icon-1024.png 派生 macOS / Windows 应用图标。
# - macOS: 写入 macos/Runner/Assets.xcassets/AppIcon.appiconset/app_icon_*.png
# - Windows: 用 ImageMagick 生成 windows/runner/resources/app_icon.ico
# 依赖：sips（macOS 自带）、ImageMagick（brew install imagemagick / choco install imagemagick）
set -euo pipefail
cd "$(dirname "$0")/.."

SRC="branding/icon-1024.png"
[[ -f "$SRC" ]] || { echo "缺少 $SRC"; exit 1; }

# --- macOS PNG 集 ---
ICONSET_DIR="macos/Runner/Assets.xcassets/AppIcon.appiconset"
for s in 16 32 64 128 256 512 1024; do
  if command -v sips >/dev/null 2>&1; then
    sips -z $s $s "$SRC" --out "$ICONSET_DIR/app_icon_${s}.png" >/dev/null
  elif command -v magick >/dev/null 2>&1; then
    magick "$SRC" -resize ${s}x${s} "$ICONSET_DIR/app_icon_${s}.png"
  else
    echo "需要 sips 或 ImageMagick"; exit 1
  fi
done
echo "macOS app_icon_*.png 已更新"

# --- Windows .ico ---
if command -v magick >/dev/null 2>&1; then
  mkdir -p windows/runner/resources
  magick "$SRC" -define icon:auto-resize=256,128,64,48,32,16 \
    windows/runner/resources/app_icon.ico
  echo "Windows app_icon.ico 已更新"
else
  echo "未检测到 ImageMagick，跳过 .ico 生成（Windows 端可在 Windows 打包机上重跑此脚本）"
fi
