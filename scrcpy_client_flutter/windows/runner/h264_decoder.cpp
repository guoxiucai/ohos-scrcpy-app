#include "h264_decoder.h"

#include <codecapi.h>
#include <mfidl.h>
#include <mfreadwrite.h>
#include <strmif.h>

// {62CE7E72-4C71-4d20-B15D-452831A87D9D}
static constexpr GUID kCLSID_MSH264DecoderMFT = {
    0x62CE7E72, 0x4C71, 0x4d20,
    {0xB1, 0x5D, 0x45, 0x28, 0x31, 0xA8, 0x7D, 0x9D}};

using flutter::EncodableMap;
using flutter::EncodableValue;

// 辅助：从 EncodableValue 拿 std::vector<uint8_t>（FlutterStandardTypedData 已解码为 vector）
static std::vector<uint8_t> GetBytes(const EncodableMap& args, const char* key) {
  auto it = args.find(EncodableValue(key));
  if (it != args.end() && std::holds_alternative<std::vector<uint8_t>>(it->second))
    return std::get<std::vector<uint8_t>>(it->second);
  return {};
}

static int GetInt(const EncodableMap& args, const char* key, int fallback = 0) {
  auto it = args.find(EncodableValue(key));
  if (it != args.end() && std::holds_alternative<int>(it->second))
    return std::get<int>(it->second);
  return fallback;
}

bool H264Decoder::Init(const EncodableMap& args, std::string* err) {
  width_ = GetInt(args, "width");
  height_ = GetInt(args, "height");

  // 构造 Annex-B SPS/PPS 缓存：00 00 00 01 + bytes
  auto sps_raw = GetBytes(args, "sps");
  auto pps_raw = GetBytes(args, "pps");
  if (!sps_raw.empty()) {
    sps_nal_ = {0, 0, 0, 1};
    sps_nal_.insert(sps_nal_.end(), sps_raw.begin(), sps_raw.end());
  }
  if (!pps_raw.empty()) {
    pps_nal_ = {0, 0, 0, 1};
    pps_nal_.insert(pps_nal_.end(), pps_raw.begin(), pps_raw.end());
  }
  sps_pps_injected_ = false;

  if (!SetupMFT(err)) {
    return false;
  }

  stop_ = false;
  worker_ = std::thread([this] { WorkerLoop(); });
  return true;
}

void H264Decoder::Feed(std::vector<uint8_t> data, bool keyframe, int64_t pts_ms) {
  bool should_pause = false, should_resume = false;
  {
    std::lock_guard<std::mutex> lk(mu_);
    if (queue_.size() < kQueueMax) {
      queue_.push_back({std::move(data), keyframe, pts_ms});
    } else {
      // 队列满：丢弃此帧并标记（WorkerLoop 将跳过 P 帧直到下一关键帧）
      has_dropped_.store(true, std::memory_order_relaxed);
    }
    // 高水位：通知服务端暂停编码
    if (!encoder_paused_ && queue_.size() >= kHighWaterMark) {
      encoder_paused_ = true;
      should_pause = true;
    }
    // 低水位：通知服务端恢复编码
    if (encoder_paused_ && queue_.size() <= kLowWaterMark) {
      encoder_paused_ = false;
      should_resume = true;
    }
  }
  cv_.notify_one();
  // 回调在锁外触发，调用线程为 platform thread，可安全调用 Dart MethodChannel
  if (should_pause && on_backpressure_) on_backpressure_(true);
  if (should_resume && on_backpressure_) on_backpressure_(false);
}

void H264Decoder::Teardown() {
  {
    std::lock_guard<std::mutex> lk(mu_);
    stop_ = true;
  }
  cv_.notify_all();
  if (worker_.joinable()) worker_.join();
  mft_.Reset();
}

