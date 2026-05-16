# Linux 端开发指南：环境准备 / 调试 / 构建 deb / 签名

> 适用项目：`scrcpy_client_flutter`  
> 适用系统：Ubuntu 22.04 LTS / 24.04 LTS（x86_64）  
> 其他基于 Debian 的发行版（Debian 12、Linux Mint 21）基本兼容，包名可能略有差异。

---

## 1. 环境准备

### 1.1 必装工具

| 工具 | 用途 |
|------|------|
| Flutter SDK（官方 3.22.1 stable） | 编译客户端 |
| GCC / Clang + CMake + Ninja | C++ 插件构建 |
| GTK3 / pkg-config | Flutter Linux 运行时依赖 |
| libavcodec / libswscale | H264 软解 |
| libjpeg-turbo | JPEG 解码 |
| dpkg-deb | 打包 .deb |
| HDC | 鸿蒙设备调试 |

### 1.2 一键安装依赖

```bash
# 构建工具
sudo apt update
sudo apt install -y \
    git curl unzip \
    clang cmake ninja-build \
    pkg-config \
    libgtk-3-dev \
    liblzma-dev \
    libstdc++-12-dev

# 视频解码库
sudo apt install -y \
    libavcodec-dev \
    libavutil-dev \
    libswscale-dev \
    libjpeg-turbo8-dev

# 打包工具（deb）
sudo apt install -y dpkg-deb fakeroot
```

Ubuntu 24.04 上 `libjpeg-turbo8-dev` 改名为 `libjpeg-turbo-dev`，按提示调整。

### 1.3 安装 Flutter SDK

```bash
# 下载 stable 3.22.1（从 flutter.dev 归档页获取链接）
cd ~
wget https://storage.googleapis.com/flutter_infra_release/releases/stable/linux/flutter_linux_3.22.1-stable.tar.xz
tar xf flutter_linux_3.22.1-stable.tar.xz

# 加入 PATH（写入 ~/.bashrc 或 ~/.zshrc）
echo 'export PATH="$HOME/flutter/bin:$PATH"' >> ~/.bashrc
source ~/.bashrc

# 初始化
flutter doctor -v
```

`flutter doctor` 期望结果：
- [x] Flutter（3.22.1）
- [x] Linux toolchain（clang + cmake + ninja）
- [ ] Android Studio（不需要，跳过）
- [x] Connected device

### 1.4 安装 HDC

`hdc` 是 OpenHarmony 设备调试工具（类似 Android 的 `adb`），随 OpenHarmony SDK 发布。

#### 获取方式

**方式 A**：从 DevEco Studio SDK 目录提取（如已安装 DevEco Studio）：
```bash
# 默认路径（api 版本号按实际安装版本替换）
ls ~/OpenHarmony/Sdk/20/toolchains/hdc
```

**方式 B**：从 OpenHarmony SDK 命令行工具包下载（推荐无 IDE 环境）：
1. 访问 https://repo.huaweicloud.com/openharmony/os/ 或 DevEco Studio 下载页面
2. 下载 `commandline-tools-linux-x64-<version>.tar.gz`
3. 解压后 `hdc` 在 `toolchains/` 目录下

#### 配置步骤

```bash
# 1. 安装 hdc 运行依赖
sudo apt install -y libusb-1.0-0

# 2. 将 hdc 所在目录加入 PATH
echo 'export PATH="$HOME/OpenHarmony/Sdk/20/toolchains:$PATH"' >> ~/.bashrc
source ~/.bashrc

# 3. 给 hdc 可执行权限（如果没有）
chmod +x ~/OpenHarmony/Sdk/20/toolchains/hdc

# 4. 验证
hdc -v
# 输出类似：Ver: 2.0.0a
```

#### USB 权限配置（必须，否则普通用户无法识别设备）

```bash
# 创建 udev 规则
sudo tee /etc/udev/rules.d/51-ohos.rules << 'EOF'
# OpenHarmony / HarmonyOS 设备 USB 权限
SUBSYSTEM=="usb", ATTR{idVendor}=="12d1", MODE="0666", GROUP="plugdev"
SUBSYSTEM=="usb", ATTR{idVendor}=="18d1", MODE="0666", GROUP="plugdev"
EOF

# 重载规则
sudo udevadm control --reload-rules
sudo udevadm trigger

# 将当前用户加入 plugdev 组（重新登录后生效）
sudo usermod -aG plugdev $USER

# 验证设备连接（USB 插入设备后）
hdc list targets
# 应显示设备序列号
```

> **说明**：`12d1` 为华为/鸿蒙设备 USB Vendor ID，`18d1` 为通用调试接口。如使用其他厂商设备，需通过 `lsusb` 查看 idVendor 并追加规则。

#### 常见 HDC 命令

