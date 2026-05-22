# Research: ohscrcpy CLI

**Date**: 2026-05-21 | **Branch**: `001-ohscrcpy-cli`

---

## 1. VideoToolbox H.264 解码（macOS）

**Decision**: 使用 Rust `unsafe` FFI 直接调用 `VideoToolbox.framework`，通过 `VTDecompressionSession` 解码。

**Rationale**:
- 现有 Flutter 客户端（`macos/Runner/VideoDecoderPlugin.swift`）已验证 VideoToolbox + `CVPixelBuffer` 路径可行
- Rust crate `videotoolbox-rs`（或自定义 bindgen FFI）能调用相同 C API
- 输出 `kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange`（NV12）后转 I420 供 SDL2 渲染

**流程**:
1. 收到协议 0x02 包 → 提取 SPS（`spsLen + sps`）、PPS（`ppsLen + pps`）
2. `CMVideoFormatDescriptionCreateFromH264ParameterSets` 构造 `CMFormatDescription`
3. `VTDecompressionSessionCreate` 创建解码 session（每次重连重建）
4. 收到 0x03 包 → Annex-B NAL → 转 AVCC（替换 start code 为 4B 长度）
5. 包成 `CMBlockBuffer` → `CMSampleBuffer` → `VTDecompressionSessionDecodeFrame`
6. 回调中取 `CVPixelBuffer`，NV12→I420 软转换，推送渲染队列

**Alternatives considered**:
- FFmpeg（`libavcodec`）: 可行但需静态链接庞大库，二进制体积 +30MB
- `media-kit` / Dart FFI: 仅适用于 Flutter 环境
- VideoToolbox `AVSampleBufferDisplayLayer`: 与 SDL2 窗口不兼容

---

## 2. SDL2 窗口渲染

**Decision**: `sdl2` crate 0.36+，使用 `SDL_Renderer` + `SDL_PIXELFORMAT_IYUV` 纹理。

**Rationale**:
- SDL2 在 macOS 上原生支持 Metal 渲染后端（SDL2 2.0.18+）
- IYUV（= I420）格式可直接通过 `SDL_UpdateYUVTexture` 上传，避免 CPU 色彩空间转换
- 鼠标/键盘事件由 SDL2 事件循环统一处理，简化架构

**事件循环设计**:
```
主线程: SDL2 event loop
  ├── MouseButtonDown/Up/Motion → 发送到 control_tx channel
  ├── WindowResized → 更新缩放比
  └── Quit → 触发 shutdown token

解码线程: VideoToolbox 回调 → 帧推送到 frame_tx channel
渲染线程（主线程）: 从 frame_rx 取帧 → SDL_UpdateYUVTexture → SDL_RenderCopy
网络线程: tokio::task → TCP 读写
```

**Alternatives considered**:
- `winit` + `wgpu`: 更现代但渲染 YUV 需要额外 shader，工作量 3×
- `minifb`: 不支持 YUV 纹理
- Cocoa/NSWindow 直接: 需要 Objective-C 桥，跨平台性差

---

## 3. hdc 子进程交互

**Decision**: `tokio::process::Command` 调用系统 `hdc`，解析 stdout 文本。

**hdc 命令映射**:

| 操作 | 命令 |
|------|------|
| 列出设备 | `hdc list targets` |
| 安装 HAP | `hdc -t <sn> install -r <hap_path>` |
| 端口转发 | `hdc -t <sn> fport tcp:<pc_port> tcp:53535` |
| 查看转发规则 | `hdc fport ls` |
| 删除转发规则 | `hdc -t <sn> fport rm tcp:<pc_port>` |
| 查询包安装状态 | `hdc -t <sn> shell "bm dump -n com.ohos.scrcpy.server"` |

**端口分配策略**: 在 5000–5099 范围内找未被 `fport ls` 占用的端口，避免冲突。

**Alternatives considered**:
- `hdc` SDK/库: 不存在公开 Rust API
- `libusb` 直连 ADB 协议: HDC 协议私有，维护成本极高

---

## 4. 协议帧解码

**Decision**: 手写状态机解码器，基于 `tokio::io::AsyncReadExt`。

**帧格式**: `[type: u8×4][length: u32 BE][payload: length bytes]`

实际 type 使用第一个字节（0x01/0x02/0x03/0x10/0x20），后三字节为 0。

**状态机**:
```
HEADER(8B) → 解析 type + length → PAYLOAD(length B) → 分发 → HEADER
```

**Alternatives considered**:
- `bytes::Buf` + `codec` crate: 可行但增加依赖
- 直接 `read_exact` 顺序读: 与异步模型天然契合，采用此方案

---

## 5. HAP 版本检测

**Decision**: 通过 `hdc shell "bm dump -n com.ohos.scrcpy.server"` 输出中提取 `versionCode` 与内置版本比较。

**比较逻辑**: 若设备无该包（命令返回错误）或 `versionCode < BUNDLED_VERSION`，触发自动安装。

---

## 6. 端口转发冲突检测

**Decision**: 启动前解析 `hdc fport ls` 输出，若已有针对同一 serial 且目标端口为 53535 的规则，视为实例冲突，打印错误退出。

**fport ls 输出格式** (示例):
```
[Forward]:  localAbstract[xxxxx]   →   127.0.0.1:5001   /   tcp:53535
```
解析规则：按行查找含目标设备 serial 和 `tcp:53535` 的行。

---

## 7. 二进制发布

**Decision**: `cargo build --release --target aarch64-apple-darwin` + `cargo build --release --target x86_64-apple-darwin` → `lipo -create` 合并为 universal binary。

资产内嵌: `rust-embed` 宏在编译期将 `assets/scrcpy_server.hap` 打包进二进制，安装时写入临时文件再调用 `hdc install`。
