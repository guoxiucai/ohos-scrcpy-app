#include "h264_d3d11_decoder.h"

#include <cassert>
#include <codecvt>
#include <locale>

#pragma comment(lib, "d3d11.lib")
#pragma comment(lib, "dxgi.lib")
#pragma comment(lib, "mf.lib")
#pragma comment(lib, "mfplat.lib")
#pragma comment(lib, "mfuuid.lib")
#pragma comment(lib, "shlwapi.lib")

using flutter::EncodableMap;
using flutter::EncodableValue;

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

bool H264D3D11Decoder::Init(const EncodableMap& args, std::string* err) {
  width_ = GetInt(args, "width");
  height_ = GetInt(args, "height");
  OutputDebugStringA("[D3D11] Init start\n");

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

  if (!SetupD3D11(err)) {
    return false;
  }
  if (!SetupHardwareMFT(err)) {
    return false;
  }

  stop_ = false;
  worker_ = std::thread([this] { WorkerLoop(); });
  return true;
}

void H264D3D11Decoder::Feed(std::vector<uint8_t> data, bool keyframe, int64_t pts_ms) {
  {
    std::lock_guard<std::mutex> lk(mu_);
    while (queue_.size() >= 5) {
      if (!queue_.front().keyframe) queue_.pop_front();
      else break;
    }
    queue_.push_back({std::move(data), keyframe, pts_ms});
  }
  cv_.notify_one();
}

void H264D3D11Decoder::Teardown() {
  {
    std::lock_guard<std::mutex> lk(mu_);
    stop_ = true;
  }
  cv_.notify_all();
  if (worker_.joinable()) worker_.join();

  if (texture_id_ >= 0 && texture_registrar_) {
    texture_registrar_->UnregisterTexture(texture_id_);
    texture_id_ = -1;
  }
  texture_variant_.reset();

  video_proc_.Reset();
  vp_enum_.Reset();
  video_context_.Reset();
  video_device_.Reset();
  output_tex_.Reset();

  if (mft_) {
    mft_->ProcessMessage(MFT_MESSAGE_COMMAND_FLUSH, 0);
    mft_->ProcessMessage(MFT_MESSAGE_NOTIFY_END_OF_STREAM, 0);
    mft_.Reset();
  }
  dxgi_manager_.Reset();
  d3d_context_.Reset();
  d3d_device_.Reset();
  shared_handle_ = nullptr;
}

bool H264D3D11Decoder::SetupD3D11(std::string* err) {
  D3D_FEATURE_LEVEL featureLevels[] = {D3D_FEATURE_LEVEL_11_0};
  D3D_FEATURE_LEVEL actualLevel;
  UINT flags = D3D11_CREATE_DEVICE_VIDEO_SUPPORT | D3D11_CREATE_DEVICE_BGRA_SUPPORT;

  HRESULT hr = D3D11CreateDevice(
      nullptr, D3D_DRIVER_TYPE_HARDWARE, nullptr, flags,
      featureLevels, 1, D3D11_SDK_VERSION,
      &d3d_device_, &actualLevel, &d3d_context_);
  if (FAILED(hr)) {
    *err = "D3D11CreateDevice failed: " + std::to_string(hr);
    return false;
  }

  // 允许多线程访问
  ComPtr<ID3D10Multithread> mt;
  if (SUCCEEDED(d3d_device_.As(&mt))) {
    mt->SetMultithreadProtected(TRUE);
  }

  hr = MFCreateDXGIDeviceManager(&dxgi_reset_token_, &dxgi_manager_);
  if (FAILED(hr)) {
    *err = "MFCreateDXGIDeviceManager failed: " + std::to_string(hr);
    return false;
  }

  hr = dxgi_manager_->ResetDevice(d3d_device_.Get(), dxgi_reset_token_);
  if (FAILED(hr)) {
    *err = "DXGIDeviceManager::ResetDevice failed: " + std::to_string(hr);
    return false;
  }

  return true;
}