bool H264Decoder::SetupMFT(std::string* err) {
  CoInitializeEx(nullptr, COINIT_MULTITHREADED);

  HRESULT hr = CoCreateInstance(kCLSID_MSH264DecoderMFT, nullptr,
                                CLSCTX_INPROC_SERVER, IID_PPV_ARGS(&mft_));
  if (FAILED(hr)) {
    *err = "CoCreateInstance H264 MFT failed: " + std::to_string(hr);
    return false;
  }

  // 输入类型：H264
  Microsoft::WRL::ComPtr<IMFMediaType> in_type;
  MFCreateMediaType(&in_type);
  in_type->SetGUID(MF_MT_MAJOR_TYPE, MFMediaType_Video);
  in_type->SetGUID(MF_MT_SUBTYPE, MFVideoFormat_H264);
  if (width_ > 0 && height_ > 0) {
    MFSetAttributeSize(in_type.Get(), MF_MT_FRAME_SIZE, width_, height_);
  }
  in_type->SetUINT32(MF_MT_INTERLACE_MODE, MFVideoInterlace_Progressive);

  // 可选：把 SPS/PPS 塞进 MF_MT_USER_DATA
  if (!sps_nal_.empty() && !pps_nal_.empty()) {
    std::vector<uint8_t> user_data;
    user_data.insert(user_data.end(), sps_nal_.begin(), sps_nal_.end());
    user_data.insert(user_data.end(), pps_nal_.begin(), pps_nal_.end());
    in_type->SetBlob(MF_MT_USER_DATA, user_data.data(),
                     static_cast<UINT32>(user_data.size()));
  }

  hr = mft_->SetInputType(0, in_type.Get(), 0);
  if (FAILED(hr)) {
    *err = "SetInputType failed: " + std::to_string(hr);
    return false;
  }

  // 枚举输出类型，找 NV12
  bool found_nv12 = false;
  for (DWORD i = 0; ; ++i) {
    Microsoft::WRL::ComPtr<IMFMediaType> out_type;
    hr = mft_->GetOutputAvailableType(0, i, &out_type);
    if (hr == MF_E_NO_MORE_TYPES || FAILED(hr)) break;
    GUID subtype = GUID_NULL;
    out_type->GetGUID(MF_MT_SUBTYPE, &subtype);
    if (subtype == MFVideoFormat_NV12) {
      hr = mft_->SetOutputType(0, out_type.Get(), 0);
      if (SUCCEEDED(hr)) { found_nv12 = true; break; }
    }
  }
  if (!found_nv12) {
    *err = "NV12 output type not found";
    return false;
  }

  // 低延迟模式：MFT 收到 1 帧就立即输出，不缓冲参考帧
  ICodecAPI* codecApi = nullptr;
  if (SUCCEEDED(mft_->QueryInterface(IID_PPV_ARGS(&codecApi)))) {
    VARIANT var;
    VariantInit(&var);
    var.vt = VT_BOOL;
    var.boolVal = VARIANT_TRUE;
    HRESULT hr2 = codecApi->SetValue(&CODECAPI_AVLowLatencyMode, &var);
    (void)hr2;
    codecApi->Release();
  } else {
  }

  // 备选：通过 IMFAttributes 设 MF_LOW_LATENCY
  Microsoft::WRL::ComPtr<IMFAttributes> attrs;
  if (SUCCEEDED(mft_->GetAttributes(&attrs))) {
    HRESULT hr3 = attrs->SetUINT32(MF_LOW_LATENCY, TRUE);
    (void)hr3;
  } else {
  }

  mft_->ProcessMessage(MFT_MESSAGE_NOTIFY_BEGIN_STREAMING, 0);
  mft_->ProcessMessage(MFT_MESSAGE_NOTIFY_START_OF_STREAM, 0);
  return true;
}

