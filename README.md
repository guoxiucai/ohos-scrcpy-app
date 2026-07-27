# 鸿镜 HongJing

<p align="center">
  <img src="https://cos-pro-pub.cvtestatic.com/seewo-school/f368b60c-2998-72b8-ff98-4b283971f1af" width="128" alt="鸿镜 Logo"/>
</p>

<p align="center">
  <strong>面向 OpenHarmony 设备的实时投屏、远程控制与 HDC 调试工具</strong>
</p>

<p align="center">
  <a href="LICENSE"><img src="https://img.shields.io/badge/license-MIT-blue.svg" alt="MIT License"></a>
  <img src="https://img.shields.io/badge/version-1.0.2-brightgreen.svg" alt="Version 1.0.2">
  <img src="https://img.shields.io/badge/client-macOS%20%7C%20Windows-lightgrey.svg" alt="Client: macOS and Windows">
  <img src="https://img.shields.io/badge/device-OpenHarmony-orange.svg" alt="Device: OpenHarmony">
</p>

<p align="center">
  <a href="#功能特性">功能特性</a> ·
  <a href="#快速开始">快速开始</a> ·
  <a href="#工作原理">工作原理</a> ·
  <a href="#从源码构建">从源码构建</a> ·
  <a href="#签名与系统权限">签名与权限</a> ·
  <a href="#已知限制">已知限制</a>
</p>

---

鸿镜由运行在 OpenHarmony 设备上的系统 HAP 和运行在 macOS/Windows 上的 Flutter 桌面客户端组成。客户端通过 `hdc fport` 与设备端服务建立本地 TCP 通道，在同一连接中传输 H.264 视频流、设备状态、心跳和控制消息。

当前版本为 **1.0.2**。macOS 与 Windows 客户端已经支持投屏、控制、MP4 录制和 PNG 截图；Linux 客户端尚在规划中。

> 服务端使用屏幕采集和输入注入等系统能力，需要 Full SDK、系统应用签名以及设备权限白名单。普通应用签名无法直接使用全部功能。

## 效果展示

