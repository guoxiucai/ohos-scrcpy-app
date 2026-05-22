#!/usr/bin/env bash
set -e

cd "$(dirname "$0")/.."

echo "构建 ohscrcpy CLI..."

if [[ ! -d "cli" ]]; then
  echo "错误：cli 目录不存在"
  exit 1
fi

cd cli

echo "==> 安装 Rust 目标（如未安装）..."
rustup target add aarch64-apple-darwin 2>/dev/null || true
rustup target add x86_64-apple-darwin 2>/dev/null || true

echo "==> 构建 aarch64 (Apple Silicon)..."
cargo build --release --target aarch64-apple-darwin

echo "==> 构建 x86_64 (Intel)..."
cargo build --release --target x86_64-apple-darwin

echo "==> 创建 Universal Binary..."
mkdir -p ../release
lipo -create \
  target/aarch64-apple-darwin/release/ohscrcpy \
  target/x86_64-apple-darwin/release/ohscrcpy \
  -output ../release/ohscrcpy-universal

echo "==> 创建架构独立的二进制..."
cp target/aarch64-apple-darwin/release/ohscrcpy ../release/ohscrcpy-aarch64-apple-darwin
cp target/x86_64-apple-darwin/release/ohscrcpy ../release/ohscrcpy-x86_64-apple-darwin

echo ""
echo "✅ 构建完成！产物位于 release/ 目录"
echo "   - ohscrcpy-universal      (通用二进制，支持 Apple Silicon 和 Intel)"
echo "   - ohscrcpy-aarch64-apple-darwin  (Apple Silicon 专用)"
echo "   - ohscrcpy-x86_64-apple-darwin   (Intel 专用)"
echo ""
echo "上传到 GitHub Releases 后，用户可通过以下命令安装："
echo "  curl -sSL https://raw.githubusercontent.com/robin8yeung/ohscrcpy-cli/main/scripts/install.sh | sh"
