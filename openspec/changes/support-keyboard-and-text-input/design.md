## Context

当前键盘转发通道（`KEY_EVENT` 0x14）已打通：`MirrorView._onKeyEvent` → `_mapKey(Flutter KeyCode → OH KeyCode)` → `encodeKeyEvent` → `sendControl` → 服务端 `InputInjector.handleKeyEvent` → `inputEventClient.injectKeyEvent`。但 `_mapKey` 映射表不完整，仅覆盖约 30 个键，大量符号键（引号、感叹号等）和功能键（F1-F12 已映射但未被所有平台正确触发）无法转发。

文本输入通道存在架构问题：`_TextInputPanel._send()` 调用 `AppState.inputText()` → `hdc.uitestInputText(lastTouchX, lastTouchY, text)`，走的是 hdc shell uitest 路径，与 scrcpy 协议通道完全无关。该路径依赖设备侧 uitest 工具可用性，且需要"上次触摸位置"来定位输入框，在纯鼠标操作或无触摸历史的场景下定位不可靠。

服务端 `handleTextInput` 当前实现是"写剪贴板 → 模拟 Ctrl+V"粘贴，但没有保存/恢复原剪贴板内容，会破坏用户剪贴板。

设备侧输入法已通过 [physical-keyboard-input](https://git.ineware.xyz/OpenHarmony/MP735/application_input_method) change 支持物理键盘输入，因此注入的 `keyCode` 可以正常进入焦点文本框。

```
┌──────────────────────────────────────────────────────────────────┐
│  PC 客户端 (Flutter)                                            │
│                                                                  │
│  ┌─────────────┐   ┌──────────────────┐   ┌──────────────────┐  │
│  │ MirrorView   │   │ Sidebar          │   │ AppState         │  │
│  │ Focus.onKey  │   │ _TextInputPanel  │   │ (中央状态)       │  │
│  │   _mapKey()  │   │  TextField       │   │                  │  │
│  │   encodeKey  │   │  发送按钮        │   │ sendTextInput()  │  │
│  │   Event()    │   │                  │   │ sendControl()    │  │
│  └──────┬───────┘   └────────┬─────────┘   └────────┬─────────┘  │
│         │                    │                       │           │
│         │ KEY_EVENT(0x14)    │ TEXT_INPUT(0x15)      │           │
│         ▼                    ▼                       ▼           │
│  ┌──────────────────────────────────────────────────────────┐    │
│  │              StreamClient (TCP)                           │    │
│  │   encodePacket(type, payload) → Socket.send()            │    │
│  └──────────────────────────┬───────────────────────────────┘    │
└─────────────────────────────┼────────────────────────────────────┘
                              │ hdc fport
┌─────────────────────────────┼────────────────────────────────────┐
│  服务端 (OpenHarmony ArkTS) │                                    │
│                             ▼                                    │
│  ┌──────────────────────────────────────────────────────────┐    │
│  │              ScrcpyService (TCP Server)                   │    │
│  │   PacketParser → 分发到 InputInjector.handle()           │    │
│  └──────────────────────────┬───────────────────────────────┘    │
│                             │                                    │
│         ┌───────────────────┼───────────────────┐                │
│         ▼                   ▼                   ▼                │
│  ┌──────────────┐  ┌──────────────┐  ┌──────────────────┐       │
│  │ handleKey    │  │ handleText   │  │ handleTouch/     │       │
│  │ Event()      │  │ Input()      │  │ Mouse/Volume…    │       │
│  │              │  │              │  │                  │       │
│  │ injectKey    │  │ 剪贴板.set   │  │ injectTouch/     │       │
│  │ Event(keyCode)│  │ Data + Ctrl+V│  │ MouseEvent       │       │
│  └──────┬───────┘  └──────┬───────┘  └──────────────────┘       │
│         │                 │                                      │
│         ▼                 ▼                                      │
│  ┌──────────────────────────────────────────────────────────┐    │
│  │           OpenHarmony 系统输入栈                          │    │
│  │  MMI → IMF → 当前输入法(已支持物理键盘) → insertText()    │    │
│  └──────────────────────────────────────────────────────────┘    │
└──────────────────────────────────────────────────────────────────┘
```

## Goals / Non-Goals

**Goals:**
- PC 客户端键盘（内置及外接）按键实时转发到服务端当前焦点文本框，英文字母/数字/符号/方向键/功能键可用
- 侧边栏文本输入面板通过 scrcpy 协议 `TEXT_INPUT` 通道发送文本到服务端
- 服务端 `handleTextInput` 粘贴前后保存并恢复用户剪贴板内容
- 客户端 `FocusNode` 在连接建立后自动获焦，用户无需额外点击即可开始键盘输入
- 所有变更与现有协议帧格式完全兼容，无需改协议结构

**Non-Goals:**
- 不修改协议帧格式或新增帧类型
- 不涉及中文输入法（中文及任意 Unicode 文本通过 `TEXT_INPUT` 剪贴板路径处理，与本 change 无关）
- 不修改服务端 `injectKeyEvent` 的注入机制（已确认 `inputEventClient.injectKeyEvent` 对所有 keyCode 有效）
- 不处理 Ctrl 组合快捷键在服务端的语义解释（如 Ctrl+C 复制等，仅转发按键）
- 不新增 Flutter 平台插件或 MethodChannel

## Decisions

### 1. 键盘转发：扩展 `_mapKey` 映射表，而非引入新映射库

**选择**：在现有 `_mapKey` 基础上补全缺失的符号键、修饰键、功能键映射，保持 `LogicalKeyboardKey → OhKeyCode` 的直接查表模式。

**理由**：
- 现有 `_mapKey` 已覆盖字母 A-Z、数字 0-9、F1-F12、方向键、常用修饰键和部分符号，结构清晰
- 补齐映射即可覆盖标准美式键盘全部可打印字符，无需引入第三方 keycode 映射库
- Flutter 的 `LogicalKeyboardKey` 在不同平台（macOS/Windows/Linux）上 keyId 一致，映射表跨平台通用

**替代方案**：使用 `RawKeyboard.instance.addListener` 监听原始按键 → 但 `RawKeyEvent` 在不同平台上的 `physicalKey`/`logicalKey` 行为不一致，且无法在 `Focus` 体系中与触控事件共存。不采用。

**需要补全的映射**（按 OH KeyCode 表）：
- 符号键：`!` `@` `#` `$` `%` `^` `&` `*` `(` `)` `_` `+` `{` `}` `|` `:` `"` `<` `>` `?` `~`
- 修饰键右侧：`shiftRight` `altRight`（已部分存在）、`metaLeft` `metaRight`
- 功能键：`insert` `home` `end` `pageUp` `pageDown` `numLock` `scrollLock` `printScreen`
- 数字小键盘：`numpad0-9` `numpadAdd` `numpadSubtract` `numpadMultiply` `numpadDivide` `numpadDecimal` `numpadEnter`

**注意**：符号键的 Shift 状态由客户端 Flutter `KeyEvent` 携带（`HardwareKeyboard.isLogicalKeyPressed`），但当前 `_onKeyEvent` 只转发 `logicalKey` 本身。对于需要 Shift 的符号（如 `!` 是 Shift+1），客户端需要判断：如果 `logicalKey` 是 `digit1` 但 Shift 按下，则转发 `KEYCODE_1` + `Shift` 修饰状态。**Phase 1 先转发字母数字和独立符号键，Shift+符号的修饰键组合在后续迭代中完善。**

### 2. 文本输入：从 hdc uitest 路径切换到 scrcpy 协议 TEXT_INPUT 通道

**选择**：`_TextInputPanel._send()` 改为调用 `AppState.sendTextInput(text)`，该方法使用 `encodeTextInput(text)` + `sendControl(ControlSubType.textInput, ...)` 走 TCP 协议通道发送。删除对 `hdc.uitestInputText` 的依赖。

**理由**：
- 协议通道是 scrcpy 的核心数据通路，不依赖设备侧 hdc shell/uitest 工具
- `TEXT_INPUT`（0x15）协议字段已在 `protocol.dart` 中定义，`encodeTextInput` 已实现，仅未被 UI 层调用
- 服务端 `handleTextInput` 已实现剪贴板粘贴逻辑，接收端就绪
- hdc uitest 路径保留作为回退手段（在 `AppState` 中保留 `inputText` 方法但不再从 UI 调用）

**替代方案**：继续用 hdc uitest 路径并修复定位问题 → 但 uitest 需要设备侧 `uitest` 工具且依赖触摸坐标定位，在无触摸历史的场景下不可靠，架构上也不如协议通道统一。

### 3. 服务端剪贴板保存与恢复

**选择**：`handleTextInput` 在写剪贴板前通过 `pasteboard.getSystemPasteboard().getData()` 读取并缓存原有内容，粘贴完成后恢复。

**理由**：
- 当前实现直接覆盖用户剪贴板，用户体验差
- `pasteboard.getSystemPasteboard().getData()` 是 `@ohos.pasteboard` 标准 API，`@since 6`，API 20 完全支持
- 恢复操作在粘贴完成后异步执行，不影响文本注入时效

**时序**：
```
getData() → 缓存 originalPasteData
  → setData(text) → injectKey(Ctrl) → injectKey(V) → injectKey(V up) → injectKey(Ctrl up)
    → setData(originalPasteData)  // 恢复
```

### 4. FocusNode 自动获焦

**选择**：在 `MirrorView` 中监听 `AppState.connState` 变化，当变为 `connected` 时调用 `_focusNode.requestFocus()`。

**理由**：
- 用户连接设备后通常立即开始操作，手动点击镜像区域才能键盘输入体验差
- `FocusNode.requestFocus()` 是 Flutter 标准方法，不涉及平台差异
- 需配合 `autofocus: true`（已设置）确保初始状态正确

## Risks / Trade-offs

- **[符号键 Shift 修饰]** 当前 `_onKeyEvent` 只根据 `logicalKey` 映射 keyCode，不判断 Shift/Ctrl 等修饰键状态。这意味着 `Shift+1`（期望 `!`）会转发为 `KEYCODE_1` 的 down/up，而不是 `!` 符号。
  → **缓解**：Phase 1 先确保字母/数字/独立符号键可用；修饰键组合（Shift+符号输出 shifted 字符）在后续迭代中通过读取 `HardwareKeyboard.instance.logicalKeysPressed` 判断修饰状态后完善。

- **[剪贴板恢复竞态]** 粘贴是异步的（`setTimeout` 串联），在粘贴完成前如果用户手动复制了新内容，恢复操作可能覆盖用户的新剪贴板。
  → **缓解**：粘贴链路总时长约 90ms（三个 setTimeout 20ms），竞态窗口极短。如需更可靠方案，可改为在 `Ctrl+V` 注入后监听剪贴板变化事件，确认粘贴已消费后再恢复。Phase 1 先采用简单时序恢复。

- **[非美式键盘布局]** `_mapKey` 基于 Flutter `LogicalKeyboardKey`（物理键位），在 AZERTY/QWERTZ 等布局的物理键盘上，键位映射可能与用户期望的字符不一致。
  → **缓解**：`LogicalKeyboardKey` 按物理键位映射，与系统键盘布局无关。这是 scrcpy 类工具的通用限制（Android scrcpy 也有此问题），属于已知局限。

- **[Flutter KeyEvent 跨平台一致性]** `KeyDownEvent`/`KeyUpEvent`/`KeyRepeatEvent` 在不同平台上对某些键（如媒体键、Fn 组合键）的行为可能不一致。
  → **缓解**：Phase 1 仅覆盖标准键盘按键（字母/数字/符号/方向/功能键），不处理媒体键和 Fn 组合键。

## Open Questions

1. 设备侧输入法是否需要设置为特定输入法才能让注入的 keyCode 正常进入文本框？（根据 physical-keyboard-input change 的验证结果，系统输入法已支持物理键盘输入，理论上无需额外设置）
2. 部分符号键（如 `grave`、`backslash`）在不同键盘布局下的 OH KeyCode 映射是否正确？需实机测试验证。