| 命令 | 说明 |
|------|------|
| `hdc list targets` | 列出已连接设备 |
| `hdc -t <SN> shell` | 进入设备 shell |
| `hdc -t <SN> fport tcp:5005 tcp:53535` | TCP 端口转发 |
| `hdc install -r app.hap` | 安装 hap 包 |
| `hdc kill` / `hdc start` | 重启 hdc server |
| `hdc tconn <ip>:5555` | 网络模式连接（无需 USB） |

---

## 2. 生成 Linux 平台脚手架

项目尚未包含 `linux/` 目录，需要先生成：

```bash
cd scrcpy_client_flutter

# 添加 linux 平台支持（只需执行一次）
flutter create --platforms=linux .

# 验证生成的目录结构
ls linux/
# 期望：CMakeLists.txt  flutter/  main.cc  my_application.cc  my_application.h
```

生成后，将 Windows 端的以下文件复制到 `linux/runner/` 并按 Linux 差异修改（参见渲染设计文档）：
- `i_decoder.h`（直接复用，无需改动）
- `video_decoder_plugin.h/cpp`（修改 Plugin 注册头文件，见下）
- `raw_decoder.h/cpp`（直接复用）
- `jpeg_decoder.h/cpp`（替换 WIC 为 libjpeg-turbo）
- `h264_decoder.h/cpp`（替换 MFT 为 FFmpeg）

---

## 3. 首次配置

```bash
cd scrcpy_client_flutter
flutter pub get

# 确认 Linux 设备可见
flutter devices
# 期望包含：Linux (desktop) • linux • linux-x64 • ...
```

---

## 4. 实机联调（调试模式）

### 4.1 服务端前置

```bash
# 安装 hap 到设备
hdc install -r entry-default-signed.hap

# 建立端口转发
hdc -t <设备SN> fport tcp:5005 tcp:53535

# 验证连通性
nc -zv 127.0.0.1 5005
# 显示 Connection to 127.0.0.1 5005 port [tcp/*] succeeded! 即正常
```

### 4.2 启动调试

```bash
cd scrcpy_client_flutter

# 热重载调试（推荐）
flutter run -d linux

# 调试构建（行为更接近 release）
flutter build linux --debug
./build/linux/x64/debug/bundle/scrcpy_client_flutter
```

### 4.3 常用调试快捷键（flutter run 运行时）

| 按键 | 效果 |
|------|------|
| `r` | 热重载 |
| `R` | 热重启 |
| `q` | 退出 |
| `P` | 显示性能图层 |

### 4.4 静态分析

```bash
flutter analyze
```

---

## 5. 构建 Release 版本

### 5.1 直接构建

```bash
cd scrcpy_client_flutter
flutter build linux --release
```

产物目录：`build/linux/x64/release/bundle/`

```
bundle/
  scrcpy_client_flutter          # 主程序（ELF）
  lib/                           # libflutter_linux_gtk.so 等
  data/                          # flutter assets
```

直接运行主程序测试：
```bash
./build/linux/x64/release/bundle/scrcpy_client_flutter
```

> 注意：直接运行时，运行机必须已安装所有动态库依赖（`libavcodec` 等）。`.deb` 包通过 `Depends` 字段在安装时自动处理依赖。

### 5.2 打包成 deb 安装包

创建打包脚本 `scripts/package_linux.sh`：

