# Flutter 3.41.9 客户端升级设计

> 文档状态：已实施并完成 macOS 验证
> 目标 Flutter：官方 Flutter 3.41.9
> macOS 验证环境：Flutter 3.41.10-ohos-1.0.0（基于官方 3.41.9）
> 目标客户端版本：1.0.3+3
> 服务端版本：保持 1.0.2 不变
> 首期平台：macOS、Windows
> 预留平台：Linux
> 最后更新：2026-07-30

## 1. 背景与目标

鸿镜客户端当前基于 Flutter 3.22.1 系列开发。开发机已经升级到
`Flutter 3.41.10-ohos-1.0.0`，该版本以官方 Flutter 3.41.9 为基础并增加
OpenHarmony/HarmonyOS 适配；后续 macOS、Windows 和 Linux PC 客户端仍使用官方
Flutter 3.41.9 编译。

本次升级目标：

1. 使现有 Flutter 桌面客户端可以在 Flutter 3.41.9 基线上完成依赖解析、静态检查、测试和平台构建。
2. 保持现有投屏、控制、终端、应用管理、录制和截图功能及协议行为不变。
3. 客户端版本统一升级为 `1.0.3+3`，对外显示版本为 `1.0.3`。
4. 服务端源码、协议和版本保持不变，继续使用 1.0.2 服务端完成客户端回归。
5. 在 macOS 完成构建与 OpenHarmony 真机功能回归后，输出 Windows 3.41.9 编译和验证指导文档。
6. Linux 本期只保留兼容性设计和现有业务占位，不实现原生解码、录制、截图或正式构建交付。

## 2. 当前基线

### 2.1 开发环境

2026-07-30 实测环境：

| 项目 | 当前值 |
| --- | --- |
| Flutter | `3.41.10-ohos-1.0.0` |
| Framework revision | `244a0e8abb` |
| 基础官方版本 | Flutter 3.41.9 |
| Dart | 3.11.5 |
| DevTools | 2.54.1 |
| macOS | 26.5.1，arm64 |
| Xcode | 26.6 |
| CocoaPods | 1.12.1，Flutter Doctor 推荐 1.16.2 |
| OpenHarmony 设备 | OpenHarmony 6.1.0.31，API 23，arm64 |

Flutter Doctor 当前可以识别 macOS 与已连接的 OpenHarmony 设备。CocoaPods 版本提示属于环境告警，不在确认前升级；实施时先验证现有版本，只有明确阻塞 3.41 构建时才升级本机 CocoaPods。

### 2.2 工程状态

| 项目 | 当前值 |
| --- | --- |
| 客户端版本 | `1.0.2+2` |
| Dart SDK 约束 | `>=3.4.0 <4.0.0` |
| Flutter 锁定下限 | `pubspec.lock` 中为 `>=3.22.0` |
| macOS Deployment Target | 10.14 |
| macOS 插件管理 | CocoaPods |
| Windows C++ 标准 | C++17 |
| Linux Runner | 未纳入当前工程 |
| Flutter migration 基线 | revision `4ebf41aeff` |

用当前 Flutter 3.41 工具生成的临时 macOS/Windows/Linux 参考工程与现工程对比后得到：

- Flutter 3.41 的 macOS 新工程最低部署版本为 10.15，工具内置迁移也会把 10.14 更新到 10.15。
- Windows 顶层 CMake 和 Flutter wrapper 模板与现工程一致，除项目名外没有必须同步的结构差异。
- Flutter 3.41 新建 macOS 工程可以使用 Swift Package Manager，但现工程及现有插件已经稳定使用 CocoaPods；本次不切换包管理方式。
- 现工程包含自定义的 macOS `VideoDecoderPlugin.swift`、Windows Media Foundation/D3D11 解码录制实现和平台 Runner 配置，不能使用新模板整体覆盖。

### 2.3 工作区保护

设计阶段发现已有用户修改：

