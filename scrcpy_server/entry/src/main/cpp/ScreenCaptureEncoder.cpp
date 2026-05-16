#include "ScreenCaptureEncoder.h"
#include "TcpServer.h"

#include <hilog/log.h>
#include <multimedia/player_framework/native_avbuffer.h>
#include <multimedia/player_framework/native_avbuffer_info.h>
#include <multimedia/player_framework/native_avcapability.h>
#include <multimedia/player_framework/native_avcodec_base.h>
#include <multimedia/player_framework/native_avcodec_videoencoder.h>
#include <multimedia/player_framework/native_averrors.h>
#include <multimedia/player_framework/native_avformat.h>
#include <multimedia/player_framework/native_avscreen_capture.h>
#include <multimedia/player_framework/native_avscreen_capture_base.h>
#include <multimedia/player_framework/native_avscreen_capture_errors.h>
#include <multimedia/image_framework/image/image_packer_native.h>
#include <multimedia/image_framework/image/pixelmap_native.h>
#include <multimedia/image_framework/image/image_common.h>
#include <native_buffer/native_buffer.h>
#include <native_window/external_window.h>

#include <atomic>
#include <chrono>
#include <cstddef>
#include <cstdint>
#include <cstring>
#include <mutex>
#include <vector>

#undef LOG_DOMAIN
#undef LOG_TAG
#define LOG_DOMAIN 0xA000
#define LOG_TAG "ScrcpyCapture"

namespace scrcpy {

namespace {

constexpr int32_t kCodecH264 = 0;
constexpr int32_t kCodecRawRgba = 1;
constexpr int32_t kCodecJpeg = 2;
// JPEG 体积小，回到接近正常的帧率；RAW 兜底走 6fps 保护带宽。
constexpr int32_t kJpegFrameRate = 10;
constexpr int32_t kRawFrameRate = 6;
constexpr int32_t kEncFrameRate = 20;

class CaptureSession {
public:
    static CaptureSession &Instance() {
        static CaptureSession s;
        return s;
    }

    bool Start(const CaptureConfig &cfg);
    void Stop();
    void SetPaused(bool paused) {
        bool prev = encoder_paused_.exchange(paused, std::memory_order_relaxed);
        if (paused == prev) return;
        if (mode_ == kCodecH264) {
            std::lock_guard<std::mutex> g(mu_);
            if (capture_ == nullptr || stopping_.load()) return;
            if (paused) {
                OH_AVScreenCapture_StopScreenCapture(capture_);
            } else {
                OH_AVScreenCapture_StartScreenCaptureWithSurface(capture_, window_);
            }
        }
    }

private:
    CaptureSession() = default;
    ~CaptureSession() { Stop(); }

    bool TryStartH264();
    bool StartRaw();
    void TeardownH264Locked();

    static void OnEncOutput(OH_AVCodec *codec, uint32_t index, OH_AVBuffer *buffer, void *userData);
    static void OnEncInput(OH_AVCodec *codec, uint32_t index, OH_AVBuffer *buffer, void *userData);
    static void OnEncStreamChanged(OH_AVCodec *codec, OH_AVFormat *format, void *userData);
    static void OnEncError(OH_AVCodec *codec, int32_t errorCode, void *userData);
    static void OnScError(OH_AVScreenCapture *capture, int32_t errorCode, void *userData);
    static void OnScStateChange(OH_AVScreenCapture *capture, OH_AVScreenCaptureStateCode stateCode, void *userData);
    static void OnScVideoBuffer(OH_AVScreenCapture *capture, bool isReady);

    void HandleEncodedOutput(uint32_t index, OH_AVBuffer *buffer);
    void HandleRawBufferAvailable();
    // 把一帧 RGBA 像素编码成 JPEG 字节流；成功返回 true。失败则回落到 RAW。
    bool EncodeJpeg(const uint8_t *rgba, int32_t width, int32_t height,
                    std::vector<uint8_t> &out);

    void SendH264Config(const std::vector<uint8_t> &sps, const std::vector<uint8_t> &pps);
    void SendRawConfig(int32_t codec, int32_t width, int32_t height);
    void SendVideoFrame(bool keyframe, int64_t ptsUs, const uint8_t *nal, size_t size);

    bool ParseSpsPps(const uint8_t *data, int32_t size,
                     std::vector<uint8_t> &sps, std::vector<uint8_t> &pps) const;

