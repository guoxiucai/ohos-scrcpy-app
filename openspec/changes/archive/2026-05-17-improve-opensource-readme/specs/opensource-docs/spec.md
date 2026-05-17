## ADDED Requirements

### Requirement: 贡献指南
CONTRIBUTING.md 包含开发环境、代码规范、提交流程、Issue/PR 规范。

#### Scenario: 新贡献者首次提交
- **WHEN** 开发者希望贡献代码
- **THEN** CONTRIBUTING.md 提供完整的从 fork 到 PR 的流程说明

### Requirement: 变更日志
CHANGELOG.md 遵循 Keep a Changelog 格式，从 1.0.0 版本开始记录。

#### Scenario: 用户了解版本变化
- **WHEN** 用户查看项目更新内容
- **THEN** CHANGELOG.md 按版本列出 Added/Changed/Fixed 等分类

### Requirement: Issue 和 PR 模板
.github/ 目录下提供 bug 报告、功能请求的 Issue 模板和 PR 模板。

#### Scenario: 用户提交 Bug 报告
- **WHEN** 用户新建 Issue 选择 Bug Report 模板
- **THEN** 模板引导填写设备型号、OH 版本、客户端平台、复现步骤、期望行为

### Requirement: README 修缮
修复现有 README 中的错别字，添加状态徽章。

#### Scenario: 访问者查看项目首页
- **WHEN** 用户打开 GitHub 仓库首页
- **THEN** 可看到 License、Platform、Release 徽章，无错别字