bool H264D3D11Decoder::SetupHardwareMFT(std::string* err) {
  MFT_REGISTER_TYPE_INFO inputType = {MFMediaType_Video, MFVideoFormat_H264};
  IMFActivate** ppActivate = nullptr;
  UINT32 count = 0;

  // 优先枚举硬件 MFT（NVIDIA/Intel 专用解码器）
  HRESULT hr = MFTEnumEx(
      MFT_CATEGORY_VIDEO_DECODER,
      MFT_ENUM_FLAG_HARDWARE | MFT_ENUM_FLAG_SORTANDFILTER,
      &inputType, nullptr, &ppActivate, &count);

  if (SUCCEEDED(hr) && count > 0) {
    hr = ppActivate[0]->ActivateObject(IID_PPV_ARGS(&mft_));
    for (UINT32 i = 0; i < count; ++i) ppActivate[i]->Release();
    CoTaskMemFree(ppActivate);
    if (FAILED(hr)) {
      *err = "ActivateObject for hardware MFT failed: " + std::to_string(hr);
      return false;
    }
  } else {
    if (ppActivate) CoTaskMemFree(ppActivate);
    *err = "No hardware H264 MFT found";
    return false;
  }

  // 将 DXGIDeviceManager 传给 MFT — 对硬件 MFT 是必须的，对软件 MFT 会启用 DXVA
  hr = mft_->ProcessMessage(MFT_MESSAGE_SET_D3D_MANAGER,
      reinterpret_cast<ULONG_PTR>(dxgi_manager_.Get()));
  if (FAILED(hr)) {
    // 软件 MFT 可能不支持 D3D Manager — 这种情况 D3D11 路径无意义，回落 CPU
    *err = "SET_D3D_MANAGER failed: " + std::to_string(hr);
    return false;
  }

  // 设置输入类型：H264
  ComPtr<IMFMediaType> in_type;
  MFCreateMediaType(&in_type);
  in_type->SetGUID(MF_MT_MAJOR_TYPE, MFMediaType_Video);
  in_type->SetGUID(MF_MT_SUBTYPE, MFVideoFormat_H264);
  if (width_ > 0 && height_ > 0) {
    MFSetAttributeSize(in_type.Get(), MF_MT_FRAME_SIZE, width_, height_);
  }
  in_type->SetUINT32(MF_MT_INTERLACE_MODE, MFVideoInterlace_Progressive);

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
    ComPtr<IMFMediaType> out_type;
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
    *err = "NV12 output type not found on hardware MFT";
    return false;
  }

  mft_->ProcessMessage(MFT_MESSAGE_NOTIFY_BEGIN_STREAMING, 0);
  mft_->ProcessMessage(MFT_MESSAGE_NOTIFY_START_OF_STREAM, 0);
  return true;
}

bool H264D3D11Decoder::SetupVideoProcessor() {
  HRESULT hr = d3d_device_.As(&video_device_);
  if (FAILED(hr)) return false;

  hr = d3d_context_.As(&video_context_);
  if (FAILED(hr)) return false;

  D3D11_VIDEO_PROCESSOR_CONTENT_DESC vpDesc = {};
  vpDesc.InputFrameFormat = D3D11_VIDEO_FRAME_FORMAT_PROGRESSIVE;
  vpDesc.InputWidth = out_width_;
  vpDesc.InputHeight = out_height_;
  vpDesc.OutputWidth = out_width_;
  vpDesc.OutputHeight = out_height_;
  vpDesc.Usage = D3D11_VIDEO_USAGE_PLAYBACK_NORMAL;

  hr = video_device_->CreateVideoProcessorEnumerator(&vpDesc, &vp_enum_);
  if (FAILED(hr)) return false;

  hr = video_device_->CreateVideoProcessor(vp_enum_.Get(), 0, &video_proc_);
  if (FAILED(hr)) return false;

  return true;
}

