#pragma once
#include <flutter/method_channel.h>
#include <flutter/plugin_registrar_windows.h>
#include <flutter/standard_method_codec.h>
#include <flutter/texture_registrar.h>

#include <memory>
#include <mutex>
#include <vector>

#include "i_decoder.h"

class H264D3D11Decoder;

class VideoDecoderPlugin : public flutter::Plugin {
 public:
  static void RegisterWith(flutter::PluginRegistrarWindows* registrar);

  explicit VideoDecoderPlugin(flutter::PluginRegistrarWindows* registrar);
  ~VideoDecoderPlugin() override;

  const FlutterDesktopPixelBuffer* CopyPixelBuffer(size_t w, size_t h);

 private:
  void HandleMethodCall(
      const flutter::MethodCall<flutter::EncodableValue>& call,
      std::unique_ptr<flutter::MethodResult<flutter::EncodableValue>> result);

  void OnFrame(DecodedFrame frame);
  void CleanupDecoder();

  flutter::PluginRegistrarWindows* registrar_;
  flutter::TextureRegistrar* texture_registrar_;

  std::unique_ptr<flutter::MethodChannel<flutter::EncodableValue>> channel_;

  std::unique_ptr<flutter::TextureVariant> cpu_texture_variant_;
  int64_t cpu_texture_id_ = -1;

  std::unique_ptr<IDecoder> decoder_;
  H264D3D11Decoder* d3d11_decoder_ = nullptr;

  std::string decoder_type_;

  // 生产者-消费者：worker → pending_ (mutex) → display_ (raster only)
  std::mutex pending_mu_;
  DecodedFrame pending_;
  bool has_pending_ = false;

  // display_ 只由 raster 线程访问，无需锁保护
  DecodedFrame display_;
  FlutterDesktopPixelBuffer display_pb_{};
};
