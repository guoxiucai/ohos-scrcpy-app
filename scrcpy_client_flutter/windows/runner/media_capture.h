#pragma once

#include <flutter/encodable_value.h>

#include <cstdint>
#include <functional>
#include <memory>
#include <string>
#include <vector>

struct MediaOperationResult {
  bool ok = false;
  std::string path;
  std::string error;
  int64_t duration_us = 0;
  int frame_count = 0;
};

class H264Mp4Recorder {
 public:
  using StateCallback =
      std::function<void(const std::string& state, const std::string& error)>;

  explicit H264Mp4Recorder(StateCallback state_callback);
  ~H264Mp4Recorder();

  MediaOperationResult Start(const flutter::EncodableMap& args);
  void Feed(const std::vector<uint8_t>& annex_b, bool keyframe, int64_t pts_us);
  MediaOperationResult Stop();
  void Cancel();

 private:
  struct Impl;
  std::unique_ptr<Impl> impl_;
};

MediaOperationResult SaveBgraFrameAsPng(
    const std::vector<uint8_t>& bgra,
    int width,
    int height);

MediaOperationResult SaveRgbaFrameAsPng(
    const std::vector<uint8_t>& rgba,
    int width,
    int height);

MediaOperationResult RevealInFileManager(const std::string& utf8_path);

flutter::EncodableValue EncodeMediaResult(const MediaOperationResult& result);