    // mu_ 保护 capture_ / encoder_ / window_ 等指针；callback_mu_ 串行化回调进入临界区。
    std::mutex mu_;
    std::mutex callback_mu_;
    // stopping_ 用作回调快速短路标志（无锁），保证 Stop 期间不会再触发新的下发。
    std::atomic<bool> stopping_{false};
    std::atomic<bool> encoder_paused_{false};  // 客户端背压：暂停向 TCP 发送编码帧
    OH_AVScreenCapture *capture_ = nullptr;
    OH_AVCodec *encoder_ = nullptr;
    OHNativeWindow *window_ = nullptr;
    CaptureConfig cfg_{};
    bool configEmitted_ = false;
    int32_t mode_ = kCodecH264;
    std::vector<uint8_t> sps_;
    std::vector<uint8_t> pps_;
    // ImagePacker 在整个会话期间复用，避免每帧 Create/Release 的开销。
    OH_ImagePackerNative *imagePacker_ = nullptr;
    OH_PackingOptions *packingOptions_ = nullptr;
    // RAW 路径的缓冲：rawBuf_ 复用去 stride 后的像素，jpegBuf_ 复用 JPEG 输出。
    std::vector<uint8_t> rawBuf_;
    std::vector<uint8_t> jpegBuf_;

    std::atomic<int64_t> lastRawEmitMs_{0};
};

bool CaptureSession::Start(const CaptureConfig &cfg) {
    std::lock_guard<std::mutex> g(mu_);
    if (capture_ != nullptr || encoder_ != nullptr) {
        OH_LOG_WARN(LOG_APP, "Start: session already running (capture=%p encoder=%p)",
                    (void *)capture_, (void *)encoder_);
        return false;
    }
    stopping_.store(false);
    cfg_ = cfg;
    configEmitted_ = false;
    sps_.clear();
    pps_.clear();
    lastRawEmitMs_ = 0;

    if (TryStartH264()) {
        mode_ = kCodecH264;
        cfg_.frameRate = kEncFrameRate;
        OH_LOG_INFO(LOG_APP, "started in H264 mode");
        return true;
    }
    // H264 启动失败：先打 stopping 防止回调访问，安全销毁，再恢复。
    stopping_.store(true);
    TeardownH264Locked();
    stopping_.store(false);

    OH_LOG_WARN(LOG_APP, "H264 unavailable, falling back to RAW");
    // 优先尝试 JPEG 编码，OH NDK 12 起 image_packer 必然可用，但仍做 fallback。
    OH_ImagePackerNative *packer = nullptr;
    OH_PackingOptions *opts = nullptr;
    bool packerOk = false;
    if (OH_ImagePackerNative_Create(&packer) == IMAGE_SUCCESS && packer != nullptr &&
        OH_PackingOptions_Create(&opts) == IMAGE_SUCCESS && opts != nullptr) {
        Image_MimeType mime{};
        // image_common.h 里的 MIME_TYPE_JPEG 是 const char*，需要包成 Image_String。
        mime.data = const_cast<char *>(MIME_TYPE_JPEG);
        mime.size = std::strlen(MIME_TYPE_JPEG);
        if (OH_PackingOptions_SetMimeType(opts, &mime) == IMAGE_SUCCESS) {
            uint32_t q = static_cast<uint32_t>(cfg_.jpegQuality > 0 ? cfg_.jpegQuality : 70);
            if (q > 100) q = 100;
            OH_PackingOptions_SetQuality(opts, q);
            packerOk = true;
        }
    }
    if (packerOk) {
        imagePacker_ = packer;
        packingOptions_ = opts;
        mode_ = kCodecJpeg;
        cfg_.frameRate = kJpegFrameRate;
    } else {
        if (opts != nullptr) OH_PackingOptions_Release(opts);
        if (packer != nullptr) OH_ImagePackerNative_Release(packer);
        OH_LOG_WARN(LOG_APP, "JPEG packer unavailable, will send raw RGBA");
        mode_ = kCodecRawRgba;
        cfg_.frameRate = kRawFrameRate;
    }
    if (!StartRaw()) {
        if (capture_ != nullptr) {
            OH_AVScreenCapture_Release(capture_);
            capture_ = nullptr;
        }
        if (packingOptions_ != nullptr) {
            OH_PackingOptions_Release(packingOptions_);
            packingOptions_ = nullptr;
        }
        if (imagePacker_ != nullptr) {
            OH_ImagePackerNative_Release(imagePacker_);
            imagePacker_ = nullptr;
        }
        OH_LOG_ERROR(LOG_APP, "Start: RAW capture failed");
        return false;
    }
    OH_LOG_INFO(LOG_APP, "started in %{public}s mode (q=%{public}d)",
                mode_ == kCodecJpeg ? "JPEG" : "RAW", cfg_.jpegQuality);
    return true;
}

// 在 mu_ 持有的前提下安全清理 H264 资源；可在 TryStartH264 失败或 Stop 中复用。
void CaptureSession::TeardownH264Locked() {
    if (capture_ != nullptr) {
        auto rs = OH_AVScreenCapture_StopScreenCapture(capture_);
        OH_LOG_INFO(LOG_APP, "TeardownH264 StopScreenCapture ret=%{public}d", rs);
        OH_AVScreenCapture_Release(capture_);
        capture_ = nullptr;
    }
    if (encoder_ != nullptr) {
        OH_VideoEncoder_Flush(encoder_);
        OH_VideoEncoder_Stop(encoder_);
        {
            std::lock_guard<std::mutex> cg(callback_mu_);
        }
        OH_VideoEncoder_Destroy(encoder_);
        encoder_ = nullptr;
    }
    window_ = nullptr;
}

bool CaptureSession::TryStartH264() {
    // 先探测截屏权限，避免创建编码器后截屏失败导致清理阻塞主线程
    if (!ProbeScreenCapture(cfg_)) {
        return false;
    }

    // ---- 1. 先创建并完整配置 VideoEncoder（必须先拿到 surface 才能给截屏用）----
    OH_AVCapability *cap = OH_AVCodec_GetCapability(OH_AVCODEC_MIMETYPE_VIDEO_AVC, true);
    if (cap == nullptr) {
        OH_LOG_INFO(LOG_APP, "no AVC encoder capability on this device");
        return false;
    }
    const char *encName = OH_AVCapability_GetName(cap);
    OH_LOG_INFO(LOG_APP, "encoder cap: %{public}s", encName ? encName : "(null)");
    // RK 编码器不支持 surface RGBA→NV12 自动转换，跳过 H264 走 JPEG fallback
    if (encName != nullptr && strstr(encName, ".rk.") != nullptr) {
        OH_LOG_WARN(LOG_APP, "RK encoder detected, skip H264 (no RGBA->NV12 support)");
        return false;
    }
    if (encName != nullptr) {
        encoder_ = OH_VideoEncoder_CreateByName(encName);
    }
    if (encoder_ == nullptr) {
        encoder_ = OH_VideoEncoder_CreateByMime(OH_AVCODEC_MIMETYPE_VIDEO_AVC);
    }
    if (encoder_ == nullptr) {
        return false;
    }

    OH_AVCodecCallback encCb{};
    encCb.onError = &CaptureSession::OnEncError;
    encCb.onStreamChanged = &CaptureSession::OnEncStreamChanged;
    encCb.onNeedInputBuffer = &CaptureSession::OnEncInput;
    encCb.onNewOutputBuffer = &CaptureSession::OnEncOutput;
    if (OH_VideoEncoder_RegisterCallback(encoder_, encCb, this) != AV_ERR_OK) {
        OH_LOG_WARN(LOG_APP, "encoder RegisterCallback failed");
        return false;
    }

    OH_AVFormat *fmt = OH_AVFormat_Create();
    OH_AVFormat_SetIntValue(fmt, OH_MD_KEY_WIDTH, cfg_.width);
    OH_AVFormat_SetIntValue(fmt, OH_MD_KEY_HEIGHT, cfg_.height);
    // surface 模式下让编码器自动匹配截屏 surface 的像素格式
    OH_AVFormat_SetIntValue(fmt, OH_MD_KEY_PIXEL_FORMAT, AV_PIXEL_FORMAT_NV12);
    OH_AVFormat_SetDoubleValue(fmt, OH_MD_KEY_FRAME_RATE, static_cast<double>(cfg_.frameRate));
    OH_AVFormat_SetIntValue(fmt, OH_MD_KEY_BITRATE, cfg_.bitrate);
    OH_AVFormat_SetIntValue(fmt, OH_MD_KEY_I_FRAME_INTERVAL, 2000);
    OH_AVFormat_SetIntValue(fmt, OH_MD_KEY_PROFILE, AVC_PROFILE_MAIN);
    OH_AVFormat_SetIntValue(fmt, OH_MD_KEY_VIDEO_ENCODE_BITRATE_MODE, VBR);
    auto ret = OH_VideoEncoder_Configure(encoder_, fmt);
    OH_AVFormat_Destroy(fmt);
    if (ret != AV_ERR_OK) {
        OH_LOG_WARN(LOG_APP, "encoder configure failed: %{public}d", ret);
        return false;
    }
    if (OH_VideoEncoder_GetSurface(encoder_, &window_) != AV_ERR_OK || window_ == nullptr) {
        OH_LOG_WARN(LOG_APP, "encoder get surface failed");
        return false;
    }
    if (OH_VideoEncoder_Prepare(encoder_) != AV_ERR_OK) {
        OH_LOG_WARN(LOG_APP, "encoder prepare failed");
        return false;
    }
    if (OH_VideoEncoder_Start(encoder_) != AV_ERR_OK) {
        OH_LOG_WARN(LOG_APP, "encoder start failed");
        return false;
    }

    // ---- 2. 创建并配置 OH_AVScreenCapture（参考 demo：先注册回调，再 Init，再 Start）----
    capture_ = OH_AVScreenCapture_Create();
    if (capture_ == nullptr) {
        OH_LOG_WARN(LOG_APP, "OH_AVScreenCapture_Create failed");
        return false;
    }

    // 显式构造 config，禁用音频（micCapInfo / innerCapInfo / audioEncInfo 全置 0）。
    OH_AVScreenCaptureConfig screenCfg{};
    screenCfg.captureMode = OH_CAPTURE_HOME_SCREEN;
    screenCfg.dataType = OH_ORIGINAL_STREAM;
    screenCfg.audioInfo.micCapInfo.audioSampleRate = 0;
    screenCfg.audioInfo.micCapInfo.audioChannels = 0;
    screenCfg.audioInfo.innerCapInfo.audioSampleRate = 0;
    screenCfg.audioInfo.innerCapInfo.audioChannels = 0;
    screenCfg.videoInfo.videoCapInfo.videoFrameWidth = cfg_.width;
    screenCfg.videoInfo.videoCapInfo.videoFrameHeight = cfg_.height;
    screenCfg.videoInfo.videoCapInfo.videoSource = OH_VIDEO_SOURCE_SURFACE_RGBA;

    // 注意：Init 之前先关麦，避免某些机型上请求录音权限弹窗。
    OH_AVScreenCapture_SetMicrophoneEnabled(capture_, false);
    OH_AVScreenCapture_SetErrorCallback(capture_, &CaptureSession::OnScError, this);
    OH_AVScreenCapture_SetStateCallback(capture_, &CaptureSession::OnScStateChange, this);

    auto err = OH_AVScreenCapture_Init(capture_, screenCfg);
    if (err != AV_SCREEN_CAPTURE_ERR_OK) {
        OH_LOG_WARN(LOG_APP, "screen capture init failed: %{public}d", err);
        return false;
    }
    err = OH_AVScreenCapture_StartScreenCaptureWithSurface(capture_, window_);
    if (err != AV_SCREEN_CAPTURE_ERR_OK) {
        OH_LOG_WARN(LOG_APP, "start capture(surface) failed: %{public}d", err);
        return false;
    }
    return true;
}

bool CaptureSession::StartRaw() {
    capture_ = OH_AVScreenCapture_Create();
    if (capture_ == nullptr) {
        OH_LOG_ERROR(LOG_APP, "OH_AVScreenCapture_Create failed");
        return false;
    }

    OH_AVScreenCaptureConfig screenCfg{};
    screenCfg.captureMode = OH_CAPTURE_HOME_SCREEN;
    screenCfg.dataType = OH_ORIGINAL_STREAM;
    screenCfg.videoInfo.videoCapInfo.videoFrameWidth = cfg_.width;
    screenCfg.videoInfo.videoCapInfo.videoFrameHeight = cfg_.height;
    screenCfg.videoInfo.videoCapInfo.videoSource = OH_VIDEO_SOURCE_SURFACE_RGBA;
    screenCfg.audioInfo.micCapInfo.audioSampleRate = 0;
    screenCfg.audioInfo.micCapInfo.audioChannels = 0;
    screenCfg.audioInfo.innerCapInfo.audioSampleRate = 0;
    screenCfg.audioInfo.innerCapInfo.audioChannels = 0;

    // 与 H264 路径对齐：先 SetMic / SetErrorCb / SetStateCb / SetCallback，再 Init，再 Start。
    // OH 的某些版本上回调注册必须早于 Init，否则首帧后回调链路被吞。
    OH_AVScreenCapture_SetMicrophoneEnabled(capture_, false);
    OH_AVScreenCapture_SetErrorCallback(capture_, &CaptureSession::OnScError, this);
    OH_AVScreenCapture_SetStateCallback(capture_, &CaptureSession::OnScStateChange, this);

    OH_AVScreenCaptureCallback cb{};
    cb.onError = nullptr;
    cb.onAudioBufferAvailable = nullptr;
    cb.onVideoBufferAvailable = &CaptureSession::OnScVideoBuffer;
    OH_AVScreenCapture_SetCallback(capture_, cb);

    auto err = OH_AVScreenCapture_Init(capture_, screenCfg);
    if (err != AV_SCREEN_CAPTURE_ERR_OK) {
        OH_LOG_ERROR(LOG_APP, "RAW capture init failed: %{public}d", err);
        return false;
    }

    err = OH_AVScreenCapture_StartScreenCapture(capture_);
    if (err != AV_SCREEN_CAPTURE_ERR_OK) {
        OH_LOG_ERROR(LOG_APP, "RAW capture start failed: %{public}d", err);
        return false;
    }
    return true;
}

void CaptureSession::Stop() {
    // 1. 先打 stopping 标志，让回调拿到旗子后立即短路返回（即便 mu_ 被持有）。
    bool wasStopping = stopping_.exchange(true);
    (void)wasStopping;

    // 2. 取出指针并清空，让任何还没排队的回调拿不到 capture_/encoder_。
    OH_AVScreenCapture *c = nullptr;
    OH_AVCodec *enc = nullptr;
    int32_t mode = kCodecH264;
    {
        std::lock_guard<std::mutex> g(mu_);
        c = capture_;
        capture_ = nullptr;
        enc = encoder_;
        encoder_ = nullptr;
        window_ = nullptr;
        mode = mode_;
    }

    // 3. 先停掉源（截屏），让 surface/RGBA buffer 不再产生新帧。
    if (c != nullptr) {
        auto ret = OH_AVScreenCapture_StopScreenCapture(c);
        OH_LOG_INFO(LOG_APP, "Stop: StopScreenCapture ret=%{public}d", ret);
    }

    // 4. 再停编码器：Flush + Stop 让排队中的输出回调走完；然后在 callback_mu_ 内串行化等待。
    if (enc != nullptr) {
        OH_VideoEncoder_Flush(enc);
        OH_VideoEncoder_Stop(enc);
    }
    {
        // 拿到 callback_mu_ 即代表当前没有回调正在临界区里访问对象，可以放心销毁。
        std::lock_guard<std::mutex> cg(callback_mu_);
    }

    // 5. 释放资源（编码器先 Destroy，再 Release 截屏）。
    if (enc != nullptr) {
        OH_VideoEncoder_Destroy(enc);
    }
    if (c != nullptr) {
        OH_AVScreenCapture_Release(c);
    }
    // ImagePacker / PackingOptions 在 Stop 时统一释放，下次 Start 重新创建。
    if (packingOptions_ != nullptr) {
        OH_PackingOptions_Release(packingOptions_);
        packingOptions_ = nullptr;
    }
    if (imagePacker_ != nullptr) {
        OH_ImagePackerNative_Release(imagePacker_);
        imagePacker_ = nullptr;
    }
    rawBuf_.clear();
    rawBuf_.shrink_to_fit();
    jpegBuf_.clear();
    jpegBuf_.shrink_to_fit();

    OH_LOG_INFO(LOG_APP, "capture stopped (mode=%{public}d)", mode);
    TcpServer::Instance().ClearVideoConfig();
}

// ----- H264 callbacks -----

void CaptureSession::OnEncOutput(OH_AVCodec * /*codec*/, uint32_t index, OH_AVBuffer *buffer, void *userData) {
    auto *self = static_cast<CaptureSession *>(userData);
    if (self == nullptr || self->stopping_.load()) return;
    // callback_mu_ 串行化所有 encoder 回调，与 Stop 同步。
    std::lock_guard<std::mutex> cg(self->callback_mu_);
    if (self->stopping_.load()) return;
    self->HandleEncodedOutput(index, buffer);
}
void CaptureSession::OnEncInput(OH_AVCodec *, uint32_t, OH_AVBuffer *, void *) {}
void CaptureSession::OnEncStreamChanged(OH_AVCodec *, OH_AVFormat *format, void *userData) {
    int32_t w = 0, h = 0;
    OH_AVFormat_GetIntValue(format, OH_MD_KEY_WIDTH, &w);
    OH_AVFormat_GetIntValue(format, OH_MD_KEY_HEIGHT, &h);
    OH_LOG_INFO(LOG_APP, "encoder stream changed %{public}dx%{public}d", w, h);
    if (w > 0 && h > 0) {
        auto *self = static_cast<CaptureSession *>(userData);
        if (self != nullptr) {
            std::lock_guard<std::mutex> g(self->mu_);
            self->cfg_.width = w;
            self->cfg_.height = h;
            self->configEmitted_ = false;
        }
    }
}
void CaptureSession::OnEncError(OH_AVCodec *, int32_t errorCode, void * /*userData*/) {
    OH_LOG_ERROR(LOG_APP, "encoder error: %{public}d", errorCode);
}
void CaptureSession::OnScError(OH_AVScreenCapture *, int32_t errorCode, void * /*userData*/) {
    OH_LOG_ERROR(LOG_APP, "screen capture error: %{public}d", errorCode);
}
void CaptureSession::OnScStateChange(OH_AVScreenCapture *, OH_AVScreenCaptureStateCode stateCode, void * /*userData*/) {
    OH_LOG_INFO(LOG_APP, "screen capture state=%{public}d", static_cast<int32_t>(stateCode));
}

void CaptureSession::HandleEncodedOutput(uint32_t index, OH_AVBuffer *buffer) {
    OH_AVCodecBufferAttr attr{};
    if (OH_AVBuffer_GetBufferAttr(buffer, &attr) != AV_ERR_OK) {
        OH_VideoEncoder_FreeOutputBuffer(encoder_, index);
        return;
    }
    uint8_t *addr = OH_AVBuffer_GetAddr(buffer);
    if (addr == nullptr || attr.size <= 0) {
        OH_VideoEncoder_FreeOutputBuffer(encoder_, index);
        return;
    }
    const uint8_t *data = addr + attr.offset;
    int32_t size = attr.size;
    bool isCodecData = (attr.flags & AVCODEC_BUFFER_FLAGS_CODEC_DATA) != 0;
    bool isKey = (attr.flags & AVCODEC_BUFFER_FLAGS_SYNC_FRAME) != 0;

    if (isCodecData) {
        std::vector<uint8_t> sps, pps;
        if (ParseSpsPps(data, size, sps, pps)) {
            std::lock_guard<std::mutex> g(mu_);
            sps_ = std::move(sps);
            pps_ = std::move(pps);
        }
    } else {
        if (isKey && (sps_.empty() || pps_.empty())) {
            std::vector<uint8_t> sps, pps;
            if (ParseSpsPps(data, size, sps, pps)) {
                std::lock_guard<std::mutex> g(mu_);
                if (sps_.empty()) sps_ = std::move(sps);
                if (pps_.empty()) pps_ = std::move(pps);
            }
        }
        bool needConfig = false;
        std::vector<uint8_t> spsCopy, ppsCopy;
        {
            std::lock_guard<std::mutex> g(mu_);
            if (!configEmitted_ && !sps_.empty() && !pps_.empty()) {
                configEmitted_ = true;
                needConfig = true;
                spsCopy = sps_;
                ppsCopy = pps_;
            }
        }
        if (needConfig) {
            SendH264Config(spsCopy, ppsCopy);
        }
        SendVideoFrame(isKey, attr.pts, data, static_cast<size_t>(size));
    }
    OH_VideoEncoder_FreeOutputBuffer(encoder_, index);
}

bool CaptureSession::ParseSpsPps(const uint8_t *data, int32_t size,
                                 std::vector<uint8_t> &sps,
                                 std::vector<uint8_t> &pps) const {
    int32_t i = 0;
    auto findStart = [&](int32_t pos, int32_t &headerLen) -> int32_t {
        for (int32_t p = pos; p + 3 < size; ++p) {
            if (data[p] == 0 && data[p + 1] == 0 && data[p + 2] == 0 && data[p + 3] == 1) {
                headerLen = 4;
                return p;
            }
            if (data[p] == 0 && data[p + 1] == 0 && data[p + 2] == 1) {
                headerLen = 3;
                return p;
            }
        }
        return -1;
    };
    while (i < size) {
        int32_t hdr = 0;
        int32_t start = findStart(i, hdr);
        if (start < 0) break;
        int32_t payloadStart = start + hdr;
        int32_t nextHdr = 0;
        int32_t next = findStart(payloadStart, nextHdr);
        int32_t payloadEnd = (next < 0) ? size : next;
        if (payloadStart >= payloadEnd) {
            i = payloadEnd;
            continue;
        }
        uint8_t nalType = data[payloadStart] & 0x1F;
        if (nalType == 7 && sps.empty()) {
            sps.assign(data + payloadStart, data + payloadEnd);
        } else if (nalType == 8 && pps.empty()) {
            pps.assign(data + payloadStart, data + payloadEnd);
        }
        i = payloadEnd;
        if (!sps.empty() && !pps.empty()) break;
    }
    return !sps.empty() && !pps.empty();
}

// ----- RAW path -----

void CaptureSession::OnScVideoBuffer(OH_AVScreenCapture * /*capture*/, bool isReady) {
    if (!isReady) return;
    auto &self = CaptureSession::Instance();
    if (self.stopping_.load()) return;
    self.HandleRawBufferAvailable();
}

void CaptureSession::HandleRawBufferAvailable() {
    int64_t now = std::chrono::duration_cast<std::chrono::milliseconds>(
                      std::chrono::steady_clock::now().time_since_epoch()).count();
    int32_t fps = cfg_.frameRate > 0 ? cfg_.frameRate : kRawFrameRate;
    int64_t minInterval = 1000 / fps;
    int64_t prev = lastRawEmitMs_.load();
    bool drop = (prev != 0) && (now - prev < minInterval);

    OH_AVScreenCapture *cap;
    {
        std::lock_guard<std::mutex> g(mu_);
        cap = capture_;
    }
    if (cap == nullptr) return;

    // OH 契约：isReady=true 后必须 Acquire+Release 各一次释放槽位，
    // 否则系统判定消费者未消费完，不再触发后续 OnScVideoBuffer 回调。
    // 因此即使要丢帧（限速 / 无客户端），也要先 Acquire 再 Release，绝不能 Release without Acquire。
    OH_Rect region{};
    int32_t fence = -1;
    int64_t timestamp = 0;
    OH_NativeBuffer *buf = OH_AVScreenCapture_AcquireVideoBuffer(cap, &fence, &timestamp, &region);
    if (buf == nullptr) return;

    bool skip = !TcpServer::Instance().HasClients() || drop ||
                encoder_paused_.load(std::memory_order_relaxed);
    if (skip) {
        OH_AVScreenCapture_ReleaseVideoBuffer(cap);
        return;
    }
    lastRawEmitMs_.store(now);

    OH_NativeBuffer_Config bcfg{};
    OH_NativeBuffer_GetConfig(buf, &bcfg);

    void *virAddr = nullptr;
    if (OH_NativeBuffer_Map(buf, &virAddr) != 0 || virAddr == nullptr) {
        OH_AVScreenCapture_ReleaseVideoBuffer(cap);
        return;
    }

    int32_t width = bcfg.width;
    int32_t height = bcfg.height;
    int32_t stride = bcfg.stride > 0 ? bcfg.stride : width * 4;

    // Emit config if dimensions changed or first time.
    bool needCfg = !configEmitted_ || width != cfg_.width || height != cfg_.height;
    if (needCfg) {
        OH_LOG_INFO(LOG_APP, "RAW/JPEG sending config codec=%{public}d w=%{public}d h=%{public}d",
                    mode_, width, height);
        SendRawConfig(mode_, width, height);
        configEmitted_ = true;
    }

    // Strip row padding: buffer stride may exceed width*4.
    size_t packedSize = static_cast<size_t>(width) * static_cast<size_t>(height) * 4;
    rawBuf_.resize(packedSize);
    uint8_t *src = static_cast<uint8_t *>(virAddr);
    int32_t rowBytes = width * 4;
    for (int32_t y = 0; y < height; ++y) {
        std::memcpy(rawBuf_.data() + y * rowBytes, src + y * stride, rowBytes);
    }

    if (mode_ == kCodecJpeg) {
        // 编码失败时退回发送原始 RGBA，避免画面冻结。
        if (EncodeJpeg(rawBuf_.data(), width, height, jpegBuf_)) {
            SendVideoFrame(true, timestamp, jpegBuf_.data(), jpegBuf_.size());
        } else {
            OH_LOG_WARN(LOG_APP, "EncodeJpeg failed, falling back to RAW frame");
            SendVideoFrame(true, timestamp, rawBuf_.data(), rawBuf_.size());
        }
    } else {
        SendVideoFrame(true, timestamp, rawBuf_.data(), rawBuf_.size());
    }

    OH_NativeBuffer_Unmap(buf);
    OH_AVScreenCapture_ReleaseVideoBuffer(cap);
}

bool CaptureSession::EncodeJpeg(const uint8_t *rgba, int32_t width, int32_t height,
                                std::vector<uint8_t> &out) {
    if (imagePacker_ == nullptr || packingOptions_ == nullptr) return false;

    OH_Pixelmap_InitializationOptions *pmOpts = nullptr;
    if (OH_PixelmapInitializationOptions_Create(&pmOpts) != IMAGE_SUCCESS || pmOpts == nullptr) {
        return false;
    }
    OH_PixelmapInitializationOptions_SetWidth(pmOpts, static_cast<uint32_t>(width));
    OH_PixelmapInitializationOptions_SetHeight(pmOpts, static_cast<uint32_t>(height));
    // 截屏 source 是 SURFACE_RGBA，对应 PIXEL_FORMAT_RGBA_8888。
    OH_PixelmapInitializationOptions_SetPixelFormat(pmOpts, PIXEL_FORMAT_RGBA_8888);
    OH_PixelmapInitializationOptions_SetSrcPixelFormat(pmOpts, PIXEL_FORMAT_RGBA_8888);

    OH_PixelmapNative *pm = nullptr;
    size_t dataLen = static_cast<size_t>(width) * static_cast<size_t>(height) * 4;
    auto err = OH_PixelmapNative_CreatePixelmap(const_cast<uint8_t *>(rgba), dataLen, pmOpts, &pm);
    OH_PixelmapInitializationOptions_Release(pmOpts);
    if (err != IMAGE_SUCCESS || pm == nullptr) {
        OH_LOG_WARN(LOG_APP, "CreatePixelmap failed: %{public}d", static_cast<int32_t>(err));
        return false;
    }

    // 预估 JPEG 体积上限：RGBA 总字节的 1/4 + 64KB 头/EOI 余量；超出会重试一次。
    size_t cap = dataLen / 4 + 65536;
    out.resize(cap);
    size_t outSize = out.size();
    err = OH_ImagePackerNative_PackToDataFromPixelmap(imagePacker_, packingOptions_, pm,
                                                     out.data(), &outSize);
    if (err != IMAGE_SUCCESS) {
        // 缓冲不足：再放大重试一次。
        out.resize(dataLen);
        outSize = out.size();
        err = OH_ImagePackerNative_PackToDataFromPixelmap(imagePacker_, packingOptions_, pm,
                                                         out.data(), &outSize);
    }
    OH_PixelmapNative_Release(pm);
    if (err != IMAGE_SUCCESS) {
        OH_LOG_WARN(LOG_APP, "PackToDataFromPixelmap failed: %{public}d", static_cast<int32_t>(err));
        out.clear();
        return false;
    }
    out.resize(outSize);
    return true;
}

// ----- Send helpers -----

void CaptureSession::SendH264Config(const std::vector<uint8_t> &sps, const std::vector<uint8_t> &pps) {
    size_t total = 1 + 12 + 2 + sps.size() + 2 + pps.size();
    std::vector<uint8_t> p(total);
    size_t off = 0;
    p[off++] = static_cast<uint8_t>(kCodecH264);
    auto putU32 = [&](uint32_t v) {
        p[off++] = (v >> 24) & 0xFF; p[off++] = (v >> 16) & 0xFF;
        p[off++] = (v >> 8) & 0xFF; p[off++] = v & 0xFF;
    };
    auto putU16 = [&](uint16_t v) {
        p[off++] = (v >> 8) & 0xFF; p[off++] = v & 0xFF;
    };
    putU32(static_cast<uint32_t>(cfg_.width));
    putU32(static_cast<uint32_t>(cfg_.height));
    putU32(static_cast<uint32_t>(cfg_.frameRate));
    putU16(static_cast<uint16_t>(sps.size()));
    if (!sps.empty()) { memcpy(p.data() + off, sps.data(), sps.size()); off += sps.size(); }
    putU16(static_cast<uint16_t>(pps.size()));
    if (!pps.empty()) { memcpy(p.data() + off, pps.data(), pps.size()); off += pps.size(); }
    TcpServer::Instance().SetVideoConfig(p.data(), p.size());
}

void CaptureSession::SendRawConfig(int32_t codec, int32_t width, int32_t height) {
    size_t total = 1 + 12;
    std::vector<uint8_t> p(total);
    size_t off = 0;
    p[off++] = static_cast<uint8_t>(codec);
    auto putU32 = [&](uint32_t v) {
        p[off++] = (v >> 24) & 0xFF; p[off++] = (v >> 16) & 0xFF;
        p[off++] = (v >> 8) & 0xFF; p[off++] = v & 0xFF;
    };
    putU32(static_cast<uint32_t>(width));
    putU32(static_cast<uint32_t>(height));
    putU32(static_cast<uint32_t>(cfg_.frameRate));
    TcpServer::Instance().SetVideoConfig(p.data(), p.size());
}

void CaptureSession::SendVideoFrame(bool keyframe, int64_t ptsUs, const uint8_t *nal, size_t size) {
    // 直接构建完整的 videoFrame payload（flags+pts+data），作为一次 alloc 传给 TcpServer。
    // 相比原来先组 p 再让 EncodeFrame 再包一层，节省一次 vector 分配和 memcpy。
    std::vector<uint8_t> p(9 + size);
    p[0] = keyframe ? 1 : 0;
    uint64_t pts = static_cast<uint64_t>(ptsUs);
    for (int i = 0; i < 8; ++i) p[1 + i] = (pts >> (56 - i * 8)) & 0xFF;
    if (size > 0) memcpy(p.data() + 9, nal, size);
    static std::atomic<int64_t> frameCount{0};
    int64_t n = ++frameCount;
    if (n <= 3 || n % 30 == 0) {
        OH_LOG_INFO(LOG_APP, "frame #%{public}ld size=%zu key=%d", (long)n, size, keyframe ? 1 : 0);
    }
    TcpServer::Instance().BroadcastVideoFrame(p.data(), p.size());
}

} // namespace

bool StartCapture(const CaptureConfig &cfg) {
    return CaptureSession::Instance().Start(cfg);
}

void StopCapture() {
    CaptureSession::Instance().Stop();
}

void SetEncoderPaused(bool paused) {
    CaptureSession::Instance().SetPaused(paused);
}

bool ProbeScreenCapture(const CaptureConfig &cfg) {
    auto *probe = OH_AVScreenCapture_Create();
    if (probe == nullptr) {
        OH_LOG_WARN(LOG_APP, "ProbeScreenCapture: Create failed");
        return false;
    }
    OH_AVScreenCaptureConfig probeCfg{};
    probeCfg.captureMode = OH_CAPTURE_HOME_SCREEN;
    probeCfg.dataType = OH_ORIGINAL_STREAM;
    probeCfg.videoInfo.videoCapInfo.videoFrameWidth = cfg.width;
    probeCfg.videoInfo.videoCapInfo.videoFrameHeight = cfg.height;
    probeCfg.videoInfo.videoCapInfo.videoSource = OH_VIDEO_SOURCE_SURFACE_RGBA;
    OH_AVScreenCapture_SetMicrophoneEnabled(probe, false);
    auto err = OH_AVScreenCapture_Init(probe, probeCfg);
    if (err != AV_SCREEN_CAPTURE_ERR_OK) {
        OH_AVScreenCapture_Release(probe);
        OH_LOG_WARN(LOG_APP, "ProbeScreenCapture: Init failed: %{public}d", err);
        return false;
    }
    err = OH_AVScreenCapture_StartScreenCapture(probe);
    OH_AVScreenCapture_StopScreenCapture(probe);
    OH_AVScreenCapture_Release(probe);
    if (err != AV_SCREEN_CAPTURE_ERR_OK) {
        OH_LOG_WARN(LOG_APP, "ProbeScreenCapture: Start failed: %{public}d", err);
        return false;
    }
    OH_LOG_INFO(LOG_APP, "ProbeScreenCapture: OK");
    return true;
}

} // namespace scrcpy
