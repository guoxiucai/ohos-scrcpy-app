#pragma once
#include "i_decoder.h"

#include <condition_variable>
#include <deque>
#include <mutex>
#include <thread>

// codec=1：RAW RGBA，R/B swap 后上屏。
class RawDecoder : public IDecoder {
 public:
  RawDecoder() = default;
  ~RawDecoder() override { Teardown(); }

  bool Init(const flutter::EncodableMap& args, std::string* err) override;
  void Feed(std::vector<uint8_t> nal, bool keyframe, int64_t pts_ms) override;
  void Teardown() override;

 private:
  void WorkerLoop();

  int width_ = 0;
  int height_ = 0;

  struct Task {
    std::vector<uint8_t> data;
  };

  std::deque<Task> queue_;
  std::mutex mu_;
  std::condition_variable cv_;
  bool stop_ = false;
  std::thread worker_;
};
