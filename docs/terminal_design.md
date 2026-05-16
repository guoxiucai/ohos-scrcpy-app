# P2 客户端虚拟终端 设计文档

> 配套主设计文档 `spec_doc/design.md` §5.4 第 7 项「终端（P2）」的细化。
> 范围：仅客户端 Flutter 工程改动；不动服务端、不动协议。

## 1. 目标

在 `scrcpy_client_flutter` 内提供一个**嵌入式 PTY 终端**面板，让用户：

- **macOS/Linux**：直接在客户端里跑 `hdc -t <sn> shell`，体验等同于本机终端（含上下键历史、`top` / `vi` / `tail -f`、彩色输出、Ctrl-C 中断）。选定设备时终端自动绑定该设备 SN。
- **Windows**：提供通用 `cmd.exe` 终端（类似 VSCode 内嵌终端），用户可自行执行 hdc 命令或任意 PC 侧命令。

非目标（明确不做）：

- 不实现 hdc 协议库；仍然依赖系统 `hdc` CLI 在 PATH。
- 不做远程 ssh / 多 tab 多会话（P3 视需求扩展）。

## 2. 平台范围与依赖

| 平台      | 后端                                      | 状态            | 备注                                                |
|-----------|-------------------------------------------|-----------------|-----------------------------------------------------|
| macOS     | `forkpty(3)` via `flutter_pty` → `hdc shell` | ✅ 一期支持  | 真交互式 PTY，自动绑定设备 SN                       |
| Windows   | ConPTY via `flutter_pty` → `cmd.exe`      | ✅ 一期支持     | 通用终端，要求 Win10 1809+ (build 17763+)           |
| Linux     | `forkpty(3)` → `hdc shell`               | ⏸ P3 再开      | 与 macOS 同后端                                     |

依赖：

```yaml
# pubspec.yaml
flutter_pty: ^0.4.1     # 跨平台 PTY 封装（forkpty / ConPTY）
xterm:                   # VT100/ANSI 渲染 (local path: third_party/xterm)
```

### Windows 平台说明

hdc 在 Windows ConPTY 环境下不兼容交互式 shell（`[W] Not support stdio TTY mode`，连接 daemon 超时退出），且管道模式下 hdc shell 不读取 stdin。因此 Windows 端不直接启动 `hdc shell`，而是启动 `cmd.exe` 作为通用终端，用户自行执行 hdc 命令。

**关键踩坑：flutter_pty 环境变量白名单**

`flutter_pty` 的 `Pty.start` 默认只从 `Platform.environment` 继承 6 个变量（`PATH`、`HOME`、`USER`、`LOGNAME`、`DISPLAY`、`LC_TYPE`），其余全部丢弃。Windows 上 hdc 需要 `SystemRoot`、`TEMP`、`APPDATA` 等系统变量才能连接 daemon。必须显式传入完整 `Platform.environment`：

```dart
final env = Map<String, String>.from(Platform.environment);
Pty.start('cmd.exe', environment: env, ...);
```

## 3. 交互形态

### 3.1 面板位置：底部可隐藏抽屉

```
┌──────────────────────────────────────────────────────────────────┐
│ TopBar                                                           │
├────────────────────────────────────────────┬─────────────────────┤
│                                            │ Sidebar             │
│   MirrorView                               │ ├ 应用安装          │
│                                            │ ├ 设备控制          │
│                                            │ └ 终端 [展开 ▾]     │
│                                            │                     │
├────────────────────────────────────────────┴─────────────────────┤
│ TerminalDrawer (默认 240px 高，可拖拽 140–1200px)                │
│ ┌──────────────────────────────────────────────────────────┐    │
│ │ ● hdc shell · SN-XXXX        [restart] [clear] [×]       │    │
│ ├──────────────────────────────────────────────────────────┤    │
│ │ macOS: # uname -a                                        │    │
│ │ Windows: C:\Users\xxx> hdc -t SN shell                   │    │
│ └──────────────────────────────────────────────────────────┘    │
└──────────────────────────────────────────────────────────────────┘
```

### 3.2 标题条按钮

| 按钮     | 行为                                                                  |
|----------|-----------------------------------------------------------------------|
| restart  | `pty.kill()` 后重启（macOS: hdc shell / Windows: cmd.exe）            |
| clear    | 清除终端 buffer                                                       |
| ×        | 关闭抽屉（**不**杀 PTY，保留会话；下次打开继续显示）                  |