```bash
#!/bin/bash
set -e
cd "$(dirname "$0")/.."

# 从 pubspec.yaml 读取版本
APP_VERSION=$(grep '^version:' pubspec.yaml | sed 's/version: //' | cut -d'+' -f1 | tr -d ' ')
echo "==> 版本: ${APP_VERSION}"

# [1/3] Flutter 构建
echo "==> [1/3] flutter build linux --release"
flutter pub get
flutter build linux --release

BUNDLE="build/linux/x64/release/bundle"
[ -f "${BUNDLE}/scrcpy_client_flutter" ] || { echo "构建产物不存在"; exit 1; }

# [2/3] 组织 deb 目录结构
echo "==> [2/3] 组织 deb 目录结构"
PKG_DIR="build/dist/hongjing_${APP_VERSION}_amd64"
rm -rf "${PKG_DIR}"

# 程序文件
install -Dm755 "${BUNDLE}/scrcpy_client_flutter" \
    "${PKG_DIR}/usr/lib/hongjing/scrcpy_client_flutter"
cp -r "${BUNDLE}/lib"  "${PKG_DIR}/usr/lib/hongjing/"
cp -r "${BUNDLE}/data" "${PKG_DIR}/usr/lib/hongjing/"

# 启动器
install -Dm755 /dev/stdin "${PKG_DIR}/usr/bin/hongjing" << 'EOF'
#!/bin/sh
exec /usr/lib/hongjing/scrcpy_client_flutter "$@"
EOF

# 桌面快捷方式
install -Dm644 /dev/stdin "${PKG_DIR}/usr/share/applications/hongjing.desktop" << EOF
[Desktop Entry]
Name=鸿镜
Exec=/usr/bin/hongjing
Icon=hongjing
Type=Application
Categories=Utility;
EOF

# 图标
if [ -f "branding/icon-1024.png" ]; then
    install -Dm644 branding/icon-1024.png \
        "${PKG_DIR}/usr/share/icons/hicolor/1024x1024/apps/hongjing.png"
fi

# DEBIAN/control
mkdir -p "${PKG_DIR}/DEBIAN"
cat > "${PKG_DIR}/DEBIAN/control" << EOF
Package: hongjing
Version: ${APP_VERSION}
Section: utils
Priority: optional
Architecture: amd64
Depends: libavcodec58 | libavcodec59 | libavcodec60, libswscale5 | libswscale6 | libswscale7, libjpeg-turbo8 | libturbojpeg, libgtk-3-0
Maintainer: Guangzhou Shirui Electronics Co., Ltd.
Description: 鸿镜 OpenHarmony 投屏调试工具
 通过 HDC 连接 OpenHarmony 设备，实时镜像屏幕并提供触控注入、HAP 安装等功能。
EOF

# [3/3] 构建 deb
echo "==> [3/3] 构建 deb"
mkdir -p build/dist
fakeroot dpkg-deb --build "${PKG_DIR}" \
    "build/dist/hongjing_${APP_VERSION}_amd64.deb"

echo ""
echo "完成。安装包位于 build/dist/hongjing_${APP_VERSION}_amd64.deb"
echo "安装命令: sudo apt install ./build/dist/hongjing_${APP_VERSION}_amd64.deb"
```

```bash
chmod +x scripts/package_linux.sh
./scripts/package_linux.sh
```

---

## 6. 安装与卸载

```bash
# 安装（apt 会自动处理依赖）
sudo apt install ./build/dist/hongjing_1.0.0_amd64.deb

# 卸载
sudo apt remove hongjing

# 完全卸载（含配置文件）
sudo apt purge hongjing
```

---

## 7. 代码签名

Linux deb 包通常不做 exe 级别的代码签名，但可以对 deb 包做 GPG 签名供包仓库分发使用。

### 7.1 生成 GPG 密钥（如尚未有）

```bash
gpg --gen-key
# 按提示输入姓名、邮箱、密码
```

### 7.2 对 deb 包签名

```bash
# 安装 dpkg-sig
sudo apt install dpkg-sig

# 签名
dpkg-sig --sign builder build/dist/hongjing_1.0.0_amd64.deb

# 验证
dpkg-sig --verify build/dist/hongjing_1.0.0_amd64.deb
```

### 7.3 建立 APT 仓库（可选）

如需提供 `apt` 在线安装渠道，可用 `reprepro` 搭建简易仓库，此处不展开。

---

## 8. 常见问题

### `flutter doctor` 报缺少 clang 或 cmake

```bash
sudo apt install clang cmake ninja-build
```

### 构建报 `Could not find package: libavcodec`

```bash
sudo apt install libavcodec-dev libavutil-dev libswscale-dev
# Ubuntu 24.04 可能需要：
sudo apt install libavcodec-dev libswscale-dev  # 包名不变，但 so 版本不同
```

### 运行报 `error while loading shared libraries: libavcodec.so.XX`

直接运行 bundle 时，需要机器上已有对应版本的 so。通过 `.deb` 安装后 `Depends` 会自动拉取。
或手动安装运行时库：

```bash
sudo apt install libavcodec58 libswscale5 libjpeg-turbo8
# Ubuntu 24.04：
sudo apt install libavcodec60 libswscale7 libjpeg-turbo8
```

### GTK 初始化失败 / 窗口无法显示（远程 SSH 环境）

SSH 默认无 DISPLAY，需要本地 X11 转发或在本机终端运行：

```bash
# 本机终端运行
./scrcpy_client_flutter

# 或 SSH 时开启 X11 转发
ssh -X user@host
```

Wayland 环境下若有问题，强制使用 X11：

```bash
GDK_BACKEND=x11 ./scrcpy_client_flutter
```

### `hdc` 无法识别设备

```bash
# 检查 USB 连接
hdc list targets

# 重启 hdc server
hdc kill
hdc start
```

---

## 9. 构建产物一览

```
build/
  linux/x64/
    debug/bundle/
      scrcpy_client_flutter      # flutter run -d linux 产物
    release/bundle/
      scrcpy_client_flutter      # flutter build linux --release 产物
      lib/                       # Flutter 运行时 so
      data/                      # assets
  dist/
    hongjing_1.0.0_amd64.deb    # package_linux.sh 输出的安装包
```
