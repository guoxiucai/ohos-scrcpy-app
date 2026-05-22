# Implementation Plan: ohscrcpy CLI 远程控制工具

**Branch**: `001-ohscrcpy-cli` | **Date**: 2026-05-21 | **Spec**: [spec.md](./spec.md)

**Input**: Feature specification from `specs/001-ohscrcpy-cli/spec.md`

---

## Summary

构建一个名为 `ohscrcpy` 的 macOS CLI 工具，基于现有项目已验证的协议和架构（`scrcpy_client_flutter` + `scrcpy_server`），用 **Rust** 实现屏幕镜像与鼠标控制。工具自动检测并安装设备端服务（`com.ohos.scrcpy.server` HAP），通过 `hdc fport` 建立端口转发，解码 H.264 视频流并渲染到原生窗口，将鼠标事件转换为触控指令发送到设备，右键映射为返回键。

---

## Technical Context

**Language/Version**: Rust 1.75+ (stable toolchain via rustup)

**Primary Dependencies**:
- `clap 4.x` — scrcpy 风格 CLI 参数解析
- `tokio 1.x` — 异步运行时（TCP 连接、进程管理）
- `sdl2 0.36+` — 跨平台原生窗口 + YUV/RGB 纹理渲染
- `videotoolbox-rs` 或自定义 `unsafe` FFI — macOS H.264 硬件解码（VideoToolbox）
- `h264-reader 0.7+` — NAL unit 解析（Annex-B）
- `rust-embed 8.x` — 将 HAP 文件内嵌到二进制
- `byteorder 1.x` — 大端 4B 帧头解析
- `anyhow 1.x` — 错误传播
- `tracing + tracing-subscriber` — 结构化日志（`--verbose` 输出到 stderr）

**Storage**: N/A（无持久化存储，运行期间保留端口转发规则，退出时清理）

**Testing**: `cargo test`（单元测试）+ shell 脚本集成测试（需真实设备或 mock TCP server）

**Target Platform**: macOS 11+ (Apple Silicon aarch64 + Intel x86_64)；构建时产出 universal binary（`lipo`）

**Project Type**: CLI tool + native desktop window

**Performance Goals**:
- 首帧显示 ≤5s（服务端已安装场景）
- 渲染帧率 ≥54 fps（目标 60 fps 的 90%）
- 鼠标点击端到端延迟 ≤200ms

**Constraints**: 内存 ≤200 MB，CPU ≤80% 单核，退出时无残留进程或 fport 规则

**Scale/Scope**: 单设备单实例，USB 连接

---

## Constitution Check

*GATE: constitution.md 为空白模板，无强制门控。遵循 CLAUDE.md 全局规则。*

- [x] 无硬编码凭证
- [x] 错误处理使用 `anyhow`，stderr 输出，无静默吞错
- [x] 单一职责：每个模块文件 <400 行
- [x] 不引入运行期外部网络依赖（HAP 内嵌）

---

## Project Structure

### Documentation (this feature)

```text
specs/001-ohscrcpy-cli/
├── plan.md              # 本文件
├── research.md          # Phase 0 研究结论
├── data-model.md        # Phase 1 数据模型
├── quickstart.md        # Phase 1 开发快速上手
├── contracts/
│   └── cli-schema.md    # CLI 参数契约
└── tasks.md             # Phase 2 任务列表（/speckit-tasks 生成）
```

### Source Code (repository root)

```text
cli/
├── Cargo.toml           # workspace member
├── build.rs             # 生成 VideoToolbox FFI 绑定（bindgen）
├── assets/
│   └── scrcpy_server.hap  # 内嵌服务端 HAP（rust-embed）
├── src/
│   ├── main.rs          # 入口：参数解析、设备选择、顶层流程编排
│   ├── args.rs          # clap 参数定义
│   ├── hdc.rs           # hdc 子进程封装（list/fport/install/shell）
│   ├── server.rs        # 服务端检测与 HAP 自动安装
│   ├── connection.rs    # TCP 客户端 + 协议帧编解码
│   ├── control.rs       # 鼠标事件 → ControlEvent 序列化
│   ├── decoder/
│   │   ├── mod.rs       # VideoDecoder trait
│   │   └── vtb.rs       # macOS VideoToolbox H.264 解码器（unsafe FFI）
│   └── renderer/
│       ├── mod.rs       # Renderer trait
│       └── sdl.rs       # SDL2 窗口管理、纹理渲染、事件循环
└── tests/
    ├── protocol_test.rs  # 帧编解码单元测试
    └── hdc_mock_test.rs  # hdc 输出 mock 测试
```

**Structure Decision**: 单 Cargo 项目置于 `cli/`，不引入 Cargo workspace（与现有 Flutter/ArkTS 项目独立）。

---

## Complexity Tracking

无 Constitution 门控违规，无需填写。

---

## Phase 0: Research 结论

详见 [research.md](./research.md)。

关键决策摘要：
- VideoToolbox 解码方案：使用 `videotoolbox` crate（`VTDecompressionSession`），SPS/PPS 从协议 0x02 包提取后构造 `CMFormatDescription`
- 渲染方案：SDL2 + `SDL_PIXELFORMAT_IYUV`（NV12→I420 转换）纹理上传
- hdc 交互：`tokio::process::Command` 异步调用，stdout 解析设备列表
- 端口转发冲突检测：`hdc fport ls` 解析现有规则，端口范围 5000–5099 动态分配

## Phase 1: 设计产物

- [data-model.md](./data-model.md) — 实体与状态机
- [contracts/cli-schema.md](./contracts/cli-schema.md) — 参数契约与退出码
- [quickstart.md](./quickstart.md) — 开发环境配置与首次构建
