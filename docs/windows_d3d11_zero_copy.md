# Windows H264 解码渲染方案调研

> 调研日期：2026-05-09  
> **当前实现：方案1优化版（MFTEnumEx DXVA 硬解 + D3D11 VideoProcessorBlt + GpuSurfaceTexture），回落 CPU 软解**

## 0. 本机硬件环境（验证时间 2026-05-09）

| 项目 | 状态 |
|------|------|
| CPU | Intel i5-7300HQ（4核4线程，2.5GHz） |
| GPU 1 | Intel HD Graphics 630，驱动 31.0.101.2141 |
| GPU 2 | NVIDIA GeForce 940MX，驱动 31.0.15.1654 |
| HardwareMFT EnableDecoders | `1`（注册表已开启）|
| msmpeg2vdec.dll | 存在（系统 DXVA/软件 H264 MFT）|
| nvEncodeAPI64.dll | 存在（NVIDIA 编解码支持）|
| D3D11 | 存在（v10.0.19041）|
| Intel IGCC（Quick Sync 运行时）| **未安装**（igfxDIR.dll 缺失）|

Intel IGCC 缺失意味着  通道不可用；NVIDIA 940MX 的 DXVA2/D3D11VA H264 硬解和系统 msmpeg2vdec.dll 均可用。

---

## 方案1：MFT 原生插件（CPU PixelBuffer 路径）

### 流水线

```
H264 NAL (Dart → MethodChannel)
  → CoCreateInstance(CLSID_MSH264DecoderMFT)   ← 软解，不启用 DXVA
  → ProcessOutput → NV12 (CPU 内存)
  → Nv12ToBgra (CPU 逐像素，1080p ~8ms/帧)
  → memcpy → FlutterDesktopPixelBuffer
  → Flutter engine upload 到 GPU
```

### 状态

已实现（`h264_decoder.h/.cpp` + `video_decoder_plugin.cpp`），但**已验证在本机卡顿**。

### 卡顿根因

- `CoCreateInstance(CLSID_MSH264DecoderMFT)` 强制使用软件 MFT，不走 DXVA 硬解
- NV12→BGRA 全程 CPU 逐像素，1080p 每帧约 8ms（800万次乘加）
- CPU 全程参与三次数据搬运，i5-7300HQ 上 20fps 占用率 > 40%

### 性能估计

| 指标 | 值 |
|------|----|
| CPU 占用 | ~40%（i5-7300HQ，1080p@20fps）|
| 解码延迟 | 30-50ms |
| 适用场景 | 无 GPU/无驱动的兜底回落 |

### 代码文件

| 文件 | 说明 |
|------|------|
| `windows/runner/h264_decoder.h/.cpp` | 软件 MFT + CPU NV12→BGRA |
| `windows/runner/video_decoder_plugin.h/.cpp` | Plugin 入口，H264 路由 |

---

## 方案2：libmdk `appendBuffer` 直推（去掉 TCP relay）

### 背景

当前 fvp/mdk 路径通过本地 TCP relay（`ServerSocket.bind` → libmdk `tcp://127.0.0.1:PORT`）给 libmdk 喂数据，引入额外的 socket 往返延迟（~10-20ms）以及 FFmpeg 格式探测阻塞问题。

### 方案原理

libmdk 原生 C++ API 支持 `stream:` 协议 + `appendBuffer()`，可直接将 H264 NAL 推入解码管线，无需 TCP relay：

```cpp
// 原生 C API（Player.h）
bool (*appendBuffer)(struct mdkPlayer*, const uint8_t* data, size_t size, int options);
```

用法：
1. `player.media = "stream:"` — 告知 libmdk 数据由外部推送
2. 每帧调用 `appendBuffer(data, size, 0)` 直接喂 Annex-B 数据
3. libmdk 内部走 D3D11/NVDEC 硬解，`updateTexture()` 等视频尺寸确定后创建 texture

### FFI 访问方式

fvp 0.36.2 的 `generated_bindings.dart` 已暴露 `appendBuffer` 的 FFI binding（line 2532），但 Dart `Player` 类未封装。可通过 `player.nativeHandle`（`Pointer<mdkPlayerAPI>` 地址）访问：

```dart
// nativeHandle = Pointer<mdkPlayerAPI>.address
final apiPtr = Pointer<mdkPlayerAPI>.fromAddress(player.nativeHandle);
final fn = apiPtr.ref.appendBuffer.asFunction<AppendBufferDart>();
fn(apiPtr.ref.object.cast<Void>(), nativeData, data.length, 0);
```

### 优缺点

| 优点 | 缺点 |
|------|------|
| 去掉 TCP relay，减少 ~10-20ms 延迟 | 依赖 fvp 内部 FFI 结构，版本升级可能 break |
| libmdk 内部走 D3D11/NVDEC 硬解 | `stream:` 协议文档稀少，需大量调试 |
| Dart 层改动为主，不需写 C++ | `appendBuffer` 线程安全性未明确文档化 |
| 保持 fvp Flutter Texture 渲染路径 | 格式探测问题（probesize）仍可能首帧卡住 |

