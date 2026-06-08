## Why

当前客户端已实现基础按键注入（`KEY_EVENT` 0x14）和服务端 `inputEventClient.injectKeyEvent`，可将 PC 键盘字母/数字/功能键转发到 OpenHarmony 设备。但存在两个短板：(1) 按键注入仅能传 `keyCode` 无法传 Unicode 字符，中文及任意 Unicode 文本无法通过按键通道输入；(2) 侧边栏已有文本输入面板 UI（`_TextInputPanel`），但发送按钮调用的是 `hdc uitest uiInput inputText` 路径，依赖设备侧 uitest 工具可用性且与 scrcpy 协议通道无关，可靠性差。现需让客户端键盘输入（PC 自带键盘/外接键盘）实时转发到服务端当前焦点文本框，并修复文本输入面板使其通过 scrcpy 协议发送文本。

## What Changes

- **客户端键盘事件转发增强**：`MirrorView._onKeyEvent` 中扩展 `_mapKey` 的按键覆盖范围，使字母/数字/符号/功能键的 keyDown/keyUp 均通过 `KEY_EVENT` 协议实时转发到服务端
- **客户端文本输入通道修复**：将 `_TextInputPanel` 的发送路径从 `hdc uitest uiInput inputText` 改为通过 scrcpy 协议 `TEXT_INPUT`（0x15）通道发送 UTF-8 文本
- **服务端文本注入优化**：`handleTextInput` 在现有的剪贴板+Ctrl+V 粘贴方案基础上，增加粘贴前后剪贴板内容的保存与恢复，避免覆盖用户剪贴板
- **客户端键盘焦点管理**：确保 `MirrorView` 的 `FocusNode` 能在连接建立后自动获取焦点，使键盘事件无需额外点击即可生效
- **服务端修饰键支持**：确认 `injectKeyEvent` 对 Shift/Ctrl 修饰键注入的支持情况，确保组合键（如 Ctrl+C/V）能正常工作

## Capabilities

### New Capabilities
- `client-keyboard-forwarding`: 客户端键盘转发 — PC 键盘（内置及外接）按键事件通过 Flutter Focus 系统捕获，经 `KEY_EVENT` 协议实时转发到服务端，注入为 `inputEventClient.injectKeyEvent`
- `text-input-channel`: 文本输入通道 — 客户端侧边栏文本输入面板通过 scrcpy 协议 `TEXT_INPUT`（0x15）通道发送 UTF-8 文本，服务端以剪贴板粘贴方式注入目标文本框

### Modified Capabilities
<!-- 无现有 spec 需要修改 -->

## Impact

- **核心文件**：
  - `scrcpy_client_flutter/lib/ui/mirror_view.dart` — 扩展 `_mapKey` 按键映射表，完善 `_onKeyEvent` 键盘事件捕获与转发逻辑
  - `scrcpy_client_flutter/lib/ui/sidebar.dart` — `_TextInputPanel._send()` 改为通过 `AppState` 走协议通道发送
  - `scrcpy_client_flutter/lib/state/app_state.dart` — 新增 `sendTextInput(String)` 方法，走 `TEXT_INPUT` 协议
  - `scrcpy_server/entry/src/main/ets/scrcpyservice/InputInjector.ets` — `handleTextInput` 增加剪贴板保存/恢复
- **受影响的平台**：macOS / Windows / Linux 客户端均适用（Flutter Focus + KeyEvent 跨平台一致）
- **无新增 SDK 依赖**：客户端 `TEXT_INPUT` 协议编码已在 `protocol.dart` 中实现，服务端仅使用已有的 `pasteboard` / `inputEventClient`
