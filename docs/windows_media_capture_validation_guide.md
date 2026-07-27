# Windows 录制视频与截图功能编译验证指南

> 适用版本：鸿镜 1.0.2  
> 功能代码基线：`37b1209 feat: 增加录制视频与截图功能`  
> 适用系统：Windows 10 1809+ / Windows 11（x64）  
> 验证目标：Windows 客户端能够录制可播放的 H.264 MP4，并从当前解码帧保存可查看的 PNG。

本文档用于将录制与截图功能交接到 Windows 设备后完成首次编译、真机联调和验收。通用 Windows 开发环境、安装包与签名说明可补充参考 [windows_dev_guide.md](windows_dev_guide.md)。

## 1. 验收范围

本轮 Windows 验收需要确认：

- 客户端 Debug 和 Release 均能完成编译。
- 客户端可以发现并连接已安装 1.0.2 服务端的 OpenHarmony 设备。
- “录制与截图”区域位于侧边栏“设备控制”和“文本输入”之间，风格与现有 UI 一致。
- 录制只在 H.264 模式下启用，从收到的第一个有效 IDR 开始写入。
- 录制期间不能切换分辨率或帧率，并显示提示。
- 停止录制后在桌面生成 MP4，弹窗显示完整路径，“打开路径”能在资源管理器中选中文件。
- MP4 第一帧是关键帧，宽高、帧率、时长合理，`ffplay` 能完整播放且无明显解码错误。
- 截图从当前解码帧生成 PNG，颜色、方向和宽高正确。
- 截图完成后弹窗显示完整路径，“打开路径”能在资源管理器中选中文件。
- 录制过程中仍可以截图。
- 断开设备或退出客户端时，不在桌面留下表面成功但实际损坏的录制文件。

以下内容不属于本轮范围：

- 音频录制。
- RAW/JPEG 视频流录制为 MP4。RAW/JPEG 模式只支持截图。
- Linux 原生实现。
- 修改服务端签名、设备权限白名单或系统配置。

## 2. 验证前准备

### 2.1 Windows 环境

建议准备以下工具：

| 工具 | 要求 | 用途 |
| --- | --- | --- |
| Windows | Windows 10 1809+ 或 Windows 11 x64 | Flutter Windows 桌面运行环境 |
| Flutter | 项目规定的 3.22.1 系列 | 客户端构建与测试 |
| Visual Studio 2022 / Build Tools | “使用 C++ 的桌面开发”工作负载 | MSVC、CMake、Windows SDK |
| Git | 任意受支持版本 | 同步和确认代码基线 |
| HDC | 能正常识别目标设备 | 设备发现、端口转发 |
| FFmpeg | 包含 `ffprobe` 和 `ffplay` | MP4/PNG 产物验证 |
| Inno Setup 6 | 可选 | 生成正式安装包 |

首次使用 Windows Flutter 桌面时执行：

```powershell
flutter config --enable-windows-desktop
flutter doctor -v
flutter devices
```

`flutter doctor -v` 至少应确认：

- Windows 系统版本满足要求。
- Visual Studio 或 Build Tools 可用。
- MSVC v143、Windows SDK、CMake 和 Ninja 已安装。
- `flutter devices` 包含 `Windows (desktop)`。

如果依赖安装时报插件需要符号链接权限，在 Windows 设置中开启“开发者模式”，重新打开 PowerShell 后再执行。

### 2.2 确认源码基线

在仓库根目录执行：

```powershell
git log -1 --oneline
git branch --contains 37b1209
git status --short
```

当前分支必须包含提交 `37b1209`。后续如果已经产生新的提交，`HEAD` 不必等于该提交，但 `git branch --contains 37b1209` 必须能列出当前分支。

不要执行 `flutter pub upgrade`，避免在验证过程中引入依赖版本变化。

### 2.3 确认 HDC 和设备

```powershell
where.exe hdc
hdc list targets
```

设置本次测试使用的设备 SN：

