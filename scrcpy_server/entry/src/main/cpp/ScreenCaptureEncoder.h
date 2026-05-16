#ifndef SCRCPY_SCREEN_CAPTURE_ENCODER_H
#define SCRCPY_SCREEN_CAPTURE_ENCODER_H

#include <cstdint>

namespace scrcpy {

struct CaptureConfig {
    int32_t width;
    int32_t height;
    int32_t frameRate;
    int32_t bitrate;
    int32_t jpegQuality; // RAW JPEG quality 1-100
};

bool StartCapture(const CaptureConfig &cfg);
void StopCapture();
void SetEncoderPaused(bool paused);
bool ProbeScreenCapture(const CaptureConfig &cfg);

} // namespace scrcpy

#endif
