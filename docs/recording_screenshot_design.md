# 客户端录制与截图功能设计

> 文档状态：待确认  
> 目标版本：1.0.2  
> 首期平台：macOS、Windows  
> 预留平台：Linux  
> 最后更新：2026-07-25

## 1. 背景与目标

鸿镜客户端已经能接收服务端发送的 H.264、RAW RGBA 或 JPEG 视频帧，并通过 macOS VideoToolbox、Windows Media Foundation 解码后使用 Flutter Texture 上屏。本次在客户端侧边栏新增“录制与截图”区域：

- 录制：直接将收到的 H.264 访问单元无损封装为 MP4，不重新编码，保存到桌面。
- 截图：从原生解码器获取最近一帧已解码图像，编码为 PNG，保存到桌面。
- 录制结束或截图成功后，弹窗显示完整路径，并提供“关闭”和“打开路径”。
- 录制期间禁止切换分辨率和帧率，尝试切换时显示 Toast 风格提示。
- 客户端与服务端应用版本统一升级为 1.0.2。
- 首期完整实现 macOS、Windows；Linux 保留统一接口和 UI 占位。

## 2. 范围与非目标

### 2.1 本期范围

- H.264 视频无损封装为 MP4。
- 无音轨 MP4。
- H.264、RAW RGBA、JPEG 三种显示模式下均可截图。
- 处理录制首帧 IDR、SPS/PPS、PTS 归一化、写入背压、正常结束和异常中断。
- macOS 使用 AVFoundation/ImageIO，Windows 使用 Media Foundation/WIC。
- 保存目录使用操作系统的“桌面”已知目录，而不是简单拼接 `$HOME/Desktop`。

### 2.2 非目标

- 不录制系统音频或麦克风。
- 不在客户端重新编码视频。
- RAW/JPEG 模式不录制为 MP4；此时只支持截图。
- 不在 MP4 内绘制客户端鼠标、侧边栏、状态栏或其他 Flutter UI。
- 本期不实现 Linux 原生插件、Linux 打包和 Linux 端真实文件输出。
- 不增加文件保存位置选择器；首期固定保存到桌面。

## 3. 现状与约束

### 3.1 当前数据路径

```text
OpenHarmony ScreenCapture
  -> OH VideoEncoder / RAW / JPEG
  -> TCP videoConfig + videoFrame
  -> Dart AppState._onPacket
  -> VideoDecoder.feed
  -> macOS/Windows 原生解码器
  -> Flutter Texture
```

H.264 帧在进入原生解码器前已经包含：

- Annex-B H.264 访问单元；
- 关键帧标记；
- 设备侧编码器 PTS；
- `videoConfig` 中独立下发的 SPS/PPS、宽高和帧率。

因此录制应在“解码前”旁路复用压缩帧，不能从纹理抓帧后再次编码。这样不会增加编码损耗，CPU/GPU 开销也远低于重编码。

### 3.2 PTS 单位需要纠正

服务端 `OH_AVCodecBufferAttr.pts` 的单位是微秒，当前协议原样发送该数值，但 Dart/Windows 变量历史上命名为 `ptsMs`，Windows 解码器也按毫秒换算成 100ns。

实施时需要做语义修正：

- `VideoFrame.ptsMs` 重命名为 `ptsUs`；
- MethodChannel 参数名称可继续使用兼容字段 `pts`，但注释明确单位为微秒；
- Windows MFT 时间换算从 `pts * 10000` 修正为 `pts * 10`；
- 协议的 8 字节字段和线上字节布局不变，不产生协议版本不兼容。

### 3.3 B 帧约束

MP4 封装 B 帧时需要同时提供 PTS 和 DTS，而当前协议只有 PTS。项目使用的 OpenHarmony API 23 头文件说明 `OH_MD_KEY_VIDEO_ENCODER_ENABLE_B_FRAME` 默认值为 0，即默认不生成 B 帧；当前服务端也没有主动开启 B 帧。

本期保持“无 B 帧”约束，不扩展 DTS 字段。实施时增加防御：

- 如果收到的 PTS 出现符合 B 帧重排特征的持续回退，立即停止录制并提示“码流时间戳不受支持”，不生成表面成功但无法播放的 MP4。
- 后续如需开启 B 帧，必须先扩展视频帧协议，显式传输 DTS。

