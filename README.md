# 鸿镜 HongJing

<p align="center">
  <img src="https://cos-pro-pub.cvtestatic.com/seewo-school/f368b60c-2998-72b8-ff98-4b283971f1af" width="128" alt="鸿镜 Logo"/>
</p>

<p align="center">
  <a href="LICENSE"><img src="https://img.shields.io/badge/license-MIT-blue.svg" alt="License: MIT"></a>
  <img src="https://img.shields.io/badge/platform-macOS%20%7C%20Windows-lightgrey.svg" alt="Platform">
  <a href="https://github.com/guoxiucai/ohos-scrcpy-app/releases"><img src="https://img.shields.io/github/v/release/guoxiucai/ohos-scrcpy-app" alt="Release"></a>
</p>

<p align="center">
  <strong>OpenHarmony 设备实时投屏与远程控制工具</strong>
</p>

<p align="center">
  <a href="#快速上手">快速上手</a> •
  <a href="#功能特性">功能特性</a> •
  <a href="#效果演示">效果演示</a> •
  <a href="#从源码构建">从源码构建</a> •
  <a href="#已知限制">已知限制</a> •
  <a href="#roadmap">Roadmap</a>
</p>

---

鸿镜是一个面向 OpenHarmony 设备的投屏调试工具。Flutter 桌面客户端通过 `hdc fport` 端口转发与设备上常驻的系统服务通信，实时镜像屏幕并提供触控注入、应用管理、终端模拟等控制功能。

本项目方案设计和编码主要通过`Claude Code`实现，UI采用`ui-ux-pro-max`美化。

本项目的AI过程文档参考`docs`目录和`spec_doc`目录。

## 效果演示