### 性能估计

| 指标 | 值 |
|------|----|
| CPU 占用 | < 10%（libmdk 内部硬解）|
| 解码延迟 | 15-25ms（vs 当前 fvp+TCP ~40-60ms）|
| 首帧延迟 | 仍依赖 libmdk 内部探测，~1-2s 风险 |

### 实现状态

**未实现**。评估为中等工作量，但维护风险高（耦合 fvp 内部结构）。fvp 依赖已移除，此方案不再考虑。

---

## 方案3：D3D11 零拷贝（MFT DXVA + VideoProcessorBlt + GpuSurfaceTexture）

### 流水线

```
H264 NAL (Dart → MethodChannel)
  │
  ▼
MFTEnumEx + DXVA2/D3D11VA 硬解
  │  输出：D3D11 Texture2D (NV12, GPU显存)
  ▼
D3D11 VideoProcessorBlt (GPU 上 NV12→BGRA，< 0.1ms)
  │  输出：D3D11 Texture2D (BGRA, DXGI_RESOURCE_MISC_SHARED)
  ▼
GpuSurfaceTexture (DXGI shared handle → Flutter engine)
  │  零 CPU 拷贝
  ▼
Flutter Texture 渲染
```

CPU 不再碰像素数据，只做 MFT API 调度和帧投递。

### 关键实现点

#### 3.1 MFT 启用 DXVA 硬解

用 `MFTEnumEx` 枚举硬件 decoder（而非 `CoCreateInstance` 强制软件 MFT）：

```cpp
MFT_REGISTER_TYPE_INFO inputType = { MFMediaType_Video, MFVideoFormat_H264 };
IMFActivate** ppActivate = nullptr;
UINT32 count = 0;
MFTEnumEx(MFT_CATEGORY_VIDEO_DECODER,
    MFT_ENUM_FLAG_HARDWARE | MFT_ENUM_FLAG_SORTANDFILTER,
    &inputType, nullptr, &ppActivate, &count);
// count==0 时回落软解（SYNCMFT）
```

将 `IMFDXGIDeviceManager` 传给 MFT，让其输出 GPU 纹理：

```cpp
UINT token = 0;
MFCreateDXGIDeviceManager(&token, &dxgiManager_);
dxgiManager_->ResetDevice(d3d_device_.Get(), token);
mft_->ProcessMessage(MFT_MESSAGE_SET_D3D_MANAGER,
    reinterpret_cast<ULONG_PTR>(dxgiManager_.Get()));
```

#### 3.2 从 ProcessOutput 取 D3D11 纹理（IMFDXGIBuffer）

```cpp
ComPtr<IMFDXGIBuffer> dxgiBuf;
outBuf->QueryInterface(IID_PPV_ARGS(&dxgiBuf));
ComPtr<ID3D11Texture2D> decodedTex;
dxgiBuf->GetResource(IID_PPV_ARGS(&decodedTex));
UINT subIdx = 0;
dxgiBuf->GetSubresourceIndex(&subIdx);  // 纹理数组子资源，可能非 0
```

#### 3.3 GPU NV12→BGRA：D3D11 VideoProcessorBlt

系统内置 GPU shader，零额外依赖，约 < 0.1ms：

```cpp
D3D11_VIDEO_PROCESSOR_CONTENT_DESC vpDesc = {};
vpDesc.InputWidth = width_; vpDesc.InputHeight = height_;
vpDesc.OutputWidth = width_; vpDesc.OutputHeight = height_;
videoDevice_->CreateVideoProcessorEnumerator(&vpDesc, &vpEnum_);
videoDevice_->CreateVideoProcessor(vpEnum_.Get(), 0, &videoProc_);

// 输出：BGRA shared 纹理
D3D11_TEXTURE2D_DESC outDesc = {};
outDesc.Format = DXGI_FORMAT_B8G8R8A8_UNORM;
outDesc.MiscFlags = D3D11_RESOURCE_MISC_SHARED;
outDesc.BindFlags = D3D11_BIND_RENDER_TARGET | D3D11_BIND_SHADER_RESOURCE;
d3d_device_->CreateTexture2D(&outDesc, nullptr, &output_tex_);
```

#### 3.4 GpuSurfaceTexture（DXGI Shared Handle）

Flutter Engine Windows（≥ 3.10）支持 `GpuSurfaceTexture` 接收 DXGI shared handle，Flutter engine 直接采样，零 CPU 拷贝：

```cpp
IDXGIResource* res;
output_tex_->QueryInterface(IID_PPV_ARGS(&res));
HANDLE sharedHandle;
res->GetSharedHandle(&sharedHandle);

flutter::GpuSurfaceTexture gpuTex(
    kFlutterDesktopGpuSurfaceTypeDxgiSharedHandle,
    [=](size_t w, size_t h) -> const FlutterDesktopGpuSurfaceDescriptor* {
        desc_.handle = sharedHandle;
        desc_.width = actual_width_;
        desc_.height = actual_height_;
        desc_.format = kFlutterDesktopPixelFormatBGRA8888;
        return &desc_;
    });
texture_id_ = texture_registrar_->RegisterTexture(&gpuTex);
```

