import 'dart:convert';
import 'dart:typed_data';

class PacketType {
  static const int heartbeat = 0x01;
  static const int videoConfig = 0x02;
  static const int videoFrame = 0x03;
  static const int control = 0x10;
  static const int deviceStatus = 0x20;
}

class ControlSubType {
  static const int touchDown = 0x01;
  static const int touchMove = 0x02;
  static const int touchUp = 0x03;
  static const int mouseEvent = 0x04;
  static const int powerKey = 0x11;
  static const int homeKey = 0x12;
  static const int backKey = 0x13;
  static const int key = 0x10;
  static const int keyEvent = 0x14;
  static const int textInput = 0x15;
  static const int volumeUp = 0x20;
  static const int volumeDown = 0x21;
  static const int brightnessUp = 0x22;
  static const int brightnessDown = 0x23;
  static const int listApps = 0x30;
  static const int pauseEncoder  = 0x40;
  static const int resumeEncoder = 0x41;
  static const int changeVideoParams = 0x42;
}

class DeviceStatusSubType {
  static const int appList = 0x10;
}

/// 应用条目（设备端可卸载应用）。
class AppEntry {
  final String bundle;
  final String label;
  const AppEntry({required this.bundle, required this.label});

  String get display => label.isEmpty ? bundle : '$label  ·  $bundle';

  @override
  bool operator ==(Object other) =>
      other is AppEntry && other.bundle == bundle;

  @override
  int get hashCode => bundle.hashCode;
}

/// 解析 0x20/0x10 设备状态包的 AppList payload。
/// payload (subType 已剥离): count(2 BE) + N×{ bundleLen(2 BE) + bundle(UTF-8)
/// + labelLen(2 BE) + label(UTF-8) }
List<AppEntry> parseAppList(Uint8List body) {
  if (body.length < 2) return const [];
  final bd = ByteData.sublistView(body);
  final count = bd.getUint16(0, Endian.big);
  int off = 2;
  final out = <AppEntry>[];
  for (int i = 0; i < count; i++) {
    if (off + 2 > body.length) break;
    final bl = bd.getUint16(off, Endian.big); off += 2;
    if (off + bl > body.length) break;
    final bundle = utf8.decode(body.sublist(off, off + bl), allowMalformed: true);
    off += bl;
    if (off + 2 > body.length) break;
    final ll = bd.getUint16(off, Endian.big); off += 2;
    if (off + ll > body.length) break;
    final label = utf8.decode(body.sublist(off, off + ll), allowMalformed: true);
    off += ll;
    out.add(AppEntry(bundle: bundle, label: label));
  }
  return out;
}

class Packet {
  final int type;
  final Uint8List payload;
  Packet(this.type, this.payload);
}

class VideoCodec {
  static const int h264 = 0;
  static const int rawRgba = 1;
  static const int jpeg = 2;
}

/// 配置包:
/// - H264: codec(1) width(4) height(4) fps(4) spsLen(2) sps ppsLen(2) pps
/// - RAW/JPEG: codec(1) width(4) height(4) fps(4)  — no SPS/PPS
class VideoConfig {
  final int codec;
  final int width;
  final int height;
  final int fps;
  final Uint8List sps;
  final Uint8List pps;
  VideoConfig(this.codec, this.width, this.height, this.fps, this.sps, this.pps);

  static VideoConfig parse(Uint8List payload) {
    final bd = ByteData.sublistView(payload);
    final codec = bd.getUint8(0);
    final w = bd.getUint32(1, Endian.big);
    final h = bd.getUint32(5, Endian.big);
    final fps = bd.getUint32(9, Endian.big);
    // RAW / JPEG 无 SPS/PPS 字段（13 字节定长）。
    if (codec == VideoCodec.rawRgba || codec == VideoCodec.jpeg) {
      return VideoConfig(codec, w, h, fps, Uint8List(0), Uint8List(0));
    }
    int off = 13;
    final spsLen = bd.getUint16(off, Endian.big); off += 2;
    final sps = Uint8List.sublistView(payload, off, off + spsLen); off += spsLen;
    final ppsLen = bd.getUint16(off, Endian.big); off += 2;
    final pps = Uint8List.sublistView(payload, off, off + ppsLen);
    return VideoConfig(codec, w, h, fps, Uint8List.fromList(sps), Uint8List.fromList(pps));
  }
}

/// 视频帧:
/// - H264: payload = flags(1) pts(8) nal(...)
/// - RAW RGBA: payload = flags(1) pts(8) width(4) height(4) RGBA pixels
///   服务端将 width/height 写在 RGBA 数据头部 (header(8) + pixels)，已合并到 nal 字段中。
class VideoFrame {
  final bool keyframe;
  final int ptsMs;
  final Uint8List nal;
  VideoFrame(this.keyframe, this.ptsMs, this.nal);

  static VideoFrame parse(Uint8List payload) {
    final bd = ByteData.sublistView(payload);
    final flags = bd.getUint8(0);
    final pts = bd.getUint64(1, Endian.big);
    final nal = Uint8List.sublistView(payload, 9);
    return VideoFrame((flags & 0x1) != 0, pts, Uint8List.fromList(nal));
  }
}

