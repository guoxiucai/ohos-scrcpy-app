# OpenHarmony Scrcpy 录屏架构设计文档

## 一、方案总览与对比

| 对比维度 | 方案一：DisplayManager 显存直读 | 方案二：OH_AVScreenCapture 应用截屏 |
|----------|--------------------------------|-------------------------------------|
| 实现层级 | 系统服务层（Native C++ 可执行程序） | 应用框架层（ArkTS + NAPI） |
| 产物形态 | 编译进系统镜像的 ELF 可执行文件 | 标准 HAP 应用包（ServiceExtensionAbility） |
| 图形数据来源 | `DisplayManager::Screenshot()` 直接从显存读取 | `OH_AVScreenCapture` + Surface 模式直通编码器 |
| 编码方式 | 截屏 RGBA → CPU 转 NV12 → 硬编码器 | 截屏 Surface 直连编码器输入 Surface（零拷贝） |
| 典型端到端延迟 | 30-50 ms（含 RGBA→NV12 转换开销） | 20-40 ms（Surface 直通，无格式转换） |
| 帧率 | 由定时器控制，理论 25 fps | 由编码器驱动，实测 20 fps 稳定 |
| 权限要求 | root / system 权限（进程以 root 运行） | `ohos.permission.CAPTURE_SCREEN` + 系统应用签名 |
| 开发环境 | 需要 OpenHarmony 完整系统源码树 | 标准 SDK + NDK（DevEco Studio 即可） |
| 固件依赖 | 需要定制固件（编译进 system 分区） | 通用固件（预装 HAP 到 `/system/app/`） |
| OTA 更新 | 需随固件一起更新 | 可独立安装/更新 HAP |
| 维护成本 | 高（跟踪系统图形栈内部 API 变更） | 低（跟随官方 NDK API） |
| 可采集普通 UI 界面 | ✅ | ✅ |
| 可采集 Surface 类型 XComponent 内容 | ✅（从显存读取全部图层合成结果） | ❌（Surface 内容位于独立图形缓冲区，录屏服务无法跨进程访问） |
| 适用场景 | 游戏投屏、视频播放器投屏、云手机 | 普通应用 UI 录屏、系统界面演示 |
| 实现状态 | 仅方案设计，未实现 | **已实现，当前采用** |

---

## 二、方案一：DisplayManager 显存直读 + TCP 传输（系统级可执行程序）

> **状态：仅方案设计，未实现。** 需要 OpenHarmony 完整源码树编译，产物为 `/system/bin/` 下的可执行文件。

### 2.1 整体架构

```
┌──────────────────────────────────────────────────────────────────────┐
│                         OpenHarmony 设备端                            │
├──────────────────────────────────────────────────────────────────────┤
│  ┌────────────────────────────────────────────────────────────────┐  │
│  │              screencap_server (系统可执行进程)                    │  │
│  │                                                                │  │
│  │  ┌────────────┐  ┌─────────────┐  ┌──────────┐  ┌──────────┐  │  │
│  │  │ 25fps Timer│─▶│DisplayMgr   │─▶│VideoEnc  │─▶│TCPServer │  │  │
│  │  │(CLOCK_MONO)│  │::Screenshot │  │(H.264硬编)│  │(epoll IO)│  │  │
│  │  └────────────┘  │→ RGBA PixMap│  │NV12 输入  │  │端口 9527 │  │  │
│  │                  └─────────────┘  └──────────┘  └────┬─────┘  │  │
│  └──────────────────────────────────────────────────────│────────┘  │
│                                                         │          │
│                              TCP Socket 127.0.0.1:9527  │          │
└─────────────────────────────────────────────────────────│──────────┘
                                                          │
                      HDC 端口转发: hdc fport tcp:<pc> tcp:9527
                                                          │
                                                          ▼
┌──────────────────────────────────────────────────────────────────────┐
│                              PC 端                                    │
│     TCP Client ──▶ 长度头解析 ──▶ H.264 解码 ──▶ 渲染/显示           │
└──────────────────────────────────────────────────────────────────────┘
```

### 2.2 核心流程

1. **截屏**：通过 `DisplayManager::Screenshot()` 直接从显存读取当前帧 RGBA PixelMap
2. **格式转换**：CPU 将 RGBA 转为 NV12（编码器要求的输入格式）
3. **H.264 编码**：通过 `OH_VideoEncoder` 硬件编码
4. **TCP 发送**：编码回调中将 NAL 单元通过 TCP 发送给 PC