```powershell
$serial = "<设备SN>"
hdc -t $serial shell param get const.product.name
hdc -t $serial shell bm dump -n com.ohos.scrcpy.server |
  Select-String "versionName|versionCode"
```

预期服务端版本：

```text
versionName: 1.0.2
versionCode: 1000002
```

注意事项：

- 开始 Windows 测试前关闭 macOS 上正在运行的鸿镜客户端，避免两个客户端同时占用设备服务。
- 客户端会自动执行 `hdc fport` 并选择本机端口，正常验证时不需要手工建立固定端口转发。
- Debug 构建和集成测试优先从系统 `PATH` 查找 `hdc.exe`，因此必须保证 `where.exe hdc` 成功。
- 如果设备上已经安装并验证过 1.0.2 服务端，不要在 Windows 上重新生成签名或修改权限白名单。

### 2.4 确认 FFmpeg

```powershell
where.exe ffprobe
where.exe ffplay
ffprobe -version
ffplay -version
```

如果命令不存在，将 FFmpeg 的 `bin` 目录加入当前 PowerShell 的 `PATH`，或者在后续命令中使用完整路径。

## 3. Windows 客户端编译

### 3.1 清理并获取依赖

在仓库根目录进入客户端：

```powershell
cd scrcpy_client_flutter
flutter clean
flutter pub get
```

如果仓库路径很长，建议放在类似 `C:\dev\ohos-scrcpy-app` 的短路径下，减少 Windows 工具链路径长度问题。

### 3.2 静态检查和单元测试

```powershell
flutter analyze
flutter test
```

预期结果：

- `flutter analyze` 输出 `No issues found!`。
- `flutter test` 全部通过，至少覆盖：
  - 视频帧时间戳按微秒解析；
  - 原生媒体结果映射；
  - 录制状态阻止视频参数切换。

### 3.3 Debug 编译

```powershell
flutter build windows --debug
```

预期主程序：

```text
build\windows\x64\runner\Debug\scrcpy_client_flutter.exe
```

确认版本信息：

```powershell
$debugExe = Resolve-Path ".\build\windows\x64\runner\Debug\scrcpy_client_flutter.exe"
(Get-Item $debugExe).VersionInfo |
  Format-List FileVersion,ProductVersion
```

预期版本为 1.0.2，其中 Windows 数字文件版本可能显示为 `1.0.2.2`。

直接启动：

```powershell
& $debugExe
```

如果 `hdc.exe` 不在 PATH，可以在启动前临时加入其目录：

```powershell
$env:PATH = "C:\path\to\openharmony\toolchains;$env:PATH"
& $debugExe
```

### 3.4 Release 编译

Debug 真机流程通过后执行：

```powershell
flutter build windows --release
```

预期主程序：

```text
build\windows\x64\runner\Release\scrcpy_client_flutter.exe
```

直接运行 Release 时，必须连同同目录 DLL 和 `data` 目录一起保留，不能只复制 EXE。

如需生成安装包并自动带上内置 Windows HDC：

```powershell
powershell -ExecutionPolicy Bypass -File scripts\package_win.ps1
```

该命令要求已安装 Inno Setup 6，预期产物：

```text
build\dist\HongJing-Setup-1.0.2.exe
```

## 4. 自动化真机验证

### 4.1 执行条件

执行集成测试前确认：

- 目标 OpenHarmony 设备已连接且 `hdc list targets` 可见。
- 设备上服务端为 1.0.2。
- 其他电脑上的鸿镜客户端已经退出。
- 当前没有手动运行的 Windows 鸿镜客户端。
- 设备能够输出 H.264 视频流；如果设备降级为 JPEG/RAW，录制按钮会禁用，测试将无法通过。
- 桌面目录可写，磁盘空间充足。

### 4.2 运行 E2E

```powershell
flutter test integration_test\media_capture_e2e_test.dart `
  -d windows `
  -r expanded
```

