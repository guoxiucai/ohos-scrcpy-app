#include "jpeg_decoder.h"

#include <shlwapi.h>

using flutter::EncodableMap;
using flutter::EncodableValue;

bool JpegDecoder::Init(const EncodableMap& /*args*/, std::string* err) {
  // worker 线程里初始化 COM + WIC，这里只启动线程。
  stop_ = false;
  worker_ = std::thread([this] { WorkerLoop(); });
  return true;
}

void JpegDecoder::Feed(std::vector<uint8_t> data, bool /*keyframe*/, int64_t /*pts_ms*/) {
  {
    std::lock_guard<std::mutex> lk(mu_);
    while (queue_.size() >= 4) queue_.pop_front();
    queue_.push_back({std::move(data)});
  }
  cv_.notify_one();
}

void JpegDecoder::Teardown() {
  {
    std::lock_guard<std::mutex> lk(mu_);
    stop_ = true;
  }
  cv_.notify_all();
  if (worker_.joinable()) worker_.join();
}

void JpegDecoder::WorkerLoop() {
  CoInitializeEx(nullptr, COINIT_MULTITHREADED);

  Microsoft::WRL::ComPtr<IWICImagingFactory> factory;
  CoCreateInstance(CLSID_WICImagingFactory, nullptr, CLSCTX_INPROC_SERVER,
                   IID_PPV_ARGS(&factory));

  while (true) {
    Task task;
    {
      std::unique_lock<std::mutex> lk(mu_);
      cv_.wait(lk, [this] { return stop_ || !queue_.empty(); });
      if (stop_ && queue_.empty()) break;
      task = std::move(queue_.front());
      queue_.pop_front();
    }

    if (!factory || task.data.empty()) continue;

    // 把字节包成 IStream
    IStream* stream = SHCreateMemStream(task.data.data(),
                                        static_cast<UINT>(task.data.size()));
    if (!stream) continue;

    Microsoft::WRL::ComPtr<IWICBitmapDecoder> decoder;
    HRESULT hr = factory->CreateDecoderFromStream(
        stream, &GUID_VendorMicrosoft, WICDecodeMetadataCacheOnLoad, &decoder);
    stream->Release();
    if (FAILED(hr)) continue;

    Microsoft::WRL::ComPtr<IWICBitmapFrameDecode> frame;
    hr = decoder->GetFrame(0, &frame);
    if (FAILED(hr)) continue;

    UINT w = 0, h = 0;
    frame->GetSize(&w, &h);
    if (w == 0 || h == 0) continue;

    Microsoft::WRL::ComPtr<IWICFormatConverter> converter;
    factory->CreateFormatConverter(&converter);
    hr = converter->Initialize(frame.Get(), GUID_WICPixelFormat32bppBGRA,
                               WICBitmapDitherTypeNone, nullptr, 0.0,
                               WICBitmapPaletteTypeMedianCut);
    if (FAILED(hr)) continue;

    DecodedFrame out;
    out.w = static_cast<int>(w);
    out.h = static_cast<int>(h);
    const UINT stride = w * 4;
    out.bgra.resize(stride * h);
    hr = converter->CopyPixels(nullptr, stride, static_cast<UINT>(out.bgra.size()),
                               out.bgra.data());
    if (FAILED(hr)) continue;

    if (on_frame_) on_frame_(std::move(out));
  }

  CoUninitialize();
}