## 4. 总体方案

### 4.1 核心决策

1. Dart 负责 UI、状态机、业务校验和服务端控制。
2. 原生插件负责 MP4 封装、PNG 编码、桌面路径解析及文件管理器定位。
3. 录制复用现有 `scrcpy/decoder` MethodChannel，不为每帧再发送一次平台消息。
4. 原生插件收到现有 `feed` 调用后，先将完整压缩访问单元投递给录制器，再投递给允许丢帧的解码队列。
5. 录制队列不允许按解码策略丢弃 P 帧；队列积压时通过现有暂停/恢复控制对服务端施加背压。
6. 点击录制后主动请求服务端生成 IDR，原生录制器只从第一个有效 IDR 开始写文件。

### 4.2 架构图

```text
                         +-----------------------+
                         |       Sidebar UI      |
                         |  录制 / 停止 / 截图    |
                         +-----------+-----------+
                                     |
                                     v
                         +-----------------------+
                         |       AppState        |
                         | 状态机 / 参数锁 / 提示 |
                         +------+-----------+----+
                                |           |
             REQUEST_KEYFRAME   |           | scrcpy/decoder
                                |           |
                                v           v
+-------------------+     +-----------+   +----------------------------+
| OpenHarmony       |     | TCP/HDC   |   | Native VideoDecoderPlugin |
| VideoEncoder      |<----| Protocol  |   |                            |
| request IDR       |     +-----------+   | feed(encoded access unit) |
+-------------------+                     |   |                        |
                                          |   +--> MP4 recorder queue  |
                                          |   |      -> desktop .mp4   |
                                          |   |                        |
                                          |   +--> decoder queue       |
                                          |          -> latest frame   |
                                          |          -> PNG snapshot   |
                                          +----------------------------+
```

## 5. UI 设计

### 5.1 侧边栏位置

在“设备控制”和“文本输入”之间新增卡片：

```text
设备控制
录制与截图      <- 新增
文本输入
终端
```

卡片沿用现有 `_Card`、颜色、圆角、边框和 34px 高按钮：

- 图标：`Icons.videocam_outlined`
- 标题：`录制与截图`
- 副标题：`RECORD · CAPTURE`
- 默认展开。

### 5.2 卡片内容

空闲状态：

```text
[ ● 开始录制 ]  [ ▣ 截图 ]
仅 H.264 支持录制，截图支持当前画面
```

等待关键帧：

```text
[ ■ 取消录制 ]  [ ▣ 截图 ]
正在等待关键帧…
```

录制状态：

```text
[ ■ 停止录制 ]  [ ▣ 截图 ]
● 录制中  00:01:26
```

结束封装状态：

```text
[   保存中…   ]  [ ▣ 截图 ]
正在完成 MP4 封装…
```

交互规则：

| 场景 | 录制按钮 | 截图按钮 |
| --- | --- | --- |
| 未连接 | 禁用 | 禁用 |
| 已连接但无视频帧 | 禁用 | 禁用 |
| H.264 已出帧 | 启用 | 启用 |
| RAW/JPEG 已出帧 | 禁用，提示“当前模式不支持录制” | 启用 |
| 等待 IDR | 显示“取消录制” | 启用 |
| 正在录制 | 显示“停止录制” | 启用 |
| 正在完成 MP4 | 禁用 | 启用 |
| Linux 占位 | 禁用并显示“Linux 平台后续支持” | 禁用 |

截图与录制互不排斥，录制过程中允许截图。

### 5.3 Toast 与结果弹窗

项目未引入 Toast 依赖，本期使用经过主题适配的 `ScaffoldMessenger.showSnackBar` 实现轻提示，显示约 2 秒：

```text
录制过程中不允许切换分辨率或帧率
```

文件保存成功后新增统一的 `showSavedFileDialog`：

- 标题：“录制完成”或“截图完成”；
- 内容：可选择、可复制的完整文件路径；
- 次按钮：“关闭”；
- 主按钮：“打开路径”，在文件管理器中定位并选中文件。

失败继续复用项目现有错误弹窗风格，显示平台错误信息，不只打印日志。

