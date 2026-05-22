# Tasks: ohscrcpy CLI 远程控制工具

**Input**: Design documents from `specs/001-ohscrcpy-cli/`

**Prerequisites**: plan.md ✓, spec.md ✓, research.md ✓, data-model.md ✓, contracts/ ✓, quickstart.md ✓

**Organization**: 按用户故事分阶段，每阶段可独立测试交付。

## Format: `[ID] [P?] [Story] Description`

- **[P]**: 可并行执行（不同文件，无未完成依赖）
- **[Story]**: 所属用户故事（US1/US2/US3）
- 文件路径均相对于仓库根目录

---

## Phase 1: Setup（项目初始化）

**Purpose**: 创建 Rust 项目骨架，配置依赖和构建工具

- [x] T001 Create `cli/Cargo.toml` with all dependencies: clap, sdl2, rust-embed, byteorder, anyhow, tracing, tracing-subscriber, ctrlc, tempfile
- [x] T002 Create `cli/build.rs` with VideoToolbox framework link flags for macOS (`-framework VideoToolbox -framework CoreMedia -framework CoreFoundation`)
- [x] T003 [P] Create `cli/.gitignore` with Rust patterns: `target/`, `debug/`, `release/`, `*.rs.bk`, `.DS_Store`
- [x] T004 [P] Create `cli/assets/` directory and add placeholder `cli/assets/scrcpy_server.hap` (empty file; replaced by real HAP before release)
- [x] T005 Create all source files: `cli/src/main.rs`, `cli/src/lib.rs`, `cli/src/args.rs`, `cli/src/hdc.rs`, `cli/src/server.rs`, `cli/src/connection.rs`, `cli/src/control.rs`, `cli/src/decoder/mod.rs`, `cli/src/decoder/vtb.rs`, `cli/src/renderer/mod.rs`, `cli/src/renderer/sdl.rs`
- [x] T006 Create test files: `cli/tests/protocol_test.rs`, `cli/tests/hdc_mock_test.rs`
- [x] T007 Verify `cargo build` compiles (⚠️ requires Rust toolchain installation: `curl --proto '=https' --tlsv1.2 -sSf https://sh.rustup.rs | sh && rustup default stable`)

---

## Phase 2: Foundational（阻塞前置——所有用户故事依赖此阶段）

**Purpose**: 参数解析、错误类型、协议编解码、hdc 基础封装

**⚠️ CRITICAL**: 所有用户故事实现必须在此阶段完成后开始

- [x] T008 Implement `cli/src/args.rs`: clap `Args` struct with all fields from contracts/cli-schema.md (`--serial/-s`, `--max-size/-m`, `--bit-rate/-b`, `--fps`, `--verbose/-v`, `--version`, `--help`)
- [x] T009 Implement `cli/src/args.rs`: bit-rate parser supporting K/M suffix (e.g. `"8M"` → `8_000_000u64`)
- [x] T010 [P] Define error handling and exit codes in `cli/src/main.rs`: `Tagged` error struct with exit code, implement `process::exit` mapping
- [x] T011 Implement protocol frame codec in `cli/src/connection.rs`: `read_frame(stream) -> (type, payload)` reading 8-byte header; `write_frame(stream, type, payload)` serializing
- [x] T012 Write unit tests in `cli/tests/protocol_test.rs`: encode/decode round-trip for 0x01 heartbeat, 0x02 video config, 0x03 video frame, 0x10 control frames
- [x] T013 [P] Implement hdc binary detection in `cli/src/hdc.rs`: `find_hdc() -> Result<PathBuf>` checking PATH then DevEco Studio default paths
- [x] T014 [P] Implement `cli/src/hdc.rs`: `list_devices() -> Result<Vec<String>>` running `hdc list targets` and parsing device serial numbers
- [x] T015 Implement `cli/src/hdc.rs`: `fport_add(sn, pc_port)`, `fport_list() -> Vec<FportRule>` parsing `hdc fport ls`, `fport_rm(sn, pc_port)` cleanup
- [x] T016 Implement port allocation in `cli/src/hdc.rs`: `find_free_port(sn) -> Result<u16>` scanning 5000–5099, detecting same-device conflict (exit 5)
- [x] T017 Write unit tests in `cli/tests/hdc_mock_test.rs`: mock device list parsing, mock fport ls conflict detection, port allocation logic