![主界面](https://cos-pro-pub.cvtestatic.com/seewo-school/1d824417-f8e2-8e14-e94c-ad435158fe58)
![主界面](https://cos-pro-pub.cvtestatic.com/seewo-school/d5181e88-5641-46e6-2902-b5c8af36f969)
<!-- 更多截图或 GIF，在此补充 -->

## 功能特性

| 功能 | 说明 |
|------|------|
| 🖥️ 实时投屏 | H.264 硬件编码 + 平台原生硬件解码，低延迟流畅画面 |
| 👆 触控注入 | 鼠标操控设备触摸屏（支持单点触摸） |
| 📱 应用管理 | HAP 安装 / 卸载、查看已安装应用列表 |
| 🔊 音量控制 | 远程调节设备音量 |
| 🔆 亮度控制 | 远程调节设备亮度 |
| ⌨️ 功能键 | 返回、主页、最近任务等系统按键模拟 |
| 💻 模拟终端 | 内嵌 hdc shell 终端，直接操作设备命令行 |
| 🎛️ 动态参数 | 运行时调整分辨率、码率、帧率 |

## 支持平台

**服务端（设备侧）：**
- OpenHarmony 5.0+（API 15+）
- 支持 H.264 硬件编码的开发板/设备（不支持时自动降级为 JPEG 模式）

**客户端（PC 侧）：**
- macOS（VideoToolbox 硬件解码）
- Windows（MediaFoundation 硬件解码）
- Linux（计划中）

## 快速上手

### 1. 下载预编译包

从 [Releases](https://github.com/guoxiucai/ohos-scrcpy-app/releases) 页面或 `release_packages/` 目录下载：

| 文件 | 说明 |
|------|------|
| `OHScrcpyServer.hap` | 设备端服务 |
| `HongJing-x.x.x.dmg` | macOS 客户端 |
| `HongJing-Setup-x.x.x.exe` | Windows 客户端 |

### 2. 安装服务端

```bash
# 连接设备后安装 HAP
hdc install -r OHScrcpyServer.hap
```

> ⚠️ 服务端需要系统应用签名和权限白名单配置，详见[服务端签名与权限白名单](#服务端签名与权限白名单)。

### 3. 启动客户端

确保电脑与 OpenHarmony 设备已经通过 HDC 连接（USB或WiFi都可以）。

打开客户端应用 → 选择已连接的设备 → 点击连接，即可看到实时投屏画面。

客户端已经内置HDC工具，可以直接运行。（本地开发期间需要确保 PC PATH 上 `hdc` 命令可用）。

## 项目架构

```
┌────────────────────┐         hdc fport          ┌────────────────────────┐
│   OpenHarmony 设备  │◄─────────────────────────►│     PC 客户端 (Flutter)  │
│                    │      TCP over USB/网络       │                        │
│  ScrcpyService     │                            │  hdc CLI 包装           │
│  ├─ ScreenCapture  │  ──── H.264 视频流 ────▶   │  ├─ 协议解析            │
│  ├─ VideoEncoder   │                            │  ├─ 原生硬件解码         │
│  ├─ TcpServer      │  ◄─── 控制指令 ────────    │  ├─ Flutter Texture 渲染 │
│  └─ InputInjector  │                            │  └─ UI（投屏/终端/侧栏） │
└────────────────────┘                            └────────────────────────┘
```

- **服务端**：以 `ServiceExtensionAbility` 形式常驻运行，通过 NAPI 调用 OH Native 截屏和编码 API，截屏 Surface 直连编码器 Surface 实现零拷贝
- **客户端**：Flutter 桌面应用，通过 `hdc fport` 端口转发建立 TCP 连接，使用平台原生解码器（MethodChannel）硬件解码 H.264 流

### 服务端录屏方案

服务端录屏存在两种技术路线，各有适用场景：

| | 方案一：DisplayManager 显存直读 | 方案二：OH_AVScreenCapture（当前采用） |
|---|---|---|
| 产物形态 | 系统可执行文件（需源码编译进固件） | 标准 HAP 应用包 |
| 编码方式 | 截屏 RGBA → CPU 转 NV12 → 硬编码 | 截屏 Surface 直连编码器（零拷贝） |
| Surface XComponent | ✅ 可采集（游戏、视频播放器） | ❌ 不可采集 |
| 部署更新 | 需随固件 OTA 更新 | 可独立安装/更新 HAP |
| 开发门槛 | 需 OH 完整系统源码树 | SDK + NDK 即可 |

当前项目采用**方案二**，优势是开发部署简单、Surface 零拷贝延迟低；局限是无法采集 Surface 类型 XComponent 内容。方案一作为未来 Roadmap 规划，用于解决游戏/视频播放器投屏需求。

> 两种方案的完整设计对比见 [服务端录屏架构设计文档](docs/scrcpy_server_plan.md)。

## 从源码构建

### 服务端签名与权限白名单

服务端以系统应用身份运行，需要完成以下配置：

#### 替换签名配置

将 `scrcpy_server/signature/scrcpy_server.json` 替换为你自己证书签发的版本。`bundle-info.bundle-name` 保持 `com.ohos.scrcpy.server` 不变，`app-privilege-capabilities` 需包含：

```
AllowAppUsePrivilegeExtension
KeepAlive
AllowAppDesktopIconHide
```

#### 写入系统白名单（需 root）

设备上需写入两个系统配置文件，参考 `scrcpy_server/signature/` 目录下的模板。如果你自己替换了签名证书，需要将 `app_signature` 换成你自己证书的指纹：

**`/system/etc/app/install_list_capability.json`** — 追加：

```json
{
  "bundleName": "com.ohos.scrcpy.server",
  "app_signature": ["8E93863FC32EE238060BF69A9B37E2608FFFB21F93C862DD511CBAC9F30024B5"],
  "allowAppUsePrivilegeExtension": true,
  "keepAlive": true,
  "allowAppDesktopIconHide": true
}
```

**`/system/etc/app/install_list_permissions.json`** — 追加：

```json
{
  "bundleName": "com.ohos.scrcpy.server",
  "app_signature": ["8E93863FC32EE238060BF69A9B37E2608FFFB21F93C862DD511CBAC9F30024B5"],
  "permissions": [
    { "name": "ohos.permission.CUSTOM_SCREEN_CAPTURE",          "userCancellable": false },
    { "name": "ohos.permission.START_ABILITIES_FROM_BACKGROUND","userCancellable": false },
    { "name": "ohos.permission.CAPTURE_SCREEN",                 "userCancellable": false },
    { "name": "ohos.permission.SYSTEM_FLOAT_WINDOW",            "userCancellable": false },
    { "name": "ohos.permission.EXEMPT_CAPTURE_SCREEN_AUTHORIZE","userCancellable": false },
    { "name": "ohos.permission.GET_INSTALLED_BUNDLE_LIST",      "userCancellable": false }
  ]
}
```

> 其中 `ohos.permission.EXEMPT_CAPTURE_SCREEN_AUTHORIZE` 从 API 15 起提供，低版本可去除此项（但每次截屏需用户手动授权）。

写入后重启设备使白名单生效。

### 服务端开发环境

| 工具 | 版本 | 说明 |
|------|------|------|
| DevEco Studio | 6.0+ | OpenHarmony 应用 IDE |
| OpenHarmony SDK | API 20 | `compileSdkVersion: 20`，`compatibleSdkVersion: 15` |
| Full SDK | 对应 API 版本 | **必须手动替换**，见下方说明 |

#### Full SDK 替换

服务端使用了 `ohos.permission.CAPTURE_SCREEN`、`inputEventClient.injectTouchEvent` 等系统 API，这些仅在 **Full SDK** 中提供，Public SDK 中不包含。**必须手动下载 Full SDK 并替换。**

**获取 Full SDK：**

通过 [OpenHarmony CI 数字化平台](https://dcp.openharmony.cn/workbench/cicd/dailybuild/dailylist) 查询并下载对应版本的 `ohos-sdk-full` 包。

OpenHarmony 6.0 Full SDK 直接下载：
- macOS (ARM)：[ohos-sdk-full_6.0 Mac-M1](https://cidownload.openharmony.cn/version/Master_Version/OpenHarmony_6.0.0.49/20260227002444/20260227002444-L2-SDK-MAC-M1-FULL.tar.gz)
- Windows / Linux：[ohos-sdk-full_6.0 Release](https://cidownload.openharmony.cn/version/Master_Version/OpenHarmony_6.0.0.49/20260225_043115/version-Master_Version-OpenHarmony_6.0.0.49-20260225_043115-ohos-sdk-full_6.0-Release.tar.gz)

**替换步骤：**

1. 下载并解压 Full SDK
2. 替换 DevEco Studio 的 SDK 目录：
   - macOS：`~/Library/OpenHarmony/Sdk/<version>/`
   - Windows：`%LOCALAPPDATA%\OpenHarmony\Sdk\<version>\`
3. 重启 DevEco Studio，确认 `ets/api/` 下存在 `@ohos.multimodalInput.inputEventClient.d.ts` 等系统 API 声明文件

#### 编译

```bash
cd scrcpy_server

# macOS
/Applications/DevEco-Studio.app/Contents/tools/node/bin/node \
  /Applications/DevEco-Studio.app/Contents/tools/hvigor/bin/hvigorw.js \
  clean --mode module -p product=default assembleHap \
  --analyze=normal --parallel --incremental --daemon

# 安装到设备
hdc install -r entry/build/default/outputs/default/entry-default-signed.hap
```

Windows 环境下将路径替换为 DevEco Studio 的 Windows 安装路径。

### 客户端开发环境

| 工具 | 版本 | 说明 |
|------|------|------|
| Flutter | 3.22.1+ | 桌面应用框架 |
| Dart | 3.4+ | 随 Flutter 一起安装 |
| hdc | — | 设备调试工具，需在系统 PATH 中可用 |

#### macOS

需要 Xcode 15+。项目已关闭 App Sandbox（允许 hdc 进程调用和 TCP 连接）。

```bash
cd scrcpy_client_flutter
flutter pub get
flutter run -d macos

# 发布构建
flutter build macos --release
bash scripts/package_mac.sh        # 生成 .dmg（支持签名+公证）
```

#### Windows

需要 Visual Studio 2022+（含 C++ 桌面开发工作负载）。

```bash
cd scrcpy_client_flutter
flutter pub get
flutter run -d windows

# 发布构建
flutter build windows --release
powershell -ExecutionPolicy Bypass -File scripts\package_win.ps1  # 生成安装包（Inno Setup）
```

#### Linux

> Linux 版本正在计划中，尚未完成视频解码和渲染适配。欢迎贡献！

## 已知限制

1. **H.264 硬件编码器兼容性**：部分开发板（如 RK 系列芯片）的编码器不支持 RGBA→NV12 自动转换，会自动降级为 JPEG 模式（帧率约 10fps），画面有明显卡顿。

2. **Surface 类型 XComponent 不可采集**：`OH_AVScreenCapture` 无法获取 Surface 类型 XComponent 的内容（如游戏画面、视频播放器），这些区域在投屏画面中显示为黑色。这是 OpenHarmony 系统录屏 API 的已知限制。

3. **录屏免授权需要 API 15+**：`ohos.permission.EXEMPT_CAPTURE_SCREEN_AUTHORIZE` 从 API 15 起提供。低于 API 15 的设备每次启动截屏需用户手动点击"同意"授权弹窗。

## Roadmap

- [ ] 服务端支持 DisplayManager 显存直读方案，解决 Surface 类型 XComponent 不可采集问题
- [ ] 客户端支持 Linux 平台
- [ ] 客户端文本发送 / 键盘实时输入功能
- [ ] Flutter 框架版本升级跟进

## 仓库结构

```
ohos-scrcpy-app/
├── scrcpy_server/             # OpenHarmony 系统服务端
│   ├── AppScope/app.json5     # 应用配置（bundleName、keepAlive）
│   ├── signature/             # 签名模板文件
│   └── entry/src/main/
│       ├── module.json5       # mainElement = ScrcpyService
│       ├── cpp/               # NAPI 模块（截屏、编码、TCP）
│       └── ets/scrcpyservice/ # ArkTS 服务层（生命周期、控制分发）
├── scrcpy_client_flutter/     # Flutter 桌面客户端
│   ├── lib/
│   │   ├── hdc/               # hdc CLI 包装
│   │   ├── net/               # 协议编解码 + TCP 客户端
│   │   ├── decoder/           # 平台原生解码抽象层
│   │   ├── state/             # 中央状态管理
│   │   └── ui/                # 界面组件
│   ├── macos/Runner/          # macOS VideoToolbox 解码插件
│   ├── windows/runner/        # Windows MediaFoundation 解码插件
│   └── scripts/               # 打包脚本
├── release_packages/          # 预编译包
└── docs/                      # 技术设计文档
```

## 贡献指南

欢迎提交 Issue 和 Pull Request！

- **Bug 报告**：请附上设备型号、OH 版本、客户端平台、复现步骤
- **功能建议**：请先开 Issue 讨论
- **代码贡献**：Fork → 新建分支 → 提交 PR，确保 `flutter analyze` 和服务端编译通过

## 致谢

本项目的设计思路受 [scrcpy](https://github.com/Genymobile/scrcpy)（Android 投屏工具）启发，针对 OpenHarmony 平台的 API 和架构进行了全新实现。

## 开源协议

本项目采用 [MIT License](LICENSE) 开源。
