# Linux 端视频渲染设计

> 目标：在 Linux 桌面客户端（x86_64）上对齐 macOS/Windows 的 `VideoDecoderPlugin` 能力，支持 **H264 / JPEG / RAW RGBA** 三种码流的解码与上屏，复用现有 `MethodChannel('scrcpy/decoder')` 协议，不改 Dart 层接口。

---

## 1. 现状与目标

### 1.1 现状

- `scrcpy_client_flutter` 目前没有 `linux/` 目录，需要通过 `flutter create --platforms=linux .` 生成脚手架。
- Windows 端已有完整的 `IDecoder` 抽象 + `PixelBufferTexture` 双缓冲上屏框架，Linux 端复用相同架构。
- 三种 codec 对应的平台 API：

  | codec | macOS | Windows | Linux（本设计） |
  |-------|-------|---------|----------------|
  | H264  | VideoToolbox | MFT (MediaFoundation) | **FFmpeg libavcodec（系统包）** |
  | JPEG  | ImageIO | WIC | **libjpeg-turbo（系统包）** |
  | RAW RGBA | CVPixelBufferPool | CPU R/B swap | **CPU R/B swap（同 Windows）** |

### 1.2 目标

- 三种 codec 共用一份 MethodChannel handler、一份纹理注册流程、一份 latest-frame 双缓冲。
- 输出为 Flutter `PixelBufferTexture`（`FlutterDesktopPixelBuffer`），保证与现有 `mirror_view` 直接对接。
- **只依赖发行版自带的系统库**（`libavcodec / libavutil / libjpeg-turbo`），不内置第三方二进制。

### 1.3 非目标

- 不做 VA-API / VDPAU 硬解（首版 CPU 软解已足够；硬解留 P2）。
- 不做 ARM 架构支持（目标 x86_64）。
- 不做 Wayland / X11 的 DMA-BUF 零拷贝纹理（PixelBuffer CPU 路径足够）。

---

## 2. 架构

```
+-----------------------------+        scrcpy/decoder (MethodChannel)
|        Dart (lib/decoder)   | <----------------------------------+
+--------------+--------------+                                    |
               |                                                   |
               v                                                   |
+-----------------------------+       Texture id (int64)           |
|  VideoDecoderPlugin (Linux) | -----------------------------------+
|  - PixelBufferTexture       |
|  - latest BGRA buf + mutex  |
|  - IDecoder* (polymorphic)  |
+-------+--------+------------+
        |        |        |
        v        v        v
+-------+--+ +---+----+ +-+--------+
| H264Ffmp | | RawDec | | JpegTurb |
| (libav)  | | (CPU)  | | (turbo)  |
+----------+ +--------+ +----------+
```

与 Windows 端架构完全一致，仅解码器实现替换为 Linux 平台 API。

- **Plugin 入口**：`VideoDecoderPlugin::HandleMethodCall` 按 `init.codec` 实例化对应 `IDecoder`，注册 `flutter::PixelBufferTexture`，把 `texture_id` 返回给 Dart。
- **`IDecoder` 接口**：复用 Windows 端的 `i_decoder.h`（`Init / Feed / Teardown / SetFrameCallback`）。
- **统一上屏**：解码器把 BGRA8888 + 宽高写入 `back_`，swap 给 `front_`，调 `MarkTextureFrameAvailable`。Flutter raster 线程调 `CopyPixelBuffer` 读 `front_`。

---

## 3. 三种 codec 实现细节

### 3.1 H264：FFmpeg libavcodec（CPU 软解）

**依赖**：`libavcodec-dev libavutil-dev libswscale-dev`

**初始化序列**：
1. `avcodec_find_decoder(AV_CODEC_ID_H264)` 拿 `AVCodec*`。
2. `avcodec_alloc_context3` + 配置 `width/height`。
3. 可选：把 SPS/PPS 拼成 `extradata`（AVCC 格式），注入 `AVCodecContext::extradata`——当服务端只在配置帧发一次 SPS/PPS 时使用。
4. `avcodec_open2`。
5. `av_packet_alloc` + `av_frame_alloc`。

**Feed 帧**：
1. Annex-B 码流直接送 `AVPacket::data`，不需要转 AVCC。
2. `avcodec_send_packet` → 循环 `avcodec_receive_frame`，直到 `AVERROR(EAGAIN)`。
3. 输出 `AVFrame` 格式通常为 `AV_PIX_FMT_YUV420P`（FFmpeg 软解默认）。
4. **YUV420P → BGRA**：使用 `libswscale`：
   ```c
   sws_ctx = sws_getContext(w, h, AV_PIX_FMT_YUV420P,
                            w, h, AV_PIX_FMT_BGRA,
                            SWS_BILINEAR, NULL, NULL, NULL);
   sws_scale(sws_ctx, frame->data, frame->linesize, 0, h,
             dst_data, dst_linesize);
   ```
