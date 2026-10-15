# Windows GitHub Actions 构建设计

## 目标

在 macOS 开发环境提交代码后，由 GitHub 托管的 Windows Runner 构建鸿镜 Windows 桌面客户端，并生成可下载的 Inno Setup 安装包。

本设计覆盖：

- 手动触发 Windows 构建。
- 推送 `v*` 版本标签时自动构建。
- 执行 Flutter 静态检查、测试、Windows Release 构建和安装包打包。
- 将安装包作为 GitHub Actions Artifact 上传。
- 复用现有可选 Authenticode 签名机制。

本次不自动创建 GitHub Release，不提交或生成签名材料，不修改应用版本号，也不改变 macOS 或 OpenHarmony 服务端构建流程。

## 方案选择

采用“GitHub Actions 调用现有 Windows 打包脚本”的方案。

未采用的方案：

- 只运行 `flutter build windows --release`：只能得到展开的 Release 目录，不能产出面向用户的安装程序。
- 在工作流 YAML 中重新实现 Inno Setup 和 HDC 打包逻辑：会与 `scripts/package_win.ps1` 形成重复实现，后续容易产生差异。

现有 `scrcpy_client_flutter/scripts/package_win.ps1` 继续作为 Windows 安装包构建的唯一入口。它负责 Flutter Release 构建、内置 `hdc.exe` 和 `libusb_shared.dll`、调用 Inno Setup，以及按环境变量选择性执行 Authenticode 签名。

## 工作流结构

新增 `.github/workflows/build-windows.yml`，使用 `windows-2022` Runner。

触发条件：

```text
workflow_dispatch
push tags: v*
```

工作流使用最小权限 `contents: read`。同一分支或标签重复触发时，通过 concurrency 取消仍在运行的旧任务，避免重复占用 Runner。

构建步骤：

1. 检出仓库源码。
2. 安装固定版本 Flutter `3.41.9` 并启用 pub 缓存。
3. 在 `scrcpy_client_flutter` 中执行 `flutter pub get`。
4. 执行 `flutter analyze`。
5. 执行 `flutter test`。
6. 检查 Inno Setup 6；若 Runner 未预装，则通过 Chocolatey 安装。
7. 调用 `scripts/package_win.ps1` 生成安装包。
8. 上传 `build/dist/HongJing-Setup-*.exe` 为 Artifact。

Artifact 名称包含应用版本或 Git 引用信息，保留期设为 14 天。上传时找不到安装包必须令任务失败，不能产生表面成功但无产物的构建。

## Flutter 与缓存

Flutter 版本固定为 `3.41.9`，与 `pubspec.yaml` 的最低要求一致，避免 GitHub Runner 上 `stable` 指向变化导致不可复现构建。

Flutter 安装 Action 的内置缓存用于缓存 SDK 和 pub 包。`pubspec.lock` 继续作为依赖锁定依据；工作流不运行依赖升级命令。

工作流中的 `flutter pub get` 用于检查依赖解析，打包脚本内部再次执行该命令属于幂等操作，保留脚本独立运行能力。

## Inno Setup

工作流先检查 `ISCC.exe` 是否可发现。如果 GitHub Runner 镜像已包含 Inno Setup 6，则直接使用；否则通过 Chocolatey 安装 `innosetup`。

安装后再次验证 `ISCC.exe` 可由脚本通过 PATH 或默认安装目录找到。安装失败或版本不可用时构建立即失败。

## 签名行为

工作流允许从 GitHub Actions Secrets 注入以下可选变量：

- `WIN_PFX_BASE64`
- `WIN_PFX_PASSWORD`

两个 Secrets 都存在时，现有脚本尝试使用 `signtool.exe` 对安装包签名；未配置时生成未签名安装包，构建本身仍可成功。

工作流不得打印 Secrets、证书内容或密码。临时 PFX 文件的创建和删除仍由现有脚本负责。本次不在仓库中新增或修改任何签名文件。

## 产物与发布边界

构建产物为：

```text
scrcpy_client_flutter/build/dist/HongJing-Setup-<version>.exe
```

工作流只将其上传至对应 Actions Run 的 Artifacts 区域。推送 `v*` 标签不会自动创建 GitHub Release，也不会自动发布、部署或修改版本号。

后续若需要自动 Release，应另行增加带 `contents: write` 权限的独立发布 Job，并明确标签与 `pubspec.yaml` 版本的一致性校验。

## 验证与错误处理

自动验证包括：

- 工作流 YAML 可解析。
- 触发条件包含手动触发和 `v*` 标签。
- Runner 固定为 `windows-2022`。
- Flutter 版本固定为 `3.41.9`。
- 按顺序执行 `flutter analyze`、`flutter test` 和 `package_win.ps1`。
- 安装包上传启用 `if-no-files-found: error`。
- 工作流权限保持为 `contents: read`。

真正的 Windows C++、MFT/D3D11 和 Inno Setup 构建只能在 Windows 环境验证。当前 macOS 环境只进行工作流和脚本的静态检查；工作流推送到 GitHub 后，首次手动运行结果才是完整构建验证依据。

任务失败时保留 GitHub Actions 日志。测试或打包失败不得继续上传不完整产物；Artifact 上传仅在前序步骤全部成功后执行。
