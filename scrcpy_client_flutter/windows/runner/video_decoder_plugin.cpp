#include "video_decoder_plugin.h"

#include <mfapi.h>

#include <cassert>
#include <stdexcept>

#include "h264_d3d11_decoder.h"
#include "h264_decoder.h"
#include "jpeg_decoder.h"
#include "raw_decoder.h"

using flutter::EncodableMap;
using flutter::EncodableValue;

// static
void VideoDecoderPlugin::RegisterWith(flutter::PluginRegistrarWindows* registrar) {
  auto plugin = std::make_unique<VideoDecoderPlugin>(registrar);
  registrar->AddPlugin(std::move(plugin));
}

VideoDecoderPlugin::VideoDecoderPlugin(flutter::PluginRegistrarWindows* registrar)
    : registrar_(registrar), texture_registrar_(registrar->texture_registrar()) {
  media_foundation_started_ =
      SUCCEEDED(MFStartup(MF_VERSION, MFSTARTUP_FULL));
  channel_ = std::make_unique<flutter::MethodChannel<EncodableValue>>(
      registrar->messenger(), "scrcpy/decoder",
      &flutter::StandardMethodCodec::GetInstance());
  channel_->SetMethodCallHandler(
      [this](const auto& call, auto result) {
        HandleMethodCall(call, std::move(result));
      });
  recorder_ = std::make_unique<H264Mp4Recorder>(
      [this](const std::string& state, const std::string& error) {
        EncodableMap args;
        args[EncodableValue("state")] = EncodableValue(state);
        if (!error.empty()) {
          args[EncodableValue("error")] = EncodableValue(error);
        }
        channel_->InvokeMethod(
            "recordingState",
            std::make_unique<EncodableValue>(args));
      });
}

VideoDecoderPlugin::~VideoDecoderPlugin() {
  recorder_->Cancel();
  CleanupDecoder();
  if (media_foundation_started_) {
    MFShutdown();
  }
}

void VideoDecoderPlugin::CleanupDecoder() {
  latest_h264_keyframe_.clear();
  codec_ = -1;
  if (decoder_) {
    decoder_->Teardown();
    decoder_.reset();
  }
  d3d11_decoder_ = nullptr;
  decoder_type_.clear();

  if (cpu_texture_id_ >= 0) {
    texture_registrar_->UnregisterTexture(cpu_texture_id_);
    cpu_texture_id_ = -1;
    cpu_texture_variant_.reset();
  }
}

