import 'dart:math' as math;

import '../net/protocol.dart';

class PixelSize {
  final int width;
  final int height;

  const PixelSize(this.width, this.height);

  @override
  bool operator ==(Object other) =>
      other is PixelSize && other.width == width && other.height == height;

  @override
  int get hashCode => Object.hash(width, height);
}

class DisplayGeometry {
  static int quarterTurns(int rotation) {
    if (rotation < 0 || rotation > 3) {
      throw RangeError.range(rotation, 0, 3, 'rotation');
    }
    return rotation;
  }

  static PixelSize effectiveSize(int rawWidth, int rawHeight, int rotation) {
    if (rotation.isOdd) {
      return PixelSize(rawHeight, rawWidth);
    }
    return PixelSize(rawWidth, rawHeight);
  }

  static int defaultMaxShort(DisplayInfo display, {required bool isWifi}) {
    final nativeShort = math.min(
      display.logicalWidth,
      display.logicalHeight,
    );
    return isWifi ? math.min(720, nativeShort) : nativeShort;
  }

  static int? scalePercent(PixelSize video, DisplayInfo display) {
    final x = video.width / display.logicalWidth;
    final y = video.height / display.logicalHeight;
    if ((x - y).abs() > 0.01) return null;
    return (math.min(x, y) * 100).round();
  }
}