测试会自动完成：

1. 启动客户端。
2. 刷新并选择设备。
3. 建立连接并等待视频首帧。
4. 请求关键帧并开始录制。
5. 录制约 5 秒。
6. 停止并完成 MP4 封装。
7. 检查 MP4 路径、扩展名和文件大小。
8. 从当前解码帧截图。
9. 检查 PNG 路径、扩展名、文件大小和 PNG 文件头。

成功时日志中会包含：

```text
E2E_RECORDING_PATH=C:\...\Desktop\HongJing_Recording_*.mp4
E2E_SCREENSHOT_PATH=C:\...\Desktop\HongJing_Screenshot_*.png
```

如需同时保留完整日志：

```powershell
flutter test integration_test\media_capture_e2e_test.dart `
  -d windows `
  -r expanded 2>&1 |
  Tee-Object windows_media_e2e.log
```

PowerShell 管道执行后，需要同时检查测试结尾是否为 `All tests passed`，不要只检查日志文件是否生成。

## 5. 手工功能验收

自动化测试验证核心原生流程，以下 UI 和交互仍需手工确认。

### 5.1 连接与界面

1. 启动 Debug 或 Release 客户端。
2. 点击刷新设备并选择目标设备。
3. 点击连接，等待画面稳定。
4. 确认侧边栏“设备控制”和“文本输入”之间显示“录制与截图”区域。
5. 确认截图按钮已启用。
6. H.264 模式下确认“开始录制”已启用。

如果截图已启用但录制仍禁用，优先确认设备是否降级为 JPEG/RAW；这不是 Windows MP4 写入器故障。

### 5.2 录制

1. 点击“开始录制”。
2. 确认出现“录制过程中不允许切换分辨率或帧率”提示。
3. 确认按钮短暂显示等待关键帧，随后进入“停止 · 00:xx”状态。
4. 录制过程中尝试修改分辨率或帧率：
   - 参数不能发生变化；
   - 不能向服务端发送新的分辨率或帧率；
   - UI 应显示阻止提示。
5. 保持设备画面有可识别的动态内容，录制 5～10 秒。
6. 可在录制过程中点击一次截图，确认两项功能互不排斥。
7. 点击停止录制。
8. 确认出现“录制已保存”弹窗并显示完整 MP4 路径。
9. 先验证“关闭”按钮。
10. 再录制一次并点击“打开路径”，确认资源管理器打开桌面并选中新生成的 MP4。

MP4 默认命名：

```text
HongJing_Recording_yyyyMMdd_HHmmss.mp4
```

### 5.3 截图

1. 保持设备画面稳定且包含明显的红、蓝、文字和方向参照物。
2. 点击“截图”。
3. 确认出现“截图已保存”弹窗并显示完整 PNG 路径。
4. 点击“关闭”，确认弹窗正常关闭。
5. 再截图一次并点击“打开路径”。
6. 确认资源管理器选中新生成的 PNG。
7. 使用系统图片查看器打开 PNG，检查：
   - 图片可正常打开；
   - 宽高与当前视频画面一致；
   - 方向正确；
   - 红蓝通道没有交换；
   - 图片不是全透明、全黑或上一连接残留画面；
   - 图片只包含设备画面，不包含客户端侧边栏和鼠标 UI。

PNG 默认命名：

```text
HongJing_Screenshot_yyyyMMdd_HHmmss.png
```

### 5.4 生命周期

补充执行以下场景：

- 完成一次录制后立即再次录制，第二个 MP4 仍可播放。
- 截图后切换设备方向，再次截图，宽高和方向随新画面更新。
- 录制过程中主动断开设备，客户端应退出录制状态，不生成伪成功文件。
- 重新连接后可以再次录制和截图。
- 退出客户端后任务管理器中没有残留的鸿镜、HDC 或媒体写入进程。

## 6. MP4 产物验证

### 6.1 获取最新 MP4