bool H264D3D11Decoder::EnsureOutputTexture(UINT width, UINT height) {
  if (output_tex_ && out_width_ == width && out_height_ == height)
    return true;

  output_tex_.Reset();
  shared_handle_ = nullptr;
  video_proc_.Reset();
  vp_enum_.Reset();

  out_width_ = width;
  out_height_ = height;

  D3D11_TEXTURE2D_DESC desc = {};
  desc.Width = width;
  desc.Height = height;
  desc.MipLevels = 1;
  desc.ArraySize = 1;
  desc.Format = DXGI_FORMAT_B8G8R8A8_UNORM;
  desc.SampleDesc.Count = 1;
  desc.Usage = D3D11_USAGE_DEFAULT;
  desc.BindFlags = D3D11_BIND_RENDER_TARGET | D3D11_BIND_SHADER_RESOURCE;
  desc.MiscFlags = D3D11_RESOURCE_MISC_SHARED;

  HRESULT hr = d3d_device_->CreateTexture2D(&desc, nullptr, &output_tex_);
  if (FAILED(hr)) return false;

  ComPtr<IDXGIResource> dxgiRes;
  hr = output_tex_.As(&dxgiRes);
  if (FAILED(hr)) return false;

  hr = dxgiRes->GetSharedHandle(&shared_handle_);
  if (FAILED(hr)) return false;

  if (!SetupVideoProcessor()) return false;

  // 注册 GpuSurfaceTexture
  if (texture_registrar_) {
    if (texture_id_ >= 0) {
      texture_registrar_->UnregisterTexture(texture_id_);
      texture_id_ = -1;
    }
    texture_variant_ = std::make_unique<flutter::TextureVariant>(
        flutter::GpuSurfaceTexture(
            kFlutterDesktopGpuSurfaceTypeDxgiSharedHandle,
            [this](size_t w, size_t h) { return ObtainDescriptor(w, h); }));
    texture_id_ = texture_registrar_->RegisterTexture(texture_variant_.get());
  }

  return true;
}

const FlutterDesktopGpuSurfaceDescriptor* H264D3D11Decoder::ObtainDescriptor(
    size_t /*w*/, size_t /*h*/) {
  std::lock_guard<std::mutex> lk(desc_mu_);
  return &descriptor_;
}