## 6. Dart 状态与接口设计

### 6.1 状态模型

在 `AppState` 中增加：

```dart
enum RecordingState {
  idle,
  waitingForKeyframe,
  recording,
  finalizing,
  error,
}

RecordingState recordingState;
DateTime? recordingStartedAt;
Duration recordingDuration;
bool screenshotBusy;
```

辅助属性：

```dart
bool get isRecordingLocked =>
    recordingState != RecordingState.idle &&
    recordingState != RecordingState.error;

bool get canStartRecording;
bool get canTakeScreenshot;
```

状态流转：

```text
idle
  -> waitingForKeyframe
      -> recording
          -> finalizing
              -> idle
      -> idle（取消/超时/失败）
```

### 6.2 业务方法

```dart
Future<AppActionResult> startRecording();
Future<MediaSaveResult> stopRecording();
Future<AppActionResult> cancelRecording();
Future<MediaSaveResult> takeScreenshot();
Future<AppActionResult> revealSavedFile(String path);
```

`MediaSaveResult` 至少包含：

```dart
class MediaSaveResult {
  final bool ok;
  final String? path;
  final String? error;
  final Duration? duration;
  final int? frameCount;
}
```

### 6.3 参数切换锁

不能只在 UI 中禁用菜单，必须由 `AppState.changeVideoParams` 做第二层保护，避免未来其他调用入口绕过限制：

```text
用户选择分辨率/帧率
  -> AppState 检查 isRecordingLocked
  -> 已锁定：不修改本地偏好、不发送 0x42，返回 blocked
  -> UI 根据 blocked 显示 SnackBar
```

从点击“开始录制”进入 `waitingForKeyframe` 起，到 MP4 完成 `finalizing` 为止都锁定参数。

### 6.4 原生事件

复用现有 MethodChannel 反向回调：

```text
recordingState:
  { state: "recording" | "error", error?: String }

encoderState:
  { source: "decoder" | "recorder", paused: bool }
```

`AppState` 用暂停原因集合合并解码和录制背压：

```text
pauseReasons 从空变非空 -> 发送 PAUSE_ENCODER
pauseReasons 从非空变空 -> 发送 RESUME_ENCODER
```

这样不会发生“录制器仍积压，但解码器提前发送恢复”的竞态。

## 7. H.264 录制设计

### 7.1 开始条件

开始录制前必须同时满足：

- 客户端处于 `connected`；
- 已收到 `VideoConfig`；
- `codec == H264`；
- SPS、PPS 均非空；
- 已收到并解码至少一帧；
- 原生录制插件可用；
- 当前没有录制或完成任务。

若任一条件不满足，直接返回可读错误，不创建空文件。

### 7.2 首帧必须是 IDR

用户点击录制时很可能位于 GOP 中间，直接把当前 P 帧写成 MP4 第一帧会导致花屏或无法解码。因此采用：

1. 原生录制器先创建会话，状态为 `waitingForKeyframe`，但不写普通帧。
2. 客户端向服务端发送 `REQUEST_KEYFRAME`。
3. 服务端调用 OpenHarmony 编码器动态参数，请求立即产生 I/IDR 帧。
4. 原生录制器同时检查服务端关键帧 flag 和 Annex-B NAL type 5。
5. 只从第一个有效 IDR 开始写 MP4，并把该帧时间归零。

服务端当前关键帧间隔为 2000ms，因此即使部分设备不响应主动请求，通常也会在 2 秒内自然等到下一个关键帧。等待超过 5 秒仍没有 IDR 时：

- 取消录制；
- 删除临时文件；
- 恢复参数切换；
- 提示“未等到关键帧，录制未开始”。

### 7.3 服务端协议扩展

新增控制 subtype：

```text
0x43 REQUEST_KEYFRAME
方向：客户端 -> 服务端
body：空
```

调用链：

```text
AppState.startRecording
  -> sendControl(0x43)
  -> ScrcpyService.onControl
  -> requestKeyFrame() NAPI
  -> CaptureSession::RequestKeyFrame()
  -> OH_AVFormat_SetIntValue(OH_MD_KEY_REQUEST_I_FRAME, 1)
  -> OH_VideoEncoder_SetParameter()
```