### 2.3 定时截屏策略

使用 `clock_nanosleep(CLOCK_MONOTONIC, TIMER_ABSTIME)` 实现精准 25fps 定时，避免累积漂移：

```
每帧目标时间 = 上一帧目标时间 + 40ms
sleep 到目标时间 → 截屏 → RGBA→NV12 → 送编码器
```

### 2.4 编译部署要点

- **构建系统**：在 OH 源码树中使用 `BUILD.gn`，编译为 `ohos_executable`
- **安装位置**：`/system/bin/screencap_server`
- **自启配置**：通过 init 服务配置文件（`.cfg`）实现开机自启
- **SELinux**：需要编写 `.te` 策略文件，授予 `sys_rawio`、`net_raw`、graphic 设备访问等权限
- **运行身份**：以 root 用户运行，加入 `graphic`、`system` 用户组

### 2.5 启动命令

```bash
# 设备端：服务已开机自启，或手动启动
hdc shell /system/bin/screencap_server &

# 建立端口转发
hdc fport tcp:<pc_port> tcp:9527

# PC 端连接并解码渲染
```

### 2.6 方案优势与风险

**优势：**
- 能采集 Surface 类型 XComponent 内容（游戏、视频播放器），这是方案二无法做到的
- 直接从合成后的显存读取，获取的是与屏幕完全一致的画面

**风险：**
- `DisplayManager` 内部 C++ API 无稳定性保证，OH 版本升级可能导致编译失败
- RGBA→NV12 的 CPU 转换在高分辨率下有明显开销（1080p 约 3-5ms/帧）
- 需要定制固件，OTA 升级时必须同步更新
- SELinux 策略审计可能较严格

---

## 三、方案二：OH_AVScreenCapture + Surface 直通编码（应用级服务）

> **状态：已实现，当前采用。**

### 3.1 整体架构

```
┌────────────────────────────────────────────────────────────────────────┐
│                          OpenHarmony 设备端                              │
├────────────────────────────────────────────────────────────────────────┤
│  ┌──────────────────────────────────────────────────────────────────┐  │
│  │               ServiceExtensionAbility (ArkTS)                     │  │
│  │  ┌────────────────────────────────────────────────────────────┐  │  │
│  │  │                    NAPI 模块 (C++)                          │  │  │
│  │  │                                                            │  │  │
│  │  │  ┌──────────────┐      ┌──────────────┐                    │  │  │
│  │  │  │OH_AVScreen-  │      │OH_VideoEncoder│                    │  │  │
│  │  │  │Capture       │      │ (H.264 硬编)  │                    │  │  │
│  │  │  │              │      │              │                    │  │  │
│  │  │  │  截屏输出     │──────│  编码器输入    │                    │  │  │
│  │  │  │  Surface ────┼─────▶│  Surface      │  (零拷贝直通)      │  │  │
│  │  │  └──────────────┘      └──────┬───────┘                    │  │  │
│  │  │                               │ 编码回调                     │  │  │
│  │  │                               ▼                            │  │  │
│  │  │                        ┌──────────────┐                    │  │  │
│  │  │                        │  TcpServer   │                    │  │  │
│  │  │                        │  (epoll IO)  │                    │  │  │
│  │  │                        │  多客户端支持  │                    │  │  │
│  │  │                        │  端口 53535   │                    │  │  │
│  │  │                        └──────┬───────┘                    │  │  │
│  │  └───────────────────────────────│────────────────────────────┘  │  │
│  └──────────────────────────────────│────────────────────────────────┘  │
│                                     │                                   │
│                      TCP Socket 127.0.0.1:53535                        │
└─────────────────────────────────────│──────────────────────────────────┘
                                      │
                   HDC 端口转发: hdc fport tcp:<pc> tcp:53535
                                      │
                                      ▼
┌────────────────────────────────────────────────────────────────────────┐
│                               PC 端                                     │
│      TCP Client ──▶ 协议解析 ──▶ H.264 解码 ──▶ 渲染/显示              │
└────────────────────────────────────────────────────────────────────────┘
```

### 3.2 Surface 直通编码（核心设计）

方案二的关键优化是利用 `OH_AVScreenCapture` 的 Surface 输出与 `OH_VideoEncoder` 的 Surface 输入直接对接，实现**零拷贝**编码：

