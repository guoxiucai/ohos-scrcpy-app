# Windows 端视频渲染设计

> 目标：在 Windows 桌面客户端上对齐 macOS 的 `VideoDecoderPlugin` 能力，支持 **H264 / JPEG / RAW RGBA** 三种码流的解码与上屏，复用现有 `MethodChannel('scrcpy/decoder')` 协议，不改 Dart 层接口。

## 1. 现状与目标

### 1.1 现状
- `scrcpy_client_flutter/windows/runner/video_decoder_plugin.{h,cpp}` 仅是 stub：`init` 直接返回 `-1`，`feed/dispose` 直接 `Success()`，UI 走占位渲染。
- `lib/decoder/video_decoder.dart` 已经把 `codec / width / height / sps / pps / nal` 全部通过 `StandardMethodCodec` 透传，Windows 侧只需补真实实现。
- macOS 端 `VideoDecoderPlugin.swift` 已经是闭环参考实现：H264 走 VideoToolbox，RAW RGBA 走 CVPixelBufferPool + R/B swap，JPEG 走 ImageIO；统一通过 `FlutterTexture.copyPixelBuffer` 把 BGRA `CVPixelBuffer` 上屏。

### 1.2 目标（P0）
- 三种 codec 共用一份 MethodChannel handler、一份纹理注册流程、一份 latest-frame 缓存与互斥锁。
- 输出为 Flutter `TextureVariant`（GPU 路径优先；不可用时回落 Pixel Buffer 路径），保证与现有 `mirror_view` 直接对接。
- 不引入 ffmpeg / media_kit / 第三方 H264 解码库，全部使用 Windows 系统组件。

### 1.3 非目标
- 不做软件解码 fallback（H264 必须硬解；硬解失败直接报错给上层，UI 维持占位）。
- 不做 D3D11 共享句柄给 dart：当前 Flutter Windows 不暴露 `ID3D11Texture2D` 共享接口，使用 CPU 像素缓冲纹理（`FlutterDesktopPixelBuffer`）即可。GPU 共享句柄留作 P2 优化。

## 2. 架构

```
+-----------------------------+        scrcpy/decoder (MethodChannel)
|        Dart (lib/decoder)   | <----------------------------------+
+--------------+--------------+                                    |
               |                                                   |
               v                                                   |
+-----------------------------+       Texture id (int64)           |
|  VideoDecoderPlugin (Win)   | -----------------------------------+
|  - PixelBufferTexture       |
|  - latest BGRA buffer + mu  |
|  - Decoder* (polymorphic)   |
+-------+--------+------------+
        |        |        |
        v        v        v
+-------+--+ +---+----+ +-+--------+
| H264MFT  | | RawDec | | JpegWIC  |
|  (D3D11) | | (CPU)  | |  (CPU)   |
+----------+ +--------+ +----------+
```

- **Plugin 入口**：`VideoDecoderPlugin::HandleMethodCall` 按 `init.codec` 实例化对应 `IDecoder`，注册 `flutter::PixelBufferTexture`，把 `texture_id` 返回给 Dart。
- **IDecoder 接口**（C++，私有头）：
  ```cpp
  struct DecodedFrame { std::vector<uint8_t> bgra; int w; int h; };
  class IDecoder {
   public:
    virtual ~IDecoder() = default;
    virtual bool Init(const flutter::EncodableMap& args, std::string* err) = 0;
    // 由 plugin 在 feed() 中调用；解码完成后回调 on_frame
    virtual void Feed(const std::vector<uint8_t>& nal, bool keyframe, int64_t pts_ms) = 0;
    using FrameCb = std::function<void(DecodedFrame)>;
    void SetFrameCallback(FrameCb cb) { on_frame_ = std::move(cb); }
   protected:
    FrameCb on_frame_;
  };
  ```
- **统一上屏**：解码器把 BGRA8888 + 宽高放进 `latest_frame_`（带 `std::mutex`），随后 `texture_registrar_->MarkTextureFrameAvailable(texture_id_)`。Flutter 引擎下一帧调 `PixelBufferTexture::CopyPixelBuffer(width,height)`，回 `FlutterDesktopPixelBuffer{ buffer=latest.bgra.data(), width, height, release_context, release_callback=nullptr }`。

## 3. 三种 codec 的实现细节

