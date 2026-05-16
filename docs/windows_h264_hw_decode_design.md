# Windows H264 硬件加速解码 — 设计与实现文档

> 日期：2026-05-10
> 基于 `docs/windows_d3d11_zero_copy.md` 方案1 优化

## 1. 目标

在方案1（MFT MethodChannel）基础上引入 DXVA 硬件加速解码 + D3D11 GPU 色彩转换 + GpuSurfaceTexture 零拷贝上屏，形成两级回落策略：

1. **D3D11 硬解**：MFTEnumEx 硬件 MFT（NVIDIA DXVA / Intel Quick Sync）→ GPU NV12→BGRA → DXGI SharedHandle → GpuSurfaceTexture
2. **CPU 软解**：原有 `H264Decoder`（CoCreateInstance 软件 MFT + CPU NV12→BGRA + PixelBufferTexture）

## 2. 本机硬件验证结果

| 项目 | 状态 |
|------|------|
| Intel HD 630 | 驱动 OK，IGCC 未安装 → Quick Sync 不可用 |
| NVIDIA 940MX | 驱动 OK → DXVA2 H264 硬解可用 |
| D3D11 | 存在（10.0.19041） |
| msmpeg2vdec.dll | 存在 → CPU MFT 回落可用 |

`MFTEnumEx(MFT_ENUM_FLAG_HARDWARE)` 预期能枚举到 NVIDIA DXVA H264 decoder。Intel Quick Sync 因 IGCC 缺失不可用，但不影响 NVIDIA 路径。

## 3. 架构

```
Dart VideoDecoder.init(codec=0)
  │
  ▼
MethodChannel 'scrcpy/decoder' → VideoDecoderPlugin::HandleMethodCall("init")
  │
  ├─ 尝试 H264D3D11Decoder.Init()
  │   ├─ MFTEnumEx(HARDWARE) 枚举硬件 MFT
  │   ├─ 创建 D3D11 Device + DXGIDeviceManager
  │   ├─ 设置 MFT 输入/输出类型
  │   ├─ 创建 VideoProcessor（NV12→BGRA）
  │   ├─ 创建 SharedTexture（BGRA, MISC_SHARED）
  │   └─ 注册 GpuSurfaceTexture
  │
  ├─ 失败 → 回落 H264Decoder（CPU 软解 + PixelBufferTexture）
  │
  └─ 两级均失败 → 返回错误
```

## 4. 关键实现细节

### 4.1 D3D11 设备创建

使用 `D3D11CreateDevice` 时优先 `D3D_DRIVER_TYPE_HARDWARE`，feature level 11.0。需要 `D3D11_CREATE_DEVICE_VIDEO_SUPPORT` flag 以支持 Video Processor。

### 4.2 硬件 MFT 枚举与激活

```cpp
MFT_REGISTER_TYPE_INFO inputType = { MFMediaType_Video, MFVideoFormat_H264 };
MFTEnumEx(MFT_CATEGORY_VIDEO_DECODER,
    MFT_ENUM_FLAG_HARDWARE | MFT_ENUM_FLAG_SORTANDFILTER,
    &inputType, nullptr, &ppActivate, &count);
```

`count > 0` 时激活第一个硬件 MFT；`count == 0` 时返回失败，由 plugin 层回落到 CPU 路径。

### 4.3 DXGIDeviceManager 绑定

硬件 MFT 需要 `IMFDXGIDeviceManager` 才能输出 GPU 纹理：

```cpp
MFCreateDXGIDeviceManager(&resetToken, &dxgiManager);
dxgiManager->ResetDevice(d3dDevice, resetToken);
mft->ProcessMessage(MFT_MESSAGE_SET_D3D_MANAGER, (ULONG_PTR)dxgiManager);
```

### 4.4 ProcessOutput 取 D3D11 Texture

硬件 MFT 输出 `IMFDXGIBuffer`，通过 `GetResource` 拿到 `ID3D11Texture2D`（NV12 格式，在 GPU 显存中）。注意 `GetSubresourceIndex` — 硬件 MFT 可能使用纹理数组。

### 4.5 VideoProcessorBlt：GPU NV12→BGRA

使用 `ID3D11VideoDevice` + `ID3D11VideoProcessor` 执行 GPU 上的色彩空间转换，耗时 < 0.1ms：

- 输入：解码输出的 NV12 纹理
- 输出：BGRA `ID3D11Texture2D`（带 `MISC_SHARED` flag）

### 4.6 GpuSurfaceTexture 上屏

Flutter 3.10+ 的 `GpuSurfaceTexture` 接受 DXGI shared handle，engine 直接采样，零 CPU 拷贝：

```cpp
flutter::GpuSurfaceTexture gpuTex(
    kFlutterDesktopGpuSurfaceTypeDxgiSharedHandle,
    [this](size_t w, size_t h) { return &descriptor_; });
```

### 4.7 BGRA 格式保证

Flutter `kFlutterDesktopPixelFormatBGRA8888` 对应 DXGI `DXGI_FORMAT_B8G8R8A8_UNORM`。VideoProcessorBlt 输出格式设为 `DXGI_FORMAT_B8G8R8A8_UNORM`，与 Flutter 预期一致，无需额外 RGBA/BGRA 转换。

## 5. 线程模型

```
Platform Thread   → Feed(nal) → 入队（mutex 保护）
Worker Thread     → MFT ProcessInput/ProcessOutput → VideoProcessorBlt → MarkTextureFrameAvailable
Raster Thread     → GpuSurfaceTexture 回调 → 返回 DXGI shared handle
```

## 6. 新增/修改文件

| 文件 | 变更 |
|------|------|
| `windows/runner/h264_d3d11_decoder.h` | **新增** D3D11 硬解实现头文件 |
| `windows/runner/h264_d3d11_decoder.cpp` | **新增** D3D11 硬解实现 |
| `windows/runner/video_decoder_plugin.h` | **修改** 支持 GpuSurfaceTexture + PixelBuffer 双路径 |
| `windows/runner/video_decoder_plugin.cpp` | **修改** H264 优先 D3D11，失败回落 CPU |
| `windows/runner/CMakeLists.txt` | **修改** 添加源文件和链接库 |
| `lib/decoder/video_decoder.dart` | **修改** Windows 使用 MethodChannel |
| `windows/runner/h264_decoder.h/.cpp` | **保留** 作为 CPU 回落路径 |

## 7. 回落策略总结

```
init(codec=0) 时：
  1. H264D3D11Decoder.Init()     → 成功：返回 "d3d11"，GpuSurfaceTexture
  2. H264Decoder.Init()          → 成功：返回 "cpu"，PixelBufferTexture
```

Dart 层通过 `init` 返回值中的 `decoder_type` 字段区分当前使用的路径。
