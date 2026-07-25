# AGENTS.md

本文档用于约束在本仓库中工作的 AI 编码代理。所有操作应以当前代码、构建配置和用户要求为准；`README.md` 与 `docs/` 用于补充背景。当文档与代码不一致时，先核对实际配置和实现，不要直接照搬历史结论。

## 沟通与交付

- 始终使用简体中文沟通，包括回复、代码注释、文档和提交信息。
- 开始修改前先阅读相关实现、配置和设计文档，避免凭经验猜测 OpenHarmony 或平台 API。
- 只修改任务所需文件，保留用户已有的未提交改动，不清理或覆盖无关变更。
- 完成后说明修改内容、验证命令与验证结果；未执行的验证及原因也要明确说明。
- 未经用户明确要求，不提交、不推送、不发布、不部署，也不改签名材料和版本号。

## 项目概览

鸿镜（HongJing）是 OpenHarmony 设备投屏与 HDC 调试工具，由两个子工程组成：

1. `scrcpy_server/`：运行在 OpenHarmony 设备上的系统 HAP。
2. `scrcpy_client_flutter/`：运行在 macOS/Windows 上的 Flutter 桌面客户端，Linux 为后续目标。

客户端通过系统或应用内置的 `hdc` 执行设备发现、安装、卸载、shell 和端口转发。投屏连接固定使用：

```text
客户端 -> hdc fport tcp:<本机端口> tcp:53535
       -> 127.0.0.1:<本机端口>
       -> 设备端 127.0.0.1:53535
```

视频流、心跳、设备状态和控制消息均复用该 TCP 通道，不增加设备 LAN 直连方案。

## 目录与职责

```text
.
├── scrcpy_server/
│   ├── AppScope/app.json5                 # bundle、版本、keepAlive
│   ├── build-profile.json5                # SDK、产品与签名配置
│   └── entry/
│       ├── build-profile.json5            # NAPI/CMake、ABI、产物名
│       └── src/main/
│           ├── module.json5               # Ability、权限、mainElement
│           ├── ets/
│           │   ├── scrcpyservice/         # 服务生命周期、协议、输入和应用列表
│           │   ├── hapinstaller/          # HAP 安装 Ability
│           │   ├── entryability/          # 调试/授权 UI 入口
│           │   └── pages/                 # ArkUI 页面
│           └── cpp/                       # TCP、截屏、编码、NAPI 桥接
├── scrcpy_client_flutter/
│   ├── lib/
│   │   ├── hdc/                           # hdc 路径解析与命令封装
│   │   ├── net/                           # TCP 客户端与协议编解码
│   │   ├── decoder/                       # MethodChannel 解码抽象
│   │   ├── state/app_state.dart           # 客户端中央状态与业务编排
│   │   ├── terminal/                      # PTY 终端
│   │   └── ui/                            # Flutter UI
│   ├── macos/Runner/VideoDecoderPlugin.swift
│   ├── windows/runner/                    # D3D11/MFT/CPU 解码与纹理插件
│   ├── bundled_tools/                     # 打包时内置的 hdc 及依赖
│   ├── third_party/xterm/                 # 本地依赖，非任务需要不改
│   └── scripts/                           # macOS/Windows 打包脚本
├── docs/                                  # 架构、平台方案和踩坑记录
├── spec_doc/                              # 需求与开发过程记录
└── openspec/                              # OpenSpec 配置
```

不要手工修改 `.dart_tool/`、`build/`、`Pods/`、`ephemeral/`、`.hvigor/` 等生成目录。

## 不可擅自改变的架构决策

- HDC 通过 Dart `Process` 调用 CLI：优先应用内置二进制，其次系统 PATH/常见 SDK 路径。
- 视频解码使用平台原生实现并通过 `MethodChannel('scrcpy/decoder')` 与 Flutter Texture 上屏：
  - macOS：VideoToolbox。
  - Windows：优先 D3D11 硬件路径，失败后使用 CPU 回退路径。
  - 不引入 `media_kit`、`fvp` 或 FFI FFmpeg 替代现有架构。
