# OpenHarmony Scrcpy (投屏 + HDC 调试) 设计文档

## 1. 背景与目标
构建一个针对 OpenHarmony 设备的 scrcpy 类工具，桌面客户端（Flutter）通过 HDC 端口转发与设备上常驻的系统服务通信，实时镜像屏幕并提供点击/滑动控制、hap 安装、亮度音量控制。

现状：
- `scrcpy_server/`：已存在 OpenHarmony 系统应用模板（bundle `com.ohos.scrcpy.server`，已申请 `CUSTOM_SCREEN_CAPTURE` / `SYSTEM_FLOAT_WINDOW` / `INTERNET`）。
- `scrcpy_client_flutter/`：空目录，需要从零创建 Flutter 3.22.1 工程（macOS / Windows 优先，Linux 留 P3）。
- API 区间：OpenHarmony API 15 ~ 20。

## 2. 关键技术决策（已与用户对齐）
- **HDC 调用**：客户端 `Process.run` 调系统 `hdc` CLI；要求用户本机 hdc 在 PATH。
- **视频解码**：平台原生硬解（macOS VideoToolbox / Windows MediaFoundation），通过 MethodChannel + Flutter Texture 上屏。
- **传输通道**：仅 `hdc fport tcp:<pcPort> tcp:<devicePort>`，USB/网络 hdc 共用。
- **服务端采集编码**：`@ohos.multimedia.screenCapture`（Surface 模式）→ `media.VideoEncoder('video/avc')` → `on('newOutputBuffer')` 输出 H264 Annex-B。

## 3. 通信协议
帧格式：`4B type | 4B length(BE) | payload`

| type | 名称       | 方向    | payload                                   |
|------|------------|---------|-------------------------------------------|
| 0x01 | 心跳       | 双向    | 空 / 时间戳 8B                            |
| 0x02 | 视频配置   | S→C     | width 4B + height 4B + fps 4B + SPS/PPS  |
| 0x03 | 视频帧     | S→C     | flags 1B (bit0=keyframe) + pts 8B + NAL  |
| 0x10 | 控制       | C→S     | sub-type 1B + 数据（touch / key / vol …） |
| 0x20 | 设备状态   | S→C     | sub-type 1B + 数据                        |

服务端在设备 `127.0.0.1:53535` listen；客户端连接 PC 侧 `hdc fport` 映射端口。

## 4. 服务端设计（`scrcpy_server/entry/src/main/ets`）

### 4.1 模块文件
1. `module.json5`
   - `extensionAbilities` 增加 `ScrcpyService`（type=`service`, srcEntry=`./ets/scrcpyservice/ScrcpyService.ets`, exported=true）。
   - 新增权限：`ohos.permission.CAPTURE_SCREEN`(系统)、`ohos.permission.KEEP_BACKGROUND_RUNNING`、`ohos.permission.RUNNING_LOCK`、`ohos.permission.RECEIVER_STARTUP_COMPLETED`。
   - ScrcpyService 上声明 `backgroundModes: ["dataTransfer","audioRecording"]`（API 12-20 最稳的 bgMode 组合）。
2. `ets/scrcpyservice/ScrcpyService.ets`：ServiceExtensionAbility
   - `onCreate`：申请 RUNNING_LOCK、调 `backgroundTaskManager.startBackgroundRunning`、启动 `ScreenPipeline`、启动 `TcpServer`。
   - `onRequest/onConnect`：接收启停、配置变更命令。
3. `ets/scrcpyservice/ScreenPipeline.ets`
   - `media.createVideoEncoderByMime('video/avc')` → `getInputSurface()` 拿到 surfaceId。
   - `screenCapture.createAVScreenCaptureRecorder()`（Surface 输出模式），把 encoder 的 surfaceId 当作输出。
   - 编码回调里组帧（带 SPS/PPS 缓存，关键帧前置 config NAL），交给 `TcpServer.broadcast`。
4. `ets/scrcpyservice/TcpServer.ets`
   - `socket.constructTCPSocketServerInstance()` listen `127.0.0.1:53535`。
   - 客户端连入后下发：配置包(0x02) → 视频流(0x03)；接收 0x10 控制包后转给 `InputInjector`。