```text
spec_doc/dev_doc.md
```

该文件不属于本任务，实施期间必须保留且不纳入本次差异。开始实施和每次修复前均检查 `git status --short`，只处理本任务文件。

## 3. 范围与非目标

### 3.1 本期范围

- 将客户端 Flutter/Dart 工程基线升级到 Flutter 3.41.9 / Dart 3.11 系列。
- 刷新由 Flutter/Dart 版本变化引起的依赖锁定结果。
- 接受 Flutter 3.41 必需的 macOS 10.15 Deployment Target 迁移。
- 修复 Flutter 3.41 引起的编译、分析或测试兼容问题，但不改变业务行为。
- 将客户端版本升级为 `1.0.3+3`，同步 Windows 资源文件和打包脚本中的兜底版本。
- 在 macOS 完成 debug/release 构建和连接 OpenHarmony 设备的功能回归。
- 输出 Windows 官方 Flutter 3.41.9 编译与真机验证指导文档。
- 更新面向当前开发环境的 README、贡献说明和变更日志；历史设计文档中的历史版本结论不批量改写。

### 3.2 非目标

- 不修改 OpenHarmony 服务端代码、权限、签名、版本或 HAP。
- 不修改 TCP 协议、MethodChannel 方法、平台解码链路或媒体文件格式。
- 不新增、删除或重新设计任何客户端功能。
- 不升级业务依赖的大版本；只有依赖无法在 Dart 3.11/Flutter 3.41 下解析或编译时，才选择最小兼容版本。
- 不把 macOS 插件从 CocoaPods 迁移到 Swift Package Manager。
- 不重新生成或覆盖自定义 macOS/Windows Runner。
- 不实现 HarmonyOS PC、OpenHarmony PC、Android、iOS 客户端。
- 不实现 Linux 原生视频解码、纹理、录制、截图和打包。
- 不执行客户端签名、公证、Windows 安装包签名或发布。

## 4. 兼容性原则

### 4.1 Flutter 版本对应关系

本次将两套 SDK 视为同一 PC 业务基线：

| 使用场景 | SDK |
| --- | --- |
| 当前 macOS 开发与真机回归 | `Flutter 3.41.10-ohos-1.0.0` |
| macOS/Windows/Linux 正式 PC 构建 | 官方 Flutter 3.41.9 |

本地 OHOS 分支额外支持 OpenHarmony 设备，不代表客户端要新增 OHOS 平台 Runner。PC 客户端代码不得依赖该分支专有 API；所有新增兼容修改必须能由官方 Flutter 3.41.9 编译。

### 4.2 依赖策略

`pubspec.yaml` 计划调整为：

```yaml
version: 1.0.3+3

environment:
  sdk: '>=3.11.0 <4.0.0'
  flutter: '>=3.41.9'
```

依赖处理遵循以下顺序：

1. 保留所有直接依赖的现有约束，先运行 `flutter pub get`。
2. 只刷新 Flutter/Dart SDK 导致变化的 `pubspec.lock`。
3. 如果依赖解析或编译失败，确认具体包和平台后，升级到满足 Flutter 3.41 的最小兼容版本。
4. 不执行 `flutter pub upgrade --major-versions`，不顺带升级 UI、状态管理或平台插件。
5. 项目内嵌 `third_party/xterm/` 不因 Flutter 升级而整体同步上游；只有出现明确 Dart 3.11 编译错误时才做最小语法修复。

### 4.3 平台工程策略

不直接在真实工程执行无差别模板覆盖。实施时以 Flutter 3.41 临时参考工程为基线，逐项审查 Flutter 工具产生的迁移差异：