### 3.3 设备切换语义

- **macOS/Linux**：用户在 TopBar 切换设备 → 抽屉里弹提示 → 自动 `pty.kill()` 并以新 SN 重启 hdc shell。
- **Windows**：切换设备重启 cmd.exe；用户需手动输入 hdc 命令连接新设备。

### 3.4 命令作用域

- **macOS/Linux**：固定 `hdc -t <sn> shell` 单一入口。
- **Windows**：通用 cmd.exe 终端，不限制命令范围。

## 4. 模块设计

### 4.1 文件结构

```
lib/
  terminal/
    pty_session.dart          # PTY 子进程生命周期 + xterm 绑定（平台分派）
    pty_availability.dart     # 平台/Windows 版本检测
  ui/
    terminal_drawer.dart      # 底部抽屉容器，含标题条和 TerminalView
    vertical_split.dart       # 主体 + 抽屉的可拖拽布局
  state/
    app_state.dart            # terminalOpen / terminalHeight 字段
```

### 4.2 PtySession（核心）

```dart
class PtySession {
  final Terminal terminal;
  Pty? _pty;
  String? _boundSn;

  Future<void> start(String sn, {String hdcPath = 'hdc'}) async {
    if (Platform.isWindows) {
      _startWindowsPty(sn, rows, cols);   // cmd.exe
    } else {
      _startPty(hdcPath, sn, rows, cols); // hdc shell
    }
  }
}
```

#### macOS/Linux PTY 模式

- `Pty.start(hdcPath, arguments: ['-t', sn, 'shell'])`
- 输出：`pty.output.listen((chunk) => terminal.write(utf8.decode(chunk)))`
- 输入：`terminal.onOutput = (data) => pty.write(utf8.encode(data))`
- 退出：监听 `pty.exitCode`，写 `[process exited code=N]`

#### Windows cmd.exe 模式

- `Pty.start('cmd.exe', environment: Platform.environment)`
  - 必须传完整环境变量，否则 hdc 无法连接 daemon
- 启动后自动执行 `chcp 65001 >nul` 设置 UTF-8 编码
- 输入/输出/退出处理与 macOS PTY 模式一致
- xterm `TerminalView` 设置 `hardwareKeyboardOnly: true`（桌面端直接监听物理键盘）

### 4.3 PtyAvailability

```dart
class PtyAvailability {
  static bool get isSupported {
    if (Platform.isMacOS || Platform.isLinux) return true;
    if (Platform.isWindows) return _windowsBuild() >= 17763;
    return false;
  }
}
```

Windows ConPTY 要求 Build 17763+（Win10 1809）。低版本禁用终端面板并提示。

### 4.4 状态接入

`AppState` 字段：

```dart
bool   terminalOpen   = false;
double terminalHeight = 240;       // clamp(140, 1200)
PtySession? terminal;              // 首次开抽屉时 lazy 创建
```

### 4.5 TerminalView 配置

```dart
TerminalView(
  session.terminal,
  focusNode: _focusNode,           // 手动管理焦点
  hardwareKeyboardOnly: true,      // 桌面端直接监听物理键盘
  autofocus: true,
  shortcuts: _shortcuts(),         // 自定义 Ctrl+C/V/A 快捷键
)
```

外层 `GestureDetector(onTap: () => _focusNode.requestFocus())` 确保点击终端区域时显式获取焦点。

## 5. 视觉风格

复用 `lib/ui/theme.dart`：

- 抽屉背景 `AppColors.surface`；标题条 `AppColors.surfaceAlt`
- 终端文字色 `#CBD5E1`；光标 `AppColors.accent`（cyan-400）
- 字体 Menlo，fallback `Consolas`、`monospace`
- 标题条状态点：running → success、exited → idle、失败 → danger

## 6. 错误与边界