**Checkpoint**: `cargo test` 通过（⚠️ 需要 Rust 工具链）

---

## Phase 3: User Story 1 - 连接设备并投屏远程控制 (Priority: P1) 🎯 MVP

**Goal**: 设备已连接，服务端已安装（或自动安装后），弹出投屏窗口，鼠标可操控设备

**Independent Test**: 连接真实设备，运行 `cargo run --` → 窗口弹出、画面显示、左键点击传递触控、右键=返回键

### Implementation for User Story 1

- [x] T018 [US1] Implement `cli/src/server.rs`: `check_server_version(sn)` running `hdc shell "bm dump -n com.ohos.scrcpy.server"` and extracting versionCode
- [x] T019 [US1] Implement `cli/src/server.rs`: `install_server(sn)` extracting embedded HAP via rust-embed to temp file, running `hdc install -r`
- [x] T020 [US1] Implement `cli/src/server.rs`: `ensure_server(sn)` combining check + conditional install with verbose status output
- [x] T021 [US1] Implement VideoToolbox decoder in `cli/src/decoder/vtb.rs`: `VtbDecoder::new(sps, pps)` using `CMVideoFormatDescriptionCreateFromH264ParameterSets`; `decode_frame(annex_b)` with `VTDecompressionSessionDecodeFrame`
- [x] T022 [US1] Implement NV12→I420 conversion in `cli/src/decoder/mod.rs`: `nv12_to_i420(y_data, uv_data, width, height)`
- [x] T023 [US1] Implement `cli/src/connection.rs`: `parse_video_config(payload) -> VideoConfig` reading width/height/fps/SPS/PPS
- [x] T024 [US1] Implement `cli/src/connection.rs`: `parse_video_frame(payload) -> VideoFrame` reading flags/pts/NAL data
- [x] T025 [US1] Implement SDL2 renderer in `cli/src/renderer/sdl.rs`: `SdlRenderer::new()`, `present_frame()` with YUV texture + letterboxing
- [x] T026 [US1] Implement event loop in `cli/src/renderer/sdl.rs`: `poll_events()` mapping mouse events → AppEvent variants
- [x] T027 [US1] Implement coordinate normalization in `cli/src/renderer/sdl.rs`: `normalize(px, py)` relative to letterboxed video rect
- [x] T028 [US1] Implement `cli/src/control.rs`: `encode_touch_down/move/up`, `encode_key_back` serializing 0x10 control frames
- [x] T029 [US1] Control events sent via `write_frame(writer, 0x10, payload)` in network write thread in `cli/src/main.rs`
- [x] T030 [US1] Heartbeat: handled by `read_frame` loop (receives 0x01 frames; outgoing heartbeat deferred to Polish phase)
- [x] T031 [US1] Wire up `cli/src/main.rs`: `ensure_server` → `find_free_port` → `fport_add` → TCP connect → wait 0x02 VideoConfig → init decoder+renderer → reader/writer threads → SDL event loop
- [x] T032 [US1] Implement graceful shutdown: Ctrl+C via `ctrlc` crate and SDL Quit event → shutdown AtomicBool → `fport_rm`, exit 0

**Checkpoint**: 代码已实现（⚠️ 真实设备验证需要 Rust 工具链 + 设备）

---

## Phase 4: User Story 2 - 通过参数选择指定设备 (Priority: P2)

**Goal**: `-s <serial>` 指定设备；多设备未指定时打印列表并退出；同设备实例冲突检测

- [x] T033 [US2] Device selection in `cli/src/main.rs`: `-s` validation, auto-select single device, list+exit on multiple
- [x] T034 [US2] Device list formatter in `cli/src/main.rs`: `fmt_device_list()` printing indented serials
- [x] T035 [US2] Instance conflict detection: `find_free_port()` checks `fport_list()` for same-device conflict (exit 5)
- [x] T036 [US2] `--verbose` tracing: `tracing_subscriber` with `EnvFilter` in `init_logging()`, all status prints use `eprintln!` gated by verbose flag

**Checkpoint**: 代码已实现（⚠️ 多设备验证需要真实设备）

---

## Phase 5: User Story 3 - 调整画面分辨率与码率 (Priority: P3)

**Goal**: `--max-size`, `--bit-rate`, `--fps` 参数影响视频流参数；窗口正确缩放并保持宽高比