### 3.1 H264：Media Foundation Transform（MFT）+ CPU 拷贝
- 使用 `CLSID_MSH264DecoderMFT`（系统自带 H.264 硬件/软件解码器，Win8+）。
- 初始化序列：
  1. `MFStartup(MF_VERSION)`（plugin 加载时一次即可，注意 `MFShutdown` 在 `dispose` 时不要做，避免影响其它插件——只在进程退出时考虑）。
  2. `CoCreateInstance(CLSID_MSH264DecoderMFT, ...)` 拿 `IMFTransform`。
  3. 把 SPS+PPS 拼成 Annex-B（`00 00 00 01 SPS 00 00 00 01 PPS`），塞到输入 `MF_MT_USER_DATA`：可选，部分驱动需要。
  4. 输入类型：`MFVideoFormat_H264`，`MF_MT_FRAME_SIZE = (width<<32)|height`，`MF_MT_INTERLACE_MODE = MFVideoInterlace_Progressive`。
  5. 输出类型：枚举 `GetOutputAvailableType` 选 `MFVideoFormat_NV12`（最稳定），保存输出宽高/stride。
  6. `IMFTransform::ProcessMessage(MFT_MESSAGE_NOTIFY_BEGIN_STREAMING, 0)`。
- Feed 帧：
  1. 把 Annex-B 的 NAL 直接 `MFCreateMemoryBuffer + MFCreateSample`（Microsoft 解码器接受 Annex-B；不需要转 AVCC，与 macOS VT 不同）。
  2. `SetSampleTime(pts_100ns)`、`SetSampleDuration` 可选。
  3. `IMFTransform::ProcessInput(0, sample, 0)`。
  4. 循环 `ProcessOutput`，直到 `MF_E_TRANSFORM_NEED_MORE_INPUT`：
     - 输出 sample → `IMFSample::ConvertToContiguousBuffer` → 拿 NV12 字节。
     - **NV12 → BGRA** 转换：自己写 SIMD（SSE2/AVX2）或者使用 `IMFTransform(CLSID_VideoProcessorMFT)` / `D3D11 VideoProcessor`。**第一版**：CPU 软件转换（参考 `libyuv` 的 NV12ToARGB；如不引入 libyuv，可手写一份 fallback，约 60 行）。
     - 拷进 `latest_frame_`，触发纹理刷新。
- Annex-B 起始码：与 macOS 不同，**不要丢 SPS/PPS NAL**——MFT 第一次解码时需要 SPS/PPS 在码流里；服务端发送的关键帧前面一般会带 SPS/PPS，照原样喂即可。如果服务端以 init 单独传，那就在 `Init` 阶段把 `00 00 00 01 SPS 00 00 00 01 PPS` 缓存，Feed 时若发现是关键帧就先把这串前缀注入一次。
- 异步模式：MS H264 MFT 默认同步即可；若后期发现 `ProcessOutput` 阻塞，可切到 `MF_TRANSFORM_ASYNC` + `IMFMediaEventGenerator`。

### 3.2 JPEG：WIC（Windows Imaging Component）
- `CoCreateInstance(CLSID_WICImagingFactory)` 拿 `IWICImagingFactory`。
- `CreateDecoderFromStream(IStream*, GUID_VendorMicrosoft, WICDecodeMetadataCacheOnLoad)`：把 `std::vector<uint8_t>` 包到 `SHCreateMemStream` 得到的 `IStream`。
- `GetFrame(0)` → `IWICFormatConverter::Initialize(..., GUID_WICPixelFormat32bppBGRA, ...)` → `CopyPixels(nullptr, stride, buf.size(), buf.data())`。
- 直接得到 BGRA8888，不用做 R/B swap。
- 宽高动态：和 macOS 对齐，每帧根据 WIC 输出尺寸更新 `latest_frame_.w/h`。

### 3.3 RAW RGBA：直接转换
- `init.codec=1` 时取 `width/height`。
- `feed` 收到 `width*height*4` 字节 RGBA，做 R/B swap 拷到 BGRA buffer。
- 与 macOS 的 `feedRaw` 一致；CPU 路径足够（典型 1080p ≈ 8MB/frame，30fps ≈ 240MB/s 内存写带宽，桌面机 OK）。
- 如果性能不够，再考虑 SSSE3 `pshufb` 一次性 swap 16 字节。

## 4. 与 Flutter 的纹理对接