该 API 从 OpenHarmony API 10 开始提供，项目最低兼容 API 15，可直接使用。调用失败时记录错误，但不立即终止录制，仍可等待 2000ms 周期关键帧作为兜底。

### 7.4 SPS/PPS 与样本格式

`videoConfig` 已独立携带 SPS/PPS，录制器初始化时必须保存一份不可变副本：

- macOS：使用 SPS/PPS 创建 `CMVideoFormatDescription`，作为 MP4 `avcC`/sample description 的格式来源。
- Windows：构造 `00 00 00 01 + SPS + 00 00 00 01 + PPS`，写入 `MF_MT_MPEG_SEQUENCE_HEADER`。

样本处理：

- 输入仍是 Annex-B 访问单元。
- macOS 写 `CMSampleBuffer` 前转换为 AVCC 长度前缀格式，并剔除访问单元中重复的 SPS/PPS。
- Windows MPEG-4 File Sink 接收 Annex-B，SPS/PPS 通过媒体类型提供，不依赖首个样本临时解析。
- 每个网络 `videoFrame` 对应一个完整访问单元和一个 presentation time。
- 关键帧样本必须设置 sync/clean-point 标记，普通帧明确设置为 non-sync。

### 7.5 时间戳与帧时长

协议 PTS 为微秒：

```text
recordPtsUs = sourcePtsUs - firstIdrPtsUs
```

录制器保留一个待写帧，使用下一帧 PTS 计算上一帧时长：

```text
durationUs = nextPtsUs - currentPtsUs
```

最后一帧没有下一帧，使用 `1_000_000 / fps` 作为默认时长。

异常规则：

- 单次 PTS 相等或轻微倒退：按上一帧加一个名义帧间隔修正，记录警告。
- 持续倒退或出现 B 帧重排特征：终止录制并报错。
- 编码背压暂停后 PTS 存在正常大间隔：保留该间隔，播放器表现为上一帧冻结，录制总时长与真实操作时间一致。
- 收到新 `videoConfig` 表示编码会话或尺寸发生变化：先完成当前文件，再重建解码器，不在同一 MP4 track 内混合两套 SPS/PPS 或分辨率。

### 7.6 录制队列与背压

显示解码队列可以为了低延迟丢弃旧帧，但 MP4 录制不能丢弃任意 P 帧，否则参考链会损坏。原生 `feed` 路径按以下顺序处理：

```text
encoded access unit
  -> 复制/引用到 recorder queue（不丢帧）
  -> 移交 decoder queue（保持现有低延迟策略）
```

录制器使用串行工作队列：

- 正常写入只做容器封装，不重新编码，理论处理能力高于输入码率。
- 队列超过高水位时发出 `source=recorder, paused=true`。
- 队列回落到低水位时发出 `paused=false`。
- 达到硬上限仍无法回落时停止录制并报错，绝不静默丢帧或产出损坏文件。
- `stopRecording` 先停止接收新录制帧，再排空队列、写最后一帧、完成 MP4 索引，最后返回结果。

水位阈值实施时按“累计字节数 + 帧数”双条件配置，并通过 2160p/12Mbps 长时录制测试校准，不把魔法值散落在平台代码中。

## 8. macOS 实现

### 8.1 MP4 封装

新增建议文件：

```text
macos/Runner/Mp4Recorder.swift
macos/Runner/PngSnapshotWriter.swift
```

实现方式：

- `AVAssetWriter(outputURL:fileType:.mp4)` 创建容器。
- `AVAssetWriterInput(mediaType:.video, outputSettings:nil, sourceFormatHint:formatDesc)` 使用压缩样本透传，不重新编码。
- `expectsMediaDataInRealTime = true`。
- 第一个 IDR 到来时 `startWriting()`，从时间 0 开始 session。
- 将 Annex-B 转为 AVCC 后创建 `CMBlockBuffer`、`CMSampleBuffer`。
- 填写 presentation time、duration 和关键帧 attachment。
- 停止时 `markAsFinished()` 后调用 `finishWriting`。

Apple 文档明确说明 `outputSettings == nil` 表示已压缩样本透传；对 MP4 透传时需要提供非空 `sourceFormatHint`，本项目正好可以用 SPS/PPS 创建的 `CMVideoFormatDescription`。

