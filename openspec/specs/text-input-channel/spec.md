## ADDED Requirements

### Requirement: 文本输入通过协议通道发送
客户端侧边栏文本输入面板 SHALL 通过 scrcpy 协议 `TEXT_INPUT`（0x15）通道发送 UTF-8 文本到服务端。

#### Scenario: 发送非空文本
- **WHEN** 用户在文本输入面板中输入文本并点击"发送"按钮
- **THEN** 客户端 SHALL 将文本以 UTF-8 编码后通过 `TEXT_INPUT`（0x15）控制帧发送至服务端

#### Scenario: 发送空文本
- **WHEN** 用户在文本输入面板中未输入任何文本时点击"发送"按钮
- **THEN** 客户端 SHALL 不发送任何帧

#### Scenario: 未连接时禁用发送
- **WHEN** 客户端未与服务端建立连接
- **THEN** "发送"按钮 SHALL 处于禁用状态，不可点击

#### Scenario: 发送成功后清空输入框
- **WHEN** 文本发送成功（服务端返回确认或发送操作完成）
- **THEN** 客户端文本输入框 SHALL 清空内容

#### Scenario: 回车快捷发送
- **WHEN** 用户在文本输入框中按下回车键（Enter）
- **THEN** 客户端 SHALL 触发与点击"发送"按钮相同的发送逻辑

### Requirement: TEXT_INPUT 协议帧格式
客户端 SHALL 按以下格式编码 `TEXT_INPUT` 控制帧：

```
控制帧头部: type(4B)=0x10 | length(4B BE)
控制帧 body: subType(1B)=0x15 | textPayload(UTF-8 bytes)
```

- `textPayload`: 文本内容的 UTF-8 编码字节序列

#### Scenario: ASCII 文本编码
- **WHEN** 用户输入纯 ASCII 文本（如 "hello world"）
- **THEN** 生成的帧 SHALL 包含 subType=0x15，payload 为文本的 UTF-8 字节序列

#### Scenario: 中文文本编码
- **WHEN** 用户输入包含中文的文本（如 "你好世界"）
- **THEN** 生成的帧 SHALL 包含 subType=0x15，payload 为文本的 UTF-8 字节序列

#### Scenario: 多行文本编码
- **WHEN** 用户输入包含换行符的多行文本
- **THEN** 生成的帧 SHALL 包含 subType=0x15，payload 为包含 `\n` 的完整 UTF-8 字节序列

### Requirement: 服务端文本注入不破坏用户剪贴板
服务端在通过剪贴板粘贴方式注入文本时，SHALL 在粘贴完成后恢复用户原有的剪贴板内容。

#### Scenario: 保存原有剪贴板内容
- **WHEN** 服务端收到 `TEXT_INPUT` 帧
- **THEN** 服务端 SHALL 在写入待注入文本前，通过 `pasteboard.getSystemPasteboard().getData()` 读取并缓存当前剪贴板内容

#### Scenario: 粘贴后恢复剪贴板
- **WHEN** 服务端完成剪贴板写入 + Ctrl+V 粘贴注入流程
- **THEN** 服务端 SHALL 将缓存的原剪贴板内容通过 `pasteboard.getSystemPasteboard().setData()` 写回

#### Scenario: 原剪贴板为空
- **WHEN** 原有剪贴板内容为空
- **THEN** 服务端 SHALL 在粘贴完成后调用 `pasteboard.getSystemPasteboard().clear()` 清空剪贴板

#### Scenario: 剪贴板读取失败
- **WHEN** 读取原有剪贴板内容失败（如权限不足）
- **THEN** 服务端 SHALL 继续执行文本注入流程（跳过保存），并在日志中记录警告

### Requirement: 服务端接收文本输入帧
服务端 `InputInjector.handleTextInput` SHALL 解析 `TEXT_INPUT` 帧的 UTF-8 payload 并注入到当前焦点文本框。

#### Scenario: 解码 UTF-8 文本
- **WHEN** 服务端收到 `TEXT_INPUT` 帧
- **THEN** 服务端 SHALL 使用 `util.TextDecoder('utf-8')` 将 payload 解码为字符串

#### Scenario: 空 payload 不处理
- **WHEN** 服务端收到 `TEXT_INPUT` 帧但 payload 为空
- **THEN** 服务端 SHALL 不执行任何注入操作

#### Scenario: 剪贴板写入失败处理
- **WHEN** 剪贴板 `setData()` 操作失败
- **THEN** 服务端 SHALL 记录错误日志，不继续执行 Ctrl+V 粘贴步骤

### Requirement: AppState 新增 sendTextInput 方法
客户端 `AppState` SHALL 提供 `sendTextInput(String text)` 方法，封装 `TEXT_INPUT` 协议帧的编码和发送。

#### Scenario: 通过协议通道发送文本
- **WHEN** `AppState.sendTextInput("hello")` 被调用且客户端已连接
- **THEN** `AppState` SHALL 调用 `encodeTextInput("hello")` 编码，再通过 `StreamClient.send(PacketType.control, ...)` 发送

#### Scenario: 未连接时返回失败
- **WHEN** `AppState.sendTextInput` 被调用但 `connState != connected`
- **THEN** 方法 SHALL 返回 `AppActionResult.fail("未连接")`，不发送任何数据