```cpp
class PixelBufferDecoderTexture : public flutter::PixelBufferTexture {
 public:
  PixelBufferDecoderTexture(VideoDecoderPlugin* owner) : owner_(owner) {}
  const FlutterDesktopPixelBuffer* CopyPixelBuffer(size_t /*w*/, size_t /*h*/) override {
    return owner_->LockLatestForFlutter();  // 内部加锁，返回 owner 持有的 buffer 指针
  }
 private:
  VideoDecoderPlugin* owner_;
};
```

- `RegisterTexture` 返回 `int64_t`，作为 `init` 的返回值。
- `LockLatestForFlutter` 返回的 `FlutterDesktopPixelBuffer*` 在下一次 `CopyPixelBuffer` 之前必须保持有效——把 `latest_frame_` 设计成 **double buffer**：`back_` 用于解码线程写入，写完原子 swap 给 `front_`；`CopyPixelBuffer` 只读 `front_`。这样无需把锁持有到 Flutter 回调返回之后。
- `MarkTextureFrameAvailable` 必须在 UI 线程之外也能调用——Flutter Windows engine 内部会切回 raster 线程，安全。

## 5. 线程模型

| 线程 | 工作 |
|------|------|
| Flutter platform thread | `HandleMethodCall`（init/feed/dispose），把 `feed` 的字节拷一份扔进解码线程队列 |
| Decoder worker thread (1 per session) | `MFT::ProcessInput/ProcessOutput`、WIC、RAW 拷贝；写 `back_` 后 swap → MarkTextureFrameAvailable |
| Flutter raster thread | 调 `CopyPixelBuffer`，读 `front_` |

- `feed` 不要在 platform thread 里做解码：MFT 软解可能上百毫秒，会卡 UI。
- 队列用 `std::deque + std::mutex + std::condition_variable`；超过阈值（例如 5 帧）丢弃旧的非关键帧，避免回放堆积。
- `dispose` 时先 set `stop=true`，notify worker，join。MFT 做 `ProcessMessage(MFT_MESSAGE_COMMAND_FLUSH)` + `MFT_MESSAGE_NOTIFY_END_OF_STREAM` 之后 release。

## 6. Windows 平台特定限制 / 注意点

1. **COM 初始化**
   - Plugin `RegisterWith` 时必须 `CoInitializeEx(nullptr, COINIT_MULTITHREADED)`；Decoder worker 线程内部也要 `CoInitializeEx`。MFT/WIC 都依赖 COM apartment。
   - `MFStartup(MF_VERSION, MFSTARTUP_FULL)` 一次足够；不要在 `dispose` 调 `MFShutdown`。

2. **H264 MFT 行为**
   - 系统自带 MFT 在 Win10+ 默认走硬件加速（GPU 驱动支持时），Win Server 缺 Media Feature Pack 会找不到 MFT；安装包/README 标注：**需要 Media Feature Pack**（Windows N/KN 版本默认无）。
   - MFT 输出格式枚举顺序不固定：必须显式选 `MFVideoFormat_NV12`，否则可能拿到 `IYUV/I420` 需要不同 stride 处理。
   - SPS/PPS 必须在 IDR 之前出现一次；若服务端只在 type=0x02 配置帧里发，而后续视频帧 0x03 不带 SPS/PPS，Windows 端必须自己把缓存的 SPS/PPS prepend 到首个 IDR 上。

3. **NV12 步长**
   - `MFGetAttributeUINT32(MF_MT_DEFAULT_STRIDE)` 可能返回 0；需要用 `MFGetStrideForBitmapInfoHeader` 计算，或读 `IMF2DBuffer` 的 `Lock2D` 拿真实 `pitch`。Y/UV 平面 pitch 可能不同。
   - 输出宽度可能向上对齐到 16 的倍数（MB），渲染时按真实 `MF_MT_FRAME_SIZE` 而不是 stride 来 crop。

4. **DPI 与缩放**
   - Windows 客户端窗口受系统 DPI 影响，`PixelBufferTexture` 的尺寸是物理像素；UI 侧 `mirror_view` 已经按 logical pixel 计算，无需特殊处理。
   - 高 DPI（150%/200%）下，`CopyPixelBuffer(w,h)` 传入的尺寸是 widget 期望的物理像素，但插件应忽略它直接返回原始解码 buffer——Flutter 会按需拉伸。

5. **进程沙盒 / 权限**
   - 桌面 Win32 应用无沙盒，不需要单独配置。需注意：Windows Defender Smart Screen 对未签名 exe 会弹"未知发布者"，发版时建议 Authenticode 签名（与 macOS notarization 等价）。
   - HDC 客户端调用 `Process.run('hdc')` 与 macOS 一致，不需要特殊权限。

