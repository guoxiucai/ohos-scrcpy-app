## 1. 客户端键盘映射扩展

- [x] 1.1 在 `OhKeyCode` 类中补充缺失的 KeyCode 常量定义：`numpad0-9`（2103-2112）、`numpadAdd`（2116）、`numpadSubtract`（2115）、`numpadMultiply`（2114）、`numpadDivide`（2113）、`numpadDot`（2117）、`numpadComma`（2118）、`numpadEnter`（2119）、`numpadEquals`（2120）、`insert`（2083）、`moveHome`（2081）、`moveEnd`（2082）、`pageUp`（2068）、`pageDown`（2069）、`altRight`（2046）、`metaLeft`（2076）、`metaRight`（2077）、`numLock`（2102）、`scrollLock`（2075）、`sysrq`（2079）
- [x] 1.2 在 `_mapKey` 方法中补充缺失的按键映射分支：数字小键盘键、Insert/Home/End/PageUp/PageDown、AltRight、MetaLeft/MetaRight、NumLock、ScrollLock、PrintScreen
- [x] 1.3 运行 `flutter analyze` 确认无编译错误

## 2. 客户端键盘焦点管理

- [x] 2.1 在 `_MirrorViewState` 中添加 `connState` 监听，当状态变为 `ConnState.connected` 时调用 `_focusNode.requestFocus()`
- [x] 2.2 确认 `Focus` widget 的 `autofocus: true` 在初始连接场景下生效
- [x] 2.3 运行 `flutter analyze` 确认无编译错误

## 3. 客户端文本输入通道切换

- [x] 3.1 在 `AppState` 中新增 `sendTextInput(String text)` 方法：检查连接状态 → `encodeTextInput(text)` → `stream.send(PacketType.control, ...)`
- [x] 3.2 修改 `_TextInputPanel._send()`：从 `widget.state.inputText(text)` 改为 `widget.state.sendTextInput(text)`
- [x] 3.3 保留 `AppState.inputText()` 方法（hdc uitest 路径）作为备用，但不再从 UI 层调用
- [x] 3.4 运行 `flutter analyze` 确认无编译错误

## 4. 服务端剪贴板保存与恢复

- [x] 4.1 在 `InputInjector.handleTextInput` 中，`pasteboard.setData()` 前通过 `pasteboard.getSystemPasteboard().getData()` 缓存原剪贴板内容
- [x] 4.2 在 Ctrl+V 粘贴完成后（三个 setTimeout 链条末尾），将缓存的原剪贴板内容通过 `setData()` 写回；读取失败时走无恢复注入路径
- [x] 4.3 对 `getData()` 和 `setData()`（恢复阶段）的异常进行 try-catch，失败时记录 hilog 警告但不影响注入流程
- [x] 4.4 运行 `hvigor` 构建命令验证编译通过

## 5. 联调验证

- [ ] 5.1 启动服务端（hdc install + hdc fport），启动客户端连接设备，确认连接后键盘焦点自动获取（无需手动点击镜像区域）
- [ ] 5.2 测试字母键（a-z）输入，确认设备焦点文本框正确显示对应字符
- [ ] 5.3 测试数字键（0-9）输入，确认设备焦点文本框正确显示对应数字
- [ ] 5.4 测试方向键（↑↓←→），确认设备端焦点导航行为正确
- [ ] 5.5 测试 Enter/Tab/Space/Backspace/Delete/Escape 键，确认功能正确
- [ ] 5.6 测试数字小键盘键（Numpad0-9、Numpad+、NumpadEnter 等），确认功能正确
- [ ] 5.7 测试侧边栏文本输入面板：输入文本（含中文）→ 点击发送，确认设备焦点文本框显示对应文本
- [ ] 5.8 测试剪贴板恢复：发送文本前复制一段内容到设备剪贴板，发送后确认剪贴板恢复为原内容
- [ ] 5.9 测试断连后键盘事件不再转发（`connState != connected` 时按键无响应）

## 6. 侧边栏折叠/展开

- [x] 6.1 修改 `SplitView` 支持右侧面板折叠：新增 `_collapsed` 状态 + `AnimationController` 动画过渡
- [x] 6.2 折叠按钮：展开时在分隔条 hover 时显示 `chevron_right` 按钮（点击收起）；折叠时分隔条扩展为 24px 宽条，始终显示 `chevron_left` 按钮（点击展开）
- [x] 6.3 折叠时右侧面板宽度动画过渡到 0，分隔条不可拖拽
- [x] 6.4 运行 `flutter analyze` 确认无编译错误

## 7. 安装器视觉优化

- [x] 7.1 重构 `HapInstallPage` 整体布局：横屏居中卡片式，白色背景为主，两边留白
- [x] 7.2 权限列表折叠/展开：默认显示"当前应用申请权限 N 个"，点击展开显示完整权限列表，超出屏幕时滚动
- [x] 7.3 优化按钮、文字、图标等视觉元素的间距和字体层次
- [x] 7.4 运行 `hvigor` 构建命令验证编译通过
