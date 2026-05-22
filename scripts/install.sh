#!/usr/bin/env bash
set -e

BINARY_NAME="ohscrcpy"
INSTALL_DIR="/usr/local/bin"
GITHUB_REPO="robin8yeung/ohscrcpy-cli"

detect_arch() {
  if [[ "$(uname -m)" == "arm64" ]]; then
    echo "aarch64-apple-darwin"
  else
    echo "x86_64-apple-darwin"
  fi
}

check_command() {
  if ! command -v "$1" &>/dev/null; then
    echo "错误：未找到 $1，请先安装"
    exit 1
  fi
}

check_command curl
check_command sudo

echo "检测系统架构..."
ARCH=$(detect_arch)
echo "架构: $ARCH"

echo "获取最新版本..."
LATEST_TAG=$(curl -s https://api.github.com/repos/$GITHUB_REPO/releases/latest | grep '"tag_name"' | sed -E 's/.*"([^"]+)".*/\1/')

if [[ -z "$LATEST_TAG" ]]; then
  echo "错误：无法获取最新版本，请检查网络连接"
  exit 1
fi

echo "最新版本: $LATEST_TAG"
echo "正在下载 $BINARY_NAME..."

DOWNLOAD_URL="https://github.com/$GITHUB_REPO/releases/download/$LATEST_TAG/ohscrcpy-$ARCH"
curl -sSL "$DOWNLOAD_URL" -o /tmp/$BINARY_NAME

if [[ ! -f /tmp/$BINARY_NAME ]]; then
  echo "错误：下载失败"
  exit 1
fi

echo "验证二进制文件..."
chmod +x /tmp/$BINARY_NAME

echo "安装到 $INSTALL_DIR..."
sudo mv /tmp/$BINARY_NAME "$INSTALL_DIR/$BINARY_NAME"

if [[ ! -f "$INSTALL_DIR/$BINARY_NAME" ]]; then
  echo "错误：安装失败"
  exit 1
fi

echo ""
echo "✅ $BINARY_NAME v$LATEST_TAG 安装成功！"
echo ""
echo "使用方法:"
echo "  ohscrcpy --help          # 查看帮助"
echo "  ohscrcpy                 # 连接唯一设备"
echo "  ohscrcpy -s <serial>     # 连接指定设备"
echo ""
echo "需要先安装 hdc 工具（DevEco Studio 附带）"
echo "  export PATH=\"\$PATH:/Applications/DevEco-Studio.app/Contents/tools/hdc/bin\""