### 8.2 PNG 截图

现有插件通过锁保护 `latestPixelBuffer`。截图流程：

1. 在锁内 retain 当前 `CVPixelBuffer`，立即释放锁，不阻塞解码回调。
2. 用 `CIImage(cvPixelBuffer:)` 或 BGRA `CGContext` 生成 `CGImage`。
3. 使用 `CGImageDestination` + PNG UTI 写入临时文件。
4. 原子移动到桌面最终路径。

截图必须使用像素原始宽高，不使用 Flutter 窗口缩放尺寸。

## 9. Windows 实现

### 9.1 MP4 封装

新增建议文件：

```text
windows/runner/mp4_recorder.h
windows/runner/mp4_recorder.cpp
windows/runner/png_snapshot_writer.h
windows/runner/png_snapshot_writer.cpp
```

使用 Media Foundation Sink Writer：

- `MFCreateSinkWriterFromURL` 创建 MP4 writer。
- output/input media type 均使用 `MFVideoFormat_H264`，执行 compressed-to-identical-compressed remux。
- 设置 `MF_MT_FRAME_SIZE`、`MF_MT_FRAME_RATE`、`MF_MT_INTERLACE_MODE`。
- 通过 `MF_MT_MPEG_SEQUENCE_HEADER` 提供 Annex-B SPS/PPS。
- 每帧创建 `IMFSample` 和 `IMFMediaBuffer`。
- `SetSampleTime(recordPtsUs * 10)` 转换为 100ns。
- `SetSampleDuration(durationUs * 10)`。
- IDR 设置 `MFSampleExtension_CleanPoint = TRUE`。
- 停止时调用 `IMFSinkWriter::Finalize()`。

Microsoft 文档明确支持“压缩输入与相同压缩输出”的无转码 remux；其 MPEG-4 File Sink 要求 H.264 为 Annex-B，并要求 SPS/PPS 出现在 sample description 中。

### 9.2 PNG 截图

Windows 有两条渲染路径，必须分别处理：

#### D3D11 硬件路径

1. 在保护当前输出纹理的锁内，把 `output_tex_` 拷贝到 `D3D11_USAGE_STAGING` 纹理。
2. 解除渲染资源锁后 Map staging texture。
3. 按真实 row pitch 复制 BGRA 数据。
4. 使用 WIC PNG encoder 写文件。

不能让截图线程在 `VideoProcessorBlt` 正在写 `output_tex_` 时读取同一资源。

#### CPU/RAW/JPEG 路径

1. 在 `pending_mu_` 内复制最近的 `pending_`，没有 pending 时复制 `display_`。
2. 明确携带该帧的像素格式，不能仅凭当前字段名 `bgra` 推断。
3. WIC 根据实际 RGBA/BGRA 格式转换后编码 PNG。

现有代码中 H.264 CPU 转换函数虽然名为 `Nv12ToBgra`，实际为适配 Flutter PixelBuffer 写入 RGBA；RAW/JPEG 路径又使用 BGRA。截图实现必须显式处理该差异，避免 PNG 红蓝通道互换。

### 9.3 构建依赖

Windows `CMakeLists.txt` 增加：

- 新的 recorder/snapshot 源文件；
- `mfreadwrite.lib`；
- `windowscodecs.lib`；
- 如使用 Known Folder API，链接 `shell32.lib`、`ole32.lib`。

## 10. 文件路径与命名

### 10.1 文件名

采用仅包含 ASCII、数字和下划线的稳定文件名，避免脚本和旧系统编码问题：

```text
HongJing_Recording_20260725_143052.mp4
HongJing_Screenshot_20260725_143125.png
```

同一秒发生重名时追加 `_1`、`_2`。

### 10.2 桌面目录

- macOS：`FileManager.urls(for: .desktopDirectory, in: .userDomainMask)`。
- Windows：`SHGetKnownFolderPath(FOLDERID_Desktop)`，兼容桌面重定向和 OneDrive。
- Linux（未来）：`g_get_user_special_dir(G_USER_DIRECTORY_DESKTOP)`，为空时读取 XDG user dirs。

如果桌面目录无法解析或不可写，操作失败并向用户说明原因，不静默保存到未知位置。

