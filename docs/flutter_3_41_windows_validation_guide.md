# Flutter 3.41.9 Windows 编译与回归指南

> 适用客户端：鸿镜 1.0.3（build 3）
> 目标 SDK：官方 Flutter 3.41.9 / Dart 3.11
> 适用系统：Windows 10 1809+、Windows 11，x64
> 服务端：沿用 OpenHarmony 1.0.2，不升级、不重新签名
> 最后更新：2026-07-30

## 1. 验证目标

本指南用于在 Windows 电脑接手 Flutter 3.41.9 升级后的首次编译与真机回归。验收重点：

1. 使用官方 Flutter 3.41.9 完成依赖解析、静态检查、测试和 debug/release 构建。
2. 生成的 EXE 版本为 `1.0.3.3`，产品显示版本为 `1.0.3`。
3. 现有 HDC、投屏、控制、应用管理、终端、录制和截图功能无回归。
4. Windows Media Foundation、D3D11 和 CPU 回退路径未因 Flutter 升级失效。
5. 服务端源码和版本保持 1.0.2。

录制与截图的专项排障步骤可继续参考
[windows_media_capture_validation_guide.md](windows_media_capture_validation_guide.md)。

## 2. 环境准备

### 2.1 必需软件

| 工具 | 要求 |
| --- | --- |
| Flutter | 官方稳定版 3.41.9，不使用 OHOS 分支编译 Windows |
| Dart | Flutter 3.41.9 内置的 3.11 系列 |
| Visual Studio | Visual Studio 2022 或 Build Tools 2022 |
| VS 工作负载 | “使用 C++ 的桌面开发” |
| Windows SDK | Windows 10/11 SDK，最低支持 Windows 10 1809 |
| Git | 可正常拉取仓库及检查差异 |
| HDC | 能识别待测 OpenHarmony 设备 |
| FFmpeg | 建议安装，确保 `ffprobe`、`ffmpeg`、`ffplay` 可用 |
| VLC | 建议安装，用于播放器兼容性验证 |

Windows N/KN 版本需要安装“媒体功能包”，否则 Media Foundation H.264
解码或 MP4 相关能力可能不可用。

### 2.2 SDK 自检

在新的 PowerShell 窗口执行：

```powershell
flutter --version
dart --version
flutter doctor -v
flutter config --enable-windows-desktop
flutter devices
hdc list targets
where.exe ffprobe
where.exe ffplay
```

预期结果：

- Flutter 首行包含 `Flutter 3.41.9`。
- Dart 为 3.11 系列。
- `flutter doctor -v` 能识别 Visual Studio 2022 与 Windows toolchain。
- `flutter devices` 包含 `Windows (desktop)`。
- `hdc list targets` 能看到目标设备，且状态不是 `Unauthorized`。

如果电脑上存在多套 Flutter，使用以下命令确认实际命中的路径：

```powershell
where.exe flutter
Get-Command flutter | Format-List Source
```

## 3. 获取代码与保护本地修改

进入仓库后先记录现场：

```powershell
git status --short
git rev-parse --short HEAD
```

不要删除或覆盖 Windows 电脑上的未提交修改。确认代码包含：

```powershell
Select-String -Path .\scrcpy_client_flutter\pubspec.yaml -Pattern "^version:|sdk:|flutter:"
Select-String -Path .\scrcpy_server\AppScope\app.json5 -Pattern "versionName|versionCode"
```

期望客户端为 `1.0.3+3`，服务端仍为 `1.0.2` / `1000002`。

## 4. 清理旧 SDK 生成物

Flutter 3.22 生成的 Windows wrapper 和构建缓存不能直接复用。只清理生成目录，
不要删除源码：

```powershell
cd .\scrcpy_client_flutter
flutter clean
flutter pub get
git status --short
```

`flutter pub get` 后 `pubspec.lock` 不应产生新的差异。如果发生变化，先保存以下信息，
不要直接执行依赖大版本升级：

```powershell
flutter --version
git diff -- pubspec.lock
flutter pub deps
```

## 5. 静态检查、测试与构建

按顺序执行，每一步成功后再继续：

```powershell
cd .\scrcpy_client_flutter

flutter analyze
flutter test
flutter build windows --debug
flutter build windows --release
```

构建产物：