void VideoDecoderPlugin::HandleMethodCall(
    const flutter::MethodCall<EncodableValue>& call,
    std::unique_ptr<flutter::MethodResult<EncodableValue>> result) {
  const auto& method = call.method_name();

  if (method == "init") {
    if (!call.arguments() || !std::holds_alternative<EncodableMap>(*call.arguments())) {
      result->Error("ARG", "missing args");
      return;
    }
    const auto& args = std::get<EncodableMap>(*call.arguments());

    int codec = 0;
    auto it = args.find(EncodableValue("codec"));
    if (it != args.end() && std::holds_alternative<int>(it->second)) {
      codec = std::get<int>(it->second);
    }

    CleanupDecoder();
    codec_ = codec;

    if (codec == 0) {
      if (!media_foundation_started_) {
        result->Error("INIT", "Media Foundation 启动失败");
        return;
      }
      // H264：优先 D3D11 硬解，失败回落 CPU 软解
      auto d3d11 = std::make_unique<H264D3D11Decoder>();
      d3d11->SetTextureRegistrar(texture_registrar_);
      std::string err;
      if (d3d11->Init(args, &err)) {
        d3d11_decoder_ = d3d11.get();
        decoder_ = std::move(d3d11);
        decoder_type_ = "d3d11";

        // D3D11 路径：纹理由 H264D3D11Decoder 自行管理（GpuSurfaceTexture）
        // 但首帧前 texture_id 可能还未就绪（需要等 EnsureOutputTexture）
        // 设置帧回调以在纹理就绪后通知 Dart
        decoder_->SetFrameCallback([this](DecodedFrame frame) {
          // D3D11 路径：frame.bgra 为空，仅携带尺寸信息
        });

        // 返回 map：{ "textureId": -1, "decoderType": "d3d11" }
        // textureId 先返回 -1，后续通过 getTextureId 获取
        EncodableMap reply;
        reply[EncodableValue("textureId")] = EncodableValue(d3d11_decoder_->texture_id());
        reply[EncodableValue("decoderType")] = EncodableValue("d3d11");
        result->Success(EncodableValue(reply));
        return;
      }

      // D3D11 失败，回落 CPU 软解
      auto cpu = std::make_unique<H264Decoder>();
      std::string cpu_err;
      if (!cpu->Init(args, &cpu_err)) {
        result->Error("INIT", "D3D11: " + err + "; CPU: " + cpu_err);
        return;
      }
      cpu->SetFrameCallback([this](DecodedFrame frame) { OnFrame(std::move(frame)); });
      cpu->SetBackpressureCallback([this](bool paused) {
        auto args = flutter::EncodableMap{
            {flutter::EncodableValue("source"), flutter::EncodableValue("decoder")},
            {flutter::EncodableValue("paused"), flutter::EncodableValue(paused)}
        };
        channel_->InvokeMethod("encoderState",
            std::make_unique<flutter::EncodableValue>(args));
      });
      decoder_ = std::move(cpu);
      decoder_type_ = "cpu";

      cpu_texture_variant_ = std::make_unique<flutter::TextureVariant>(
          flutter::PixelBufferTexture([this](size_t w, size_t h) -> const FlutterDesktopPixelBuffer* {
            return CopyPixelBuffer(w, h);
          }));
      cpu_texture_id_ = texture_registrar_->RegisterTexture(cpu_texture_variant_.get());

      EncodableMap reply;
      reply[EncodableValue("textureId")] = EncodableValue(cpu_texture_id_);
      reply[EncodableValue("decoderType")] = EncodableValue("cpu");
      result->Success(EncodableValue(reply));
      return;

    } else {
      // 非 H264 编解码器（JPEG / RAW）
      std::unique_ptr<IDecoder> dec;
      if (codec == 1) {
        dec = std::make_unique<RawDecoder>();
      } else if (codec == 2) {
        dec = std::make_unique<JpegDecoder>();
      } else {
        result->Error("ARG", "unknown codec");
        return;
      }

      std::string err;
      if (!dec->Init(args, &err)) {
        result->Error("INIT", err);
        return;
      }

      dec->SetFrameCallback([this](DecodedFrame frame) { OnFrame(std::move(frame)); });
      decoder_ = std::move(dec);
      decoder_type_ = "cpu";

      cpu_texture_variant_ = std::make_unique<flutter::TextureVariant>(
          flutter::PixelBufferTexture([this](size_t w, size_t h) -> const FlutterDesktopPixelBuffer* {
            return CopyPixelBuffer(w, h);
          }));
      cpu_texture_id_ = texture_registrar_->RegisterTexture(cpu_texture_variant_.get());

      EncodableMap reply;
      reply[EncodableValue("textureId")] = EncodableValue(cpu_texture_id_);
      reply[EncodableValue("decoderType")] = EncodableValue("cpu");
      result->Success(EncodableValue(reply));
      return;
    }

  } else if (method == "feed") {
    if (!decoder_) {
      result->Success();
      return;
    }
    if (!call.arguments() || !std::holds_alternative<EncodableMap>(*call.arguments())) {
      result->Success();
      return;
    }
    const auto& args = std::get<EncodableMap>(*call.arguments());

    std::vector<uint8_t> nal;
    auto it = args.find(EncodableValue("nal"));
    if (it != args.end() && std::holds_alternative<std::vector<uint8_t>>(it->second)) {
      nal = std::get<std::vector<uint8_t>>(it->second);
    }

    bool keyframe = false;
    auto it2 = args.find(EncodableValue("keyframe"));
    if (it2 != args.end() && std::holds_alternative<bool>(it2->second)) {
      keyframe = std::get<bool>(it2->second);
    }

    int64_t pts_us = 0;
    auto it3 = args.find(EncodableValue("pts"));
    if (it3 != args.end()) {
      if (std::holds_alternative<int64_t>(it3->second)) {
        pts_us = std::get<int64_t>(it3->second);
      } else if (std::holds_alternative<int>(it3->second)) {
        pts_us = std::get<int>(it3->second);
      }
    }

    if (!nal.empty()) {
      if (codec_ == 0 && keyframe) {
        latest_h264_keyframe_ = nal;
      }
      recorder_->Feed(nal, keyframe, pts_us);
      decoder_->Feed(std::move(nal), keyframe, pts_us);
    }
    result->Success();

  } else if (method == "startRecording") {
    if (!call.arguments() ||
        !std::holds_alternative<EncodableMap>(*call.arguments())) {
      MediaOperationResult response;
      response.error = "缺少录制参数";
      result->Success(EncodeMediaResult(response));
      return;
    }
    MediaOperationResult response =
        recorder_->Start(std::get<EncodableMap>(*call.arguments()));
    if (response.ok && !latest_h264_keyframe_.empty()) {
      // 静止画面可能不会产生新输入帧，复用当前视频配置下缓存的 IDR
      // 立即启动录制；录制时间戳仍由本地单调时钟生成。
      recorder_->Feed(latest_h264_keyframe_, true, 0);
    }
    result->Success(EncodeMediaResult(response));

  } else if (method == "stopRecording") {
    result->Success(EncodeMediaResult(recorder_->Stop()));

  } else if (method == "cancelRecording") {
    recorder_->Cancel();
    MediaOperationResult response;
    response.ok = true;
    result->Success(EncodeMediaResult(response));

  } else if (method == "capturePng") {
    result->Success(EncodeMediaResult(CapturePng()));

  } else if (method == "revealInFileManager") {
    if (!call.arguments() ||
        !std::holds_alternative<EncodableMap>(*call.arguments())) {
      MediaOperationResult response;
      response.error = "保存路径为空";
      result->Success(EncodeMediaResult(response));
      return;
    }
    const auto& args = std::get<EncodableMap>(*call.arguments());
    const auto path_it = args.find(EncodableValue("path"));
    if (path_it == args.end() ||
        !std::holds_alternative<std::string>(path_it->second)) {
      MediaOperationResult response;
      response.error = "保存路径为空";
      result->Success(EncodeMediaResult(response));
      return;
    }
    result->Success(EncodeMediaResult(
        RevealInFileManager(std::get<std::string>(path_it->second))));

  } else if (method == "getTextureId") {
    // D3D11 路径：纹理 ID 在首帧解码后才确定
    if (d3d11_decoder_) {
      result->Success(EncodableValue(d3d11_decoder_->texture_id()));
    } else {
      result->Success(EncodableValue(cpu_texture_id_));
    }

  } else if (method == "dispose") {
    recorder_->Cancel();
    CleanupDecoder();
    result->Success();

  } else {
    result->NotImplemented();
  }
}