5. `ets/scrcpyservice/InputInjector.ets`
   - 触摸/按键：`@ohos.multimodalInput.inputEventClient.injectEvent`（系统应用可用）。
   - 亮度：`@ohos.brightness.setValue`。
   - 音量：`@ohos.multimedia.audio.AudioVolumeManager`。
6. `ets/entryability/EntryAbility.ets` + `pages/Index.ets`
   - 一个最小调试 UI：服务运行状态、当前监听端口、停止/启动按钮。

### 4.2 数据流
```
ScreenCapture(Surface) ──▶ VideoEncoder.InputSurface
                                │
                                ▼
                  on('newOutputBuffer') 回调
                                │
                                ▼
              组帧(SPS/PPS缓存 + Annex-B)
                                │
                                ▼
                  TcpServer.broadcast(0x03)
```

## 5. 客户端 UI 设计（`scrcpy_client_flutter`）

### 5.1 窗口布局
单窗口三段式（最小尺寸 1100×680，默认 1280×800）：

```
┌─────────────────────────────────────────────────────────────────┐
│  TopBar (高 48)                                                 │
│  [刷新] [设备下拉: SN-xxx (USB) ▾] [连接/断开] [状态●]  ⋯ [设置]│
├──────────────────────────────────────────┬──────────────────────┤
│                                          │  Sidebar (1/3 ≈ 360) │
│                                          │ ┌──────────────────┐ │
│   MirrorView (2/3, 自适应)               │ │ 应用安装          │ │
│   ┌──────────────────────────┐           │ │ [选择 .hap] 拖入  │ │
│   │                          │           │ │ 安装进度 / 日志   │ │
│   │   设备屏幕镜像           │           │ ├──────────────────┤ │
│   │   (按设备分辨率比例)     │           │ │ 设备控制          │ │
│   │   黑色 letterbox 填充    │           │ │ 音量 [-] ▮▮▮ [+] │ │
│   │                          │           │ │ 亮度 [-] ▮▮▮ [+] │ │
│   │                          │           │ │ [Home][Back][电源]│ │
│   └──────────────────────────┘           │ ├──────────────────┤ │
│   底部状态条: 1080×2340 · 60fps · 4.2Mb/s│ │ 终端 (折叠)    │ │
│                                          │ │ > hdc shell ...   │ │
│                                          │ └──────────────────┘ │
└──────────────────────────────────────────┴──────────────────────┘
```

### 5.2 布局规则
- TopBar 固定高 48；macOS 用 `window_manager` 设 `titleBarStyle: hidden` 与原生标题栏融合，预留红绿灯空间。
- 主体 `Row`：左 `Expanded(flex: 2)` 包 `MirrorView`，右 `SizedBox(width: max(320, screenW/3))` 包 `Sidebar`，可拖拽分隔条调整（最小左 600 / 右 320）。
- `MirrorView`：`AspectRatio(aspectRatio: deviceW/deviceH)` 居中 + `FittedBox(fit: contain)`，外层黑底 letterbox；未连接时显示空态（"请选择设备并连接"）。
- 触控命中：`Listener` 捕获指针 → 结合 RenderBox 求屏幕坐标 → 缩放到设备真实坐标后下发 0x10。
- `Sidebar` 用 `ListView` + `ExpansionTile` 折叠卡片；P0 展示"应用安装"+"设备控制"；"终端"P2 折叠占位。
- 状态色：未连接灰、连接中黄、已连接绿、出错红；TopBar 圆点与 MirrorView 底部状态条联动。
- 主题：跟随系统亮/暗模式（`ThemeMode.system`），Material3。

### 5.3 工程目录
```
scrcpy_client_flutter/
  lib/
    main.dart
    app.dart
    hdc/                    # hdc CLI 包装
      hdc_client.dart       # devices/fport/install/shell
      device.dart
    net/
      protocol.dart         # 包编解码
      stream_client.dart    # TCP 客户端 + reconnect
    decoder/
      video_decoder.dart    # MethodChannel 抽象
    state/
      app_state.dart        # Riverpod / Provider 单一状态
    ui/
      top_bar.dart
      mirror_view.dart      # Texture + Listener + 状态条
      split_view.dart       # 可拖动分隔条
      empty_state.dart
      sidebar.dart
      sidebar/
        install_panel.dart
        control_panel.dart
        terminal_panel.dart # P2 占位
  macos/Runner/
    VideoDecoderPlugin.swift   # VideoToolbox + CVPixelBuffer→FlutterTexture
  windows/runner/
    video_decoder_plugin.cpp   # MediaFoundation MFT + ID3D11Texture2D 共享句柄
  scripts/
    package_mac.sh             # create-dmg
    package_win.ps1            # inno setup / msix
```