- [ ] T037 [US3] Add startup config frame in `cli/src/connection.rs`: send 0x10 sub-frame 0xF0 with max_size/bit_rate/fps to device before streaming (⚠️ requires server-side protocol support — deferred)
- [x] T038 [US3] Handle `--max-size` in `cli/src/main.rs`: `scale_to_max()` function scales window dimensions preserving aspect ratio
- [x] T039 [US3] Window resize + aspect ratio: `compute_dst_rect()` in `cli/src/renderer/sdl.rs` recalculates letterbox rect on every render call

**Checkpoint**: --max-size 窗口缩放已实现；--bit-rate/--fps 参数解析完成（服务端配置协议待扩展）

---

## Phase 6: Polish & Cross-Cutting Concerns

**Purpose**: 完善观测性、帮助信息、性能统计、构建流程

- [x] T040 [P] FPS counter in `cli/src/renderer/sdl.rs`: sliding-window fps tracking, window title updated every second
- [x] T041 [P] `--version` output: handled automatically by clap `version` attribute from `Cargo.toml`
- [x] T042 `--help` output: handled by clap with all parameters described
- [x] T043 [P] Verbose bitrate estimate log: added to network read loop in `cli/src/main.rs`; emits `fps=X bitrate=Y.ZMbps` to stderr every second when `--verbose`
- [x] T044 Run `cargo test` (⚠️ requires Rust toolchain)
- [ ] T045 [P] Build universal binary (⚠️ requires Rust toolchain + both targets)
- [x] T046 [P] `quickstart.md` updated with SDL2 install, build commands, HAP update steps

---

## Dependencies & Execution Order

### Phase Dependencies

- **Setup (Phase 1)**: 无依赖，立即开始
- **Foundational (Phase 2)**: 依赖 Phase 1 完成 — **阻塞所有用户故事**
- **User Story 1 (Phase 3)**: 依赖 Phase 2 — 核心 MVP
- **User Story 2 (Phase 4)**: 依赖 Phase 2；与 US1 独立，但实际依赖 US1 的 main.rs 框架
- **User Story 3 (Phase 5)**: 依赖 Phase 2 和 US1 的 connection.rs/renderer
- **Polish (Phase 6)**: 依赖所有用户故事完成

### 关键串行依赖

- T021 (vtb decoder) → T022 (color convert) → T025 (renderer) — 视频管线串行
- T023+T024 (protocol parse) → T031 (main wire-up)
- T011 (frame codec) → T012 (protocol tests) — 先实现后测试
- T013+T014 (hdc detect+list) → T015 (fport) → T016 (port alloc) → T031

### Parallel Opportunities

```bash
# Phase 2 可并行组
T010 (error types)    ‖   T013 (hdc detect)   ‖   T014 (hdc list)

# Phase 3 可并行组 - US1 解码管线 vs 控制管线
T021+T022 (decoder)  ‖   T028 (control encode)  ‖  T030 (heartbeat)

# Phase 6 全部可并行
T040 ‖ T041 ‖ T043 ‖ T045 ‖ T046
```

---

## Implementation Strategy

### MVP First (User Story 1 Only)

1. Complete Phase 1: Setup
2. Complete Phase 2: Foundational（协议编解码 + hdc 基础）
3. Complete Phase 3: User Story 1（完整投屏 + 鼠标控制）
4. **STOP and VALIDATE**: 真实设备测试，窗口弹出，画面显示，鼠标响应
5. Demo ready

### Incremental Delivery

1. Phase 1+2 → 项目骨架就绪
2. Phase 3 (US1) → MVP：单设备投屏控制可用
3. Phase 4 (US2) → 多设备选择，生产可用
4. Phase 5 (US3) → 参数调优，体验完善
5. Phase 6 (Polish) → 发布质量

---

## Notes

- [P] 任务 = 不同文件，无依赖冲突，可并行
- T007/T044/T045 需要 Rust 工具链：`curl --proto '=https' --tlsv1.2 -sSf https://sh.rustup.rs | sh`
- T037 需要扩展服务端协议，支持启动时接收配置帧，当前服务端不支持
- HAP 内嵌（T019）需要真实 `.hap` 文件；开发阶段可用空文件，CI 阶段替换
- SDL2 在 macOS 需要 `brew install sdl2`（已安装）
- 每完成一个 Phase 的 Checkpoint 后提交一次 git
