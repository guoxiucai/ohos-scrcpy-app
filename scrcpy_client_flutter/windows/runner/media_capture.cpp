#include "media_capture.h"

#include <windows.h>
#include <wincodec.h>
#include <shlobj.h>
#include <shellapi.h>
#include <mfapi.h>
#include <mferror.h>
#include <mfidl.h>
#include <mfreadwrite.h>
#include <wrl/client.h>

#include <algorithm>
#include <chrono>
#include <cstring>
#include <iomanip>
#include <iterator>
#include <limits>
#include <sstream>
#include <utility>

using Microsoft::WRL::ComPtr;
using flutter::EncodableMap;
using flutter::EncodableValue;

namespace {

std::wstring Utf8ToWide(const std::string& value) {
  if (value.empty()) return {};
  const int size = MultiByteToWideChar(
      CP_UTF8, 0, value.data(), static_cast<int>(value.size()), nullptr, 0);
  std::wstring output(size, L'\0');
  MultiByteToWideChar(
      CP_UTF8, 0, value.data(), static_cast<int>(value.size()),
      output.data(), size);
  return output;
}

std::string WideToUtf8(const std::wstring& value) {
  if (value.empty()) return {};
  const int size = WideCharToMultiByte(
      CP_UTF8, 0, value.data(), static_cast<int>(value.size()),
      nullptr, 0, nullptr, nullptr);
  std::string output(size, '\0');
  WideCharToMultiByte(
      CP_UTF8, 0, value.data(), static_cast<int>(value.size()),
      output.data(), size, nullptr, nullptr);
  return output;
}

std::string HResultText(const char* action, HRESULT hr) {
  std::ostringstream stream;
  stream << action << " (HRESULT=0x" << std::hex
         << static_cast<unsigned long>(hr) << ")";
  return stream.str();
}

bool Exists(const std::wstring& path) {
  return GetFileAttributesW(path.c_str()) != INVALID_FILE_ATTRIBUTES;
}

std::wstring DesktopPath(const wchar_t* prefix, const wchar_t* extension) {
  PWSTR desktop_raw = nullptr;
  if (FAILED(SHGetKnownFolderPath(
          FOLDERID_Desktop, KF_FLAG_DEFAULT, nullptr, &desktop_raw))) {
    return {};
  }
  std::wstring desktop(desktop_raw);
  CoTaskMemFree(desktop_raw);

  SYSTEMTIME time{};
  GetLocalTime(&time);
  std::wostringstream stem;
  stem << prefix << L"_" << std::setfill(L'0')
       << std::setw(4) << time.wYear
       << std::setw(2) << time.wMonth
       << std::setw(2) << time.wDay << L"_"
       << std::setw(2) << time.wHour
       << std::setw(2) << time.wMinute
       << std::setw(2) << time.wSecond;
  const std::wstring base = desktop + L"\\" + stem.str();
  std::wstring candidate = base + L"." + extension;
  int suffix = 1;
  while (Exists(candidate)) {
    candidate = base + L"_" + std::to_wstring(suffix++) + L"." + extension;
  }
  return candidate;
}

std::wstring TemporaryPath(const wchar_t* extension) {
  wchar_t directory[MAX_PATH] = {};
  if (GetTempPathW(MAX_PATH, directory) == 0) return {};
  GUID guid{};
  if (FAILED(CoCreateGuid(&guid))) return {};
  wchar_t guid_text[64] = {};
  StringFromGUID2(guid, guid_text, 64);
  std::wstring name(guid_text);
  name.erase(std::remove(name.begin(), name.end(), L'{'), name.end());
  name.erase(std::remove(name.begin(), name.end(), L'}'), name.end());
  return std::wstring(directory) + L"HongJing_" + name + L"." + extension;
}

int GetInt(const EncodableMap& args, const char* key, int fallback = 0) {
  const auto it = args.find(EncodableValue(key));
  if (it == args.end()) return fallback;
  if (std::holds_alternative<int>(it->second)) {
    return std::get<int>(it->second);
  }
  if (std::holds_alternative<int64_t>(it->second)) {
    return static_cast<int>(std::get<int64_t>(it->second));
  }
  return fallback;
}

std::vector<uint8_t> GetBytes(const EncodableMap& args, const char* key) {
  const auto it = args.find(EncodableValue(key));
  if (it != args.end() &&
      std::holds_alternative<std::vector<uint8_t>>(it->second)) {
    return std::get<std::vector<uint8_t>>(it->second);
  }
  return {};
}

struct ConvertedAccessUnit {
  std::vector<uint8_t> annex_b;
  bool contains_idr = false;
};

bool FindStartCode(const std::vector<uint8_t>& bytes,
                   size_t from,
                   size_t* offset,
                   size_t* length) {
  for (size_t index = from; index + 2 < bytes.size(); ++index) {
    if (bytes[index] != 0 || bytes[index + 1] != 0) continue;
    if (bytes[index + 2] == 1) {
      *offset = index;
      *length = 3;
      return true;
    }
    if (index + 3 < bytes.size() && bytes[index + 2] == 0 &&
        bytes[index + 3] == 1) {
      *offset = index;
      *length = 4;
      return true;
    }
  }
  return false;
}

ConvertedAccessUnit StripParameterSets(const std::vector<uint8_t>& bytes) {
  ConvertedAccessUnit output;
  size_t cursor = 0;
  size_t start = 0;
  size_t start_length = 0;
  while (FindStartCode(bytes, cursor, &start, &start_length)) {
    const size_t nal_start = start + start_length;
    size_t next = 0;
    size_t next_length = 0;
    const bool has_next =
        FindStartCode(bytes, nal_start, &next, &next_length);
    const size_t nal_end = has_next ? next : bytes.size();
    if (nal_end > nal_start) {
      const uint8_t type = bytes[nal_start] & 0x1F;
      if (type == 5) output.contains_idr = true;
      if (type != 7 && type != 8) {
        static constexpr uint8_t kStartCode[] = {0, 0, 0, 1};
        output.annex_b.insert(
            output.annex_b.end(), std::begin(kStartCode), std::end(kStartCode));
        output.annex_b.insert(
            output.annex_b.end(),
            bytes.begin() + static_cast<ptrdiff_t>(nal_start),
            bytes.begin() + static_cast<ptrdiff_t>(nal_end));
      }
    }
    if (!has_next) break;
    cursor = next;
  }
  return output;
}

struct PendingFrame {
  std::vector<uint8_t> data;
  int64_t pts_us = 0;
  bool keyframe = false;
};

}  // namespace