void H264Decoder::WorkerLoop() {
  CoInitializeEx(nullptr, COINIT_MULTITHREADED);

  while (true) {
    Task task;
    {
      std::unique_lock<std::mutex> lk(mu_);
      cv_.wait(lk, [this] { return stop_ || !queue_.empty(); });
      if (stop_ && queue_.empty()) break;
      task = std::move(queue_.front());
      queue_.pop_front();
    }

    // 队列满时丢过帧：跳过 P 帧直到下一个关键帧，避免解码花屏
    if (has_dropped_.load(std::memory_order_relaxed)) {
      if (!task.keyframe) continue;
      has_dropped_.store(false, std::memory_order_relaxed);
    }

    // 首个关键帧前注入 SPS/PPS
    std::vector<uint8_t> payload;
    if (task.keyframe && !sps_pps_injected_ &&
        !sps_nal_.empty() && !pps_nal_.empty()) {
      payload.insert(payload.end(), sps_nal_.begin(), sps_nal_.end());
      payload.insert(payload.end(), pps_nal_.begin(), pps_nal_.end());
      sps_pps_injected_ = true;
    }
    payload.insert(payload.end(), task.data.begin(), task.data.end());

    // 打包成 IMFSample
    Microsoft::WRL::ComPtr<IMFMediaBuffer> buf;
    MFCreateMemoryBuffer(static_cast<DWORD>(payload.size()), &buf);
    {
      BYTE* dst = nullptr; DWORD max_len = 0, cur_len = 0;
      buf->Lock(&dst, &max_len, &cur_len);
      memcpy(dst, payload.data(), payload.size());
      buf->Unlock();
      buf->SetCurrentLength(static_cast<DWORD>(payload.size()));
    }
    Microsoft::WRL::ComPtr<IMFSample> sample;
    MFCreateSample(&sample);
    sample->AddBuffer(buf.Get());
    sample->SetSampleTime(task.pts_ms * 10000LL);  // ms → 100ns

    HRESULT hr = mft_->ProcessInput(0, sample.Get(), 0);
    if (FAILED(hr)) {
      continue;
    }

    // 循环取输出
    while (true) {
      MFT_OUTPUT_STREAM_INFO stream_info{};
      mft_->GetOutputStreamInfo(0, &stream_info);

      Microsoft::WRL::ComPtr<IMFMediaBuffer> out_buf;
      Microsoft::WRL::ComPtr<IMFSample> out_sample;
      bool alloc_by_mft = (stream_info.dwFlags & MFT_OUTPUT_STREAM_PROVIDES_SAMPLES) != 0;

      if (!alloc_by_mft) {
        MFCreateMemoryBuffer(stream_info.cbSize, &out_buf);
        MFCreateSample(&out_sample);
        out_sample->AddBuffer(out_buf.Get());
      }

      MFT_OUTPUT_DATA_BUFFER out_data{};
      out_data.dwStreamID = 0;
      out_data.pSample = alloc_by_mft ? nullptr : out_sample.Get();
      DWORD status = 0;
      hr = mft_->ProcessOutput(0, 1, &out_data, &status);

      if (hr == MF_E_TRANSFORM_NEED_MORE_INPUT) break;
      if (hr == MF_E_TRANSFORM_STREAM_CHANGE) {
        // 重新协商输出类型
        for (DWORD i = 0; ; ++i) {
          Microsoft::WRL::ComPtr<IMFMediaType> new_type;
          HRESULT hr2 = mft_->GetOutputAvailableType(0, i, &new_type);
          if (hr2 == MF_E_NO_MORE_TYPES || FAILED(hr2)) break;
          GUID sub = GUID_NULL;
          new_type->GetGUID(MF_MT_SUBTYPE, &sub);
          if (sub == MFVideoFormat_NV12) {
            mft_->SetOutputType(0, new_type.Get(), 0);
            break;
          }
        }
        continue;
      }
      if (FAILED(hr)) {
        break;
      }

      IMFSample* result_sample = alloc_by_mft ? out_data.pSample : out_sample.Get();
      if (!result_sample) { if (alloc_by_mft && out_data.pSample) out_data.pSample->Release(); break; }

      // 拿输出尺寸（可能被 MFT 对齐到 16 像素，如 1080→1088）
      Microsoft::WRL::ComPtr<IMFMediaType> cur_out;
      mft_->GetOutputCurrentType(0, &cur_out);
      UINT32 out_w = width_, out_h = height_;
      MFGetAttributeSize(cur_out.Get(), MF_MT_FRAME_SIZE, &out_w, &out_h);

      // 可见区域使用原始请求尺寸，避免对齐填充区的绿边
      int visible_w = width_ > 0 ? width_ : static_cast<int>(out_w);
      int visible_h = height_ > 0 ? height_ : static_cast<int>(out_h);
      if (visible_w > static_cast<int>(out_w)) visible_w = static_cast<int>(out_w);
      if (visible_h > static_cast<int>(out_h)) visible_h = static_cast<int>(out_h);

      // 用 IMF2DBuffer 拿真实 pitch
      Microsoft::WRL::ComPtr<IMFMediaBuffer> contig;
      result_sample->ConvertToContiguousBuffer(&contig);

      int stride_y = out_w;

      Microsoft::WRL::ComPtr<IMF2DBuffer> buf2d;
      if (SUCCEEDED(contig.As(&buf2d))) {
        BYTE* scan0 = nullptr; LONG pitch = 0;
        if (SUCCEEDED(buf2d->Lock2D(&scan0, &pitch))) {
          stride_y = static_cast<int>(pitch < 0 ? -pitch : pitch);

          DecodedFrame frame;
          frame.w = visible_w;
          frame.h = visible_h;
          Nv12ToBgra(scan0, stride_y, stride_y,
                     visible_w, visible_h, static_cast<int>(out_h), frame.bgra);
          buf2d->Unlock2D();
          if (on_frame_) {
            on_frame_(std::move(frame));
          }
        }
      } else {
        // fallback：ConvertToContiguousBuffer 拿平坦 NV12
        BYTE* raw = nullptr; DWORD raw_len = 0, max_l = 0;
        contig->Lock(&raw, &max_l, &raw_len);
        if (raw && raw_len >= out_w * out_h * 3 / 2) {
          DecodedFrame frame;
          frame.w = visible_w;
          frame.h = visible_h;
          Nv12ToBgra(raw, out_w, out_w,
                     visible_w, visible_h, static_cast<int>(out_h), frame.bgra);
          if (on_frame_) on_frame_(std::move(frame));
        }
        contig->Unlock();
      }

      if (alloc_by_mft && out_data.pSample) out_data.pSample->Release();
    }
  }

  mft_->ProcessMessage(MFT_MESSAGE_COMMAND_FLUSH, 0);
  mft_->ProcessMessage(MFT_MESSAGE_NOTIFY_END_OF_STREAM, 0);
  mft_.Reset();
  CoUninitialize();
}

