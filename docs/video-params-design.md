# H264 模式码率/分辨率/帧率动态调整设计

## 背景

原有实现中视频参数（分辨率、码率、帧率）在服务端 `onCreate` 时一次性计算，客户端无法动态调整。本方案在 H264 模式下支持用户运行时切换分辨率（两档）和帧率（三档），并按连接类型（USB/WiFi）自动选择默认值。

## 默认值策略

| 场景 | maxShortEdge | bitrate | fps |
|------|-------------|---------|-----|
| USB 首次连接 | 2160 | 8 Mbps | 15 |
| WiFi 首次连接 | 1080 | 4 Mbps | 15 |
| 用户切 1080p | 1080 | 4 Mbps | 保持当前帧率 |
| 用户切 2160p | 2160 | 8 Mbps | 保持当前帧率 |
| 用户切帧率 | 保持当前分辨率档 | 保持当前码率 | 选定值 |

码率跟随分辨率档位联动，不单独暴露给用户。

## 协议扩展

新增 `ControlSubType = 0x42` — `CHANGE_VIDEO_PARAMS`，payload 格式：

| 字段 | 偏移 | 长度 | 说明 |
|------|------|------|------|
| maxShortEdge | 0 | 4B BE | 最短边像素限制（1080 或 2160） |
| bitrate | 4 | 4B BE | 码率 bps |
| frameRate | 8 | 4B BE | 帧率 fps |

## 服务端处理流程

```
客户端发 0x42 → onControl → restartCapture(maxShort, bitrate, fps)
  → stopCapture()          // 释放编码器 + 截屏
  → 按 maxShort 等比缩放屏幕分辨率（与 computeCaptureConfig 逻辑一致）
  → 更新 this.captureCfg
  → startCapture()         // 重建截屏 + 编码器
  → Native 层自动下发新 VideoConfig 帧
```

## 客户端处理流程

```
用户点击状态栏分辨率/帧率 → PopupMenu 选项 → changeVideoParams()
  → 更新 targetMaxShort / targetBitrate / targetFps
  → sendControl(0x42, encodeVideoParams(...))
  → 收到新 VideoConfig → _onPacket 检测变化 → decoder.dispose() + decoder.init()
```

## 限制

- 仅 H264 模式生效；JPEG / RAW 模式下 UI 按钮置灰
- 非连接状态下按钮禁用
- 服务端 `JPEG` 降级路径（API < 12 或不支持 Surface RGBA→NV12）不受影响
