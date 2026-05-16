// 协议帧格式: 4B type | 4B length(BE) | payload
import util from '@ohos.util';

export class PacketType {
  static readonly HEARTBEAT: number = 0x01;
  static readonly VIDEO_CONFIG: number = 0x02;
  static readonly VIDEO_FRAME: number = 0x03;
  static readonly CONTROL: number = 0x10;
  static readonly DEVICE_STATUS: number = 0x20;
}

export class ControlSubType {
  static readonly TOUCH_DOWN: number = 0x01;
  static readonly TOUCH_MOVE: number = 0x02;
  static readonly TOUCH_UP: number = 0x03;
  static readonly MOUSE_EVENT: number = 0x04;     // 鼠标右键 / 滚轮
  static readonly KEY: number = 0x10;
  static readonly POWER_KEY: number = 0x11;
  static readonly HOME_KEY: number = 0x12;
  static readonly BACK_KEY: number = 0x13;
  static readonly KEY_EVENT: number = 0x14;       // 实时按键转发
  static readonly TEXT_INPUT: number = 0x15;      // 文本输入（UTF-8）
  static readonly VOLUME_UP: number = 0x20;
  static readonly VOLUME_DOWN: number = 0x21;
  static readonly BRIGHTNESS_UP: number = 0x22;
  static readonly BRIGHTNESS_DOWN: number = 0x23;
  static readonly LIST_APPS: number = 0x30;
  static readonly PAUSE_ENCODER: number = 0x40;
  static readonly RESUME_ENCODER: number = 0x41;
  static readonly CHANGE_VIDEO_PARAMS: number = 0x42;
}

export class DeviceStatusSubType {
  static readonly APP_LIST: number = 0x10;
}

export interface AppEntry {
  bundle: string;
  label: string;
}

// AppList payload (subType 已剥离):
//   count(2 BE) + N×{ bundleLen(2 BE) + bundle(UTF-8) + labelLen(2 BE) + label(UTF-8) }
export function encodeAppList(entries: AppEntry[]): Uint8Array {
  const enc = new util.TextEncoder();
  const bundles: Uint8Array[] = [];
  const labels: Uint8Array[] = [];
  let bodyLen = 2;
  const count = Math.min(entries.length, 1024);
  for (let i = 0; i < count; i++) {
    const b = enc.encodeInto(entries[i].bundle);
    const l = enc.encodeInto(entries[i].label);
    bundles.push(b);
    labels.push(l);
    bodyLen += 2 + b.byteLength + 2 + l.byteLength;
  }
  const buf = new ArrayBuffer(1 + bodyLen);
  const view = new DataView(buf);
  view.setUint8(0, DeviceStatusSubType.APP_LIST);
  view.setUint16(1, count, false);
  let offset = 3;
  for (let i = 0; i < count; i++) {
    const b = bundles[i];
    const l = labels[i];
    view.setUint16(offset, b.byteLength, false);
    offset += 2;
    new Uint8Array(buf, offset, b.byteLength).set(b);
    offset += b.byteLength;
    view.setUint16(offset, l.byteLength, false);
    offset += 2;
    new Uint8Array(buf, offset, l.byteLength).set(l);
    offset += l.byteLength;
  }
  return new Uint8Array(buf);
}

export interface ParsedPacket {
  type: number;
  payload: Uint8Array;
}

export function encodePacket(type: number, payload: Uint8Array): ArrayBuffer {
  const len = payload.byteLength;
  const buf = new ArrayBuffer(8 + len);
  const view = new DataView(buf);
  view.setUint32(0, type, false);
  view.setUint32(4, len, false);
  new Uint8Array(buf, 8, len).set(payload);
  return buf;
}

// 视频配置 payload: codec(1) width(4) height(4) fps(4) spsLen(2) sps ppsLen(2) pps
// codec: 0 = H264 Annex-B, 1 = raw RGBA, 2 = JPEG（sps/pps 长度均为 0）
export class VideoCodec {
  static readonly H264: number = 0;
  static readonly RAW_RGBA: number = 1;
  static readonly JPEG: number = 2;
}

export function encodeVideoConfig(codec: number, width: number, height: number, fps: number,
                                  sps: Uint8Array, pps: Uint8Array): Uint8Array {
  const total = 1 + 12 + 2 + sps.byteLength + 2 + pps.byteLength;
  const buf = new ArrayBuffer(total);
  const view = new DataView(buf);
  view.setUint8(0, codec);
  view.setUint32(1, width, false);
  view.setUint32(5, height, false);
  view.setUint32(9, fps, false);
  let offset = 13;
  view.setUint16(offset, sps.byteLength, false);
  offset += 2;
  new Uint8Array(buf, offset, sps.byteLength).set(sps);
  offset += sps.byteLength;
  view.setUint16(offset, pps.byteLength, false);
  offset += 2;
  new Uint8Array(buf, offset, pps.byteLength).set(pps);
  return new Uint8Array(buf);
}

// 视频帧 payload: flags(1) pts(8) nal(...)
export function encodeVideoFrame(isKeyframe: boolean, ptsMs: bigint, nal: Uint8Array): Uint8Array {
  const buf = new ArrayBuffer(9 + nal.byteLength);
  const view = new DataView(buf);
  view.setUint8(0, isKeyframe ? 1 : 0);
  view.setBigUint64(1, ptsMs, false);
  new Uint8Array(buf, 9, nal.byteLength).set(nal);
  return new Uint8Array(buf);
}

// 简易解析器：从客户端 socket 收到的字节流中循环切包
export class PacketParser {
  private buffer: Uint8Array = new Uint8Array(0);

  feed(chunk: ArrayBuffer): ParsedPacket[] {
    const incoming = new Uint8Array(chunk);
    const merged = new Uint8Array(this.buffer.byteLength + incoming.byteLength);
    merged.set(this.buffer, 0);
    merged.set(incoming, this.buffer.byteLength);
    this.buffer = merged;

    const packets: ParsedPacket[] = [];
    while (this.buffer.byteLength >= 8) {
      const view = new DataView(this.buffer.buffer, this.buffer.byteOffset, this.buffer.byteLength);
      const type = view.getUint32(0, false);
      const len = view.getUint32(4, false);
      if (this.buffer.byteLength < 8 + len) {
        break;
      }
      const payload = this.buffer.slice(8, 8 + len);
      packets.push({ type: type, payload: payload });
      this.buffer = this.buffer.slice(8 + len);
    }
    return packets;
  }
}
