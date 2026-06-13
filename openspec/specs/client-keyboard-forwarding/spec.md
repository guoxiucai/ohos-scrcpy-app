## ADDED Requirements

### Requirement: PC keyboard key event forwarding
客户端 SHALL 捕获 PC 键盘按键事件（KeyDown/KeyUp），将其映射为 OpenHarmony KeyCode 后通过 `KEY_EVENT`（0x14）协议帧实时转发到服务端。

#### Scenario: 转发字母键
- **WHEN** 用户按下或释放 PC 键盘字母键（A-Z）
- **THEN** 客户端 SHALL 将键码映射为对应的 OH KeyCode（2017-2042），并以 `KEY_EVENT` 帧发送至服务端

#### Scenario: 转发数字键
- **WHEN** 用户按下或释放 PC 键盘数字键（0-9）
- **THEN** 客户端 SHALL 将键码映射为对应的 OH KeyCode（2000-2009），并以 `KEY_EVENT` 帧发送至服务端

#### Scenario: 转发方向键
- **WHEN** 用户按下或释放方向键（↑↓←→）
- **THEN** 客户端 SHALL 将键码映射为 OH KeyCode（DPAD_UP=2012, DPAD_DOWN=2013, DPAD_LEFT=2014, DPAD_RIGHT=2015），并以 `KEY_EVENT` 帧发送至服务端

#### Scenario: 转发功能键
- **WHEN** 用户按下或释放 F1-F12 功能键
- **THEN** 客户端 SHALL 将键码映射为对应的 OH KeyCode（2090-2101），并以 `KEY_EVENT` 帧发送至服务端

#### Scenario: 转发修饰键
- **WHEN** 用户按下或释放 Shift/Ctrl/Alt/CapsLock 等修饰键
- **THEN** 客户端 SHALL 将键码映射为对应的 OH KeyCode（Shift=2047/2048, Ctrl=2072/2073, Alt=2045/2046, CapsLock=2074），并以 `KEY_EVENT` 帧发送至服务端

#### Scenario: 转发独立符号键
- **WHEN** 用户按下或释放独立符号键（如 `-` `=` `[` `]` `\` `;` `'` `,` `.` `/` `` ` ``）
- **THEN** 客户端 SHALL 将键码映射为对应的 OH KeyCode，并以 `KEY_EVENT` 帧发送至服务端

#### Scenario: 转发 Enter/Tab/Space/Escape/Backspace/Delete
- **WHEN** 用户按下或释放 Enter/Tab/Space/Escape/Backspace/Delete 键
- **THEN** 客户端 SHALL 将键码映射为对应的 OH KeyCode（Enter=2054, Tab=2049, Space=2050, Escape=2070, Backspace=2055, Delete=2071），并以 `KEY_EVENT` 帧发送至服务端

#### Scenario: 转发数字小键盘键
- **WHEN** 用户按下或释放数字小键盘键（0-9, +, -, *, /, ., Enter）
- **THEN** 客户端 SHALL 将键码映射为对应的 OH KeyCode（Numpad0-9=2102-2111, NumpadAdd=2113, NumpadSubtract=2114, NumpadMultiply=2115, NumpadDivide=2116, NumpadDecimal=2117, NumpadEnter=2118），并以 `KEY_EVENT` 帧发送至服务端

#### Scenario: 按键释放事件
- **WHEN** 用户释放 PC 键盘上的任意键
- **THEN** 客户端 SHALL 发送 `isPressed=0` 的 `KEY_EVENT` 帧至服务端

#### Scenario: 按键重复事件
- **WHEN** 用户按住 PC 键盘上的任意键产生 KeyRepeat 事件
- **THEN** 客户端 SHALL 将其视为 KeyDown 事件，发送 `isPressed=1` 的 `KEY_EVENT` 帧至服务端

#### Scenario: 未映射的按键
- **WHEN** 用户按下不在映射表中的按键
- **THEN** 客户端 SHALL 忽略该事件（`KeyEventResult.ignored`），不发送任何帧

#### Scenario: 未连接时忽略键盘事件
- **WHEN** 客户端未与服务端建立连接（`connState != connected`）
- **THEN** 客户端 SHALL 忽略所有键盘事件（`KeyEventResult.ignored`）

### Requirement: 镜像区域键盘焦点管理
客户端 SHALL 在设备连接建立后自动获取键盘焦点，使用户无需手动点击即可开始键盘输入。

#### Scenario: 连接后自动获焦
- **WHEN** 客户端与服务端的连接状态变为 `connected`
- **THEN** `MirrorView` 的 `FocusNode` SHALL 调用 `requestFocus()` 自动获取键盘焦点

#### Scenario: 断连后焦点保留
- **WHEN** 客户端与服务端断开连接
- **THEN** `FocusNode` SHALL 保持当前焦点状态不变，不主动释放焦点

### Requirement: KEY_EVENT 协议帧格式
客户端 SHALL 按以下格式编码 `KEY_EVENT` 控制帧：

```
控制帧头部: type(4B)=0x10 | length(4B BE)
控制帧 body: subType(1B)=0x14 | isPressed(1B) | keyCode(4B BE)
```

- `isPressed`: 1 表示按键按下，0 表示按键释放
- `keyCode`: OpenHarmony KeyCode 值（大端序 4 字节无符号整数）

#### Scenario: 按键按下帧
- **WHEN** 客户端发送 KeyDown 事件
- **THEN** 生成的帧 SHALL 满足：subType=0x14, isPressed=1, keyCode=对应 OH KeyCode

#### Scenario: 按键释放帧
- **WHEN** 客户端发送 KeyUp 事件
- **THEN** 生成的帧 SHALL 满足：subType=0x14, isPressed=0, keyCode=对应 OH KeyCode