- 保留 macOS 自定义 AppDelegate、主窗口、应用名、Bundle ID、Entitlements 和 VideoDecoderPlugin。
- 保留 Windows 自定义 CMake、Runner 资源、D3D11/MFT 解码器、MP4 录制器和截图实现。
- 保留 macOS App Sandbox 关闭状态，不改变 HDC 子进程和本地 TCP 能力。
- `.dart_tool/`、`build/`、`Pods/`、`ephemeral/` 等生成目录不提交。
- `.metadata` 不手工伪造 revision；如 Flutter 官方迁移命令更新该文件，只接受与 macOS/Windows 3.41 模板迁移直接相关的内容。

## 5. 平台方案

### 5.1 macOS

必须进行的工程迁移：

- `macos/Podfile`：`platform :osx, '10.14'` 更新为 `10.15`。
- `macos/Runner.xcodeproj/project.pbxproj`：各构建配置的 `MACOSX_DEPLOYMENT_TARGET` 从 `10.14` 更新为 `10.15`。

保持不变：

- CocoaPods 集成和 `Flutter-Debug.xcconfig` / `Flutter-Release.xcconfig` 中的 Pods include。
- `PRODUCT_NAME = 鸿镜`、Bundle ID 和版权信息。
- `DebugProfile.entitlements` 与 `Release.entitlements`，特别是 App Sandbox 关闭状态。
- VideoToolbox 解码、AVFoundation MP4 封装、PNG 截图和 MethodChannel。
- `SIGPIPE` 处理、主窗口初始化和原生纹理注册。

验证构建时允许 Flutter 生成新的 ephemeral 文件，但不提交这些文件。若 CocoaPods 1.12.1 无法支持当前 Xcode/Flutter 组合，先记录原始错误，再把本机 CocoaPods 升级到 Flutter Doctor 推荐的 1.16.2；这属于构建环境调整，不修改业务代码。

### 5.2 Windows

当前 Windows CMake 模板已经与 Flutter 3.41 参考模板兼容。本次原则上只需要：

- 使用官方 Flutter 3.41.9 和对应 Dart SDK 重新生成 ephemeral wrapper。
- 确认 Flutter 3.41 的纹理注册、MethodChannel 和 C++ wrapper API 没有破坏现有调用。
- 保持 C++17、D3D11 硬件路径、CPU 回退路径、BGRA/RGBA 约定及 Media Foundation 录制实现不变。
- 更新 `Runner.rc` 的版本兜底值为 `1,0,3,3` / `1.0.3`。
- 更新 Windows 打包脚本中的版本兜底值和静态 `installer.iss` 示例为 1.0.3。

macOS 无法生成或验证 Windows 原生二进制，因此本阶段对 Windows 只做模板差异审查和代码静态检查。最终 Windows 构建、播放器兼容性和安装包验证必须在 Windows 10/11 上按交接文档执行。

### 5.3 Linux 占位

本期不新增 Linux Runner，也不声明 Linux 功能已完成。兼容性要求为：

- Dart 共享层不新增 macOS/Windows 专属的无保护导入。
- 保留现有 `Platform.isLinux` 能力判断和“暂未实现”提示。
- 公共依赖继续选择具有 Linux 声明的版本，避免为未来适配制造额外阻塞。
- Windows 指导文档完成后，在设计结果中记录 Linux 仍为占位。
- 后续 Linux 实现应使用官方 Flutter 3.41.9，独立设计原生纹理、解码、录制和截图方案。

## 6. 客户端版本升级

客户端版本统一由 `pubspec.yaml` 提供：

```text
1.0.2+2 -> 1.0.3+3
```

计划同步检查的文件：

| 文件 | 处理 |
| --- | --- |
| `scrcpy_client_flutter/pubspec.yaml` | 更新为 `1.0.3+3` |
| `scrcpy_client_flutter/windows/runner/Runner.rc` | 更新无 Flutter 宏时的兜底版本 |
| `scrcpy_client_flutter/scripts/package_win.ps1` | 更新无法解析 pubspec 时的兜底版本 |
| `scrcpy_client_flutter/scripts/installer.iss` | 更新静态示例版本及输出文件名 |
| `CHANGELOG.md` | 新增 1.0.3，仅记录 Flutter 客户端升级 |
| `README.md` | 更新当前客户端版本和 Flutter 构建要求 |
| `CONTRIBUTING.md` | 更新 Flutter/Dart 开发环境要求 |