```
                    OHNativeWindow (共享)
                    ┌─────────────┐
OH_AVScreenCapture ─┤  Surface    ├─ OH_VideoEncoder
  (截屏生产者)       │ (显存缓冲)  │   (编码消费者)
                    └─────────────┘
```

启动顺序：
1. 创建 `OH_VideoEncoder`，配置 H.264 参数（分辨率、码率、帧率）
2. 调用 `OH_VideoEncoder_GetSurface()` 获取编码器的输入 `OHNativeWindow`
3. `OH_VideoEncoder_Prepare()` + `OH_VideoEncoder_Start()` 启动编码器
4. 创建 `OH_AVScreenCapture`，配置截屏参数
5. 调用 `OH_AVScreenCapture_StartScreenCaptureWithSurface(capture, window)` 启动截屏，截屏数据直接写入编码器 Surface

这种模式下：
- 截屏产生的 RGBA 帧直接在 GPU 侧送入编码器，无需 CPU 参与格式转换
- 编码器硬件自动完成 RGBA → NV12 转换（部分芯片支持，不支持的降级处理）
- 整条数据通路在内核态完成，应用层零拷贝

### 3.3 NAPI 模块接口

模块名：`libscrcpy_capture.so`

| 导出函数 | 参数 | 说明 |
|---------|------|------|
| `startServer(port, config, onPresence, onControl)` | 端口、采集配置、客户端上下线回调、控制指令回调 | 启动 TCP 服务 |
| `stopServer()` | 无 | 停止 TCP 服务并释放截屏/编码器资源 |
| `startCapture(config)` | 采集配置 | 创建截屏+编码器，开始采集 |
| `stopCapture()` | 无 | 停止采集，释放截屏/编码器资源 |
| `setEncoderPaused(paused)` | boolean | 暂停/恢复编码输出（背压控制） |
| `broadcastDeviceStatus(data)` | Uint8Array | 向所有客户端广播设备状态 |
| `probeScreenCapture(config)` | 采集配置 | 预检截屏权限是否可用 |

采集配置（`CaptureConfig`）：

```typescript
interface CaptureConfig {
  width: number;       // 采集宽度（像素，偶数对齐）
  height: number;      // 采集高度（像素，偶数对齐）
  frameRate: number;    // 目标帧率
  bitrate: number;      // H.264 码率 (bps)
  jpegQuality: number;  // JPEG 降级时的质量 1-100
}
```

### 3.4 TcpServer 设计

采用 epoll I/O 多路复用，支持多客户端并发连接：

```
                          ┌─ Client A (fd=5)  txQueue: [frame1, frame2]
    listenFd ──accept──▶  ├─ Client B (fd=7)  txQueue: [frame2]
         │                └─ Client C (fd=9)  txQueue: [frame1, frame2, frame3]
         │
    epoll_wait ──▶ EPOLLIN:  读取控制指令 / 心跳
                   EPOLLOUT: 非阻塞发送队列中的帧数据
```

关键设计：

- **shared_ptr 帧共享**：广播帧时各客户端队列持有同一份 `shared_ptr<const vector<uint8_t>>`，消除 per-client 拷贝
- **非阻塞写入**：每个客户端维护独立的 `txQueue` + `txOffset`，EPOLLOUT 触发时分批写入
- **心跳超时**：记录每个客户端最后活跃时间，超时自动断开
- **客户端上下线感知**：通过 `napi_threadsafe_function` 回调 ArkTS 层，触发截屏的启动/停止
- **新客户端自动同步**：连接时立即发送最新的 `VideoConfig` 包
- **wakeup pipe**：IO 线程阻塞在 epoll_wait 时，主线程通过 pipe 写端唤醒

### 3.5 编码器参数

```
编码格式：H.264 Main Profile
码率控制：VBR
默认码率：4 Mbps
默认帧率：20 fps
I 帧间隔：2000 ms
像素格式：NV12（编码器 Surface 模式自动转换）
分辨率：动态（默认缩放到短边 720px，偶数对齐）
```

### 3.6 截屏生命周期管理