Windows 原生实现使用系统桌面 Known Folder，即使桌面被 OneDrive 重定向，也应使用下面的方式定位：

```powershell
$desktop = [Environment]::GetFolderPath("Desktop")
$mp4 = Get-ChildItem $desktop -Filter "HongJing_Recording_*.mp4" |
  Sort-Object LastWriteTime -Descending |
  Select-Object -First 1

if (-not $mp4) {
  throw "桌面未找到录制 MP4"
}

$mp4 | Format-List FullName,Length,LastWriteTime
```

### 6.2 检查容器和视频流

```powershell
ffprobe -v error `
  -select_streams v:0 `
  -show_entries stream=codec_name,profile,width,height,avg_frame_rate,nb_frames `
  -show_entries format=format_name,duration,size `
  -of default=noprint_wrappers=1 `
  $mp4.FullName
```

验收标准：

- `codec_name=h264`。
- `format_name` 包含 `mov,mp4`。
- 宽高与当前投屏配置一致。
- `duration` 与实际录制时长接近。
- `avg_frame_rate` 合理，不出现极端帧率。
- `size` 大于 0，且不是仅包含 MP4 头的空文件。

### 6.3 检查第一帧关键帧

```powershell
$firstFrameJson = ffprobe -v error `
  -select_streams v:0 `
  -read_intervals "%+#1" `
  -show_frames `
  -show_entries frame=key_frame,pict_type `
  -of json `
  $mp4.FullName

$firstFrame = ($firstFrameJson | ConvertFrom-Json).frames[0]
$firstFrame | Format-List key_frame,pict_type
```

预期：

```text
key_frame : 1
pict_type : I
```

如果第一帧不是关键帧，即使部分播放器能够容错播放，也判定本轮录制验收失败。

### 6.4 播放验证

```powershell
ffplay -autoexit -loglevel warning $mp4.FullName
```

验收标准：

- 可以从头播放到尾。
- 首屏正常，不需要等待后续关键帧才出现画面。
- 没有大面积马赛克、绿屏、冻结或明显时间跳跃。
- `ffplay` 控制台没有持续出现 H.264 解码错误。
- 播放时长与 `ffprobe` 输出基本一致。

建议同时使用 Windows 系统播放器打开一次，确认常见 Windows 播放链路可识别：

```powershell
Start-Process $mp4.FullName
```

## 7. PNG 产物验证

### 7.1 获取最新 PNG

```powershell
$desktop = [Environment]::GetFolderPath("Desktop")
$png = Get-ChildItem $desktop -Filter "HongJing_Screenshot_*.png" |
  Sort-Object LastWriteTime -Descending |
  Select-Object -First 1

if (-not $png) {
  throw "桌面未找到截图 PNG"
}

