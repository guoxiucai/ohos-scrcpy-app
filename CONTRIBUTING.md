# 贡献指南

感谢你对鸿镜项目的关注！欢迎提交 Issue 和 Pull Request。

## 开发环境准备

### 服务端

| 工具 | 版本 | 说明 |
|------|------|------|
| DevEco Studio | 6.0+ | OpenHarmony 应用 IDE |
| OpenHarmony SDK | API 20 | 需替换为 Full SDK |

### 客户端

| 工具 | 版本 | 说明 |
|------|------|------|
| Flutter | 3.22.1+ | 桌面应用框架 |
| Dart | 3.4+ | 随 Flutter 安装 |
| Xcode | 15+（macOS） | macOS 构建 |
| Visual Studio | 2022+（Windows） | Windows 构建，需 C++ 桌面开发工作负载 |

## 代码规范

- 所有注释、文档、提交信息使用**简体中文**
- 客户端：复用 `state/app_state.dart` 中央状态，不在 widget 里新建独立实例
- 服务端：遵循 ArkTS 严格模式（禁止 `any/unknown`、禁止内联对象类型）
- 提交前验证：
  - 客户端：`flutter analyze` 无报错
  - 服务端：hvigor 构建通过

## 分支与提交规范

- 从 `main` 分支创建特性分支，命名格式：`feat/<描述>` 或 `fix/<描述>`
- 提交信息格式：`<type>:<描述>`，如 `feat:添加音量控制` / `fix:修复TCP断连后重连失败`
- type 可选：`feat`、`fix`、`docs`、`refactor`、`chore`

## 提交流程

1. Fork 本仓库
2. 创建特性分支：`git checkout -b feat/your-feature`
3. 完成开发并确保验证通过
4. 提交 Pull Request 到 `main` 分支
5. 等待 Review，根据反馈修改

## Issue 规范

- **Bug 报告**：请附上设备型号、OpenHarmony 版本、客户端平台、复现步骤
- **功能建议**：请先开 Issue 讨论，说明使用场景和预期效果

## Pull Request 规范

- PR 标题简明扼要，说明本次变更内容
- 描述中说明改了什么、为什么改、如何验证
- 确保不引入无关改动