```
客户端连接 ──▶ onPresence(true)  ──▶ startCapture()
                                       │
                                       ├─ 创建 VideoEncoder
                                       ├─ 获取 encoder Surface
                                       ├─ 创建 ScreenCapture
                                       └─ StartScreenCaptureWithSurface()
                                              │
                                              ▼
                                        编码回调输出 H.264 NAL
                                              │
                                              ▼
                                        TcpServer.BroadcastVideoFrame()

所有客户端断开 ──▶ onPresence(false) ──▶ stopCapture()
                                          │
                                          ├─ StopScreenCapture()
                                          ├─ Encoder Flush + Stop + Destroy
                                          └─ Release ScreenCapture
```

**关键原则**：无客户端时**必须** `stopCapture()`，释放系统截屏和编码器资源，不许常驻占用。

### 3.7 ArkTS 服务层

`ScrcpyService`（ServiceExtensionAbility）职责：

- 生命周期管理：`onCreate` 启动 TCP 服务，`onDestroy` 停止一切
- 客户端感知：收到 `onPresence(true)` 启动截屏，`onPresence(false)` 停止截屏
- 控制指令分发：收到 `onControl(sub, body)` 后分发给 `InputInjector`（触控注入）或执行内部操作（暂停编码、切换分辨率等）
- 后台保活：客户端连接期间申请 `backgroundTaskManager` 长时任务
- 动态分辨率调整：收到 `CHANGE_VIDEO_PARAMS` 指令时停止当前截屏，按新参数重新启动

### 3.8 编译与部署

#### 3.8.1 NAPI 模块编译（CMakeLists.txt）

```cmake
cmake_minimum_required(VERSION 3.5)
project(scrcpy_capture)

add_library(scrcpy_capture SHARED
    napi_init.cpp
    ScreenCaptureEncoder.cpp
    TcpServer.cpp
)

target_link_libraries(scrcpy_capture PUBLIC
    libace_napi.z.so
    libhilog_ndk.z.so
    libnative_media_avscreen_capture.so
    libnative_media_codecbase.so
    libnative_media_venc.so
    libnative_media_core.so
    libnative_buffer.so
    libnative_window.so
    libimage_packer.so
    libpixelmap.so
)
```

#### 3.8.2 应用配置（module.json5）

```json
{
  "module": {
    "name": "entry",
    "type": "entry",
    "mainElement": "ScrcpyService",
    "extensionAbilities": [
      {
        "name": "ScrcpyService",
        "type": "service",
        "srcEntry": "./ets/scrcpyservice/ScrcpyService.ets",
        "permissions": [
          "ohos.permission.CAPTURE_SCREEN",
          "ohos.permission.INTERNET",
          "ohos.permission.INPUT_CONTROL",
          "ohos.permission.KEEP_BACKGROUND_RUNNING"
        ]
      }
    ]
  }
}
```

#### 3.8.3 部署步骤

1. DevEco Studio 编译生成 HAP 包
2. 使用系统证书签名（需要 `ohos.permission.CAPTURE_SCREEN` 等系统权限）
3. `hdc install -r entry-default-signed.hap` 安装到设备
4. `app.json5` 配置 `keepAlive: true` 实现开机自启

#### 3.8.4 启动命令

```bash
# 端口转发（客户端自动执行）
hdc -t <serial> fport tcp:<pc_port> tcp:53535

# 验证服务是否在运行
hdc shell netstat -tlnp | grep 53535
```

---

## 四、通信协议

方案一与方案二共用同一套帧协议。

### 4.1 帧格式

```
┌──────────┬──────────┬──────────────┐
│ type (4B)│length(4B)│  payload     │
│  大端     │  大端     │  length 字节 │
└──────────┴──────────┴──────────────┘
```

### 4.2 消息类型

| type | 名称 | 方向 | payload 格式 |
|------|------|------|-------------|
| `0x01` | 心跳 | 双向 | 空 或 时间戳 8B |
| `0x02` | 视频配置 | S→C | codec(1) + width(4) + height(4) + fps(4) [+ spsLen(2) + sps + ppsLen(2) + pps] |
| `0x03` | 视频帧 | S→C | flags(1, bit0=keyframe) + pts(8) + NAL 数据 |
| `0x10` | 控制指令 | C→S | subType(1) + body |
| `0x20` | 设备状态 | S→C | subType(1) + body |

### 4.3 视频配置 payload 详解

第一字节 `codec` 标识编码类型：

