# Data Model: ohscrcpy CLI

**Date**: 2026-05-21 | **Branch**: `001-ohscrcpy-cli`

---

## 核心实体

### Device（设备）

```
Device {
  serial: String          // hdc 设备序列号，唯一标识
  state: DeviceState      // 连接状态（见状态机）
}

DeviceState {
  Available,              // hdc list targets 可见
  Connecting,             // fport 建立中 / 服务端安装中
  Streaming,              // 视频流正常接收
  Disconnected,           // USB 断开或 TCP 断连
}
```

### Connection（连接）

```
Connection {
  device_serial: String
  pc_port: u16            // hdc fport 分配的 PC 端口（5000-5099）
  tcp_stream: TcpStream   // 到 127.0.0.1:<pc_port> 的 TCP 连接
  state: ConnectionState
}

ConnectionState {
  Handshaking,            // 等待 0x02 视频配置包
  Active,                 // 正常收帧
  Error(String),          // 错误描述
}
```

### VideoConfig（视频配置，来自协议 0x02 包）

```
VideoConfig {
  width: u32
  height: u32
  fps: u32
  sps: Vec<u8>            // SPS NAL（不含 start code）
  pps: Vec<u8>            // PPS NAL（不含 start code）
}
```

### VideoFrame（视频帧，来自协议 0x03 包）

```
VideoFrame {
  is_keyframe: bool       // flags byte bit0
  pts: u64                // presentation timestamp（单位 us）
  data: Vec<u8>           // Annex-B H.264 NAL units
}
```

### DecodedFrame（解码后帧，送渲染器）

```
DecodedFrame {
  width: u32
  height: u32
  y_plane: Vec<u8>        // I420 Y 分量
  u_plane: Vec<u8>        // I420 U 分量
  v_plane: Vec<u8>        // I420 V 分量
  pts: u64
}
```

### ControlEvent（控制事件，C→S）

```
ControlEvent {
  sub_type: ControlSubType
  body: ControlBody
}

ControlSubType {
  TouchDown  = 0x01
  TouchMove  = 0x02
  TouchUp    = 0x03
  KeyBack    = 0x10       // 右键映射
}

ControlBody {
  Touch { x: f32, y: f32, pointer_id: u16 }  // 归一化坐标 [0.0, 1.0]
  Key { key_code: u32 }
}
```

### AppState（运行期全局状态）

```
AppState {
  device: Device
  config: CliArgs         // 用户传入参数
  video_config: Option<VideoConfig>
  verbose: bool
  shutdown: CancellationToken
}
```

---

## 状态转换

### 主流程状态机

```
[Start]
   │
   ▼
[ListDevices]  ──错误──▶ [PrintErrorExit]
   │
   ▼
[SelectDevice]  ──多设备未指定 -s──▶ [PrintListExit]
   │
   ▼
[CheckServer]  ──未安装──▶ [InstallServer] ──失败──▶ [PrintErrorExit]
   │                              │
   │◀─────────────────────────────┘ 成功
   ▼
[SetupFPort]   ──冲突/失败──▶ [PrintErrorExit]
   │
   ▼
[ConnectTCP]   ──失败──▶ [CleanupFPort] ──▶ [PrintErrorExit]
   │
   ▼
[WaitVideoConfig]  ──超时──▶ [CleanupAll] ──▶ [PrintErrorExit]
   │
   ▼
[Streaming]    ──断连──▶ [CleanupAll] ──▶ [Exit 0]
   │
   ▼（用户关窗口 / Ctrl+C）
[CleanupAll]
   │
   ▼
[Exit 0]
```

### 清理动作（CleanupAll）

1. 关闭 TCP 连接
2. 执行 `hdc -t <sn> fport rm tcp:<pc_port>`
3. 关闭 SDL2 窗口
4. 停止解码 session（VTDecompressionSessionInvalidate）

---

## 协议帧字段映射（Rust 类型）

| 字段 | 类型 | 备注 |
|------|------|------|
| type | `[u8; 4]` | 取 `[0]`，其余为 0 |
| length | `u32` | 大端字节序 |
| payload | `Vec<u8>` | 长度由 `length` 决定 |

### 0x02 视频配置 payload 布局

```
width(4B) height(4B) fps(4B) spsLen(2B) sps(spsLen B) ppsLen(2B) pps(ppsLen B)
```

### 0x03 视频帧 payload 布局

```
flags(1B) pts(8B, BE) nal_data(remaining B, Annex-B)
```

### 0x10 控制 payload 布局

```
sub_type(1B) body(variable)
  Touch: x(4B f32 BE) y(4B f32 BE) pointer_id(2B)
  Key:   key_code(4B BE)
```
