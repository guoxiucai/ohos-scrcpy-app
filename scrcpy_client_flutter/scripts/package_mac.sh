#!/usr/bin/env bash
# 鸿镜 macOS 打包脚本：build → codesign → DMG → DMG codesign [→ 公证 → staple]
#
# 用法：
#   ./scripts/package_mac.sh          仅构建并签名 DMG，不公证
#   ./scripts/package_mac.sh nota     构建、签名、公证、staple，输出公证后的 DMG
#
# 必需环境变量（始终）：
#   SIGN_IDENTITY           Developer ID Application 签名身份
#
# 额外必需环境变量（nota 模式）：
#   APPLE_ID                Apple ID 邮箱
#   APPLE_TEAM_ID           开发者 Team ID
#   APPLE_APP_PASSWORD      Apple ID 应用专用密码（appleid.apple.com 生成）
#
# 可选环境变量：
#   MAC_CERT_P12_BASE64 / MAC_CERT_PASSWORD   CI：从 base64 还原证书到临时 keychain
set -euo pipefail
cd "$(dirname "$0")/.."

NOTA_MODE=false
if [[ "${1:-}" == "nota" ]]; then
  NOTA_MODE=true
fi

# 校验必需环境变量
check_var() {
  local name="$1"
  local val="${!name:-}"
  if [[ -z "$val" ]]; then
    echo "错误：环境变量 $name 未设置或为空"
    exit 1
  fi
}

check_var SIGN_IDENTITY
if $NOTA_MODE; then
  check_var APPLE_ID
  check_var APPLE_TEAM_ID
  check_var APPLE_APP_PASSWORD
fi
APP_DISPLAY="鸿镜"
PRODUCT="鸿镜.app"
ENTITLEMENTS="macos/Runner/Release.entitlements"
VERSION="$(grep -E '^version:' pubspec.yaml | awk '{print $2}' | cut -d+ -f1)"
[[ -n "$VERSION" ]] || { echo "无法解析 pubspec.yaml version"; exit 1; }
TOTAL_STEPS=4; $NOTA_MODE && TOTAL_STEPS=6
echo "版本: $VERSION  签名: $SIGN_IDENTITY  公证: $NOTA_MODE"

echo "==> [1/${TOTAL_STEPS}] 生成图标 + flutter build"
bash scripts/gen_icons.sh
flutter build macos --release

APP="build/macos/Build/Products/Release/${PRODUCT}"
[[ -d "$APP" ]] || { echo "构建产物不存在: $APP"; exit 1; }
OUT="build/dist"; mkdir -p "$OUT"
DMG="$OUT/HongJing-${VERSION}.dmg"
rm -f "$DMG"

# 内嵌 hdc 及其依赖库到 .app/Contents/Resources/
HDC_SRC="bundled_tools/hdc"
if [[ -f "$HDC_SRC" ]]; then
  cp "$HDC_SRC" "$APP/Contents/Resources/hdc"
  chmod +x "$APP/Contents/Resources/hdc"
  echo "  [bundled] hdc 已拷入 Resources/"
  # hdc 依赖 libusb_shared.dylib（通过 @rpath → @loader_path/.）
  for dep in bundled_tools/libusb_shared.dylib; do
    [[ -f "$dep" ]] && cp "$dep" "$APP/Contents/Resources/" && echo "  [bundled] $(basename "$dep") 已拷入 Resources/"
  done
else
  echo "  [warn] bundled_tools/hdc 不存在，跳过内嵌 hdc"
fi

# CI: 从 base64 还原证书到临时 keychain
if [[ -n "${MAC_CERT_P12_BASE64:-}" ]]; then
  echo "  [CI] 创建临时 keychain 并导入证书"
  TMP_KEY="${RUNNER_TEMP:-/tmp}/build.keychain-db"
  KEY_PWD="$(uuidgen)"
  security create-keychain -p "$KEY_PWD" "$TMP_KEY"
  security set-keychain-settings -lut 21600 "$TMP_KEY"
  security unlock-keychain -p "$KEY_PWD" "$TMP_KEY"
  P12="${RUNNER_TEMP:-/tmp}/cert.p12"
  echo "$MAC_CERT_P12_BASE64" | base64 -D > "$P12"
  security import "$P12" -P "${MAC_CERT_PASSWORD:-}" -A -t cert -f pkcs12 -k "$TMP_KEY"
  security list-keychain -d user -s "$TMP_KEY" $(security list-keychain -d user | sed -e 's/"//g')
  security set-key-partition-list -S apple-tool:,apple: -s -k "$KEY_PWD" "$TMP_KEY" >/dev/null
fi

echo "==> [2/${TOTAL_STEPS}] inside-out codesign"
# 先签嵌套 framework / dylib (不带 entitlements)，最后签 .app (带 entitlements)。
# 全程不用 --deep —— --deep 会把外层 entitlements 错误传播到嵌套 framework，
# hardened runtime 启动时被 AMFI 拒绝即闪退。
find "$APP/Contents/Frameworks" -type d -name "*.framework" -prune -print0 2>/dev/null \
  | while IFS= read -r -d '' fw; do
      codesign --force --options=runtime --timestamp --sign "$SIGN_IDENTITY" "$fw"
    done
find "$APP/Contents/Frameworks" -type f -name "*.dylib" -print0 2>/dev/null \
  | while IFS= read -r -d '' dy; do
      codesign --force --options=runtime --timestamp --sign "$SIGN_IDENTITY" "$dy"
    done
# 签名内嵌 hdc 及其依赖库（需在签 .app 之前）
if [[ -f "$APP/Contents/Resources/hdc" ]]; then
  for f in "$APP/Contents/Resources/libusb_shared.dylib" "$APP/Contents/Resources/hdc"; do
    [[ -f "$f" ]] && codesign --force --options=runtime --timestamp --sign "$SIGN_IDENTITY" "$f"
  done
fi
codesign --force --options=runtime --timestamp \
  --entitlements "$ENTITLEMENTS" --sign "$SIGN_IDENTITY" "$APP"
codesign --verify --strict --verbose=2 "$APP"

echo "==> [3/${TOTAL_STEPS}] 创建 DMG"
command -v create-dmg >/dev/null 2>&1 || { echo "请先安装：brew install create-dmg"; exit 1; }
create-dmg \
  --volname "$APP_DISPLAY" \
  --window-size 540 360 --icon-size 96 \
  --app-drop-link 380 180 \
  --icon "$PRODUCT" 160 180 \
  "$DMG" "$APP"

echo "==> [4/${TOTAL_STEPS}] DMG 签名"
codesign --force --sign "$SIGN_IDENTITY" --timestamp "$DMG"
codesign --verify --verbose=2 "$DMG"

if $NOTA_MODE; then
  echo "==> [5/${TOTAL_STEPS}] 提交公证（notarytool submit，同步等待结果）"
  xcrun notarytool submit "$DMG" \
    --apple-id "$APPLE_ID" \
    --team-id "$APPLE_TEAM_ID" \
    --password "$APPLE_APP_PASSWORD" \
    --wait

  echo "==> [6/${TOTAL_STEPS}] staple 公证票据到 DMG"
  xcrun stapler staple "$DMG"
  xcrun stapler validate "$DMG"
fi

echo
echo "完成: $DMG"