### 10.3 临时文件和原子完成

- 写入阶段使用系统临时目录中的 `.part.mp4` / `.part.png`。
- 完成 MP4 `moov`/PNG 编码后再移动到桌面最终文件名。
- 成功移动后才向 Dart 返回最终路径。
- 失败时尽量删除无效临时文件；若文件已完整但移动失败，错误结果中携带临时路径供排查。
- 应用启动时可清理本功能产生且超过 24 小时的孤立临时文件。

### 10.4 打开路径

- macOS：`NSWorkspace.activateFileViewerSelecting`。
- Windows：Shell API 或 `explorer.exe /select,`，路径使用宽字符。
- Linux（未来）：打开父目录；桌面环境不支持选中文件时退化为打开目录。

## 11. MethodChannel 扩展

继续使用 `scrcpy/decoder`：

| 方法 | 参数 | 返回 |
| --- | --- | --- |
| `startRecording` | codec、width、height、fps、sps、pps | `{ok, error?}` |
| `stopRecording` | 无 | `{ok, path?, durationUs?, frameCount?, error?}` |
| `cancelRecording` | 无 | `{ok, error?}` |
| `capturePng` | 无 | `{ok, path?, error?}` |
| `revealInFileManager` | path | `{ok, error?}` |

现有 `feed` 参数继续携带：

```text
nal: Uint8List
keyframe: bool
pts: int（微秒）
```

不增加第二次逐帧 MethodChannel 调用，避免每帧二次序列化和内存拷贝。

## 12. 生命周期与异常处理

| 事件 | 处理 |
| --- | --- |
| 用户正常停止 | 排空录制队列，Finalize，移动文件，弹完成对话框 |
| 等待 IDR 时取消 | 删除临时文件，不生成空 MP4 |
| TCP 主动/异常断开 | 自动完成已有录制；若尚无 IDR 则取消 |
| 收到新 VideoConfig | 先自动完成当前录制，再 dispose/init 解码器 |
| 用户切换设备 | 先完成当前设备录制，再切换 |
| 原生 writer 失败 | 停止接收录制帧，解除参数锁和录制背压，弹错误 |
| 截图时没有帧 | 返回“当前没有可截图画面” |
| 截图写文件失败 | 保持视频播放，弹错误，不影响录制 |
| 应用正常退出 | 尝试同步排空并完成录制，设置有限超时 |
| 应用崩溃/强杀 | MP4 可能无法 Finalize；下次启动清理 `.part` |

`decoder.dispose()` 前必须先停止或完成录制，避免原生录制器持有已经销毁的格式描述或纹理。

## 13. Linux 占位设计

### 13.1 本期行为

- Dart 层保留与 macOS/Windows 一致的接口和状态模型。
- Linux 平台返回结构化 `UNSUPPORTED_PLATFORM`。
- 侧边栏卡片保留，但按钮禁用并显示“Linux 平台后续支持”。
- 不创建虚假的空文件，不调用未注册 MethodChannel。

### 13.2 后续实现路径

与现有 `docs/linux_render_design.md` 对齐：

- 录制：在 FFmpeg 解码前旁路 Annex-B H.264，使用 `libavformat` 的 MP4 muxer 无损封装。
- 截图：从 Linux 解码器最新 BGRA/RGBA buffer 使用 libpng 或 GdkPixbuf 编码。
- 桌面路径：GLib XDG user directory。
- 文件管理器：优先 GTK/GIO，退化为 `xdg-open`。
- 新增系统依赖：`libavformat-dev`、`libpng-dev` 或对应运行时包。

Linux 后续实现不改变 Dart API、状态机、文件命名或首帧 IDR 规则。

## 14. 版本升级

确认实现后统一调整：

| 模块 | 当前值 | 目标值 |
| --- | --- | --- |
| Flutter `pubspec.yaml` | `1.0.1+1` | `1.0.2+2` |
| 服务端 `AppScope/app.json5` versionName | `1.0.0` | `1.0.2` |
| 服务端 `AppScope/app.json5` versionCode | `1000001` | `1000002` |
| Native 类型包 `oh-package.json5` | `1.0.0` | `1.0.2` |
| `CHANGELOG.md` | 无 1.0.2 | 新增 1.0.2 记录 |