| 场景                                   | 处理                                                                 |
|----------------------------------------|----------------------------------------------------------------------|
| `hdc` 不在 PATH（macOS/Linux）          | 抽屉写 `[hdc not found in PATH]`                                    |
| 设备未选                               | macOS: 不启动 shell / Windows: cmd.exe 正常启动                      |
| Windows < 1809                         | 终端整体禁用 + tooltip 说明                                          |
| `Pty.start` 抛 FFI 异常               | catch 后写 `[start failed: ...]`                                     |
| 子进程退出                             | 写 `[process exited code=N]`；不自动重启                              |
| 抽屉关闭后重开                         | 历史 buffer 保留，PTY 不杀                                           |
| 应用退出                               | `dispose()` → `session.kill()`                                       |
| flutter_pty 环境变量丢失（Windows）     | 显式传完整 `Platform.environment`                                    |
| hdc 在 ConPTY 下不兼容（Windows）      | 不直接启动 hdc shell，改用 cmd.exe                                    |

## 7. 安全与边界

- 子进程参数严格用 `arguments: [...]` 数组形式传给 `Pty.start`，避免命令注入。
- SN 来自 `hdc list targets`，`start()` 入口白名单校验 `^[A-Za-z0-9._:-]+$`。
- 复制粘贴默认开启。

## 8. 验证方案

1. **macOS 冒烟**：
   - 选设备 → 展开终端 → 看到 `#` → 输入 `ls /system`、`top`、`tail -f` → 正常。
   - 切设备 → 自动重启 shell。
2. **Windows 冒烟**：
   - 展开终端 → 看到 `cmd.exe` 提示符 → 输入 `hdc list targets` → 显示设备。
   - 输入 `hdc -t <SN> shell` → 进入交互式 shell → `cd /system && ls` → 正常。
   - 输入 `exit` 退出 shell → 回到 cmd → 再次输入 hdc 命令 → 正常。
3. **resize**：拖拽抽屉高度 → 终端 cols/rows 跟随。
4. **进程清理**：退出应用 → 无残留 cmd/hdc 进程。
5. **降级**：Win10 1803 → 终端禁用 + 提示。

## 9. 踩坑记录

### 9.1 hdc 不支持 Windows ConPTY

hdc 在 ConPTY 环境下检测到 TTY stdin 后输出 `[W] Not support stdio TTY mode`，交互式 shell 约 10 秒后连接 daemon 失败退出（`Connect server failed`）。管道模式（`Process.start`）下 hdc shell 显示提示符但不读取 stdin，也不可用。

**结论**：Windows 上无法直接用 PTY 或管道模式启动 `hdc shell`。改为启动 `cmd.exe`，用户自行输入 hdc 命令。

### 9.2 flutter_pty 环境变量白名单

`flutter_pty` 0.4.x 的 `Pty.start` 默认只继承 `PATH`、`HOME`、`USER`、`LOGNAME`、`DISPLAY`、`LC_TYPE` 六个环境变量。Windows 上 hdc 连接 daemon 需要 `SystemRoot`、`TEMP`、`APPDATA` 等系统变量，缺失则报 `Connect server failed`。

**修复**：显式传入 `environment: Map.from(Platform.environment)`。

### 9.3 PowerShell 在 ConPTY 中启动失败

`powershell.exe` 在 Flutter GUI 进程的 ConPTY 中启动报错 `800900`（托管加载失败）。

**修复**：改用 `cmd.exe`，更轻量且无 .NET 依赖。

### 9.4 cmd.exe 中文编码

cmd.exe 默认使用 GBK (code page 936)。启动后自动执行 `chcp 65001 >nul` 切换 UTF-8。

## 10. 风险与未决

- 中文/CJK 渲染依赖 `xterm.dart` 字体回退（P3 打包 CJK 字体）。
- ConPTY 极端窄尺寸（cols<10）可能拒绝 resize，`resize()` 里 `cols = max(cols, 10)` 兜底。
- Linux PTY 已就绪但暂不出包。

## 11. 关联文件

- 修改：`scrcpy_client_flutter/pubspec.yaml`（依赖）
- 修改：`scrcpy_client_flutter/lib/app.dart`（VerticalSplit）
- 修改：`scrcpy_client_flutter/lib/state/app_state.dart`（terminal 字段）
- 修改：`scrcpy_client_flutter/lib/ui/sidebar.dart`（终端卡片改入口）
- 修改：`scrcpy_client_flutter/lib/ui/terminal_drawer.dart`（TerminalView 配置）
- 核心：`scrcpy_client_flutter/lib/terminal/pty_session.dart`（平台分派逻辑）
- 核心：`scrcpy_client_flutter/lib/terminal/pty_availability.dart`（版本检测）