struct H264Mp4Recorder::Impl {
  explicit Impl(StateCallback callback) : state_callback(std::move(callback)) {}

  StateCallback state_callback;
  ComPtr<IMFSinkWriter> writer;
  DWORD stream_index = 0;
  std::wstring temporary_path;
  std::wstring final_path;
  bool active = false;
  bool writing = false;
  int fps = 15;
  int frame_count = 0;
  std::unique_ptr<PendingFrame> pending;
  // 本地时钟计时 — 录制时长不再依赖服务端 PTS。
  // 即使屏幕静止无新帧，视频 duration 也能反映真实录制时间。
  std::chrono::steady_clock::time_point recording_start;
  std::chrono::steady_clock::time_point last_frame_time;
  int64_t elapsed_us = 0;

  bool WriteFrame(const PendingFrame& frame,
                  int64_t duration_us,
                  std::string* error) {
    ComPtr<IMFMediaBuffer> buffer;
    HRESULT hr = MFCreateMemoryBuffer(
        static_cast<DWORD>(frame.data.size()), &buffer);
    if (FAILED(hr)) {
      *error = HResultText("创建媒体缓冲失败", hr);
      return false;
    }
    BYTE* destination = nullptr;
    DWORD maximum = 0;
    hr = buffer->Lock(&destination, &maximum, nullptr);
    if (FAILED(hr)) {
      *error = HResultText("锁定媒体缓冲失败", hr);
      return false;
    }
    memcpy(destination, frame.data.data(), frame.data.size());
    buffer->Unlock();
    buffer->SetCurrentLength(static_cast<DWORD>(frame.data.size()));

    ComPtr<IMFSample> sample;
    hr = MFCreateSample(&sample);
    if (SUCCEEDED(hr)) hr = sample->AddBuffer(buffer.Get());
    if (SUCCEEDED(hr)) {
      // pts_us 现已存储为从 recording_start 起的本地时钟偏移(µs)
      hr = sample->SetSampleTime(frame.pts_us * 10);
    }
    if (SUCCEEDED(hr)) {
      hr = sample->SetSampleDuration(std::max<int64_t>(1, duration_us) * 10);
    }
    if (SUCCEEDED(hr)) {
      sample->SetUINT32(
          MFSampleExtension_CleanPoint, frame.keyframe ? 1U : 0U);
      if (frame_count == 0) {
        sample->SetUINT32(MFSampleExtension_Discontinuity, 1U);
      }
      hr = writer->WriteSample(stream_index, sample.Get());
    }
    if (FAILED(hr)) {
      *error = HResultText("写入 MP4 样本失败", hr);
      return false;
    }
    ++frame_count;
    return true;
  }