MediaOperationResult VideoDecoderPlugin::CapturePng() {
  if (d3d11_decoder_) {
    std::vector<uint8_t> bgra;
    int width = 0;
    int height = 0;
    std::string error;
    if (!d3d11_decoder_->CopyLatestBgra(
            &bgra, &width, &height, &error)) {
      MediaOperationResult response;
      response.error = error;
      return response;
    }
    return SaveBgraFrameAsPng(bgra, width, height);
  }

  DecodedFrame frame;
  {
    std::lock_guard<std::mutex> lock(pending_mu_);
    if (has_pending_) {
      frame = pending_;
    } else {
      frame = display_;
    }
  }
  return SaveRgbaFrameAsPng(frame.bgra, frame.w, frame.h);
}

void VideoDecoderPlugin::OnFrame(DecodedFrame frame) {
  if (frame.w <= 0 || frame.h <= 0 || frame.bgra.empty()) {
    return;
  }

  {
    std::lock_guard<std::mutex> lk(pending_mu_);
    pending_ = std::move(frame);
    has_pending_ = true;
  }

  if (cpu_texture_id_ >= 0) {
    texture_registrar_->MarkTextureFrameAvailable(cpu_texture_id_);
  }
}

const FlutterDesktopPixelBuffer* VideoDecoderPlugin::CopyPixelBuffer(size_t /*w*/, size_t /*h*/) {
  {
    std::lock_guard<std::mutex> lk(pending_mu_);
    if (has_pending_) {
      std::swap(display_, pending_);
      has_pending_ = false;
      display_pb_.buffer = display_.bgra.data();
      display_pb_.width = static_cast<size_t>(display_.w);
      display_pb_.height = static_cast<size_t>(display_.h);
    }
  }
  if (display_.bgra.empty()) return nullptr;
  return &display_pb_;
}