```text
build\windows\x64\runner\Debug\scrcpy_client_flutter.exe
build\windows\x64\runner\Release\scrcpy_client_flutter.exe
```

检查 Release EXE 版本：

```powershell
$exe = Resolve-Path .\build\windows\x64\runner\Release\scrcpy_client_flutter.exe
$info = (Get-Item $exe).VersionInfo
$info | Format-List FileVersion,ProductVersion,ProductName,FileDescription
```

验收值：

```text
FileVersion    : 1.0.3
ProductVersion : 1.0.3
ProductName    : 鸿镜
```

Windows 属性页可能把四段文件版本显示为 `1.0.3.3`；两种显示均需确认 build
number 实际为 3。

## 6. 真机启动

优先使用 debug 构建确认基础功能：

```powershell
flutter run -d windows
```

然后关闭 debug 进程，直接运行 Release：

```powershell
.\build\windows\x64\runner\Release\scrcpy_client_flutter.exe
```

客户端会自行执行 HDC 设备发现和端口转发，不需要提前手工固定本地端口。若连接失败：

```powershell
hdc list targets
hdc fport ls
```

确认没有其他客户端持续占用设备端 `tcp:53535`。不要在不清楚目标端口的情况下批量删除
其他项目的转发。

## 7. 功能回归清单

### 7.1 基础与视频

- [ ] 冷启动成功，录制/截图区域默认折叠。
- [ ] 能发现、选择并连接 OpenHarmony 设备。
- [ ] 投屏画面尺寸、颜色和方向正确，无黑屏、花屏或 RGBA/BGRA 色偏。
- [ ] 静止画面持续显示正常；移动鼠标或播放动画时画面连续。
- [ ] 断开后重新连接成功，不出现半包残留或首屏解码失败。
- [ ] 切换一次分辨率和帧率后，画面能恢复并继续更新。

### 7.2 输入、控制与工具

- [ ] 左键点击、拖动、右键、滚轮坐标正确。
- [ ] 返回、主页、电源、音量、亮度控制正常。
- [ ] 文本输入与常用键盘按键正常。
- [ ] 应用列表能刷新；安装/卸载仅使用明确的测试 HAP。
- [ ] HDC 终端能打开，执行 `pwd`、`ls` 等只读命令有输出。

### 7.3 录制

至少录制两段：

1. 静止画面 10 秒。
2. 持续移动鼠标或播放动画 10～15 秒。

每段均检查：

- [ ] 点击录制后状态及时进入“录制中”，投屏不新增明显闪屏。
- [ ] 录制期间点击分辨率或帧率，中央 Toast 显示约 1.5 秒，参数不改变。
- [ ] 停止后弹窗展示桌面 MP4 的完整路径。
- [ ] “打开路径”能在资源管理器中定位文件。
- [ ] Windows 10/11 系统播放器、VLC 和 ffplay 均从首帧正常播放。
- [ ] 无开头黑屏/花屏、提前结束、尾部冻结或时长为 0。

### 7.4 截图

- [ ] 投屏画面稳定后点击截图。
- [ ] 完成弹窗显示桌面 PNG 的完整路径。
- [ ] “打开路径”能在资源管理器中定位文件。
- [ ] Windows“照片”和浏览器均可打开 PNG。
- [ ] 截图尺寸与当前视频帧一致，无空白、色偏、上下颠倒或裁切。

## 8. 媒体文件自动检查

在 PowerShell 中定位最新产物：

```powershell
$desktop = [Environment]::GetFolderPath("Desktop")
$mp4 = Get-ChildItem $desktop -Filter "HongJing_Recording_*.mp4" |
  Sort-Object LastWriteTime -Descending |
  Select-Object -First 1
$png = Get-ChildItem $desktop -Filter "HongJing_Screenshot_*.png" |
  Sort-Object LastWriteTime -Descending |
  Select-Object -First 1

$mp4.FullName
$png.FullName
```

验证 MP4 容器、首帧和全帧解码：

```powershell
ffprobe -v error `
  -show_entries format=duration,size `
  -show_entries stream=codec_name,profile,width,height,pix_fmt,avg_frame_rate,nb_frames `
  -of default=noprint_wrappers=1 `
  $mp4.FullName

ffprobe -v error `
  -select_streams v:0 `
  -show_entries frame=key_frame,pict_type,best_effort_timestamp_time `
  -read_intervals "%+#1" `
  -of default=noprint_wrappers=1 `
  $mp4.FullName