  void Reset(bool delete_temporary) {
    writer.Reset();
    if (delete_temporary && !temporary_path.empty()) {
      DeleteFileW(temporary_path.c_str());
    }
    temporary_path.clear();
    final_path.clear();
    active = false;
    writing = false;
    frame_count = 0;
    elapsed_us = 0;
    pending.reset();
  }

  void Fail(const std::string& message) {
    Reset(true);
    state_callback("error", message);
  }
};

H264Mp4Recorder::H264Mp4Recorder(StateCallback state_callback)
    : impl_(std::make_unique<Impl>(std::move(state_callback))) {}

H264Mp4Recorder::~H264Mp4Recorder() {
  Cancel();
}

MediaOperationResult H264Mp4Recorder::Start(const EncodableMap& args) {
  MediaOperationResult result;
  if (impl_->active) {
    result.error = "已有录制任务正在进行";
    return result;
  }
  const int width = GetInt(args, "width");
  const int height = GetInt(args, "height");
  const int bitrate = GetInt(args, "bitrate", 4000000);
  impl_->fps = GetInt(args, "fps", 15);
  auto sps = GetBytes(args, "sps");
  auto pps = GetBytes(args, "pps");
  if (width <= 0 || height <= 0 || impl_->fps <= 0 ||
      sps.empty() || pps.empty()) {
    result.error = "H.264 录制参数不完整";
    return result;
  }
  impl_->temporary_path = TemporaryPath(L"mp4");
  impl_->final_path = DesktopPath(L"HongJing_Recording", L"mp4");
  if (impl_->temporary_path.empty() || impl_->final_path.empty()) {
    result.error = "无法定位系统桌面或临时目录";
    impl_->Reset(true);
    return result;
  }

  HRESULT hr = MFCreateSinkWriterFromURL(
      impl_->temporary_path.c_str(), nullptr, nullptr, &impl_->writer);
  ComPtr<IMFMediaType> media_type;
  if (SUCCEEDED(hr)) hr = MFCreateMediaType(&media_type);
  if (SUCCEEDED(hr)) hr = media_type->SetGUID(MF_MT_MAJOR_TYPE, MFMediaType_Video);
  if (SUCCEEDED(hr)) hr = media_type->SetGUID(MF_MT_SUBTYPE, MFVideoFormat_H264);
  if (SUCCEEDED(hr)) hr = MFSetAttributeSize(
      media_type.Get(), MF_MT_FRAME_SIZE,
      static_cast<UINT32>(width), static_cast<UINT32>(height));
  if (SUCCEEDED(hr)) hr = MFSetAttributeRatio(
      media_type.Get(), MF_MT_FRAME_RATE,
      static_cast<UINT32>(impl_->fps), 1);
  if (SUCCEEDED(hr)) hr = media_type->SetUINT32(
      MF_MT_INTERLACE_MODE,
      static_cast<UINT32>(MFVideoInterlace_Progressive));
  if (SUCCEEDED(hr)) hr = media_type->SetUINT32(
      MF_MT_ALL_SAMPLES_INDEPENDENT, 0U);
  if (SUCCEEDED(hr)) hr = media_type->SetUINT32(
      MF_MT_AVG_BITRATE, static_cast<UINT32>(std::max(1, bitrate)));
  if (SUCCEEDED(hr)) hr = MFSetAttributeRatio(
      media_type.Get(), MF_MT_PIXEL_ASPECT_RATIO, 1, 1);
  if (SUCCEEDED(hr)) {
    std::vector<uint8_t> sequence = {0, 0, 0, 1};
    sequence.insert(sequence.end(), sps.begin(), sps.end());
    sequence.insert(sequence.end(), {0, 0, 0, 1});
    sequence.insert(sequence.end(), pps.begin(), pps.end());
    hr = media_type->SetBlob(
        MF_MT_MPEG_SEQUENCE_HEADER, sequence.data(),
        static_cast<UINT32>(sequence.size()));
  }
  if (SUCCEEDED(hr)) {
    hr = impl_->writer->AddStream(media_type.Get(), &impl_->stream_index);
  }
  if (SUCCEEDED(hr)) {
    hr = impl_->writer->SetInputMediaType(
        impl_->stream_index, media_type.Get(), nullptr);
  }
  if (SUCCEEDED(hr)) hr = impl_->writer->BeginWriting();
  if (FAILED(hr)) {
    result.error = HResultText("初始化 MP4 写入器失败", hr);
    impl_->Reset(true);
    return result;
  }

  impl_->active = true;
  impl_->writing = false;
  result.ok = true;
  return result;
}