| codec 值 | 编码类型 | 后续字段 |
|----------|---------|---------|
| `0x00` | H.264 | width(4) + height(4) + fps(4) + spsLen(2) + SPS + ppsLen(2) + PPS |
| `0x01` | RAW RGBA | width(4) + height(4) + fps(4) |
| `0x02` | JPEG | width(4) + height(4) + fps(4) |

### 4.4 控制指令 subType

| subType | 名称 | body 格式 |
|---------|------|----------|
| `0x01` | TOUCH_DOWN | x(4) + y(4) + pointerId(2) |
| `0x02` | TOUCH_MOVE | x(4) + y(4) + pointerId(2) |
| `0x03` | TOUCH_UP | x(4) + y(4) + pointerId(2) |
| `0x10` | KEY | keyCode(4) + action(4) |
| `0x20` | VOL_UP | 空 |
| `0x21` | VOL_DOWN | 空 |
| `0x22` | BR_UP | 空 |
| `0x23` | BR_DOWN | 空 |
| `0x30` | BACK | 空 |
| `0x31` | HOME | 空 |
| `0x32` | RECENT | 空 |
| `0x40` | PAUSE_ENCODER | 空 |
| `0x41` | RESUME_ENCODER | 空 |
| `0x42` | CHANGE_VIDEO_PARAMS | maxShort(4) + bitrate(4) + frameRate(4) |
| `0x50` | LIST_APPS | 空 |

---

## 五、PC 端接收与解码

PC 端通过 `hdc fport` 将设备 TCP 端口映射到本地，然后：

1. **TCP 连接**：连接本地映射端口，按 `4B type + 4B length + payload` 解析帧
2. **视频配置同步**：收到 `0x02` 包后提取编码类型、分辨率、SPS/PPS，初始化对应解码器
3. **H.264 解码**：使用平台原生硬件解码器（macOS VideoToolbox / Windows MediaFoundation / Linux VA-API 等）
4. **渲染上屏**：解码后的 YUV/RGB 帧渲染到窗口

H.264 视频帧中的 NAL 数据为 **Annex-B 格式**（`0x00000001` 起始码分隔），解码器可直接消费。

---

## 六、方案选择决策树

```
录屏目标是否包含 Surface 类型 XComponent 内容（游戏、视频播放器等）？
├─ 是 → 必须选方案一（DisplayManager 显存直读）
│        方案二的 OH_AVScreenCapture 无法采集 Surface 图层内容
│
└─ 否 → 是否有 OpenHarmony 完整系统源码？
         ├─ 是 → 两种方案均可，根据以下因素权衡：
         │       • 需要独立更新服务 → 方案二（HAP 可独立安装）
         │       • 需要最低延迟 → 两者接近（方案二 Surface 直通同样高效）
         │       • 需要简化部署 → 方案二
         └─ 否 → 选择方案二（仅需 SDK + NDK）
```

---

## 七、附录

### 7.1 术语说明

| 术语 | 说明 |
|------|------|
| **Surface 类型 XComponent** | 提供独立 `OHNativeWindow` 的组件，由 EGL/Vulkan 直接渲染，不经过 ArkUI 渲染管线 |
| **Component 类型 XComponent** | 内容由 ArkUI 直接渲染的组件，属于应用 UI 图层 |
| **Surface 直通** | 截屏输出 Surface 与编码器输入 Surface 共享同一块 `OHNativeWindow`，数据在 GPU 侧流转 |
| **AVCC** | H.264 编码数据存储格式，每个 NALU 前用 4 字节长度标识 |
| **Annex-B** | H.264 流格式，每个 NALU 前用起始码 `0x00000001` 分隔，解码器通用格式 |
| **NV12** | YUV 4:2:0 半平面格式，Y 平面 + 交错 UV 平面，H.264 编码器标准输入格式 |
| **epoll** | Linux/OH 内核的 I/O 事件通知机制，用于高效处理多个 TCP 连接 |

### 7.2 环境要求

| 项目 | 方案一 | 方案二 |
|------|--------|--------|
| 操作系统 | OpenHarmony ≥ 5.0 | OpenHarmony ≥ 5.0 |
| API 版本 | 无要求（系统内部 API） | `compileSdkVersion ≥ 15` |
| 开发环境 | OH 完整系统源码 + 交叉编译工具链 | DevEco Studio + SDK + NDK |
| 签名要求 | 无需签名（系统进程） | 系统应用证书签名 |
| PC 端 | 支持 H.264 硬解的平台 + hdc 工具 | 同左 |