- 服务端 `module.json5` 的 `mainElement` 必须保持为 `ScrcpyService`。`EntryAbility` 只承担调试页或必要的授权入口，不承载核心服务逻辑。
- 服务自启和常驻以 `AppScope/app.json5` 的 `keepAlive` 为基础，不新增 BootReceiver、StaticSubscriber 或启动完成广播。
- 截屏和编码必须按客户端连接状态启停：无客户端时释放截屏、编码器和相关系统资源，重连后重新创建。
- macOS App Sandbox 当前关闭，以允许调用 `hdc` 和建立本地 TCP 连接；修改时必须同步检查 `DebugProfile.entitlements` 与 `Release.entitlements`。
- 当前真实 SDK 配置以 `scrcpy_server/build-profile.json5` 为准：`compileSdkVersion` 为 23，`compatibleSdkVersion` 为 15。`CLAUDE.md` 中的 API 20 是历史信息，除非用户明确要求降级，否则不要改回。

## 服务端开发规则

### 分层

- `ScrcpyService.ets`：管理服务生命周期、客户端 presence、采集启停、控制分发和后台任务。
- `InputInjector.ets`：处理触摸、鼠标、键盘、音量和亮度等输入。
- `Protocol.ets`：ArkTS 侧协议常量及编码；协议变更必须与 Dart/C++ 同步。
- `AppListProvider.ets`：生成可卸载应用列表。
- `ScreenCaptureEncoder.*`：OH_AVScreenCapture、H.264/RAW/JPEG 和背压控制。
- `TcpServer.*`：监听 53535、连接管理、协议拆包与消息广播。
- `napi_init.cpp` 与 `types/libscrcpy_capture/Index.d.ts`：NAPI 导出及 ArkTS 类型声明；改 native 导出时三处必须一致。

### ArkTS 约束

修改 `.ets` 文件时遵守 ArkTS 严格语法：

- 禁止 `any`、`unknown` 和无约束动态类型，变量与回调参数使用明确类型。
- 不使用内联对象类型；提取为命名 `interface` 或 `class`。
- 对象字面量必须有明确目标类型，并写完整字段名，不使用属性 shorthand。
- 避免直接 `for...of Map.values()`，优先使用 `.forEach`。
- 系统 API 的导入路径、类型字段和版本差异必须以当前 Full SDK 声明为准。
- 需要新增 OpenHarmony API 时，优先查当前 SDK 的真实 `.d.ts` 和官方文档。常用本机目录为 `~/Library/OpenHarmony/Sdk/<版本>/ets/api/`，不要假定固定为 API 20。

### Native 约束

- C++ 使用 C++17，目标 ABI 当前为 `arm64-v8a`。
- 所有 native 资源遵循严格的创建/销毁配对，断开、失败和提前返回路径同样要释放。
- `OH_AVScreenCapture` RAW 模式的 `AcquireVideoBuffer` 与 `ReleaseVideoBuffer` 必须一一配对；丢帧或跳过路径也不能省略。
- H.264 帧编码完成后不要随意丢弃依赖帧。队列压力应优先使用现有暂停/恢复控制，让服务端在编码前背压。
- 修改 NAPI 接口时同步更新 C++ 注册、ArkTS `.d.ts` 和调用方。

## 客户端开发规则

- 业务状态、连接生命周期和共享实例集中在 `lib/state/app_state.dart`。Widget 不自行创建新的 `HdcClient`、`StreamClient` 或 `VideoDecoder`。
- `lib/hdc/` 统一封装 HDC 命令；UI 层不要直接调用 `Process.run`。
- `lib/net/protocol.dart` 是 Dart 侧协议真值之一。改包格式或 subtype 时同步检查：
  - `scrcpy_server/entry/src/main/ets/scrcpyservice/Protocol.ets`
  - `scrcpy_server/entry/src/main/cpp/TcpServer.*`
  - 所有发送、解析和状态处理调用点
- TCP 使用大端序。帧头固定为 `type(4B) + length(4B) + payload`。
- `StreamClient` 在 `connect` 和 `disconnect` 时都必须重置解析器，防止半包残留污染重连。
- 触摸、鼠标和文本输入涉及渲染尺寸到设备尺寸的坐标转换；修改 UI 布局后必须验证横竖屏、缩放和留黑区域。
- 修改 MethodChannel 方法、参数或返回值时，同步更新 Dart、Swift 和 Windows C++ 实现。
- Windows 两条纹理路径的像素约定不同：
  - PixelBuffer 路径按 RGBA。
  - D3D11 `DXGI_FORMAT_B8G8R8A8_UNORM` 路径按 BGRA。
  不要混用通道顺序。
- `third_party/xterm/` 是项目内嵌依赖，只有任务明确涉及终端内核时才修改。

## 通信协议

当前基础帧格式：

```text
4B type（大端）| 4B payload length（大端）| payload
```

主要包类型：

