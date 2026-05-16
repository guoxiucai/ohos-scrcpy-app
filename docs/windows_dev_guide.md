# Windows 端开发指南：环境准备 / 调试 / 构建 / 签名

> 适用项目：`scrcpy_client_flutter`（Flutter 3.22.1-ohos-1.0.4）  
> 适用系统：Windows 10 1809+ / Windows 11（x64）

---

## 1. 环境准备

### 1.1 必装工具

| 工具 | 用途 | 获取方式 |
|------|------|----------|
| Flutter SDK（官方 3.22.1） | 编译客户端 | 见 1.2 |
| Build Tools for Visual Studio 2022 | MSVC 编译器 + Windows SDK（命令行，无 IDE） | 见 1.3 |
| Git | 源码管理 | https://git-scm.com/download/win |
| HDC（鸿蒙设备调试） | 设备连接 + 端口转发 | 随 DevEco Studio 一起安装，加入 PATH |

### 1.2 安装 Flutter（官方渠道）

Windows 端开发基于 Flutter 3.22.1。

```powershell
# 解压到本地（示例路径，可自定义）
# 从 https://docs.flutter.dev/release/archive 下载 flutter_windows_3.22.1-stable.zip
Expand-Archive flutter_windows_3.22.1-stable.zip C:\flutter

# 加入环境变量（PowerShell 配置文件或系统变量）
$env:PATH = "C:\flutter\bin;$env:PATH"

# 首次初始化
flutter doctor -v
```

`flutter doctor` 检查清单：
- [x] Flutter（版本 3.22.1）
- [x] Windows Version（≥ 10.0.17763）
- [x] Visual Studio（检测到 Build Tools 也会通过）
- [ ] Android Studio / Xcode（不需要，跳过）
- [x] Connected device：运行时检测

### 1.3 安装 Build Tools for Visual Studio 2022（命令行，无 IDE）

不需要安装完整 Visual Studio IDE，只需命令行构建工具，体积约 4–6 GB。

1. 打开 https://visualstudio.microsoft.com/downloads/
2. 向下滚动找到"**用于 Visual Studio 2022 的生成工具**"，下载 `vs_BuildTools.exe`
3. 运行安装，在"工作负载"页勾选：**使用 C++ 的桌面生成工具**

该工作负载会自动包含：
- MSVC v143 编译器
- Windows 10/11 SDK（≥ 10.0.17763）
- CMake 和 Ninja（Flutter Windows 构建内部使用）

> 完整 Visual Studio 2022（IDE）同样可用，`flutter doctor` 均能识别，两者无区别。  
> 不需要安装"通用 Windows 平台开发"工作负载。

### 1.4 可选工具

| 工具 | 用途 | 获取方式 |
|------|------|----------|
| Inno Setup 6 | 打包成 `Setup.exe` 安装程序 | https://jrsoftware.org/isdl.php |
| Windows 10 SDK（signtool） | Authenticode 代码签名 | VS Installer 附带，或单独下载 |

---

## 2. 首次配置

```powershell
# 进入客户端目录
cd scrcpy_client_flutter

# 获取 dart 依赖
flutter pub get

# 确认可以找到 Windows 设备
flutter devices
# 期望输出包含：Windows (desktop) • windows • windows-x64 • ...
```

---

## 3. 实机联调（调试模式）

### 3.1 服务端前置

1. 安装服务端 hap（在服务端构建出 `entry-default-signed.hap` 后）：
   ```powershell
   hdc install -r entry-default-signed.hap
   ```

2. 建立端口转发（`53535` 是服务端监听端口）：
   ```powershell
   hdc -t <设备SN> fport tcp:5005 tcp:53535
   ```

3. 验证连通性：
   ```powershell
   # 能看到字节流说明服务端已启动
   Test-NetConnection -ComputerName 127.0.0.1 -Port 5005
   ```

### 3.2 启动调试

```powershell
cd scrcpy_client_flutter

# 热重载调试（推荐）
flutter run -d windows

# 调试构建（不热重载，行为更接近 release）
flutter build windows --debug
.\build\windows\x64\runner\Debug\scrcpy_client_flutter.exe
```

### 3.3 常用调试快捷键（flutter run 运行时）

| 按键 | 效果 |
|------|------|
| `r` | 热重载 |
| `R` | 热重启 |
| `q` | 退出 |
| `P` | 显示性能图层 |

### 3.4 静态分析

