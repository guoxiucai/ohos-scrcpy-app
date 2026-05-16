#pragma once
#include "i_decoder.h"

#include <condition_variable>
#include <deque>
#include <mutex>
#include <thread>

#include <wincodec.h>
#include <wrl/client.h>

// codec=2：JPEG，WIC 解码为 BGRA。
class JpegDecoder : public IDecoder {
 public:
  JpegDecoder() = default;
  ~JpegDecoder() override { Teardown(); }

  bool Init(const flutter::EncodableMap& args, std::string* err) override;
  void Feed(std::vector<uint8_t> nal, bool keyframe, int64_t pts_ms) override;
  void Teardown() override;

 private:
  void WorkerLoop();

  Microsoft::WRL::ComPtr<IWICImagingFactory> wic_factory_;

  struct Task {
    std::vector<uint8_t> data;
  };

  std::deque<Task> queue_;
  std::mutex mu_;
  std::condition_variable cv_;
  bool stop_ = false;
  std::thread worker_;
};
