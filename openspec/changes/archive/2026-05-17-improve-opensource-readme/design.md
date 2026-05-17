## Context

项目已开源到 GitHub（guoxiucai/ohos-scrcpy-app），README 内容质量较高，但缺少国际化和社区协作基础设施。当前只有 LICENSE 文件，无 CONTRIBUTING、CHANGELOG、Issue/PR 模板。

## Goals / Non-Goals

**Goals:**
- 建立完整的开源社区文档体系，降低外部贡献者参与门槛
- 提供英文 README 覆盖国际开发者
- 规范 Issue 和 PR 提交流程

**Non-Goals:**
- 不重构 README 整体结构
- 不翻译 docs/ 设计文档
- 不涉及代码变更

## Decisions

1. **CONTRIBUTING.md 使用中文**，关键术语保留英文。理由：与项目整体语言一致。

2. **Issue 模板使用中文**。理由：项目暂不考虑国际化。

3. **CHANGELOG 格式遵循 [Keep a Changelog](https://keepachangelog.com/)**，从 1.0.0 开始记录。

4. **徽章选择**：License (MIT)、Platform (macOS/Windows)、Latest Release。不加 CI badge（当前无 CI）。

## Risks / Trade-offs

- **CHANGELOG 回溯**：1.0.0 之前的历史不追溯，从当前版本开始维护。