macOS 和 Windows 应用版本均由 Flutter build name/build number 传入，打包脚本也从 `pubspec.yaml` 读取版本，不在平台工程中重复硬编码 1.0.2。

## 15. 预计修改文件

### 15.1 客户端公共代码

```text
scrcpy_client_flutter/lib/state/app_state.dart
scrcpy_client_flutter/lib/decoder/video_decoder.dart
scrcpy_client_flutter/lib/net/protocol.dart
scrcpy_client_flutter/lib/ui/sidebar.dart
scrcpy_client_flutter/lib/ui/mirror_view.dart
scrcpy_client_flutter/lib/ui/dialogs.dart
scrcpy_client_flutter/pubspec.yaml
CHANGELOG.md
```

可按实现复杂度新增：

```text
scrcpy_client_flutter/lib/media/media_capture.dart
scrcpy_client_flutter/lib/media/media_save_result.dart
```

### 15.2 macOS

```text
scrcpy_client_flutter/macos/Runner/VideoDecoderPlugin.swift
scrcpy_client_flutter/macos/Runner/Mp4Recorder.swift
scrcpy_client_flutter/macos/Runner/PngSnapshotWriter.swift
scrcpy_client_flutter/macos/Runner.xcodeproj/project.pbxproj
```

### 15.3 Windows

```text
scrcpy_client_flutter/windows/runner/video_decoder_plugin.h
scrcpy_client_flutter/windows/runner/video_decoder_plugin.cpp
scrcpy_client_flutter/windows/runner/h264_d3d11_decoder.h
scrcpy_client_flutter/windows/runner/h264_d3d11_decoder.cpp
scrcpy_client_flutter/windows/runner/i_decoder.h
scrcpy_client_flutter/windows/runner/mp4_recorder.h
scrcpy_client_flutter/windows/runner/mp4_recorder.cpp
scrcpy_client_flutter/windows/runner/png_snapshot_writer.h
scrcpy_client_flutter/windows/runner/png_snapshot_writer.cpp
scrcpy_client_flutter/windows/runner/CMakeLists.txt
```

### 15.4 服务端

```text
scrcpy_server/AppScope/app.json5
scrcpy_server/entry/src/main/ets/scrcpyservice/Protocol.ets
scrcpy_server/entry/src/main/ets/scrcpyservice/ScrcpyService.ets
scrcpy_server/entry/src/main/cpp/ScreenCaptureEncoder.h
scrcpy_server/entry/src/main/cpp/ScreenCaptureEncoder.cpp
scrcpy_server/entry/src/main/cpp/napi_init.cpp
scrcpy_server/entry/src/main/cpp/types/libscrcpy_capture/Index.d.ts
scrcpy_server/entry/src/main/cpp/types/libscrcpy_capture/oh-package.json5
```

## 16. 验证方案

### 16.1 自动化测试

Dart 单元测试：

- 录制状态机合法/非法流转；
- 录制期间参数切换被拦截，且不更新 SharedPreferences；
- 断开、新配置、设备切换触发自动完成；
- 原生错误能解除参数锁；
- Linux placeholder 返回明确错误。

Native/工具测试：

- Annex-B 3/4 字节 start code 解析；
- SPS/PPS 剔除和 Windows sequence header 构造；
- IDR NAL type 5 检测；
- PTS 微秒归一化、末帧时长和回退检测；
- 文件重名与桌面路径解析；
- RGBA/BGRA PNG 色彩测试图。

### 16.2 macOS 验收

- H.264 1080p/2160p，8/15/20fps 分别录制。
- 在任意 P 帧时刻点击录制，文件第一帧仍可立即解码。
- QuickTime 可打开，时长、宽高正确，无前段花屏。
- VideoToolbox 解码播放与 AVAssetWriter 录制并行时画面不卡顿。
- 截图尺寸等于视频原始尺寸，颜色、方向正确。
- “打开路径”在 Finder 中选中文件。
- 中文用户名、桌面重定向或无写权限场景给出正确结果。

### 16.3 Windows 验收

