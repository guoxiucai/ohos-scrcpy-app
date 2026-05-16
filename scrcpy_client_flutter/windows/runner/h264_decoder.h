#pragma once
#include "i_decoder.h"

#include <atomic>
#include <condition_variable>
#include <deque>
#include <mutex>
#include <thread>

#include <mfapi.h>
#include <mferror.h>
#include <mftransform.h>
#include <wrl/client.h>

// codec=0：H264 Annex-B → MFT → NV12 → BGRA。
// SPS/PPS 从 init 参数缓存，首个 IDR 前自动 prepend。
class H264Decoder : public IDecoder {
 public:
  using BackpressureCb = std::function<void(bool paused)>;

  H264Decoder() = default;
  ~H264Decoder() override { Teardown(); }

  bool Init(const flutter::EncodableMap& args, std::string* err) override;
  void Feed(std::vector<uint8_t> nal, bool keyframe, int64_t pts_ms) override;
  void Teardown() override;

  // 队列达到高水位时回调 true（建议暂停编码），低水位时回调 false（恢复编码）。
  void SetBackpressureCallback(BackpressureCb cb) { on_backpressure_ = std::move(cb); }

 private:
  void WorkerLoop();
  bool SetupMFT(std::string* err);
  static void Nv12ToBgra(const uint8_t* nv12, int src_stride_y,
                          int src_stride_uv, int width, int height,
                          int alloc_height,
                          std::vector<uint8_t>& bgra);

  static constexpr size_t kQueueMax      = 30;  // 最大队列深度（30帧 ≈ 1.5s@20fps）
  static constexpr size_t kHighWaterMark = 24;  // 触发背压（暂停服务端编码）
  static constexpr size_t kLowWaterMark  =  8;  // 恢复服务端编码

  std::vector<uint8_t> sps_nal_;
  std::vector<uint8_t> pps_nal_;
  bool sps_pps_injected_ = false;

  int width_ = 0;
  int height_ = 0;

  Microsoft::WRL::ComPtr<IMFTransform> mft_;

  struct Task {
    std::vector<uint8_t> data;
    bool keyframe = false;
    int64_t pts_ms = 0;
  };

  std::deque<Task> queue_;
  std::mutex mu_;
  std::condition_variable cv_;
  bool stop_ = false;
  std::thread worker_;

  bool encoder_paused_ = false;          // 已发送 pause，保护于 mu_
  std::atomic<bool> has_dropped_{false}; // 队列满时丢过帧，WorkerLoop 读
  BackpressureCb on_backpressure_;
};
