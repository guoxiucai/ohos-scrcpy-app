#include "ScreenCaptureEncoder.h"
#include "TcpServer.h"
#include "napi/native_api.h"
#include <hilog/log.h>
#include <cstdint>

#undef LOG_DOMAIN
#undef LOG_TAG
#define LOG_DOMAIN 0xA000
#define LOG_TAG "ScrcpyNapi"

static bool GetIntProp(napi_env env, napi_value obj, const char *key, int32_t *out) {
    napi_value v;
    if (napi_get_named_property(env, obj, key, &v) != napi_ok) return false;
    return napi_get_value_int32(env, v, out) == napi_ok;
}

static napi_value StartServer(napi_env env, napi_callback_info info) {
    OH_LOG_INFO(LOG_APP, "StartServer enter");
    size_t argc = 4;
    napi_value args[4] = {nullptr};
    napi_get_cb_info(env, info, &argc, args, nullptr, nullptr);

    napi_value boolFalse;
    napi_get_boolean(env, false, &boolFalse);
    if (argc < 4) {
        OH_LOG_ERROR(LOG_APP, "StartServer argc=%{public}zu", argc);
        return boolFalse;
    }

    int32_t port = 0;
    if (napi_get_value_int32(env, args[0], &port) != napi_ok) {
        OH_LOG_ERROR(LOG_APP, "StartServer port not int");
        return boolFalse;
    }

    scrcpy::CaptureConfig cfg{};
    if (!GetIntProp(env, args[1], "width", &cfg.width)) { OH_LOG_ERROR(LOG_APP, "missing width"); return boolFalse; }
    if (!GetIntProp(env, args[1], "height", &cfg.height)) { OH_LOG_ERROR(LOG_APP, "missing height"); return boolFalse; }
    if (!GetIntProp(env, args[1], "frameRate", &cfg.frameRate)) { OH_LOG_ERROR(LOG_APP, "missing frameRate"); return boolFalse; }
    if (!GetIntProp(env, args[1], "bitrate", &cfg.bitrate)) { OH_LOG_ERROR(LOG_APP, "missing bitrate"); return boolFalse; }
    int32_t q = 70;
    GetIntProp(env, args[1], "jpegQuality", &q);
    cfg.jpegQuality = q;

    OH_LOG_INFO(LOG_APP, "StartServer port=%{public}d %{public}dx%{public}d", port, cfg.width, cfg.height);

    napi_value onPresence = args[2];
    napi_value onControl = args[3];

    bool ok = scrcpy::TcpServer::Instance().Start(env, port, onPresence, onControl);
    OH_LOG_INFO(LOG_APP, "StartServer result=%{public}d", ok ? 1 : 0);
    napi_value out;
    napi_get_boolean(env, ok, &out);
    return out;
}

static napi_value StopServer(napi_env env, napi_callback_info /*info*/) {
    scrcpy::StopCapture();
    scrcpy::TcpServer::Instance().Stop();
    napi_value undef;
    napi_get_undefined(env, &undef);
    return undef;
}

static napi_value StartCaptureJs(napi_env env, napi_callback_info info) {
    size_t argc = 1;
    napi_value args[1] = {nullptr};
    napi_get_cb_info(env, info, &argc, args, nullptr, nullptr);
    napi_value boolFalse;
    napi_get_boolean(env, false, &boolFalse);
    if (argc < 1) return boolFalse;
    scrcpy::CaptureConfig cfg{};
    if (!GetIntProp(env, args[0], "width", &cfg.width)) return boolFalse;
    if (!GetIntProp(env, args[0], "height", &cfg.height)) return boolFalse;
    if (!GetIntProp(env, args[0], "frameRate", &cfg.frameRate)) return boolFalse;
    if (!GetIntProp(env, args[0], "bitrate", &cfg.bitrate)) return boolFalse;
    int32_t q = 70;
    GetIntProp(env, args[0], "jpegQuality", &q);
    cfg.jpegQuality = q;
    bool ok = scrcpy::StartCapture(cfg);
    napi_value out;
    napi_get_boolean(env, ok, &out);
    return out;
}

static napi_value StopCaptureJs(napi_env env, napi_callback_info /*info*/) {
    scrcpy::StopCapture();
    napi_value undef;
    napi_get_undefined(env, &undef);
    return undef;
}