- D3D11 硬解和 CPU 回退两条路径分别截图。
- Windows 自带播放器可打开 MP4，首帧、时长、拖动播放正常。
- Media Foundation 写入的 MP4 含正确 SPS/PPS 和关键帧索引。
- 截图没有红蓝通道互换。
- “打开路径”在 Explorer 中选中文件。
- Windows 10、Windows 11 分别验证。

### 16.4 稳定性与异常

- 连续截图 100 次，无句柄和内存持续增长。
- 2160p/12Mbps 连续录制 30 分钟，录制队列稳定，无 P 帧丢失。
- 录制期间点击分辨率/帧率：只出现提示，不发送 `CHANGE_VIDEO_PARAMS`。
- 录制期间断开 HDC、拔线、服务端重启：已有内容可正常完成或明确报错。
- 等待 IDR 阶段立即取消：不留下空文件。
- 模拟磁盘满、桌面无权限、Finalize 失败：播放不中断，错误可见。
- 录制中截图：MP4 和 PNG 均正常。

### 16.5 构建检查

```bash
cd scrcpy_client_flutter
flutter analyze
flutter test
flutter build macos --debug
```

Windows 环境：

```powershell
cd scrcpy_client_flutter
flutter analyze
flutter test
flutter build windows --release
```

服务端：

```bash
cd scrcpy_server
/Applications/DevEco-Studio.app/Contents/tools/node/bin/node \
  /Applications/DevEco-Studio.app/Contents/tools/hvigor/bin/hvigorw.js \
  clean --mode module -p product=default assembleHap \
  --analyze=normal --parallel --incremental --daemon
```

## 17. 实施顺序

1. 修正 PTS 单位命名和 Windows 换算，增加相关测试。
2. 扩展 `REQUEST_KEYFRAME` 协议和 OpenHarmony native 请求 IDR 能力。
3. 建立 Dart 录制状态机、参数锁、统一结果对象和 UI。
4. 实现 macOS MP4 录制和 PNG 截图。
5. 实现 Windows MP4 录制和 CPU/D3D11 PNG 截图。
6. 完善断开、新配置、退出和背压收尾。
7. 增加 Linux 占位。
8. 统一升级 1.0.2，更新变更日志。
9. 完成两平台构建、真机功能和异常矩阵验证。

## 18. 待确认项

实施前需要确认以下产品边界：

1. MP4 仅包含画面，不包含设备音频或麦克风音频。
2. 录制只支持 H.264；设备降级到 RAW/JPEG 时录制按钮不可用，但截图仍可用。
3. 点击录制后最多等待 5 秒 IDR；超时则取消，不保存空文件。
4. TCP 断开或视频配置意外变化时，自动完成并保留已经录制的内容。
5. 文件固定保存到桌面，不在本期增加另存为选择器。

## 19. 参考资料

- OpenHarmony 6.1 Full SDK 文档：`6.1-Release/media/avcodec/video-encoding.md`
- 本地 OpenHarmony API 23：
  - `native_avbuffer_info.h`：`OH_AVCodecBufferAttr.pts` 单位为微秒。
  - `native_avcodec_base.h`：`OH_MD_KEY_REQUEST_I_FRAME` 从 API 10 起支持；B 帧编码默认关闭。
  - `native_avcodec_videoencoder.h`：`OH_VideoEncoder_SetParameter`。
- [Apple AVAssetWriterInput outputSettings](https://developer.apple.com/documentation/avfoundation/avassetwriterinput/outputsettings)
- [Apple AVAssetWriterInput compressed sample passthrough](https://developer.apple.com/documentation/avfoundation/avassetwriterinput/assetwriterinputwithmediatype%3Aoutputsettings%3A)
- [Microsoft Using the Sink Writer](https://learn.microsoft.com/en-us/windows/win32/medfound/using-the-sink-writer)
- [Microsoft MPEG-4 File Sink](https://learn.microsoft.com/en-us/windows/win32/medfound/mpeg-4-file-sink)
- [Microsoft MFCreateSinkWriterFromURL](https://learn.microsoft.com/en-us/windows/win32/api/mfreadwrite/nf-mfreadwrite-mfcreatesinkwriterfromurl)
- [Microsoft Windows Imaging Component encoder](https://learn.microsoft.com/en-us/windows/win32/wic/-wic-imp-iwicbitmapencoder)
