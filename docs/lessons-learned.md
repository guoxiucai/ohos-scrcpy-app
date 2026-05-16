# 踩坑笔记

记录调试过程中遇到的非显然问题与根因。新踩坑时往这里追加。

## 1. TCP 流式解析器在断开/重连时必须 reset

**症状**：客户端断开后再次连接，能 connect 上、能收到字节，但所有 `videoConfig` / `videoFrame` 包都"丢失"，UI 卡在"等待视频流"。重启 app 又恢复正常。

**根因**：`scrcpy_client_flutter/lib/net/stream_client.dart` 的 `StreamClient._parser` 是 `final PacketParser`，整个 app 生命周期共用一个 `BytesBuilder _buf`。第一次连接断开瞬间若有不足完整 header/payload 的字节挂在 `_buf` 里，下次 connect 后新流的字节会被拼到这些残留之后——type / length 字段从错位的偏移读起，整个新流被解析成无意义 packet 全部丢弃。

**修复**：`StreamClient.connect` / `disconnect` 都显式调 `_parser.reset()`（`PacketParser.reset()` 内部 `_buf.clear()`）。

**通用经验**：任何"长生命周期 client + 内部解析器/缓冲区"的组合，断开/重连路径都必须显式 reset 内部状态。`final` 字段不代表无状态。排查"重连后行为异常"时，先看共享的有状态对象，比纠结 OS / SDK 行为高效得多。

## 2. OH_AVScreenCapture RAW 模式 Acquire/Release 必须严格配对

**症状**：RAW 路径下，第一次连接正常出帧；之后每次重连都只回调一次 `OnScVideoBuffer` 后彻底停摆，`screen capture state=0`（采集器自身正常）。

**根因**：`OH_AVScreenCapture` + `OH_ORIGINAL_STREAM` 模式下，`OnScVideoBuffer(isReady=true)` 是消费者契约信号——必须 `OH_AVScreenCapture_AcquireVideoBuffer` 一次再 `OH_AVScreenCapture_ReleaseVideoBuffer` 一次释放槽位。两个错误都让 OS 判定消费者卡住，从此不再触发后续回调：

- **Release 不 Acquire**：在 `!HasClients` / 限速 drop 分支里直接 `Release` 跳过工作，破坏内部计数。
- **Acquire 不 Release**：拿了 buffer 不还。

本项目最初在 drop 分支直接 `Release` 跳过，导致第二次连接首帧后回调全停。

**修复**：`HandleRawBufferAvailable` 入口先无条件 `Acquire`，再决定要不要发；要发就 map / copy / Unmap / `Release`，不要就直接 `Release` 走人。

**附注**：encoder surface 模式（`StartScreenCaptureWithSurface`）不需要应用层 Acquire/Release，由 encoder surface 自动消费。

**调试技巧**：在 `OnScVideoBuffer` 入口打日志看回调间隔，突变到秒级就是消费者卡住，立刻去找 Acquire / Release 配对。

## 3. OpenHarmony 系统服务应用 mainElement 指向 ServiceExtension

服务端 `module.json5` 的 `mainElement` 必须写 ServiceExtensionAbility 名（本项目是 `ScrcpyService`）。UIAbility（`EntryAbility`）只做调试 UI 入口，不放业务逻辑。