![主界面](https://cos-pro-pub.cvtestatic.com/seewo-school/1d824417-f8e2-8e14-e94c-ad435158fe58)
![主界面](https://cos-pro-pub.cvtestatic.com/seewo-school/d5181e88-5641-46e6-2902-b5c8af36f969)

## 功能特性

| 功能 | 说明 |
| --- | --- |
| 实时投屏 | 设备端 H.264 硬件编码，macOS 使用 VideoToolbox，Windows 使用 Media Foundation/D3D11 解码 |
| 录制视频 | 将接收的 H.264 码流封装为 MP4，自动保存到系统桌面 |
| 当前帧截图 | 从平台解码器获取当前画面并保存为 PNG |
| 鼠标与触控 | 单点触摸、鼠标按键、滚轮及坐标映射 |
| 键盘与文本输入 | 转发常用键盘事件，支持向设备当前焦点输入框发送 UTF-8 文本 |
| 设备控制 | 电源、返回、主页、音量和亮度控制 |
| 视频参数 | 运行时切换分辨率、码率和帧率；录制期间自动锁定相关参数 |
| 应用管理 | 通过客户端本地 HDC 安装 HAP、查看应用列表并卸载应用 |
| HDC 终端 | 内嵌 PTY 终端，可直接执行设备 Shell 命令 |
| USB/Wi-Fi 连接 | 使用 HDC 已发现的设备，不要求设备额外开放局域网端口 |

## 平台支持

| 组件 | 平台 | 状态 |
| --- | --- | --- |
| 设备端服务 | OpenHarmony 5.0+（API 15+） | 已支持 |
| 桌面客户端 | macOS | 已支持 |
| 桌面客户端 | Windows 10/11 | 已支持 |
| 桌面客户端 | Linux | 规划中，仅保留平台占位 |

设备需要提供 `OH_AVScreenCapture`，并且最好具有可用的 H.264 硬件编码器。H.264 初始化失败时服务端会尝试降级到 JPEG 投屏，但 MP4 录制仅支持 H.264 模式。

## 快速开始

### 1. 获取安装包

可以从 [GitHub Releases](https://github.com/guoxiucai/ohos-scrcpy-app/releases) 下载最新版本，也可以使用仓库中 `release_packages/<版本>/` 下的预编译文件：

| 文件 | 用途 |
| --- | --- |
| `OHScrcpyServer.hap` | OpenHarmony 设备端服务 |
| `HongJing-<版本>.dmg` | macOS 客户端 |
| `HongJing-Setup-<版本>.exe` | Windows 客户端安装程序 |

> 预编译 HAP 的签名必须被目标系统信任，并与设备权限白名单一致。不同厂商或不同系统镜像通常需要重新签名并更新白名单。

### 2. 安装设备端服务

确认 HDC 已经识别目标设备：

```bash
hdc list targets
hdc install -r OHScrcpyServer.hap
```

服务端监听设备本机的 `127.0.0.1:53535`，不直接监听设备局域网地址。

### 3. 启动桌面客户端

1. 通过 USB 或 HDC Wi-Fi 方式连接设备。
2. 启动鸿镜客户端。
3. 在设备列表中选择目标设备并点击连接。
4. 画面就绪后即可使用侧边栏进行控制、录制、截图、应用管理和文本输入。

客户端发布包内置 HDC 工具；源码开发时也会按系统 `PATH` 和常见 SDK 目录查找 HDC。

## 工作原理

```text
macOS / Windows 客户端
        │
        │ hdc fport tcp:<本机动态端口> tcp:53535
        ▼
127.0.0.1:<本机动态端口>
        │
        │ HDC 转发
        ▼
OpenHarmony 设备 127.0.0.1:53535
        │
        ├── OH_AVScreenCapture
        ├── H.264 VideoEncoder Surface
        ├── TCP 视频/状态/控制协议
        └── 输入事件与设备控制
```

基础协议帧格式为：

```text
4B type（大端）| 4B payload length（大端）| payload
```

- 设备端以 `ServiceExtensionAbility` 运行，无客户端连接时释放截屏和编码资源。
- H.264 采集 Surface 直接连接编码器 Surface，避免在 CPU 侧复制完整图像。
- 客户端通过 `hdc fport` 建立转发，不增加设备 LAN 直连协议。
- macOS 和 Windows 使用平台原生解码器，并通过 Flutter Texture 渲染。
- 开始录制时服务端重建 VideoEncoder，使录制码流从新的 SPS/PPS 和 IDR 开始；ScreenCapture 实例保持复用。

更完整的设计说明参见：

- [项目设计](docs/design.md)
- [服务端采集方案](docs/scrcpy_server_plan.md)
- [录制与截图设计](docs/recording_screenshot_design.md)
- [Windows 开发指南](docs/windows_dev_guide.md)
- [踩坑与经验记录](docs/lessons-learned.md)

## 从源码构建

### 获取源码

```bash
git clone https://github.com/guoxiucai/ohos-scrcpy-app.git
cd ohos-scrcpy-app
```

### 构建设备端服务

开发环境：

| 工具 | 要求 |
| --- | --- |
| DevEco Studio | 6.0 或兼容版本 |
| OpenHarmony SDK | Full SDK，当前工程 `compileSdkVersion` 为 23 |
| 兼容版本 | `compatibleSdkVersion` 为 15 |
| Native 工具链 | C++17，当前目标 ABI 为 `arm64-v8a` |

服务端使用系统 API，Public SDK 无法完成编译。请从 OpenHarmony 官方构建或发行渠道获取对应版本的 Full SDK，并确认 SDK 中包含项目引用的系统 API 声明。

macOS 默认构建命令：

```bash
cd scrcpy_server

/Applications/DevEco-Studio.app/Contents/tools/node/bin/node \
  /Applications/DevEco-Studio.app/Contents/tools/hvigor/bin/hvigorw.js \
  clean --mode module -p product=default assembleHap \
  --analyze=normal --parallel --incremental --daemon
```

构建产物默认位于：

```text
scrcpy_server/entry/build/default/outputs/default/OHScrcpyServer.hap
```

安装属于设备变更，请在确认签名和权限白名单正确后执行：

```bash
hdc install -r entry/build/default/outputs/default/OHScrcpyServer.hap
```

Windows 环境可以通过 DevEco Studio 构建，或将上述 Node 与 Hvigor 路径替换为本机安装路径。

### 构建 Flutter 客户端

基础环境：

- Flutter 3.22.1 或更高版本
- Dart 3.4 或更高版本
- macOS：Xcode 15 或更高版本
- Windows：Visual Studio 2022，安装“使用 C++ 的桌面开发”工作负载

安装依赖并运行检查：

```bash
cd scrcpy_client_flutter
flutter pub get
flutter analyze
flutter test
```

macOS：

```bash
flutter run -d macos
flutter build macos --release
```

Windows：

```powershell
flutter run -d windows
flutter build windows --release
```

打包脚本可能使用本机签名、公证或安装包工具，仅在完成本地环境配置后执行：

```bash
# macOS：生成 DMG
bash scripts/package_mac.sh
```

```powershell
# Windows：使用 Inno Setup 生成安装程序
powershell -ExecutionPolicy Bypass -File scripts\package_win.ps1
```

macOS 客户端当前关闭 App Sandbox，以便启动 HDC 子进程并建立本地 TCP 连接。

## 签名与系统权限

### 签名要求

服务端 Bundle 名称为：

```text
com.ohos.scrcpy.server
```

部署到自己的设备或系统镜像时：

1. 使用目标系统信任的应用证书和 Profile 重新签名。
2. Profile 的 `app-privilege-capabilities` 至少包含：

```text
AllowAppUsePrivilegeExtension
KeepAlive
AllowAppDesktopIconHide
```

3. Profile 的 `acls.allowed-acls` 至少包含：

```text
ohos.permission.CAPTURE_SCREEN
ohos.permission.EXEMPT_CAPTURE_SCREEN_AUTHORIZE
ohos.permission.INJECT_INPUT_EVENT
```

4. 将应用证书 SHA-256 指纹写入目标系统的应用能力和权限白名单。

> 不要把生产私钥、证书密码或设备专用签名材料提交到公开仓库。仓库中的配置路径只用于说明工程结构，发布者应使用自己的签名材料。

### 当前声明权限

以下内容以 [`scrcpy_server/entry/src/main/module.json5`](scrcpy_server/entry/src/main/module.json5) 为准：

| 权限 | 用途 |
| --- | --- |
| `ohos.permission.INTERNET` | TCP 服务与本地转发通信 |
| `ohos.permission.GET_WIFI_INFO` | 获取设备网络相关信息 |
| `ohos.permission.CUSTOM_SCREEN_CAPTURE` | 使用定制屏幕采集能力 |
| `ohos.permission.CAPTURE_SCREEN` | 执行系统屏幕采集 |
| `ohos.permission.EXEMPT_CAPTURE_SCREEN_AUTHORIZE` | 免除每次采集的交互式授权 |
| `ohos.permission.KEEP_BACKGROUND_RUNNING` | 服务后台运行 |
| `ohos.permission.START_ABILITIES_FROM_BACKGROUND` | 服务在必要时从后台启动 Ability |
| `ohos.permission.INJECT_INPUT_EVENT` | 注入触摸、鼠标和按键事件 |
| `ohos.permission.GET_INSTALLED_BUNDLE_LIST` | 查询可管理的已安装应用 |
| `ohos.permission.RUNNING_LOCK` | 获取运行锁 |
| `ohos.permission.ACCESS_NOTIFICATION_POLICY` | 调节设备音量策略 |

其中 `CAPTURE_SCREEN`、`EXEMPT_CAPTURE_SCREEN_AUTHORIZE` 和 `INJECT_INPUT_EVENT` 属于受限系统权限，需要签名 Profile ACL；`CUSTOM_SCREEN_CAPTURE` 和 `GET_INSTALLED_BUNDLE_LIST` 等用户授权权限可通过系统白名单预授权。

仓库当前签名材料对应的白名单示例如下；如果替换签名证书，必须将 `app_signature` 同步替换为新证书的 SHA-256 指纹：

```json
{
  "bundleName": "com.ohos.scrcpy.server",
  "app_signature": ["8E93863FC32EE238060BF69A9B37E2608FFFB21F93C862DD511CBAC9F30024B5"],
  "allowAppUsePrivilegeExtension": true,
  "keepAlive": true,
  "allowAppDesktopIconHide": true
}
```

```json
{
  "bundleName": "com.ohos.scrcpy.server",
  "app_signature": ["8E93863FC32EE238060BF69A9B37E2608FFFB21F93C862DD511CBAC9F30024B5"],
  "permissions": [
    {
      "name": "ohos.permission.CUSTOM_SCREEN_CAPTURE",
      "userCancellable": false
    },
    {
      "name": "ohos.permission.GET_INSTALLED_BUNDLE_LIST",
      "userCancellable": false
    }
  ]
}
```

实际文件位置和白名单格式可能随系统版本或厂商镜像变化，请以目标系统源码及安全策略为准。

## 已知限制

1. `OH_AVScreenCapture` 可能无法采集 Surface 类型 XComponent 的内容，例如部分游戏或视频播放器；对应区域可能显示为黑色。
2. 服务端依赖系统签名、Full SDK 和受限权限白名单，预编译 HAP 不保证可以直接安装到所有 OpenHarmony 设备。
3. 不同芯片的 H.264 硬件编码器能力存在差异。H.264 初始化失败时会降级为 JPEG 投屏，JPEG 模式不支持 MP4 录制。
4. Linux 客户端尚未实现原生解码、录制、截图和渲染。
5. 当前自动化测试覆盖有限，跨平台媒体功能仍建议在真实设备上验证。

## 仓库结构

```text
.
├── scrcpy_server/                 # OpenHarmony 系统 HAP
│   ├── AppScope/app.json5         # Bundle、版本和 keepAlive
│   ├── build-profile.json5        # SDK、产品和签名配置
│   └── entry/src/main/
│       ├── module.json5           # Ability 与权限
│       ├── ets/scrcpyservice/     # 服务生命周期和控制协议
│       └── cpp/                   # TCP、屏幕采集、编码和 NAPI
├── scrcpy_client_flutter/         # macOS/Windows Flutter 客户端
│   ├── lib/                       # HDC、协议、状态和 UI
│   ├── macos/Runner/              # VideoToolbox 与 AVFoundation
│   ├── windows/runner/            # Media Foundation、D3D11 与 Media Sink
│   └── scripts/                   # 平台打包脚本
├── docs/                          # 架构、平台设计和验证记录
├── images/                        # README 与应用图片
└── release_packages/              # 历史预编译发布包
```

## Roadmap

- [ ] Linux 客户端原生解码、渲染、录制与截图
- [ ] 探索 DisplayManager 显存读取方案，改善 Surface XComponent 采集限制
- [ ] 扩充协议、录制封装和跨平台集成测试
- [ ] 持续验证更多 OpenHarmony 设备和硬件编码器

## 参与贡献

欢迎提交 Issue 和 Pull Request。开始贡献前请阅读 [CONTRIBUTING.md](CONTRIBUTING.md)。

提交问题时建议附上：

- OpenHarmony 版本、设备型号和芯片平台
- 客户端操作系统与鸿镜版本
- USB/Wi-Fi 连接方式
- 可复现步骤、日志和必要的截图

提交代码前至少完成与改动范围相符的静态检查和构建验证。请勿在 Issue、日志或 PR 中上传私钥、密码、设备证书或内部网络信息。

## 致谢与说明

本项目受 [Genymobile/scrcpy](https://github.com/Genymobile/scrcpy) 的设计思路启发，并基于 OpenHarmony API 重新实现设备端和桌面端通信链路。本项目与 Genymobile/scrcpy 项目不存在隶属关系。

项目开发过程中使用了 AI 辅助工具；功能行为、兼容性和安全边界以当前源码与实际验证结果为准。

## 开源协议

本项目基于 [MIT License](LICENSE) 开源。