5. 拷进 `back_`，触发纹理刷新。

**SPS/PPS 处理**：
- Linux FFmpeg 与 Windows MFT 相同：Annex-B 码流需要 SPS/PPS 出现在 IDR 之前。
- Init 时缓存 SPS/PPS（从 `init` 参数的 `sps/pps` 字节取得），首个关键帧前 prepend。

**性能说明**：
- FFmpeg H264 软解 1080p30 在现代 x86 CPU 上单核 CPU 占用约 20–40%，满足日常使用。
- VA-API 硬解路径（`vaapi` / `h264_vaapi`）留 P2，通过 `avcodec_find_decoder_by_name("h264_vaapi")` 启用。

### 3.2 JPEG：libjpeg-turbo

**依赖**：`libjpeg-turbo8-dev`（Ubuntu/Debian；CentOS 为 `libjpeg-turbo-devel`）

**解码流程**：
```cpp
tjhandle tj = tjInitDecompress();
int w, h, subsamp, colorspace;
tjDecompressHeader3(tj, src, src_len, &w, &h, &subsamp, &colorspace);

std::vector<uint8_t> bgra(w * h * 4);
tjDecompress2(tj, src, src_len, bgra.data(), w, 0, h, TJPF_BGRA, TJFLAG_FASTDCT);
tjDestroy(tj);
```

- 直接输出 BGRA8888，无需 R/B swap。
- 每帧创建/销毁 `tjhandle` 开销极小；如需优化可复用 handle（线程内缓存）。
- 宽高动态：每帧通过 `tjDecompressHeader3` 获取，自动适应分辨率变化。

### 3.3 RAW RGBA：CPU R/B swap

与 Windows 端 `raw_decoder.cpp` 完全相同逻辑，无平台差异：
- `init.codec=1` 时取 `width/height`。
- 逐像素 R/B swap（RGBA → BGRA）。
- 如性能敏感，可用 SSSE3 `pshufb` 一次处理 4 个像素（16 字节）。

---

## 4. 与 Flutter 的纹理对接

Linux Flutter Engine 与 Windows 共用相同的 `flutter/texture_registrar.h` API：

```cpp
// 注册纹理
texture_variant_ = std::make_unique<flutter::TextureVariant>(
    flutter::PixelBufferTexture([this](size_t w, size_t h) {
        return CopyPixelBuffer(w, h);
    }));
texture_id_ = texture_registrar_->RegisterTexture(texture_variant_.get());

// 通知刷新（可在任意线程调用）
texture_registrar_->MarkTextureFrameAvailable(texture_id_);

// 提供像素数据
const FlutterDesktopPixelBuffer* CopyPixelBuffer(size_t, size_t) {
    std::lock_guard lk(front_mu_);
    if (front_.bgra.empty()) return nullptr;
    return &front_.pixel_buffer;  // buffer/width/height 已在 OnFrame 填好
}
```

Plugin 注册入口使用 `flutter::PluginRegistrar`（Linux 版为 `flutter/plugin_registrar_linux.h`），不是 Windows 的 `plugin_registrar_windows.h`。

---

## 5. 线程模型

| 线程 | 工作 |
|------|------|
| Flutter platform thread | `HandleMethodCall`（init/feed/dispose），把 `feed` 的字节投递到 worker 队列 |
| Decoder worker thread（每 session 一个） | FFmpeg `avcodec_send/receive`、libjpeg-turbo、RAW swap；写 `back_` 后 swap → `MarkTextureFrameAvailable` |
| Flutter raster thread | 调 `CopyPixelBuffer`，只读 `front_` |

- 队列上限 5 帧；超出时丢弃非关键帧。
- `Teardown` 时 `stop_=true` → `cv_.notify_all()` → `worker_.join()` → `avcodec_close / av_free`。

---

## 6. CMake 构建依赖

`linux/runner/CMakeLists.txt` 需追加：

```cmake
# 查找系统库
find_package(PkgConfig REQUIRED)
pkg_check_modules(AVCODEC REQUIRED libavcodec)
pkg_check_modules(AVUTIL  REQUIRED libavutil)
pkg_check_modules(SWSCALE REQUIRED libswscale)
pkg_check_modules(JPEGTURBO REQUIRED libturbojpeg)

# 链接
target_include_directories(${BINARY_NAME} PRIVATE
    ${AVCODEC_INCLUDE_DIRS}
    ${AVUTIL_INCLUDE_DIRS}
    ${SWSCALE_INCLUDE_DIRS}
    ${JPEGTURBO_INCLUDE_DIRS}
)
target_link_libraries(${BINARY_NAME} PRIVATE
    ${AVCODEC_LIBRARIES}
    ${AVUTIL_LIBRARIES}
    ${SWSCALE_LIBRARIES}
    ${JPEGTURBO_LIBRARIES}
    pthread
)
```