6. **构建依赖**
   - `runner/CMakeLists.txt` 需追加：
     ```cmake
     target_link_libraries(${BINARY_NAME} PRIVATE
         "mfplat.lib" "mfuuid.lib" "mfreadwrite.lib" "mf.lib"
         "windowscodecs.lib"   # WIC
         "ole32.lib")
     ```
   - 最低 Windows SDK：10.0.17763 即可（已在 Flutter Windows 模板默认范围内）。
   - 不引入第三方依赖；如果手写 NV12→BGRA 太慢，再考虑 vcpkg 引 libyuv（单独评估）。

7. **Flutter Windows 纹理限制**
   - 当前 Flutter Engine Windows 暴露的 texture 类型：`PixelBufferTexture`（CPU）和 `GpuSurfaceTexture`（D3D11，Engine ≥ 3.10）。本设计使用 PixelBuffer 路径，简单可靠。
   - GpuSurfaceTexture 路径要求 D3D11 Device 与 Flutter Engine 共享，目前 ohos 分支 Flutter 3.22.1-ohos 是否启用需在实机验证；首版不启用。

8. **多设备多会话**
   - 当前协议一次只连一个设备，单 Plugin 实例够用。若未来扩展多窗口，每个 `MethodChannel` 实例需要独立的 decoder/texture（按 channel name 加后缀），本设计预留 IDecoder 抽象方便扩展。

9. **打包**
   - `flutter build windows --release` 产物 `Runner.exe` + Flutter dll + 当前插件 dll（plugin 静态链接到 runner，无独立 dll）。
   - `scripts/package_win.ps1` 用 Inno Setup 打 `Setup.exe`：需要把 hdc 客户端要求（`hdc.exe` 在 PATH）写入 README/安装向导提示，**不要内置 hdc**（与 mac 一致）。

## 7. 落地里程碑

| 阶段 | 内容 | 验收 |
|------|------|------|
| W1 | 把 stub plugin 改造成统一 `IDecoder` 抽象 + `PixelBufferTexture` 注册；实现 RAW codec | RAW 模式在 Win 实机看到画面 |
| W2 | 实现 JPEG（WIC） | JPEG 模式在 Win 实机看到画面，CPU 占用合理 |
| W3 | 实现 H264（MFT），含 SPS/PPS 缓存、NV12→BGRA、worker 线程、队列 | H264 模式在 Win 实机看到 30fps 1080p；断开/重连不黑屏 |
| W4 | CMake / 链接 / Inno Setup 打包脚本验证；签名 + Smart Screen 验证 | `Setup.exe` 在干净 Win10/11 双开机能直接跑通 |
| W5（可选） | GpuSurfaceTexture 评估：MFT 直接输出 D3D11 Texture2D，零拷贝上屏 | 与 PixelBuffer 路径性能对比 |

## 8. 与 macOS 实现的对照表

| 维度 | macOS | Windows |
|------|-------|---------|
| H264 解码 | VideoToolbox `VTDecompressionSession` | Media Foundation `IMFTransform`（H264 MFT） |
| H264 码流 | Annex-B → AVCC（4 字节长度前缀） | Annex-B 直接喂 |
| H264 SPS/PPS | 通过 `CMVideoFormatDescription` 创建时一次性给 | 必须每个 IDR 前出现在码流里（Plugin 缓存并 prepend） |
| 像素格式 | BGRA via VT 输出 | NV12 via MFT → 软件转 BGRA |
| JPEG 解码 | ImageIO `CGImageSource` | WIC `IWICImagingFactory` |
| RAW | CVPixelBufferPool + R/B swap | 普通 buffer + R/B swap |
| 纹理 | `FlutterTexture.copyPixelBuffer` (`CVPixelBuffer`) | `PixelBufferTexture::CopyPixelBuffer` (`FlutterDesktopPixelBuffer`) |
| 纹理零拷贝 | `IOSurface` 自带 GPU 共享 | 暂走 CPU buffer；GPU 共享留 P2 |
| 线程 | VT 异步回调直接写 latest | 自建 worker 线程串行解码 |
| 平台权限 | entitlements 关闭 sandbox | 无沙盒，签名规避 SmartScreen |

---

后续如有第三方 H264 库（如 OpenH264/dav1d）需求，单独走独立设计文档评估，不在本文范围。
