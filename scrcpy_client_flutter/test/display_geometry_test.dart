import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:scrcpy_client_flutter/display/display_geometry.dart';
import 'package:scrcpy_client_flutter/net/protocol.dart';

void main() {
  test('显示信息按大端序解析并严格校验', () {
    final body = Uint8List(9);
    final view = ByteData.sublistView(body);
    view.setUint32(0, 1280, Endian.big);
    view.setUint32(4, 800, Endian.big);
    view.setUint8(8, 3);

    final info = DisplayInfo.parse(body);

    expect(info.logicalWidth, 1280);
    expect(info.logicalHeight, 800);
    expect(info.rotation, 3);
    expect(() => DisplayInfo.parse(Uint8List(8)), throwsFormatException);

    body[8] = 4;
    expect(() => DisplayInfo.parse(body), throwsFormatException);

    view.setUint32(0, 0, Endian.big);
    body[8] = 0;
    expect(() => DisplayInfo.parse(body), throwsFormatException);
  });

  test('四种 rotation 映射为确定的 Texture 旋转和有效尺寸', () {
    expect(DisplayGeometry.quarterTurns(0), 0);
    expect(DisplayGeometry.quarterTurns(1), 1);
    expect(DisplayGeometry.quarterTurns(2), 2);
    expect(DisplayGeometry.quarterTurns(3), 3);
    expect(
      DisplayGeometry.effectiveSize(720, 1152, 0),
      const PixelSize(720, 1152),
    );
    expect(
      DisplayGeometry.effectiveSize(720, 1152, 1),
      const PixelSize(1152, 720),
    );
    expect(
      DisplayGeometry.effectiveSize(720, 1152, 2),
      const PixelSize(720, 1152),
    );
    expect(
      DisplayGeometry.effectiveSize(720, 1152, 3),
      const PixelSize(1152, 720),
    );
  });

  test('连接默认分辨率区分 USB、TCP 和缩放比例', () {
    const display = DisplayInfo(
      logicalWidth: 1280,
      logicalHeight: 800,
      rotation: 3,
    );

    expect(DisplayGeometry.defaultMaxShort(display, isWifi: false), 800);
    expect(DisplayGeometry.defaultMaxShort(display, isWifi: true), 720);
    expect(
      DisplayGeometry.scalePercent(const PixelSize(1152, 720), display),
      90,
    );
    expect(
      DisplayGeometry.scalePercent(const PixelSize(1152, 700), display),
      isNull,
    );
  });
}
