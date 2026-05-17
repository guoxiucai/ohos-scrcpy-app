## Why

项目已开源到 GitHub，当前 README 内容完整但存在以下问题：
1. 缺少 CONTRIBUTING.md、CHANGELOG.md、Issue/PR 模板等标准开源社区基础设施
3. README 中有一处错别字（"O喷Harmony"应为"OpenHarmony"）
4. 缺少徽章（badges）展示项目状态（license、platform、release 等）

参考 scrcpy、rustdesk 等优秀投屏/远控开源项目，补齐社区协作所需的标准文档。

## What Changes

- 修复 README.md 中的错别字和格式细节
- 添加项目状态徽章（License、Platform、Release）
- 新增 CONTRIBUTING.md 贡献指南（独立文件，从 README 简短段落链接过去）
- 新增 CHANGELOG.md 变更日志
- 新增 `.github/ISSUE_TEMPLATE/`（bug_report.md、feature_request.md）
- 新增 `.github/PULL_REQUEST_TEMPLATE.md`

## 非目标

- 不重写 README 的整体结构（当前结构已经很好）
- 不翻译 docs/ 目录下的内部设计文档
- 不涉及任何代码改动或功能变更
- 不做多语言国际化（i18n），暂不提供英文版

## Capabilities

### New Capabilities

- `opensource-docs`: 开源社区标准文档体系（CONTRIBUTING、CHANGELOG、Issue/PR 模板、英文 README）

### Modified Capabilities

（无现有 spec 需要修改）

## Impact

- 仅涉及项目根目录下的文档文件和 `.github/` 目录
- 不影响任何源代码、构建流程或运行时行为
- 受影响平台：无（纯文档变更）