对应的系统包安装（Ubuntu 22.04）：
```bash
sudo apt install \
    libavcodec-dev libavutil-dev libswscale-dev \
    libjpeg-turbo8-dev
```

---

## 7. Linux 平台特定限制 / 注意点

1. **Plugin 注册头文件不同**
   - Windows：`flutter/plugin_registrar_windows.h`，类型 `flutter::PluginRegistrarWindows*`
   - Linux：`flutter/plugin_registrar_linux.h`，类型 `FlutterDesktopPluginRegistrarRef`（C API）或通过 `flutter::PluginRegistrar` 包装
   - 需要条件编译或独立的 `video_decoder_plugin_linux.cpp`。

2. **FFmpeg 版本**
   - Ubuntu 22.04 提供 FFmpeg 4.4.x；Ubuntu 24.04 提供 5.x。两个版本 API 兼容，无需适配。
   - 如发行版 FFmpeg 太旧（< 3.4），考虑 PPA 或静态链接，但通常 22.04+ 无此问题。

3. **deb 打包依赖声明**
   - `package_linux.sh` 的 `Depends` 字段需包含：
     ```
     libavcodec58 | libavcodec59 | libavcodec60,
     libjpeg-turbo8,
     libswscale5 | libswscale6 | libswscale7
     ```
   - 使用 `|` 列出多个版本以兼容 Ubuntu 22.04 / 24.04。

4. **沙盒 / 权限**
   - 桌面 Linux 无沙盒，`Process.run('hdc')` 无需特殊权限。
   - 若需 Snap/Flatpak 发布，`hdc` 调用需要 `network` + `system-files` 权限声明，首版 deb 无此问题。

5. **X11 vs Wayland**
   - Flutter Linux 默认走 GTK + X11/Wayland 自适应。`PixelBufferTexture` CPU 路径在两种协议下均正常工作。
   - 若强制 Wayland（`GDK_BACKEND=wayland`），确认 Flutter Engine 版本支持（3.10+ 已稳定）。

6. **libjpeg vs libjpeg-turbo**
   - 系统可能存在 `libjpeg-dev`（指向 libjpeg-turbo 的兼容符号链接）和 `libjpeg-turbo8-dev` 两个包。
   - 推荐明确依赖 `libjpeg-turbo8-dev` 并用 `turbojpeg.h` API（`tjInitDecompress` 系列）而非标准 `jpeglib.h`，性能更好。

---

## 8. 与 macOS / Windows 实现对照

| 维度 | macOS | Windows | Linux |
|------|-------|---------|-------|
| H264 解码 | VideoToolbox VTDecompressionSession | MFT CLSID_MSH264DecoderMFT | FFmpeg libavcodec (CPU) |
| H264 输出格式 | BGRA（VT 直出） | NV12 → CPU 转 BGRA | YUV420P → libswscale → BGRA |
| H264 SPS/PPS | CMVideoFormatDescription | 码流内 + prepend | AVCodecContext extradata + prepend |
| JPEG 解码 | ImageIO CGImageSource | WIC IWICImagingFactory | libjpeg-turbo tjDecompress2 |
| JPEG 输出 | BGRA（CGContext） | BGRA（WIC Converter） | BGRA（TJPF_BGRA） |
| RAW RGBA | CVPixelBufferPool + swap | CPU swap | CPU swap（同 Windows） |
| 纹理接口 | FlutterTexture copyPixelBuffer | PixelBufferTexture | PixelBufferTexture（同 Windows） |
| Plugin 注册 | FlutterPluginRegistrar (ObjC) | PluginRegistrarWindows (C++) | FlutterDesktopPluginRegistrarRef (C API) |
| 硬解 | IOSurface（自动） | MFT 自适应 GPU | VA-API（P2） |
| 打包 | .dmg（package_mac.sh） | Setup.exe（package_win.ps1） | .deb（package_linux.sh） |

---

## 9. 落地里程碑

| 阶段 | 内容 | 验收 |
|------|------|------|
| L1 | `flutter create --platforms=linux .` 生成脚手架；移植 `i_decoder.h` + Plugin 骨架；实现 RAW codec | RAW 模式在 Linux 实机看到画面 |
| L2 | 实现 JPEG（libjpeg-turbo） | JPEG 模式正常渲染，CPU 占用合理 |
| L3 | 实现 H264（FFmpeg），含 SPS/PPS 缓存、worker 线程、队列 | H264 1080p30 正常渲染；断开/重连不黑屏 |
| L4 | CMake pkg-config 依赖；`package_linux.sh` 生成 .deb；在 Ubuntu 22.04 干净安装测试 | 从 .deb 安装后能直接运行并连接设备 |
| L5（可选） | VA-API 硬解路径（`h264_vaapi`）；Flatpak 清单 | GPU 占用替代 CPU 解码 |
