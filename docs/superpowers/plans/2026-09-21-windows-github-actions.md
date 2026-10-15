# Windows GitHub Actions 构建 Implementation Plan

> **For agentic workers:** 实施时逐项执行并记录验证结果。仓库规则禁止未经要求提交，因此本计划不包含 commit 步骤。

**Goal:** 使用 GitHub 托管的 Windows Runner 检查 Flutter 客户端并生成可下载的鸿镜 Windows 安装包。

**Architecture:** 新增单一 GitHub Actions 工作流，以 `windows-2022` 运行客户端检查，然后调用现有 `package_win.ps1` 完成 Windows Release、内置 HDC、Inno Setup 和可选 Authenticode 签名。Node 结构测试约束工作流的关键安全和交付属性，实际原生构建留给 GitHub Windows Runner 验证。

**Tech Stack:** GitHub Actions、Windows Server 2022、Flutter 3.41.9、PowerShell、Inno Setup 6、Node.js `node:test`。

---

## 文件结构

- Create: `.github/workflows/build-windows.yml`：Windows CI 和安装包 Artifact。
- Create: `scripts/windows_workflow.test.mjs`：工作流结构回归测试。
- Create: `docs/superpowers/plans/2026-09-21-windows-github-actions.md`：本实施计划。

### Task 1: 锁定工作流契约

**Files:**
- Create: `scripts/windows_workflow.test.mjs`

- [x] **Step 1: 写失败测试**

测试读取 `.github/workflows/build-windows.yml`，要求：

- 存在 `workflow_dispatch` 和 `v*` 标签触发器。
- 使用 `windows-2022` 和 `contents: read`。
- 固定 Flutter `3.41.9` 并启用缓存。
- 执行 `flutter analyze`、`flutter test` 和 `scripts/package_win.ps1`。
- 支持可选 `WIN_PFX_BASE64`、`WIN_PFX_PASSWORD` Secrets。
- 使用 `actions/upload-artifact@v4`，上传安装包且 `if-no-files-found: error`。
- 不包含自动 Release 或 `contents: write`。

- [x] **Step 2: 运行测试确认 RED**

Run: `node --test scripts/windows_workflow.test.mjs`

Expected: FAIL，提示 `.github/workflows/build-windows.yml` 不存在。

### Task 2: 实现 Windows 构建工作流

**Files:**
- Create: `.github/workflows/build-windows.yml`

- [x] **Step 1: 配置触发、权限和并发控制**

加入手动触发、`v*` 标签触发、`contents: read`、同引用重复运行取消及 60 分钟超时。

- [x] **Step 2: 配置 Flutter 检查**

使用 `actions/checkout@v4` 和 `subosito/flutter-action@v2`，固定 Flutter `3.41.9`、stable channel 和缓存。在客户端目录依次执行：

```powershell
flutter pub get
flutter analyze
flutter test
```

- [x] **Step 3: 确保 Inno Setup 6 可用**

PowerShell 先检查 PATH 和默认安装目录；不存在时执行：

```powershell
choco install innosetup --yes --no-progress
```

安装后将 `ISCC.exe` 所在目录写入 `GITHUB_PATH`，找不到时立即失败。

- [x] **Step 4: 打包并上传 Artifact**

仅在打包步骤注入可选签名 Secrets，运行：

```powershell
powershell -NoProfile -ExecutionPolicy Bypass -File scripts\package_win.ps1
```

从 `pubspec.yaml` 读取版本作为 Artifact 名称，上传 `build/dist/HongJing-Setup-*.exe`，保留 14 天，找不到文件时失败。

- [x] **Step 5: 运行测试确认 GREEN**

Run: `node --test scripts/windows_workflow.test.mjs`

Expected: PASS。

### Task 3: 静态验证与交付说明

**Files:**
- Verify: `.github/workflows/build-windows.yml`
- Verify: `scripts/windows_workflow.test.mjs`

- [x] **Step 1: 解析 YAML**

Run: `ruby -e "require 'yaml'; YAML.safe_load_file('.github/workflows/build-windows.yml', aliases: true); puts 'YAML OK'"`

Expected: 输出 `YAML OK`。

- [x] **Step 2: 检查差异格式**

Run: `git diff --check -- .github/workflows/build-windows.yml scripts/windows_workflow.test.mjs docs/superpowers/specs/2026-09-21-windows-github-actions-design.md docs/superpowers/plans/2026-09-21-windows-github-actions.md`

Expected: 无输出。

- [x] **Step 3: 检查仓库安全规则**

Run: `bash scripts/check_repository_safety.sh`

Expected: PASS；若该脚本检查整个脏工作区而报告用户已有改动，则单独记录，不修改或清理这些改动。

- [x] **Step 4: 说明 Windows 验证边界**

当前 macOS 环境不执行 `flutter build windows`。完整验证需要将工作流推送到 GitHub，再从 Actions 页面手动运行；提交和推送只在用户明确授权后执行。
