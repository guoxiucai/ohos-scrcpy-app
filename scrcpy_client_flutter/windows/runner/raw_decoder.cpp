#include "raw_decoder.h"

using flutter::EncodableMap;
using flutter::EncodableValue;

bool RawDecoder::Init(const EncodableMap& args, std::string* err) {
  auto get_int = [&](const char* key, int fallback) {
    auto it = args.find(EncodableValue(key));
    if (it != args.end() && std::holds_alternative<int>(it->second))
      return std::get<int>(it->second);
    return fallback;
  };
  width_ = get_int("width", 0);
  height_ = get_int("height", 0);
  if (width_ <= 0 || height_ <= 0) {
    *err = "raw: invalid width/height";
    return false;
  }

  stop_ = false;
  worker_ = std::thread([this] { WorkerLoop(); });
  return true;
}

void RawDecoder::Feed(std::vector<uint8_t> data, bool /*keyframe*/, int64_t /*pts_ms*/) {
  {
    std::lock_guard<std::mutex> lk(mu_);
    // 队列过长时丢弃旧帧
    while (queue_.size() >= 4) queue_.pop_front();
    queue_.push_back({std::move(data)});
  }
  cv_.notify_one();
}

void RawDecoder::Teardown() {
  {
    std::lock_guard<std::mutex> lk(mu_);
    stop_ = true;
  }
  cv_.notify_all();
  if (worker_.joinable()) worker_.join();
}

void RawDecoder::WorkerLoop() {
  while (true) {
    Task task;
    {
      std::unique_lock<std::mutex> lk(mu_);
      cv_.wait(lk, [this] { return stop_ || !queue_.empty(); });
      if (stop_ && queue_.empty()) break;
      task = std::move(queue_.front());
      queue_.pop_front();
    }

    const int expected = width_ * height_ * 4;
    if (static_cast<int>(task.data.size()) < expected) continue;

    DecodedFrame frame;
    frame.w = width_;
    frame.h = height_;
    frame.bgra.resize(expected);

    // RGBA → BGRA（R/B swap）
    const uint8_t* src = task.data.data();
    uint8_t* dst = frame.bgra.data();
    for (int i = 0; i < width_ * height_; ++i) {
      dst[0] = src[2];  // B
      dst[1] = src[1];  // G
      dst[2] = src[0];  // R
      dst[3] = src[3];  // A
      src += 4;
      dst += 4;
    }

    if (on_frame_) on_frame_(std::move(frame));
  }
}