void H264Mp4Recorder::Feed(const std::vector<uint8_t>& annex_b,
                           bool keyframe,
                           int64_t pts_us) {
  if (!impl_->active || annex_b.empty()) return;
  auto converted = StripParameterSets(annex_b);
  if (converted.annex_b.empty()) return;

  const auto now = std::chrono::steady_clock::now();

  if (!impl_->writing) {
    if (!keyframe || !converted.contains_idr) return;
    impl_->writing = true;
    impl_->recording_start = now;
    impl_->last_frame_time = now;
    impl_->elapsed_us = 0;
    impl_->state_callback("recording", "");
  } else {
    // 用本地时钟差作为上一帧的 duration，确保视频时长与真实时间一致
    const auto elapsed_since_last =
        std::chrono::duration_cast<std::chrono::microseconds>(
            now - impl_->last_frame_time);
    if (impl_->pending) {
      std::string error;
      if (!impl_->WriteFrame(
              *impl_->pending,
              std::max<int64_t>(1, elapsed_since_last.count()),
              &error)) {
        impl_->Fail(error);
        return;
      }
      impl_->elapsed_us += elapsed_since_last.count();
    }
    impl_->last_frame_time = now;
  }

  impl_->pending = std::make_unique<PendingFrame>();
  impl_->pending->data = std::move(converted.annex_b);
  impl_->pending->pts_us = impl_->elapsed_us;
  impl_->pending->keyframe = keyframe && converted.contains_idr;
}