$png | Format-List FullName,Length,LastWriteTime
```

### 7.2 检查 PNG 文件头

```powershell
$pngBytes = [IO.File]::ReadAllBytes($png.FullName)
if ($pngBytes.Length -lt 8) {
  throw "PNG 文件过小"
}
[BitConverter]::ToString($pngBytes[0..7])
```

预期输出：

```text
89-50-4E-47-0D-0A-1A-0A
```

### 7.3 检查图片尺寸

```powershell
Add-Type -AssemblyName System.Drawing
$image = [System.Drawing.Image]::FromFile($png.FullName)
try {
  $image | Format-List Width,Height,PixelFormat
} finally {
  $image.Dispose()
}
```

宽高应与截图时的视频画面一致。

### 7.4 查看图片

```powershell
Start-Process $png.FullName
```

除可打开外，必须人工检查颜色和方向。Windows CPU PixelBuffer 使用 RGBA，D3D11 输出纹理使用 BGRA；红蓝互换或图片透明通常说明路径间像素格式处理有误。

正常带硬件 H.264 MFT 的电脑通常使用 D3D11 路径；硬件初始化失败时会自动回退 CPU 路径。本轮至少要验证当前 Windows 电脑实际选择的路径。如果环境自然发生 CPU 回退，录制和截图仍必须通过。无需为了强制回退而临时修改生产代码。

## 8. Release 与安装包复验

Debug 验收通过后，还需要至少用 Release 或安装包重复一次最短流程：

1. 连接设备。
2. 录制 5 秒。
3. 停止并使用“打开路径”定位 MP4。
4. 使用 `ffprobe` 检查第一帧。
5. 使用 `ffplay` 播放。
6. 截图并使用系统图片查看器打开。

如果使用安装包验证：

- 安装版本显示为 1.0.2。
- 安装目录中 `tools\hdc.exe` 和 `tools\libusb_shared.dll` 存在。
- 从开始菜单或桌面快捷方式启动时仍能发现设备。
- 卸载旧版本再安装不是必需步骤；应优先验证 1.0.1 → 1.0.2 覆盖安装。

## 9. 常见问题

### 9.1 Windows 构建找不到 Visual Studio

现象：

```text
Unable to find suitable Visual Studio toolchain
```

处理：

- 打开 Visual Studio Installer。
- 安装“使用 C++ 的桌面开发”。
- 确认包含 MSVC v143、Windows SDK、CMake 和 Ninja。
- 关闭并重新打开 PowerShell，再执行 `flutter doctor -v`。

### 9.2 构建报 Spectre 库缺失

现象：

```text
MSB8040: Spectre-mitigated libraries are required
```

处理：

- 在 Visual Studio Installer 中增加 MSVC v143 x64 Spectre 缓解库。
- 执行 `flutter clean` 后重新构建。

### 9.3 插件构建要求符号链接

处理：

- Windows 设置 → 隐私和安全性 → 开发者选项 → 开启开发者模式。
- 重新打开 PowerShell。
- 执行 `flutter clean`、`flutter pub get` 后重试。

### 9.4 HDC 找不到设备

依次检查：

```powershell
where.exe hdc
hdc list targets
hdc -t $serial shell param get const.product.name
```

同时确认：

- USB 调试已开启。
- Windows 驱动正常。
- 没有另一个鸿镜客户端占用设备服务。
- 防火墙没有阻止鸿镜本机 TCP 通信。

### 9.5 画面正常但录制按钮禁用

常见原因：

- 当前视频配置是 JPEG 或 RAW，不是 H.264。
- 尚未收到第一帧。
- 上一次录制仍在保存或异常状态尚未清理。

先断开并重新连接，观察设备是否确实输出 H.264。不要把 JPEG/RAW 模式无法录制误判为 Windows MP4 封装失败。

### 9.6 等待关键帧超时

检查：

- 服务端是否为 1.0.2。
- 设备编码器是否支持运行时请求 I 帧。
- 连接后画面是否持续更新。
- macOS 或其他 Windows 客户端是否仍连接同一设备。

如果每次都在约 5 秒后提示等待关键帧超时，需要收集客户端日志和设备侧服务日志，不要只反复点击录制。

### 9.7 Media Foundation 启动或 H.264 初始化失败

Windows N/KN 版本可能缺少媒体组件。安装对应系统的 Media Feature Pack，并更新显卡驱动后重启。

如果硬件 D3D11 解码失败，客户端应尝试 CPU 回退；只有硬件和 CPU 两条路径都失败时，才会完全无法显示 H.264。

### 9.8 MP4 生成但无法播放

立即保留问题文件并执行：

```powershell
ffprobe -v warning -show_format -show_streams $mp4.FullName
ffprobe -v warning -select_streams v:0 `
  -show_packets `
  -show_entries packet=pts_time,dts_time,duration_time,flags `
  -of csv `
  $mp4.FullName > mp4_packets.csv
