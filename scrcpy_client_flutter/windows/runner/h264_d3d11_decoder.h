#pragma once
#include "i_decoder.h"

#include <condition_variable>
#include <deque>
#include <mutex>
#include <thread>

#include <d3d11.h>
#include <d3d11_1.h>
#include <dxgi.h>
#include <mfapi.h>
#include <mferror.h>
#include <mfidl.h>
#include <mftransform.h>
#include <wrl/client.h>

#include <flutter/texture_registrar.h>

using Microsoft::WRL::ComPtr;

// H264 DXVA 硬件加速解码 + D3D11 VideoProcessorBlt(NV12→BGRA) + GpuSurfaceTexture 零拷贝上屏。
// 当硬件 MFT 不可用时 Init 返回 false，由上层回落到 CPU 软解。
class H264D3D11Decoder : public IDecoder {
 public:
  H264D3D11Decoder() = default;
  ~H264D3D11Decoder() override { Teardown(); }

  bool Init(const flutter::EncodableMap& args, std::string* err) override;
  void Feed(std::vector<uint8_t> nal, bool keyframe, int64_t pts_ms) override;
  void Teardown() override;

  // 供 VideoDecoderPlugin 注册 GpuSurfaceTexture 后设置
  void SetTextureRegistrar(flutter::TextureRegistrar* registrar) { texture_registrar_ = registrar; }
  int64_t texture_id() const { return texture_id_; }

  // GpuSurfaceTexture 回调：返回当前 DXGI shared handle
  const FlutterDesktopGpuSurfaceDescriptor* ObtainDescriptor(size_t w, size_t h);

 private:
  void WorkerLoop();
  bool SetupD3D11(std::string* err);
  bool SetupHardwareMFT(std::string* err);
  bool SetupVideoProcessor();
  bool EnsureOutputTexture(UINT width, UINT height);

  // SPS/PPS 缓存
  std::vector<uint8_t> sps_nal_;
  std::vector<uint8_t> pps_nal_;
  bool sps_pps_injected_ = false;

  int width_ = 0;
  int height_ = 0;

  // D3D11
  ComPtr<ID3D11Device> d3d_device_;
  ComPtr<ID3D11DeviceContext> d3d_context_;
  ComPtr<IMFDXGIDeviceManager> dxgi_manager_;
  UINT dxgi_reset_token_ = 0;

  // MFT
  ComPtr<IMFTransform> mft_;

  // Video Processor (NV12→BGRA)
  ComPtr<ID3D11VideoDevice> video_device_;
  ComPtr<ID3D11VideoContext> video_context_;
  ComPtr<ID3D11VideoProcessorEnumerator> vp_enum_;
  ComPtr<ID3D11VideoProcessor> video_proc_;

  // 输出纹理 (BGRA, SHARED)
  ComPtr<ID3D11Texture2D> output_tex_;
  HANDLE shared_handle_ = nullptr;
  UINT out_width_ = 0;
  UINT out_height_ = 0;

  // Flutter 纹理
  flutter::TextureRegistrar* texture_registrar_ = nullptr;
  std::unique_ptr<flutter::TextureVariant> texture_variant_;
  int64_t texture_id_ = -1;

  // GPU surface descriptor
  FlutterDesktopGpuSurfaceDescriptor descriptor_{};
  std::mutex desc_mu_;

  struct Task {
    std::vector<uint8_t> data;
    bool keyframe = false;
    int64_t pts_ms = 0;
  };

  std::deque<Task> queue_;
  std::mutex mu_;
  std::condition_variable cv_;
  bool stop_ = false;
  std::thread worker_;
};