// NV12 → BGRA（纯 CPU，BT.601 有限范围）
void H264Decoder::Nv12ToBgra(const uint8_t* nv12, int stride_y, int stride_uv,
                               int width, int height,
                               int alloc_height,
                               std::vector<uint8_t>& bgra) {
  bgra.resize(width * height * 4);
  uint8_t* dst = bgra.data();
  const uint8_t* y_plane = nv12;
  const uint8_t* uv_plane = nv12 + stride_y * alloc_height;

  for (int row = 0; row < height; ++row) {
    const uint8_t* y_row = y_plane + row * stride_y;
    const uint8_t* uv_row = uv_plane + (row / 2) * stride_uv;
    uint8_t* dst_row = dst + row * width * 4;

    for (int col = 0; col < width; ++col) {
      int Y = static_cast<int>(y_row[col]) - 16;
      int U = static_cast<int>(uv_row[(col & ~1)]) - 128;
      int V = static_cast<int>(uv_row[(col & ~1) + 1]) - 128;

      // BT.601 有限范围转换（*256 定点化）
      int c = Y * 298;
      int r = (c + 409 * V + 128) >> 8;
      int g = (c - 100 * U - 208 * V + 128) >> 8;
      int b = (c + 516 * U + 128) >> 8;

      auto clamp = [](int v) -> uint8_t {
        return v < 0 ? 0 : v > 255 ? 255 : static_cast<uint8_t>(v);
      };
      dst_row[col * 4 + 0] = clamp(r);
      dst_row[col * 4 + 1] = clamp(g);
      dst_row[col * 4 + 2] = clamp(b);
      dst_row[col * 4 + 3] = 255;
    }
  }
}