static napi_value SetEncoderPausedJs(napi_env env, napi_callback_info info) {
    size_t argc = 1;
    napi_value args[1] = {nullptr};
    napi_get_cb_info(env, info, &argc, args, nullptr, nullptr);
    bool paused = false;
    if (argc >= 1) napi_get_value_bool(env, args[0], &paused);
    scrcpy::SetEncoderPaused(paused);
    napi_value undef;
    napi_get_undefined(env, &undef);
    return undef;
}

static napi_value BroadcastDeviceStatus(napi_env env, napi_callback_info info) {
    size_t argc = 1;
    napi_value args[1] = {nullptr};
    napi_get_cb_info(env, info, &argc, args, nullptr, nullptr);
    napi_value undef;
    napi_get_undefined(env, &undef);
    if (argc < 1) return undef;
    bool isTypedArray = false;
    napi_is_typedarray(env, args[0], &isTypedArray);
    void *data = nullptr;
    size_t length = 0;
    napi_typedarray_type type;
    napi_value arrBuf;
    size_t byteOffset = 0;
    if (isTypedArray) {
        if (napi_get_typedarray_info(env, args[0], &type, &length, &data, &arrBuf, &byteOffset) != napi_ok) {
            return undef;
        }
    } else {
        bool isArrBuf = false;
        napi_is_arraybuffer(env, args[0], &isArrBuf);
        if (!isArrBuf) return undef;
        if (napi_get_arraybuffer_info(env, args[0], &data, &length) != napi_ok) return undef;
    }
    if (data && length > 0) {
        scrcpy::TcpServer::Instance().BroadcastDeviceStatus(
            reinterpret_cast<const uint8_t *>(data), length);
    }
    return undef;
}

static napi_value ProbeScreenCaptureJs(napi_env env, napi_callback_info info) {
    size_t argc = 1;
    napi_value args[1] = {nullptr};
    napi_get_cb_info(env, info, &argc, args, nullptr, nullptr);
    napi_value boolFalse;
    napi_get_boolean(env, false, &boolFalse);
    if (argc < 1) return boolFalse;
    scrcpy::CaptureConfig cfg{};
    if (!GetIntProp(env, args[0], "width", &cfg.width)) return boolFalse;
    if (!GetIntProp(env, args[0], "height", &cfg.height)) return boolFalse;
    cfg.frameRate = 10;
    cfg.bitrate = 4000000;
    cfg.jpegQuality = 60;
    bool ok = scrcpy::ProbeScreenCapture(cfg);
    napi_value out;
    napi_get_boolean(env, ok, &out);
    return out;
}

EXTERN_C_START
static napi_value Init(napi_env env, napi_value exports) {
    napi_property_descriptor desc[] = {
        {"startServer", nullptr, StartServer, nullptr, nullptr, nullptr, napi_default, nullptr},
        {"stopServer", nullptr, StopServer, nullptr, nullptr, nullptr, napi_default, nullptr},
        {"startCapture", nullptr, StartCaptureJs, nullptr, nullptr, nullptr, napi_default, nullptr},
        {"stopCapture", nullptr, StopCaptureJs, nullptr, nullptr, nullptr, napi_default, nullptr},
        {"setEncoderPaused", nullptr, SetEncoderPausedJs, nullptr, nullptr, nullptr, napi_default, nullptr},
        {"broadcastDeviceStatus", nullptr, BroadcastDeviceStatus, nullptr, nullptr, nullptr, napi_default, nullptr},
        {"probeScreenCapture", nullptr, ProbeScreenCaptureJs, nullptr, nullptr, nullptr, napi_default, nullptr},
    };
    napi_define_properties(env, exports, sizeof(desc) / sizeof(desc[0]), desc);
    return exports;
}
EXTERN_C_END

static napi_module captureModule = {
    .nm_version = 1,
    .nm_flags = 0,
    .nm_filename = nullptr,
    .nm_register_func = Init,
    .nm_modname = "scrcpy_capture",
    .nm_priv = ((void *)0),
    .reserved = {0},
};

extern "C" __attribute__((constructor)) void RegisterScrcpyCaptureModule(void) {
    napi_module_register(&captureModule);
}
