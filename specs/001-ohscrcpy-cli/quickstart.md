# Quickstart: ohscrcpy CLI 开发环境

**Date**: 2026-05-21 | **Branch**: `001-ohscrcpy-cli`

---

## 前置要求

- macOS 11+（Apple Silicon 或 Intel）
- Rust stable toolchain（`rustup`）
- `hdc` CLI 已安装（DevEco Studio 附带，或手动加入 PATH）
- SDL2 库（`brew install sdl2`）
- Xcode Command Line Tools（`xcode-select --install`）

---

## 安装 Rust toolchain

```bash
# 安装 rustup（如未安装）
curl --proto '=https' --tlsv1.2 -sSf https://sh.rustup.rs | sh

# 添加 Apple Silicon + Intel 目标（用于 universal binary）
rustup target add aarch64-apple-darwin
rustup target add x86_64-apple-darwin
```

---

## 安装 SDL2

```bash
brew install sdl2
# 确认头文件路径（bindgen 需要）
ls /opt/homebrew/include/SDL2/SDL.h  # Apple Silicon
ls /usr/local/include/SDL2/SDL.h     # Intel
```

---

## 首次构建

```bash
cd cli

# 调试构建（快，适合开发）
cargo build

# 运行（需要设备连接）
cargo run -- -v

# 指定设备
cargo run -- -s <serial> -v

# 发布构建（Apple Silicon）
cargo build --release --target aarch64-apple-darwin

# Universal binary
cargo build --release --target aarch64-apple-darwin
cargo build --release --target x86_64-apple-darwin
lipo -create \
  target/aarch64-apple-darwin/release/ohscrcpy \
  target/x86_64-apple-darwin/release/ohscrcpy \
  -output ohscrcpy
```

---

## 运行测试

```bash
cd cli

# 全部单元测试
cargo test

# 仅协议解码测试
cargo test protocol

# 输出详细日志
cargo test -- --nocapture
```

---

## 目录结构说明

```
cli/
├── Cargo.toml         # 依赖声明
├── build.rs           # bindgen 生成 VideoToolbox FFI（首次构建自动运行）
├── assets/
│   └── scrcpy_server.hap  # 需要从 scrcpy_server 构建产物复制到此处
└── src/
    ├── main.rs        # 从这里开始阅读
    ├── args.rs        # 所有 CLI 参数定义
    ├── hdc.rs         # hdc 命令封装
    ├── server.rs      # HAP 安装逻辑
    ├── connection.rs  # 协议帧读写
    ├── control.rs     # 鼠标 → 触控序列化
    ├── decoder/vtb.rs # VideoToolbox 解码器
    └── renderer/sdl.rs# SDL2 渲染
```

---

## 更新内嵌 HAP

```bash
# 1. 构建服务端 HAP（在项目根目录执行）
cd scrcpy_server && \
  /Applications/DevEco-Studio.app/Contents/tools/node/bin/node \
  /Applications/DevEco-Studio.app/Contents/tools/hvigor/bin/hvigorw.js \
  clean --mode module -p product=default assembleHap \
  --analyze=normal --parallel --incremental --daemon

# 2. 复制产物到 cli/assets/
cp scrcpy_server/entry/build/default/outputs/default/entry-default-signed.hap \
   cli/assets/scrcpy_server.hap

# 3. 重新构建 CLI（rust-embed 会自动内嵌新 HAP）
cd cli && cargo build
```

---

## 常见问题

**Q: 构建时找不到 VideoToolbox headers**
```bash
# 确认 Xcode CLT 已安装
xcode-select -p
# 输出应为 /Applications/Xcode.app/Contents/Developer 或 /Library/Developer/CommandLineTools
```

**Q: SDL2 链接失败**
```bash
# 在 Cargo.toml 中确认 features = ["bundled"] 或手动设置
export LIBRARY_PATH="$(brew --prefix sdl2)/lib:$LIBRARY_PATH"
```

**Q: hdc 命令找不到**
```bash
# DevEco Studio 安装后通常在
export PATH="$PATH:/Applications/DevEco-Studio.app/Contents/tools/hdc/bin"
```