ffmpeg -v error -i $mp4.FullName -f null -
ffplay -autoexit -loglevel error $mp4.FullName
```

通过标准：

- `codec_name=h264`，宽高大于 0，`duration` 与实录时长基本一致。
- 第一帧为关键帧，通常输出 `key_frame=1`、`pict_type=I`。
- `ffmpeg` 全帧解码无错误。
- `ffplay` 能正常播放到结尾。

验证 PNG：

```powershell
Add-Type -AssemblyName System.Drawing
$image = [System.Drawing.Image]::FromFile($png.FullName)
try {
  "PNG: $($image.Width)x$($image.Height), format=$($image.RawFormat)"
} finally {
  $image.Dispose()
}
```

## 9. D3D11 与 CPU 回退验证

Windows 客户端默认优先使用 D3D11 硬件解码，初始化失败时自动回退到 CPU 路径。
本次升级没有改变该策略。

### 9.1 D3D11 路径

在普通物理机和正常显卡驱动下完成第 7、8 节，重点观察：

- 视频颜色正常，避免把 BGRA 纹理按 RGBA 处理。
- 截图颜色与投屏一致。
- 录制使用收到的 H.264 码流，播放兼容性不受纹理路径影响。

可使用 Sysinternals DebugView 或 Visual Studio“输出”窗口查看
`[D3D11] Init start` 等调试输出。

### 9.2 CPU 回退路径

CPU 回退属于故障降级验证。不要为了测试修改或提交解码器源码。可在没有可用 D3D11
硬件解码能力的虚拟机、远程环境或已知会触发回退的测试机上执行同一套检查，并确认：

- 能继续显示画面。
- PixelBuffer 路径颜色正常。
- 截图和录制仍可用。

如果当前电脑无法稳定触发回退，记录“未覆盖”及显卡/驱动信息，不应通过破坏系统驱动
强制测试。

## 10. 安装包验证（可选）

只有需要交付安装包时才执行：

```powershell
cd .\scrcpy_client_flutter
powershell -ExecutionPolicy Bypass -File .\scripts\package_win.ps1
```

未配置签名环境变量时脚本会生成未签名安装包：

```text
build\dist\HongJing-Setup-1.0.3.exe
```

至少检查安装、覆盖安装、开始菜单/桌面快捷方式、启动、卸载。签名材料与密码不得写入
日志、文档或仓库。

## 11. 失败信息采集

构建失败时保存：

```powershell
flutter --version
dart --version
flutter doctor -v
flutter analyze
flutter build windows --release -v *> flutter_windows_build.log
git status --short
git diff -- pubspec.lock
```

运行或媒体失败时补充：

- Windows 版本、显卡型号和驱动版本。
- Windows 是否为 N/KN 版本、媒体功能包是否已安装。
- debug/release 是否都复现。
- 设备型号、OpenHarmony 版本、连接方式（USB/TCP）。
- 复现步骤、录制开始前画面是否静止、实际录制时长。
- 原始 MP4/PNG，不要通过聊天工具转码后再分析。
- `ffprobe` 输出、`ffmpeg` 全帧解码输出。
- DebugView/Visual Studio 中的 D3D11、Media Foundation 日志。

问题反馈时请同时说明通过项，便于区分 Flutter 3.41 工程问题、Windows 解码问题与设备端
码流问题。

## 12. 验收记录模板

```text
Windows 版本：
Flutter / Dart：
Visual Studio / MSVC：
Windows SDK：
显卡 / 驱动：
设备 / OpenHarmony：
Git 短 SHA：

flutter analyze：
flutter test：
debug 构建：
release 构建：
EXE 版本：

设备发现 / 连接：
D3D11 视频：
CPU 回退：
输入与设备控制：
应用管理：
HDC 终端：
分辨率 / 帧率切换：
静止画面录制：
动态画面录制：
录制中参数 Toast：
PNG 截图：
断开 / 重连：
安装包（可选）：

MP4 路径与 ffprobe 摘要：
PNG 路径与尺寸：
未覆盖项：
异常与日志路径：
最终结论：通过 / 不通过
```