```powershell
flutter analyze
```

---

## 4. 构建 Release 版本

### 4.1 直接构建

```powershell
cd scrcpy_client_flutter
flutter build windows --release
```

产物目录：`build\windows\x64\runner\Release\`  
主程序：`build\windows\x64\runner\Release\scrcpy_client_flutter.exe`

> 直接运行 `Release\scrcpy_client_flutter.exe` 即可测试 Release 行为，此时 flutter devtools 不可用。

### 4.2 打包成安装程序（Setup.exe）

需要先安装 Inno Setup 6（见 1.4）。

```powershell
cd scrcpy_client_flutter
powershell -ExecutionPolicy Bypass -File scripts\package_win.ps1
```

脚本执行步骤：
1. 从 `pubspec.yaml` 读取版本号
2. `flutter build windows --release`
3. 生成 Inno Setup 脚本（`scripts\installer.iss`），调用 `ISCC.exe` 打包
4. （可选）Authenticode 签名

产物：`build\dist\HongJing-Setup-<version>.exe`

---

## 5. 代码签名

未签名的 exe 在 Windows 上会触发 **SmartScreen "未知发布者"** 弹窗，用户需要手动点"仍要运行"。正式发版建议签名。

### 5.1 签名证书

需要从受信任 CA（如 DigiCert、Sectigo）购买 **代码签名证书（EV 或 OV）**，导出为 `.pfx` 文件。

> EV 证书签名后 SmartScreen 信誉立即建立；OV 证书需要一定下载量才能消除警告。

### 5.2 手动签名

```powershell
# 找到 signtool.exe（VS 安装后一般在此路径）
$signtool = "C:\Program Files (x86)\Windows Kits\10\bin\10.0.22621.0\x64\signtool.exe"

# 对安装包签名（带时间戳）
& $signtool sign `
    /f "your-cert.pfx" `
    /p "your-password" `
    /tr http://timestamp.digicert.com `
    /td sha256 /fd sha256 `
    "build\dist\HongJing-Setup-1.0.0.exe"

# 验证签名
& $signtool verify /pa "build\dist\HongJing-Setup-1.0.0.exe"
```

### 5.3 CI 自动签名（通过打包脚本）

在 CI 环境中设置以下环境变量，打包脚本会自动签名：

```powershell
$env:WIN_PFX_BASE64  = "<pfx 文件的 base64 编码>"
$env:WIN_PFX_PASSWORD = "<pfx 密码>"
```

将 `.pfx` 文件转为 base64：
```powershell
[Convert]::ToBase64String([IO.File]::ReadAllBytes("your-cert.pfx")) | Set-Clipboard
```

---

## 6. 常见问题

### `flutter doctor` 报找不到 Visual Studio
- 确认安装了 Build Tools for VS 2022，且勾选了"**使用 C++ 的桌面生成工具**"工作负载。
- 重新打开 PowerShell，让 PATH 生效。

### 构建报 `MSB8040: Spectre-mitigated libraries`
在 VS Installer 中追加安装：**MSVC v143 - VS 2022 C++ x64 Spectre 缓解库**。

### H264 解码报错 / 黑屏（CoCreateInstance 失败）
Windows N / KN 版本默认缺少 Media Feature Pack，需要手动安装：  
设置 → 应用 → 可选功能 → 添加功能 → 搜索"媒体功能包"安装。

### `hdc` 命令找不到
将 DevEco Studio 安装目录下的 `sdk/default/openharmony/toolchains/` 加入系统 PATH，或直接用完整路径。

### SmartScreen 弹窗"Windows 已保护你的电脑"
- 开发测试阶段：点"更多信息" → "仍要运行"。
- 正式发版：对 exe 和 Setup.exe 做 Authenticode 签名（见第 5 节）。

---

## 7. 构建产物一览

```
build\
  windows\x64\runner\
    Debug\                     # flutter build windows --debug
    Release\                   # flutter build windows --release
      scrcpy_client_flutter.exe
      flutter_windows.dll
      *.dll                    # 依赖 dll（VC runtime 等）
      data\                    # flutter assets
  dist\
    HongJing-Setup-1.0.0.exe  # package_win.ps1 输出的安装包
```

> `Release\` 目录下的所有文件都需要一起发布，`package_win.ps1` 已通过 Inno Setup 将其打包进 `Setup.exe`，用户安装后无需关心 dll 依赖。