| type | 名称 | 方向 |
| --- | --- | --- |
| `0x01` | 心跳 | 双向 |
| `0x02` | 视频配置 | 服务端到客户端 |
| `0x03` | 视频帧 | 服务端到客户端 |
| `0x10` | 控制 | 客户端到服务端 |
| `0x20` | 设备状态 | 服务端到客户端 |

视频配置当前以 `codec(1)` 开头，支持 H.264、RAW RGBA 和 JPEG；不能按旧文档中“不含 codec 字段”的格式实现。完整字段、控制 subtype 和键码以两端 `Protocol` 源码为准。

协议修改必须满足：

1. 两端常量和字节布局同步。
2. 明确长度、端序、字符串编码和兼容策略。
3. 对短包、半包、非法长度和断线重连进行防御。
4. 更新相关设计文档或协议注释。

## 构建与验证

只运行与改动范围相称的验证。不要把打包、签名、公证或真机安装当作普通静态检查自动执行。

### Flutter 客户端

```bash
cd scrcpy_client_flutter
flutter pub get
flutter analyze
flutter test
flutter run -d macos
flutter build macos --debug
flutter build macos --release
```

Windows 构建必须在 Windows 环境执行：

```powershell
cd scrcpy_client_flutter
flutter analyze
flutter test
flutter build windows --release
```

打包命令：

```bash
cd scrcpy_client_flutter
bash scripts/package_mac.sh
```

```powershell
cd scrcpy_client_flutter
powershell -ExecutionPolicy Bypass -File scripts\package_win.ps1
```

打包脚本可能触发签名、公证或生成安装包，只有用户明确要求打包/发布时才执行。客户端主工程测试目前较少，不能仅凭占位测试通过判断业务正确。

### OpenHarmony 服务端

macOS 默认构建命令：

```bash
cd scrcpy_server
/Applications/DevEco-Studio.app/Contents/tools/node/bin/node \
  /Applications/DevEco-Studio.app/Contents/tools/hvigor/bin/hvigorw.js \
  clean --mode module -p product=default assembleHap \
  --analyze=normal --parallel --incremental --daemon
```

HAP 输出位于 `scrcpy_server/entry/build/default/outputs/default/`。安装属于真机变更，仅在用户要求时执行：

```bash
hdc install -r <signed-hap-path>
```

### 最低验证要求

- 仅 Dart/UI 改动：至少运行 `flutter analyze`；新增纯逻辑时补充并运行相应测试。
- Swift/macOS 插件改动：运行 `flutter analyze`，并至少完成 macOS debug 构建。
- Windows native 改动：在 Windows 完成对应构建；当前环境无法验证时必须明确说明。
- ArkTS/C++/权限/模块配置改动：运行完整 Hvigor HAP 构建。
- 协议或跨端改动：同时验证服务端构建与客户端静态检查/测试。
- 文档改动：检查路径、命令、版本和现有实现是否一致。

## 签名、权限与敏感文件

- 服务端依赖系统应用签名、Full SDK 和设备侧权限白名单。
- `scrcpy_server/build-profile.json5`、`scrcpy_server/signature/` 可能包含签名配置或材料。不要在回复、日志或新文档中复制密码、私钥内容、证书指纹等敏感信息。
- 未经明确要求，不重新生成、替换或提交签名材料，不修改系统白名单。
- 新增权限前先确认真实 API、最小版本、权限等级、申请理由和系统应用限制；保持 `module.json5`、profile 与设备白名单一致。

## 文档优先级与常见陷阱

建议按以下顺序核对信息：

1. 当前源码和构建配置。
2. `docs/lessons-learned.md` 及与任务直接相关的 `docs/*_design.md`。
3. `README.md`、`CONTRIBUTING.md`。
4. `CLAUDE.md` 和 `spec_doc/dev_doc.md` 中的历史规划。

重点避免：

- 将核心业务移入 `EntryAbility`。
- 无客户端时仍持续截屏或编码。
- 只修改一端协议或 MethodChannel。
- 在重连时复用未清空的流解析缓存。
- 将 Windows RGBA 与 BGRA 路径混为一谈。
- 直接编辑构建产物、Flutter 生成文件或第三方依赖。
- 为解决背压而在 H.264 编码后任意丢弃 P 帧。

## 提交规范

用户明确要求提交时，使用简体中文提交信息，格式为：

```text
<type>:<简短描述>
```

可用 `type`：`feat`、`fix`、`docs`、`refactor`、`test`、`chore`。提交前检查差异，只包含本任务相关文件，并记录实际完成的验证。
