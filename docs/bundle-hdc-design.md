# 将 hdc 打包进应用 — 技术设计

## 背景

当前客户端通过 `Process.run` 调用系统 PATH 中的 `hdc` CLI，用户必须自行安装 OpenHarmony SDK 并配置环境变量。目标：将各平台 hdc 二进制文件内嵌到应用安装包中，用户安装后开箱即用。

## 各平台 hdc 二进制来源

hdc 来自 OpenHarmony SDK `toolchains/` 目录，需要用户（或 CI）**手动准备**并放到约定位置：

```
scrcpy_client_flutter/
├── bundled_tools/
│   ├── mac/hdc            # macOS x64 (或 universal)
│   ├── win/hdc.exe        # Windows x64
│   └── linux/hdc          # Linux x64（预留）
```

> **需要用户处理**：从各平台 OpenHarmony SDK 中拷贝 hdc 到 `bundled_tools/` 目录。
> 典型路径：`~/Library/OpenHarmony/Sdk/20/toolchains/hdc`（macOS）、
> `%LOCALAPPDATA%\Huawei\Sdk\openharmony\20\toolchains\hdc.exe`（Windows）。

## 各平台打包方案

### macOS

hdc 放入 `鸿镜.app/Contents/Resources/hdc`。

**打包脚本 `package_mac.sh` 新增步骤**（在 flutter build 之后、codesign 之前）：

```bash
HDC_SRC="bundled_tools/mac/hdc"
if [[ -f "$HDC_SRC" ]]; then
  cp "$HDC_SRC" "$APP/Contents/Resources/hdc"
  chmod +x "$APP/Contents/Resources/hdc"
  echo "  [bundled] hdc 已拷入 Resources/"
else
  echo "  [warn] bundled_tools/mac/hdc 不存在，跳过内嵌"
fi
```

codesign 步骤需要签名该二进制（已有 inside-out 签名逻辑，在签 `.app` 之前单独签）：

```bash
if [[ -f "$APP/Contents/Resources/hdc" ]]; then
  codesign --force --options=runtime --timestamp --sign "$SIGN_IDENTITY" "$APP/Contents/Resources/hdc"
fi
```

**运行时路径**（Dart 侧）：

```dart
// macOS: NSBundle.mainBundle.resourcePath + '/hdc'
final bundled = '${Platform.resolvedExecutable.split('/Contents/')[0]}/Contents/Resources/hdc';
```

### Windows

hdc.exe 放入安装目录（与 `鸿镜.exe` 同级或 `tools/` 子目录）。

**打包脚本 `package_win.ps1` 新增步骤**（在 Inno Setup 打包之前）：

```powershell
$hdcSrc = "bundled_tools\win\hdc.exe"
$toolsDir = "build\windows\x64\runner\Release\tools"
if (Test-Path $hdcSrc) {
    New-Item -ItemType Directory -Force -Path $toolsDir | Out-Null
    Copy-Item $hdcSrc $toolsDir
    Write-Host "  [bundled] hdc.exe -> tools/"
}
```

Inno Setup `.iss` 文件增加条目：

```
[Files]
Source: "build\windows\x64\runner\Release\tools\hdc.exe"; DestDir: "{app}\tools"; Flags: ignoreversion
```

**运行时路径**（Dart 侧）：

```dart
// Windows: exe 同级 tools\hdc.exe
final bundled = '${File(Platform.resolvedExecutable).parent.path}\\tools\\hdc.exe';
```

### Linux（预留）

hdc 放入 `<install>/lib/<app>/tools/hdc`（遵循 FHS），打包脚本待 Linux 支持时补充。

```dart
final bundled = '${File(Platform.resolvedExecutable).parent.path}/tools/hdc';
```

## 路径解析策略（HdcClient 改动）

优先级：**内嵌 hdc → 系统 PATH hdc → 候选路径扫描**

修改 `_resolveHdc()` 方法，在现有逻辑**之前**插入内嵌路径检测：

```dart
Future<void> _resolveHdc() async {
  if (_resolved) return;

  // 1. 优先使用内嵌的 hdc
  final bundled = _bundledHdcPath();
  if (bundled != null && await File(bundled).exists()) {
    _hdcPath = bundled;
    _resolved = true;
    return;
  }

  // 2. 原有逻辑：which/where → 登录 shell → 候选路径扫描
  // ...（不变）
}

String? _bundledHdcPath() {
  final exe = Platform.resolvedExecutable;
  if (Platform.isMacOS) {
    final dotApp = exe.split('/Contents/').first;
    return '$dotApp/Contents/Resources/hdc';
  } else if (Platform.isWindows) {
    return '${File(exe).parent.path}\\tools\\hdc.exe';
  } else if (Platform.isLinux) {
    return '${File(exe).parent.path}/tools/hdc';
  }
  return null;
}
```

## PTY 终端的处理

`PtySession.start()` 已经接受 `hdcPath` 参数，调用链：

```
AppState.setTerminalOpen()
  → hdc.resolvedPath()      // 返回解析后的绝对路径
  → terminal.start(sn, hdcPath: p)
    → Pty.start(hdcPath, ['-t', sn, 'shell'])
```

`resolvedPath()` 底层调 `_resolveHdc()`，改完后自动走内嵌路径，**PTY 终端无需额外改动**。

## 错误提示更新

当内嵌 hdc 不存在且系统也找不到时，错误信息需更新：

```dart
throw HdcException(
  '找不到 hdc 命令。\n'
  '• 应用内嵌 hdc 缺失（开发构建可能未打包）\n'
  '• 也未在系统 PATH 中找到 hdc\n'
  '请安装 OpenHarmony SDK 并将 hdc 加入 PATH，或重新安装应用。'
);
```

## macOS 沙盒与权限

当前 entitlements 已关闭 `app-sandbox`（设为 false），`Resources/` 目录下的可执行文件可直接 `Process.run`，无需额外权限。

## 实施清单

| 步骤 | 负责 | 说明 |
|------|------|------|
| 1. 创建 `bundled_tools/` 目录结构 | 用户 | 从 SDK 拷贝各平台 hdc 二进制 |
| 2. `.gitignore` 添加 `bundled_tools/` | Claude | 二进制不入仓 |
| 3. 修改 `HdcClient._resolveHdc()` | Claude | 新增内嵌路径优先检测 |
| 4. 修改 `package_mac.sh` | Claude | 拷贝 + 签名 hdc |
| 5. 修改 `package_win.ps1` | Claude | 拷贝 hdc.exe + Inno Setup 配置 |
| 6. 更新错误提示 | Claude | 优化找不到 hdc 时的提示信息 |

> **需要用户配合**：准备 macOS 和 Windows 的 hdc 二进制文件放到 `bundled_tools/` 对应目录。CI 环境可在 pipeline 中从 SDK 路径自动拷贝。
