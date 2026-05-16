export interface CaptureConfig {
  width: number;
  height: number;
  frameRate: number;
  bitrate: number;
  jpegQuality: number;
}

export const startServer: (
  port: number,
  cfg: CaptureConfig,
  onPresence: (hasClient: boolean) => void,
  onControl: (sub: number, body: ArrayBuffer) => void,
) => boolean;

export const stopServer: () => void;

export const startCapture: (cfg: CaptureConfig) => boolean;
export const stopCapture: () => void;

export const setEncoderPaused: (paused: boolean) => void;

export const probeScreenCapture: (cfg: CaptureConfig) => boolean;

// 把已编码好的 device-status 帧 (subType + payload) 广播给所有 client。
// 帧格式由 ArkTS 侧的 Protocol.encodeAppList 等函数产出。
export const broadcastDeviceStatus: (payload: Uint8Array | ArrayBuffer) => void;