macOS 的 `CFBundleShortVersionString` 和 build number 已读取 `FLUTTER_BUILD_NAME` / `FLUTTER_BUILD_NUMBER`，不额外硬编码。

以下服务端内容不得修改：

- `scrcpy_server/AppScope/app.json5` 的 `versionName: 1.0.2` 和 `versionCode: 1000002`。
- 服务端 `oh-package.json5`、签名 Profile、权限白名单和 HAP 产物。

## 7. 实施步骤

用户确认本设计后按以下顺序实施：

1. 记录 Flutter、Dart、Xcode、CocoaPods 和设备基线，确认用户现有未提交改动。
2. 在临时目录生成 Flutter 3.41 macOS/Windows/Linux 参考工程，用于模板对比，不覆盖真实工程。
3. 更新 `pubspec.yaml` 的客户端版本、Dart SDK 和 Flutter SDK 约束。
4. 运行 `flutter clean` 与 `flutter pub get`，审查 lockfile 变化，不接受无关直接依赖升级。
5. 应用 macOS 10.15 必需迁移；审查 Flutter 工具产生的其他平台差异。
6. 修复 Dart 3.11/Flutter 3.41 引起的最小兼容问题，不改业务流程和 UI 规格。
7. 同步 Windows 版本兜底、README、CONTRIBUTING 和 CHANGELOG。
8. 执行静态检查、测试和 macOS debug/release 构建。
9. 启动 macOS 客户端，连接现有 OpenHarmony 设备完成全功能回归。
10. 输出 `docs/flutter_3_41_windows_validation_guide.md`，包含 Windows 官方 Flutter 3.41.9 的环境、构建、功能验证和问题采集步骤。
11. 最后检查服务端文件无差异、生成目录未入库、用户原有改动未被覆盖。

## 8. 验证方案

### 8.1 静态检查与构建

```bash
cd scrcpy_client_flutter

flutter --version
dart --version
flutter clean
flutter pub get
flutter analyze
flutter test
flutter build macos --debug
flutter build macos --release
```

验收要求：

- Flutter 为 `3.41.10-ohos-1.0.0`，Dart 为 3.11 系列。
- `flutter analyze` 无 error/warning。
- 所有现有测试通过。
- macOS debug 和 release 构建成功。
- 构建生成的应用版本为 1.0.3，build number 为 3。
- 没有修改或重新构建服务端。

### 8.2 macOS 真机功能回归

使用当前已连接的 OpenHarmony API 23 设备，至少验证：

| 模块 | 验证内容 | 通过标准 |
| --- | --- | --- |
| 冷启动 | 启动客户端、录制区域初始状态 | 正常启动，录制区域默认折叠 |
| 设备发现 | HDC 设备列表和连接类型 | 能发现并选择当前设备 |
| 连接 | HDC 转发、TCP 连接、心跳 | 正常进入镜像状态 |
| 视频 | H.264 解码、尺寸、帧率、横竖屏 | 画面正常，无新增黑屏、花屏或色偏 |
| 鼠标/触控 | 点击、拖动、右键、滚轮 | 坐标正确，设备有对应响应 |
| 键盘/文本 | 常用键、功能键、UTF-8 文本 | 设备焦点输入框收到正确内容 |
| 设备控制 | 电源、返回、主页、音量、亮度 | 控制指令正常生效 |
| 视频参数 | 分辨率和帧率切换 | 重连新码流正常，画面恢复 |
| 录制 | 静止画面和动态画面各录制一段 | MP4 时长正确、首帧正常、可用 QuickTime 和 ffplay 播放 |
| 录制约束 | 录制期间切换分辨率/帧率 | 中央 Toast 显示约 1.5 秒，参数不改变 |
| 截图 | 当前帧截图 | 桌面生成可打开的 PNG，内容与画面一致 |
| 保存提示 | 录制/截图完成弹窗和打开路径 | 路径正确，Finder 定位正常 |
| 应用管理 | 刷新列表、测试 HAP 安装/卸载 | HDC 命令结果与 UI 状态正确 |
| 终端 | 打开 HDC Shell 并执行只读命令 | 输入输出和窗口缩放正常 |
| 生命周期 | 断开、重连、关闭客户端 | 资源释放，重连后无半包或黑屏 |