ByteBuffer encodePacket(int type, Uint8List payload) {
  final buf = Uint8List(8 + payload.length);
  final bd = ByteData.sublistView(buf);
  bd.setUint32(0, type, Endian.big);
  bd.setUint32(4, payload.length, Endian.big);
  buf.setRange(8, 8 + payload.length, payload);
  return buf.buffer;
}

/// 控制包 payload: subType(1) ...rest
Uint8List encodeControl(int subType, Uint8List body) {
  final out = Uint8List(1 + body.length);
  out[0] = subType;
  out.setRange(1, out.length, body);
  return out;
}

/// 触摸事件 body: x(4) y(4) pointerId(2)
Uint8List encodeTouch(double x, double y, int pointerId) {
  final out = Uint8List(10);
  final bd = ByteData.sublistView(out);
  bd.setUint32(0, x.toInt(), Endian.big);
  bd.setUint32(4, y.toInt(), Endian.big);
  bd.setUint16(8, pointerId, Endian.big);
  return out;
}

/// 鼠标事件 body: action(1) button(1) x(4) y(4) axisValue(4 float BE)
Uint8List encodeMouseEvent(int action, int button, double x, double y, double axisValue) {
  final out = Uint8List(14);
  final bd = ByteData.sublistView(out);
  out[0] = action;
  out[1] = button;
  bd.setUint32(2, x.toInt(), Endian.big);
  bd.setUint32(6, y.toInt(), Endian.big);
  bd.setFloat32(10, axisValue, Endian.big);
  return out;
}

/// 按键事件 body: isPressed(1) keyCode(4)
Uint8List encodeKeyEvent(bool isPressed, int keyCode) {
  final out = Uint8List(5);
  final bd = ByteData.sublistView(out);
  out[0] = isPressed ? 1 : 0;
  bd.setUint32(1, keyCode, Endian.big);
  return out;
}

/// 文本输入 body: UTF-8 bytes
Uint8List encodeTextInput(String text) {
  return Uint8List.fromList(utf8.encode(text));
}

/// 视频参数变更 payload: maxShortEdge(4 BE) + bitrate(4 BE) + frameRate(4 BE)
Uint8List encodeVideoParams(int maxShortEdge, int bitrate, int frameRate) {
  final out = Uint8List(12);
  final bd = ByteData.sublistView(out);
  bd.setInt32(0, maxShortEdge, Endian.big);
  bd.setInt32(4, bitrate, Endian.big);
  bd.setInt32(8, frameRate, Endian.big);
  return out;
}

/// 鼠标 action 常量（与 OH MouseEvent.Action 对齐）
class MouseAction {
  static const int buttonDown = 2;
  static const int buttonUp = 3;
  static const int axisUpdate = 5;
}

/// 鼠标 button 常量（与 OH MouseEvent.Button 对齐）
class MouseButton {
  static const int left = 0;
  static const int middle = 1;
  static const int right = 2;
}

/// Flutter LogicalKeyboardKey → OpenHarmony KeyCode 映射
class OhKeyCode {
  static const int a = 2017;
  static const int key0 = 2000;
  static const int dpadUp = 2012;
  static const int dpadDown = 2013;
  static const int dpadLeft = 2014;
  static const int dpadRight = 2015;
  static const int comma = 2043;
  static const int period = 2044;
  static const int altLeft = 2045;
  static const int shiftLeft = 2047;
  static const int shiftRight = 2048;
  static const int tab = 2049;
  static const int space = 2050;
  static const int enter = 2054;
  static const int del = 2055;        // Backspace
  static const int grave = 2056;
  static const int minus = 2057;
  static const int equals = 2058;
  static const int leftBracket = 2059;
  static const int rightBracket = 2060;
  static const int backslash = 2061;
  static const int semicolon = 2062;
  static const int apostrophe = 2063;
  static const int slash = 2064;
  static const int escape = 2070;
  static const int forwardDel = 2071; // Delete
  static const int ctrlLeft = 2072;
  static const int ctrlRight = 2073;
  static const int capsLock = 2074;
  static const int f1 = 2090;
  static const int home = 1;
  static const int back = 2;
}

/// 切包解析器
class PacketParser {
  final BytesBuilder _buf = BytesBuilder(copy: false);

  /// 重置解析状态。断开/重连时必须调用，否则上次连接残留的半包字节会
  /// 与新连接首批字节拼接，导致 type/length 解析错位、整个流被丢弃。
  void reset() {
    _buf.clear();
  }

  Iterable<Packet> feed(Uint8List chunk) sync* {
    _buf.add(chunk);
    while (true) {
      final bytes = _buf.toBytes();
      if (bytes.length < 8) break;
      final bd = ByteData.sublistView(bytes);
      final type = bd.getUint32(0, Endian.big);
      final len = bd.getUint32(4, Endian.big);
      if (bytes.length < 8 + len) break;
      final payload = Uint8List.fromList(bytes.sublist(8, 8 + len));
      yield Packet(type, payload);
      _buf
        ..clear()
        ..add(bytes.sublist(8 + len));
    }
  }
}