```

重点检查：

- 第一帧是否为 IDR/I 帧。
- SPS/PPS 是否成功写入 MP4 sample description。
- PTS 是否单调且单位为微秒。
- 文件是否在 `Finalize` 完成前被中断。
- 设备端是否意外开启 B 帧；当前协议没有独立 DTS，不支持 B 帧重排。

不要用转码修复后的文件作为功能通过依据，必须保证客户端原始输出的 MP4 可直接播放。

### 9.9 PNG 无法打开、透明或颜色错误

检查：

- PNG 文件头是否正确。
- 宽高是否为 0 或异常值。
- 正常硬件路径是否从 D3D11 BGRA 纹理读取。
- CPU 回退路径是否按 Flutter Windows PixelBuffer 的 RGBA 约定处理。
- 红色和蓝色是否交换。

将问题 PNG、当前设备画面照片、GPU 型号和客户端日志一并保留。

### 9.10 文件没有出现在预期桌面

不要假定桌面一定是 `%USERPROFILE%\Desktop`。系统可能将桌面重定向到 OneDrive。使用：

```powershell
[Environment]::GetFolderPath("Desktop")
```

客户端和本文验证命令都以 Windows Known Folder 为准。

## 10. 日志收集与重试规则

### 10.1 构建日志

```powershell
flutter build windows --debug -v 2>&1 |
  Tee-Object windows_debug_build.log
```

### 10.2 运行日志

```powershell
flutter run -d windows -v 2>&1 |
  Tee-Object windows_flutter_run.log
```

### 10.3 E2E 日志

```powershell
flutter test integration_test\media_capture_e2e_test.dart `
  -d windows `
  -r expanded 2>&1 |
  Tee-Object windows_media_e2e.log
```

### 10.4 问题回传材料

出现问题时至少保留：

- `git rev-parse HEAD` 输出。
- `flutter --version` 和 `flutter doctor -v`。
- Windows 版本：`winver`。
- GPU 型号和驱动版本。
- `hdc list targets` 输出，设备 SN 可在对外材料中脱敏。
- 服务端版本。
- Debug/Release 以及直接运行/安装包运行中的哪一种失败。
- 完整构建或 E2E 日志。
- 失败 MP4/PNG 原文件。
- `ffprobe` 输出和 `mp4_packets.csv`。
- UI 错误弹窗中的 HRESULT。

同一问题最多尝试 6 次。每次只改变一个变量，并记录：

```text
尝试序号：
修改/操作：
结果：
新增日志：
```

第 6 次仍未解决时停止继续试错，保留现场和全部日志，与开发人员沟通后再继续。

## 11. 最终验收记录模板

```text
【环境】
Windows 版本：
Flutter 版本：
Visual Studio / Build Tools：
GPU / 驱动：
代码提交：
服务端版本：
设备型号 / 系统版本：

【构建】
[ ] flutter analyze 通过
[ ] flutter test 通过
[ ] Debug 编译通过
[ ] Release 编译通过
[ ] 安装包生成/安装通过（如本轮要求）

【录制】
[ ] H.264 模式录制按钮可用
[ ] 能从关键帧开始录制
[ ] 录制期间分辨率/帧率切换被阻止
[ ] 录制期间可以截图
[ ] 停止后弹窗路径正确
[ ] 打开路径能选中 MP4
[ ] ffprobe 识别 H.264 MP4
[ ] 第一帧 key_frame=1 / pict_type=I
[ ] ffplay 从头到尾正常播放
[ ] 第二次录制仍正常

【截图】
[ ] 空闲状态截图成功
[ ] 录制过程中截图成功
[ ] PNG 文件头正确
[ ] PNG 宽高正确
[ ] PNG 方向正确
[ ] PNG 红蓝通道正确
[ ] PNG 非透明/非黑屏/非旧帧
[ ] 打开路径能选中 PNG

【生命周期】
[ ] 断开设备后录制状态清理
[ ] 重连后录制与截图仍可用
[ ] 退出客户端后无相关残留进程

【产物路径】
MP4：
PNG：
构建日志：
E2E 日志：

【结论】
通过 / 不通过

【遗留问题】
```