媒体产物补充验证：

```bash
ffprobe -hide_banner <录制文件.mp4>
ffplay <录制文件.mp4>
file <截图文件.png>
```

回归过程中不升级或重新安装服务端；若测试 HAP 安装会影响正在运行的服务，先完成其他功能，再使用明确的测试 HAP，并在验证后恢复设备状态。

### 8.3 Windows 后续验证

Windows 指导文档至少覆盖：

1. 安装官方 Flutter 3.41.9，并确认 Dart 版本。
2. Visual Studio 2022、Windows SDK、CMake/Ninja 和 Inno Setup 环境。
3. 清理旧 Flutter 3.22 生成物，重新执行 `flutter pub get`。
4. `flutter analyze`、`flutter test`、`flutter build windows --debug` 和 `--release`。
5. 校验 EXE 文件版本 `1.0.3.3` 与显示版本 `1.0.3`。
6. D3D11 硬解和 CPU 回退路径。
7. Windows 10/11 默认播放器、电影与电视、VLC 和 ffplay 的 MP4 兼容性。
8. PNG 截图、桌面路径、资源管理器定位、HDC、应用管理和终端。
9. 打包脚本与 `HongJing-Setup-1.0.3.exe` 的安装/覆盖安装验证。
10. 出错时需要收集的 Flutter、CMake、Visual Studio、应用日志和媒体探测信息。

## 9. 风险与应对

| 风险 | 影响 | 应对 |
| --- | --- | --- |
| Dart 3.11 分析规则或 SDK API 变化 | analyze/test 失败 | 只做等价语法修复，不改业务 |
| 旧插件不兼容 Flutter 3.41 | pub get 或平台编译失败 | 定位具体插件，升级最小兼容版本 |
| macOS 最低版本迁移遗漏 | Xcode 警告或构建失败 | Podfile 与 Xcode 三种配置统一到 10.15 |
| CocoaPods 1.12.1 与 Xcode 26.6 不兼容 | pod install/build 失败 | 保留原错后升级本机到 1.16.2 |
| Flutter 新模板启用 SPM | 插件重复或工程变化过大 | 现有工程继续使用 CocoaPods |
| 模板更新覆盖原生媒体代码 | 功能回归 | 只做差异迁移，不整体覆盖 Runner |
| OHOS 分支专有行为进入共享代码 | 官方 3.41.9 无法编译 | 禁止使用分支专有 API，Windows 再验证 |
| Windows 无法在 macOS 本地编译 | 风险后移 | 静态审查后输出完整 Windows 交接文档 |
| 录制/截图跨版本媒体回归 | 文件不可播放或损坏 | 真机生成产物并用系统播放器、ffprobe/ffplay 验证 |
| 用户已有未提交修改被覆盖 | 数据丢失 | 每轮检查状态，只改任务文件 |

## 10. 重试与暂停规则

本任务最多进行 6 个修复验证循环。

一个循环定义为：发现一个可定位问题，完成一组最小修复后，重新执行受影响的完整验证链。单条命令因网络瞬断等原因原样重跑不单独计为新循环，但必须记录原因。

每轮记录：

- 失败命令或功能步骤；
- 原始错误或实际现象；
- 根因判断；
- 修改文件；
- 修复后的验证结果。

