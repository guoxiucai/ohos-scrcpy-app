#ifndef SCRCPY_TCP_SERVER_H
#define SCRCPY_TCP_SERVER_H

#include "napi/native_api.h"
#include <atomic>
#include <chrono>
#include <cstdint>
#include <deque>
#include <map>
#include <memory>
#include <mutex>
#include <string>
#include <thread>
#include <vector>

namespace scrcpy {

// Packet header: 4B type | 4B BE length | payload
constexpr uint32_t kPktHeartbeat = 0x01;
constexpr uint32_t kPktVideoConfig = 0x02;
constexpr uint32_t kPktVideoFrame = 0x03;
constexpr uint32_t kPktControl = 0x10;
constexpr uint32_t kPktDeviceStatus = 0x20;

// Callback fired when first client arrives or last client leaves.
using PresenceCallback = void (*)(bool hasClient);

class TcpServer {
public:
    static TcpServer &Instance();

    // Start listening on 127.0.0.1:port. Spawns the IO thread.
    bool Start(napi_env env, int port, napi_value onPresence, napi_value onControl);
    void Stop();

    // Save lastConfig and broadcast to all clients.
    void SetVideoConfig(const uint8_t *payload, size_t size);
    void ClearVideoConfig();
    void BroadcastVideoFrame(const uint8_t *payload, size_t size);
    void BroadcastDeviceStatus(const uint8_t *payload, size_t size);

    bool HasClients();

private:
    TcpServer() = default;
    ~TcpServer() { Stop(); }

    // 发送队列元素改为 shared_ptr：多客户端共享同一份只读帧缓冲，消除 per-client 拷贝。
    using FramePtr = std::shared_ptr<const std::vector<uint8_t>>;

    struct ClientState {
        int fd;
        std::deque<FramePtr> txQueue;
        size_t txOffset = 0; // bytes already sent of txQueue.front()
        // inbound parsing state
        std::vector<uint8_t> rxBuf;
        // 任意 inbound 字节都更新此时间，用于心跳超时检测
        std::chrono::steady_clock::time_point lastRxAt = std::chrono::steady_clock::now();
    };

    void IoLoop();
    void AcceptNew();
    void HandleReadable(ClientState &c, bool &shouldClose);
    void HandleWritable(ClientState &c, bool &shouldClose);
    void CloseClient(int fd, const char *reason);
    void EnqueueAll(FramePtr frame);
    void EnqueueFor(ClientState &c, FramePtr frame);
    void UpdateInterest(int fd, bool wantWrite);
    void OnPacket(ClientState &c, uint32_t type, const uint8_t *payload, size_t size);
    void NotifyPresence(bool hasClient);
    void NotifyControl(uint8_t sub, const uint8_t *body, size_t size);

    static void TsPresenceCb(napi_env env, napi_value cb, void *ctx, void *data);
    static void TsControlCb(napi_env env, napi_value cb, void *ctx, void *data);

    static FramePtr EncodeFrame(uint32_t type, const uint8_t *payload, size_t size);

    std::mutex mu_; // guards clients_, lastConfig_
    std::map<int, ClientState> clients_;
    FramePtr lastConfig_; // shared_ptr，新客户端接入时直接共享，无需拷贝

    int listenFd_ = -1;
    int epollFd_ = -1;
    int wakeRd_ = -1;
    int wakeWr_ = -1;
    std::atomic<bool> running_{false};
    std::thread ioThread_;

    napi_threadsafe_function tsPresence_ = nullptr;
    napi_threadsafe_function tsControl_ = nullptr;

    // Throttle: notify presence transitions only on edges.
    std::atomic<bool> hadClients_{false};
};

} // namespace scrcpy

#endif