MediaOperationResult H264Mp4Recorder::Stop() {
  MediaOperationResult result;
  if (!impl_->active) {
    result.error = "当前没有录制任务";
    return result;
  }
  if (!impl_->writing || !impl_->pending) {
    impl_->Reset(true);
    result.error = "尚未收到有效关键帧";
    return result;
  }
  // 最后一帧的持续时间 = 从最后一帧到当前的本地时间差
  const auto now = std::chrono::steady_clock::now();
  const auto final_duration =
      std::chrono::duration_cast<std::chrono::microseconds>(
          now - impl_->last_frame_time);

  std::string error;
  if (!impl_->WriteFrame(
          *impl_->pending,
          std::max<int64_t>(1, final_duration.count()), &error)) {
    impl_->Reset(true);
    result.error = error;
    return result;
  }
  impl_->pending.reset();
  impl_->elapsed_us += final_duration.count();
  const int64_t duration = impl_->elapsed_us;
  const int frame_count = impl_->frame_count;
  const std::wstring temporary = impl_->temporary_path;
  const std::wstring destination = impl_->final_path;
  const HRESULT hr = impl_->writer->Finalize();
  if (FAILED(hr)) {
    result.error = HResultText("MP4 文件收尾失败", hr);
    impl_->Reset(true);
    return result;
  }
  impl_->writer.Reset();
  if (!MoveFileExW(
          temporary.c_str(), destination.c_str(),
          MOVEFILE_COPY_ALLOWED | MOVEFILE_WRITE_THROUGH)) {
    result.error = HResultText(
        "无法将录制文件移动到桌面",
        HRESULT_FROM_WIN32(GetLastError()));
    impl_->Reset(true);
    return result;
  }
  impl_->Reset(false);
  result.ok = true;
  result.path = WideToUtf8(destination);
  result.duration_us = duration;
  result.frame_count = frame_count;
  return result;
}

void H264Mp4Recorder::Cancel() {
  if (!impl_ || !impl_->active) return;
  impl_->Reset(true);
}

MediaOperationResult SavePixelFrameAsPng(
    const std::vector<uint8_t>& pixels,
    int width,
    int height,
    bool is_rgba) {
  MediaOperationResult result;
  if (width <= 0 || height <= 0) {
    result.error = "当前没有可截图的解码帧";
    return result;
  }
  const size_t expected =
      static_cast<size_t>(width) * static_cast<size_t>(height) * 4;
  if (pixels.size() < expected ||
      expected > std::numeric_limits<UINT>::max()) {
    result.error = "当前解码帧尺寸无效";
    return result;
  }
  const UINT frame_width = static_cast<UINT>(width);
  const UINT frame_height = static_cast<UINT>(height);
  const std::wstring temporary = TemporaryPath(L"png");
  const std::wstring destination = DesktopPath(L"HongJing_Screenshot", L"png");
  if (temporary.empty() || destination.empty()) {
    result.error = "无法定位系统桌面或临时目录";
    return result;
  }

  ComPtr<IWICImagingFactory> factory;
  HRESULT hr = CoCreateInstance(
      CLSID_WICImagingFactory, nullptr, CLSCTX_INPROC_SERVER,
      IID_PPV_ARGS(&factory));
  ComPtr<IWICStream> stream;
  if (SUCCEEDED(hr)) hr = factory->CreateStream(&stream);
  if (SUCCEEDED(hr)) {
    hr = stream->InitializeFromFilename(temporary.c_str(), GENERIC_WRITE);
  }
  ComPtr<IWICBitmapEncoder> encoder;
  if (SUCCEEDED(hr)) {
    hr = factory->CreateEncoder(GUID_ContainerFormatPng, nullptr, &encoder);
  }
  if (SUCCEEDED(hr)) hr = encoder->Initialize(stream.Get(), WICBitmapEncoderNoCache);
  ComPtr<IWICBitmapFrameEncode> frame;
  ComPtr<IPropertyBag2> properties;
  if (SUCCEEDED(hr)) hr = encoder->CreateNewFrame(&frame, &properties);
  if (SUCCEEDED(hr)) hr = frame->Initialize(properties.Get());
  if (SUCCEEDED(hr)) hr = frame->SetSize(frame_width, frame_height);
  WICPixelFormatGUID format = GUID_WICPixelFormat32bppBGRA;
  if (SUCCEEDED(hr)) hr = frame->SetPixelFormat(&format);
  if (SUCCEEDED(hr) && format != GUID_WICPixelFormat32bppBGRA) {
    hr = WINCODEC_ERR_UNSUPPORTEDPIXELFORMAT;
  }
  std::vector<uint8_t> converted;
  const uint8_t* png_pixels = pixels.data();
  if (is_rgba) {
    converted.resize(expected);
    for (size_t offset = 0; offset < expected; offset += 4) {
      converted[offset] = pixels[offset + 2];
      converted[offset + 1] = pixels[offset + 1];
      converted[offset + 2] = pixels[offset];
      converted[offset + 3] = pixels[offset + 3];
    }
    png_pixels = converted.data();
  }
  if (SUCCEEDED(hr)) {
    hr = frame->WritePixels(
        frame_height, frame_width * 4, static_cast<UINT>(expected),
        const_cast<BYTE*>(png_pixels));
  }
  if (SUCCEEDED(hr)) hr = frame->Commit();
  if (SUCCEEDED(hr)) hr = encoder->Commit();
  // 必须在 MoveFileExW 之前释放所有 COM 对象，否则 encoder/frame
  // 内部可能仍持有 WIC stream 的文件句柄，导致 ERROR_SHARING_VIOLATION。
  stream.Reset();
  frame.Reset();
  encoder.Reset();
  factory.Reset();
  if (FAILED(hr)) {
    DeleteFileW(temporary.c_str());
    result.error = HResultText("PNG 编码失败", hr);
    return result;
  }
  if (!MoveFileExW(
          temporary.c_str(), destination.c_str(),
          MOVEFILE_COPY_ALLOWED | MOVEFILE_WRITE_THROUGH)) {
    const HRESULT move_error = HRESULT_FROM_WIN32(GetLastError());
    DeleteFileW(temporary.c_str());
    result.error = HResultText("无法将截图移动到桌面", move_error);
    return result;
  }
  result.ok = true;
  result.path = WideToUtf8(destination);
  return result;
}

