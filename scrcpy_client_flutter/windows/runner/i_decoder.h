#pragma once
#include <cstdint>
#include <functional>
#include <string>
#include <vector>

#include <flutter/encodable_value.h>

struct DecodedFrame {
  std::vector<uint8_t> bgra;
  int w = 0;
  int h = 0;
};

class IDecoder {
 public:
  using FrameCb = std::function<void(DecodedFrame)>;

  virtual ~IDecoder() = default;

  // 初始化解码器；出错时 err 非空，返回 false。
  virtual bool Init(const flutter::EncodableMap& args, std::string* err) = 0;

  // 投递一帧原始数据；解码完成后异步回调 on_frame_。
  virtual void Feed(std::vector<uint8_t> nal, bool keyframe, int64_t pts_ms) = 0;

  // 销毁解码器（停止 worker 线程）。
  virtual void Teardown() = 0;

  void SetFrameCallback(FrameCb cb) { on_frame_ = std::move(cb); }

 protected:
  FrameCb on_frame_;
};