void H264D3D11Decoder::WorkerLoop() {
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
    ComPtr<IMFMediaBuffer> buf;
    MFCreateMemoryBuffer(static_cast<DWORD>(payload.size()), &buf);
    {
      BYTE* dst = nullptr;
      DWORD max_len = 0, cur_len = 0;
      buf->Lock(&dst, &max_len, &cur_len);
      memcpy(dst, payload.data(), payload.size());
      buf->Unlock();
      buf->SetCurrentLength(static_cast<DWORD>(payload.size()));
    }
    ComPtr<IMFSample> sample;
    MFCreateSample(&sample);
    sample->AddBuffer(buf.Get());
    sample->SetSampleTime(task.pts_ms * 10000LL);

    HRESULT hr = mft_->ProcessInput(0, sample.Get(), 0);
    if (FAILED(hr)) {
      continue;
    }

    // 循环取输出
    while (true) {
      MFT_OUTPUT_STREAM_INFO stream_info{};
      mft_->GetOutputStreamInfo(0, &stream_info);

      MFT_OUTPUT_DATA_BUFFER out_data{};
      out_data.dwStreamID = 0;
      out_data.pSample = nullptr;
      DWORD status = 0;

      hr = mft_->ProcessOutput(0, 1, &out_data, &status);
      if (hr == MF_E_TRANSFORM_NEED_MORE_INPUT) break;

      if (hr == MF_E_TRANSFORM_STREAM_CHANGE ||
          hr == static_cast<HRESULT>(0xC00D6D72) /* MF_E_TRANSFORM_TYPE_NOT_SET */) {
        // 输出格式变更 — 重新协商
        for (DWORD i = 0; ; ++i) {
          ComPtr<IMFMediaType> new_type;
          hr = mft_->GetOutputAvailableType(0, i, &new_type);
          if (FAILED(hr)) break;
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

      IMFSample* result_sample = out_data.pSample;
      if (!result_sample) {
        break;
      }

      // 从输出 sample 取 D3D11 Texture
      ComPtr<IMFMediaBuffer> out_buf;
      result_sample->GetBufferByIndex(0, &out_buf);

      ComPtr<IMFDXGIBuffer> dxgiBuf;
      hr = out_buf.As(&dxgiBuf);
      if (FAILED(hr)) {
        result_sample->Release();
        break;
      }

      ComPtr<ID3D11Texture2D> decoded_tex;
      hr = dxgiBuf->GetResource(IID_PPV_ARGS(&decoded_tex));
      UINT sub_idx = 0;
      dxgiBuf->GetSubresourceIndex(&sub_idx);

      if (FAILED(hr) || !decoded_tex) {
        result_sample->Release();
        break;
      }

      // 获取实际尺寸
      D3D11_TEXTURE2D_DESC tex_desc;
      decoded_tex->GetDesc(&tex_desc);

      // 从当前输出类型获取实际分辨率
      ComPtr<IMFMediaType> cur_out;
      mft_->GetOutputCurrentType(0, &cur_out);
      UINT32 actual_w = tex_desc.Width, actual_h = tex_desc.Height;
      if (cur_out) {
        MFGetAttributeSize(cur_out.Get(), MF_MT_FRAME_SIZE, &actual_w, &actual_h);
      }

      // 确保输出纹理和 VideoProcessor 就绪
      if (!EnsureOutputTexture(actual_w, actual_h)) {
        result_sample->Release();
        break;
      }

      // VideoProcessorBlt: NV12 → BGRA
      D3D11_VIDEO_PROCESSOR_INPUT_VIEW_DESC ivDesc = {};
      ivDesc.FourCC = 0;
      ivDesc.ViewDimension = D3D11_VPIV_DIMENSION_TEXTURE2D;
      ivDesc.Texture2D.MipSlice = 0;
      ivDesc.Texture2D.ArraySlice = sub_idx;

      ComPtr<ID3D11VideoProcessorInputView> inputView;
      hr = video_device_->CreateVideoProcessorInputView(
          decoded_tex.Get(), vp_enum_.Get(), &ivDesc, &inputView);
      if (FAILED(hr)) {
        result_sample->Release();
        break;
      }

      D3D11_VIDEO_PROCESSOR_OUTPUT_VIEW_DESC ovDesc = {};
      ovDesc.ViewDimension = D3D11_VPOV_DIMENSION_TEXTURE2D;
      ovDesc.Texture2D.MipSlice = 0;

      ComPtr<ID3D11VideoProcessorOutputView> outputView;
      hr = video_device_->CreateVideoProcessorOutputView(
          output_tex_.Get(), vp_enum_.Get(), &ovDesc, &outputView);
      if (FAILED(hr)) {
        result_sample->Release();
        break;
      }

      D3D11_VIDEO_PROCESSOR_STREAM stream = {};
      stream.Enable = TRUE;
      stream.pInputSurface = inputView.Get();

      hr = video_context_->VideoProcessorBlt(
          video_proc_.Get(), outputView.Get(), 0, 1, &stream);

      result_sample->Release();

      if (SUCCEEDED(hr)) {
        {
          std::lock_guard<std::mutex> lk(desc_mu_);
          descriptor_.struct_size = sizeof(FlutterDesktopGpuSurfaceDescriptor);
          descriptor_.handle = shared_handle_;
          descriptor_.width = actual_w;
          descriptor_.height = actual_h;
          descriptor_.visible_width = actual_w;
          descriptor_.visible_height = actual_h;
          descriptor_.format = kFlutterDesktopPixelFormatBGRA8888;
          descriptor_.release_callback = nullptr;
          descriptor_.release_context = nullptr;
        }

        if (texture_id_ >= 0 && texture_registrar_) {
          texture_registrar_->MarkTextureFrameAvailable(texture_id_);
        }

        // 通知 IDecoder 回调（plugin 层可能需要知道尺寸变化）
        if (on_frame_) {
          DecodedFrame f;
          f.w = static_cast<int>(actual_w);
          f.h = static_cast<int>(actual_h);
          on_frame_(std::move(f));
        }
      }
    }
  }

  CoUninitialize();
}