MediaOperationResult SaveBgraFrameAsPng(
    const std::vector<uint8_t>& bgra,
    int width,
    int height) {
  return SavePixelFrameAsPng(bgra, width, height, false);
}

MediaOperationResult SaveRgbaFrameAsPng(
    const std::vector<uint8_t>& rgba,
    int width,
    int height) {
  return SavePixelFrameAsPng(rgba, width, height, true);
}

MediaOperationResult RevealInFileManager(const std::string& utf8_path) {
  MediaOperationResult result;
  const std::wstring path = Utf8ToWide(utf8_path);
  if (path.empty() || !Exists(path)) {
    result.error = "保存文件不存在";
    return result;
  }
  PIDLIST_ABSOLUTE item = nullptr;
  const HRESULT parse_hr = SHParseDisplayName(
      path.c_str(), nullptr, &item, 0, nullptr);
  if (FAILED(parse_hr) || item == nullptr) {
    result.error = HResultText("无法解析保存路径", parse_hr);
    return result;
  }
  const HRESULT open_hr = SHOpenFolderAndSelectItems(item, 0, nullptr, 0);
  CoTaskMemFree(item);
  if (FAILED(open_hr)) {
    result.error = HResultText("无法打开保存位置", open_hr);
    return result;
  }
  result.ok = true;
  result.path = utf8_path;
  return result;
}

EncodableValue EncodeMediaResult(const MediaOperationResult& result) {
  EncodableMap map;
  map[EncodableValue("ok")] = EncodableValue(result.ok);
  map[EncodableValue("durationUs")] = EncodableValue(result.duration_us);
  map[EncodableValue("frameCount")] = EncodableValue(result.frame_count);
  if (!result.path.empty()) {
    map[EncodableValue("path")] = EncodableValue(result.path);
  }
  if (!result.error.empty()) {
    map[EncodableValue("error")] = EncodableValue(result.error);
  }
  return EncodableValue(map);
}