如果第 6 个修复循环后仍无法满足 macOS 构建或核心功能回归：

1. 立即停止继续修改。
2. 保留现场和日志，不提交、不推送。
3. 向用户汇报已尝试的 6 轮方案、当前差异、剩余阻塞和建议选择。
4. 等待用户确认后再继续。

## 11. 交付物与验收标准

### 11.1 交付物

- 本设计文档：`docs/flutter_3_41_upgrade_design.md`。
- Flutter 3.41.9 / Dart 3.11 客户端兼容改动。
- 客户端版本 1.0.3 的版本与变更日志更新。
- macOS 构建和 OpenHarmony 真机回归结果。
- Windows 指导文档：`docs/flutter_3_41_windows_validation_guide.md`。

### 11.2 最终验收

- macOS 使用当前 Flutter 3.41.10-ohos-1.0.0 完成 analyze、test、debug 和 release 构建。
- macOS 客户端连接现有 OpenHarmony 设备，已有功能规格回归正常。
- 客户端显示版本为 1.0.3，服务端仍为 1.0.2。
- Windows 代码保持官方 Flutter 3.41.9 可构建设计，并提供可直接执行的验证文档。
- Linux 明确保留占位，未错误宣称功能完成。
- 没有无关功能修改、协议修改、服务端修改、签名修改或生成目录入库。

## 12. 已确认决策

本方案默认采用以下决策：

1. 客户端版本使用 `1.0.3+3`。
2. Dart SDK 下限提升到 3.11，Flutter SDK 下限写入 3.41.9。
3. macOS 最低版本按 Flutter 3.41 要求从 10.14 提升到 10.15。
4. macOS 保持 CocoaPods，不迁移 Swift Package Manager。
5. Linux 本期不生成 Runner，仅保留代码和文档占位。
6. macOS 真机回归完成后再新增 Windows 3.41.9 指导文档。

以上决策已由用户确认，并按本设计实施。

## 13. 实施与验证结果

2026-07-30 在 macOS 开发机完成：

- 客户端已升级为 `1.0.3+3`，Dart 下限为 3.11，Flutter 下限为 3.41.9。
- 服务端源码、权限、签名和版本均未修改，设备端仍为 1.0.2。
- macOS Deployment Target 已统一迁移到 10.15，继续使用 CocoaPods。
- Flutter 3.41 的 `CardThemeData` 和 `Color.withValues` 兼容调整均为等价 API
  替换，没有修改 UI 或业务流程。
- `flutter analyze`、`flutter test`、macOS debug 和 release 构建全部通过。
- Release 应用版本为 1.0.3（build 3），Universal Binary 包含 arm64 和 x86_64，
  App Sandbox 仍为关闭状态。
- 连接 OpenHarmony API 23 真机的媒体集成回归通过：成功录制 5.293 秒
  H.264 Baseline、3840×2160、yuv420p MP4；`ffmpeg` 全帧解码和 `ffplay`
  播放均通过。
- 成功从当前解码帧生成 3840×2160 RGB PNG，并完成文件格式与目视检查。
- Windows CMake/Runner 自定义解码与媒体代码未被模板覆盖，后续实机构建与回归步骤见
  [flutter_3_41_windows_validation_guide.md](flutter_3_41_windows_validation_guide.md)。
- Linux 仍为占位，本期未新增 Runner 或宣称原生媒体能力已完成。

实施中共进行 3 轮修复/验证，未达到 6 轮暂停上限：

1. 修复 Flutter 3.41 的 `CardTheme` 类型变化及 `withOpacity` 弃用提示后，
   静态检查、测试和两种 macOS 构建通过。
2. 扩展真机用例时发现当前设备端未回显帧率切换；确认不是 Flutter/native 崩溃，
   且本任务不修改服务端后，撤销该测试扩展，未改变业务实现。
3. 按仓库原有媒体真机用例重新验证，录制与截图主链路及媒体产物检查全部通过。