#### 3.5 回落策略

D3D11 初始化失败（旧驱动、无 Media Feature Pack 等）时自动回落方案1（`H264Decoder` CPU 路径），Dart 层接口不变。

### 线程模型

```
Platform Thread  → Feed(nal) → 入队（mutex保护）
Worker Thread    → MFT ProcessInput/ProcessOutput
                → VideoProcessorBlt（GPU）
                → MarkTextureFrameAvailable
Raster Thread    → GpuSurfaceTexture 回调 → 返回 sharedHandle（无拷贝）
```

### 性能估计

| 路径 | CPU 占用 | 解码延迟 |
|------|---------|---------|
| 方案1 MFT 软解 + CPU 转色 | ~40%（i5-7300HQ）| 30-50ms |
| 方案2 fvp appendBuffer | < 10% | 15-25ms |
| 方案3 D3D11 零拷贝（当前）| < 5% | 5-15ms |

### 实现文件

| 文件 | 说明 |
|------|------|
| `windows/runner/h264_d3d11_decoder.h/.cpp` | 新文件，D3D11 路径核心实现 |
| `windows/runner/video_decoder_plugin.h/.cpp` | Plugin 入口，H264 优先 D3D11，失败回落 CPU |
| `windows/runner/h264_decoder.h/.cpp` | 保留，作为回落 CPU 路径 |
| `windows/runner/flutter_window.h/.cpp` | 手动注册 VideoDecoderPlugin，registrar 生命周期与 window 对齐 |
| `windows/runner/CMakeLists.txt` | 追加源文件 + D3D11/MF/shlwapi 链接库 + `/utf-8` |
| `lib/decoder/video_decoder.dart` | Windows H264 MethodChannel 解码 |

### 已知问题 / 待验证

- NVIDIA 940MX DXVA 硬解在本机可用，但 Intel Quick Sync 因 IGCC 未安装不可用
- 首次连接"等待解码器就绪"问题（原 fvp 路径的 bug）在方案3下因走同步 MethodChannel 而消除
- 异步 MFT（部分硬件 decoder 为异步模式）当前用同步循环 ProcessOutput 兼容，后续可优化为事件驱动

### 踩坑记录：Windows PixelBuffer 颜色空间

**问题**：CPU 软解路径渲染画面偏杏黄色。

**根因**：`NV12→BGRA` 转换函数按 BGRA 顺序输出像素（B=byte0, G=byte1, R=byte2, A=byte3），但 Flutter Windows 的 `FlutterDesktopPixelBuffer` **实际按 RGBA 顺序解释**（R=byte0, G=byte1, B=byte2, A=byte3），导致 R 和 B 通道互换。

**关键规则**：
- `FlutterDesktopPixelBuffer`（PixelBufferTexture 路径）→ 像素数据必须是 **RGBA** 顺序
- `GpuSurfaceTexture` + DXGI SharedHandle 路径 → 纹理格式用 `DXGI_FORMAT_B8G8R8A8_UNORM`，Flutter descriptor 设 `kFlutterDesktopPixelFormatBGRA8888`，两者一致即可
- 两条路径的颜色空间约定**不同**，不能混用

**修复**：`Nv12ToBgra` 中将输出顺序改为 R-G-B-A：
```cpp
dst_row[col * 4 + 0] = clamp(r);  // 之前错写成 clamp(b)
dst_row[col * 4 + 1] = clamp(g);
dst_row[col * 4 + 2] = clamp(b);  // 之前错写成 clamp(r)
dst_row[col * 4 + 3] = 255;
```

### 踩坑记录：MFT 首帧延迟（MF_LOW_LATENCY）

**问题**：连接成功后要等 40-50 秒才看到第一帧画面，之后也非常卡顿。

**根因**：Windows Media Foundation H264 MFT 默认会缓冲多个参考帧后才开始输出。对于实时投屏场景，MFT 收到第一个关键帧后不会立即输出解码结果，而是等待后续帧填满参考缓冲区。

**解决方案**：通过 `IMFAttributes` 设置 `MF_LOW_LATENCY` 属性，让 MFT 收到 1 帧就立即输出：

```cpp
Microsoft::WRL::ComPtr<IMFAttributes> attrs;
if (SUCCEEDED(mft_->GetAttributes(&attrs))) {
    attrs->SetUINT32(MF_LOW_LATENCY, TRUE);
}
```

**注意事项**：
- `ICodecAPI::SetValue(CODECAPI_AVLowLatencyMode)` 是另一种设置低延迟的方式，但在部分机器上返回 `E_INVALIDARG`，不可靠
- `MF_LOW_LATENCY` 通过 `IMFAttributes` 接口设置，兼容性更好，推荐优先使用
- 需要 `#include <codecapi.h>` 和 `#include <strmif.h>`（如果同时尝试 ICodecAPI 路径）
- 此属性对软件 MFT 和硬件 MFT 均有效