### 5.4 关键流程
1. 启动：`HdcClient.devices()` 列设备 → 用户选择 → `hdc -t <sn> fport tcp:0 tcp:53535` 拿本机随机端口。
2. 连接：`StreamClient.connect('127.0.0.1', pcPort)` → 收 0x02 配置包初始化解码器（SPS/PPS、宽高、帧率）→ Texture 创建 → 收 0x03 视频帧喂入解码器。
3. 渲染：`Texture(textureId)` + `AspectRatio` 保持原比例；窗口 resize 按短边缩放。
4. 触控：`Listener` 捕获 PointerDown/Move/Up，按显示尺寸/真实分辨率换算后封 0x10 包发回。
5. hap 安装：文件选择 → `hdc -t <sn> install -r <path>` → 流式回显。详见 `spec_doc/app_install_uninstall_design.md`（含安装弹窗化与卸载功能）。
6. 亮度/音量：发 0x10 控制包；服务端调系统 API。
7. 终端：`xterm.dart` 嵌入 + `hdc shell` 进程交互。详见 `spec_doc/terminal_design.md`。

### 5.5 平台原生解码（MethodChannel `scrcpy/decoder`）
- 方法：`init(width, height, sps, pps) -> textureId`、`feed(nalu, isKeyframe, ptsMs)`、`dispose()`。
- macOS：`VTDecompressionSession` → `CVPixelBuffer` → `FlutterTexture.copyPixelBuffer`。
- Windows：`IMFTransform` (H264 解码 MFT) → `ID3D11Texture2D` → `flutter::TextureVariant::GpuSurfaceTexture` 共享句柄。

### 5.6 打包产物
- macOS：`flutter build macos` + `create-dmg` → `.dmg`。
- Windows：`flutter build windows` + Inno Setup 或 MSIX → `.exe` / `.msix`。
- Linux（P3）：`flutter build linux` + `dpkg-deb` → `.deb`。

## 6. 关键文件清单
- 修改：`scrcpy_server/entry/src/main/module.json5`
- 修改：`scrcpy_server/entry/src/main/ets/entryability/EntryAbility.ets`、`pages/Index.ets`
- 新建：`scrcpy_server/entry/src/main/ets/scrcpyservice/{ScrcpyService,ScreenPipeline,TcpServer,Protocol,InputInjector}.ets`
- 新建：`scrcpy_server/entry/src/main/ets/bootreceiver/BootReceiver.ets`
- 新建：`scrcpy_client_flutter/`（整个 Flutter 工程）

## 7. 验证方案
1. 服务端：`hvigorw assembleHap` → `hdc install -r entry-default-signed.hap` → `hdc shell aa start -A ohos.want.action.home -b com.ohos.scrcpy.server`；`hdc shell hilog | grep ScrcpyService` 看启动日志。
2. 端口转发自检：`hdc fport tcp:5005 tcp:53535 && nc 127.0.0.1 5005`，能收到字节流（含 0x02 头）。
3. 客户端：`flutter run -d macos` → 选设备 → 屏幕镜像在 1s 内出现，分辨率与设备一致；点击/滑动设备有反馈。
4. 自启：设备重启后无需手动操作，客户端连上仍可看流。
5. hap 安装：UI 选 hap → 设备成功安装并能启动。
6. 多设备：插两台，设备列表能切换且互不串流。

## 8. 实施顺序
1. 服务端 TCP server + 心跳（打通通路）。
2. 客户端 hdc 包装 + 协议 + 假数据渲染（占位灰图）。
3. 服务端接入 screenCapture+VideoEncoder，输出真实 H264。
4. 客户端 macOS 原生解码 + Texture 上屏。
5. 控制注入（点击 → 滑动）。
6. hap 安装、自启动、亮度音量。
7. Windows 解码插件。
8. 打包脚本（macOS、windows, linux（P3））。
9. 终端面板（P2）。
10. 客户端Linux平台支持（P3）
