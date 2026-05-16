import 'dart:async';
import 'dart:io';
import 'dart:typed_data';

import 'package:flutter/services.dart';

/// 平台原生视频解码/渲染抽象。
///
/// Windows：MethodChannel 'scrcpy/decoder'
///   - H264：优先 D3D11 硬解（GpuSurfaceTexture），失败回落 CPU 软解（PixelBufferTexture）
///   - 回落逻辑在 C++ 插件内部完成，Dart 层无需干预
///
/// macOS：MethodChannel 'scrcpy/decoder'（VideoToolbox）
class VideoDecoder {
  static const _channel = MethodChannel('scrcpy/decoder');

  int? textureId;
  int? width;
  int? height;
  int? codec;

  /// 当前解码路径："d3d11" / "cpu" / "native"
  String? decoderType;

  /// textureId 就绪（或更新）时的回调，由 AppState 设置
  void Function()? onTextureReady;

  /// C++ 背压回调：true=队列高水位（暂停服务端编码），false=低水位（恢复）
  void Function(bool paused)? onEncoderState;

  /// D3D11 路径的轮询定时器（等待首帧纹理就绪）
  Timer? _pollTimer;

  Future<int> init({
    required int codec,
    required int width,
    required int height,
    required Uint8List sps,
    required Uint8List pps,
  }) async {
    this.width = width;
    this.height = height;
    this.codec = codec;

    if (Platform.isWindows) {
      // 接收 C++ 插件发来的背压通知
      _channel.setMethodCallHandler((call) async {
        if (call.method == 'encoderState') {
          final paused = call.arguments['paused'] as bool? ?? false;
          onEncoderState?.call(paused);
        }
      });

      final reply = await _channel.invokeMethod<Map>('init', {
        'codec': codec,
        'width': width,
        'height': height,
        'sps': sps,
        'pps': pps,
      });

      if (reply != null) {
        final tid = reply['textureId'] as int? ?? -1;
        decoderType = reply['decoderType'] as String? ?? 'cpu';

        if (decoderType == 'd3d11' && tid < 0) {
          _startTexturePolling();
          return -1;
        }

        textureId = tid;
        if (tid >= 0) {
          onTextureReady?.call();
        }
        return tid;
      }

      return -1;
    }

    // macOS / 其他平台
    try {
      final id = await _channel.invokeMethod<int>('init', {
        'codec': codec,
        'width': width,
        'height': height,
        'sps': sps,
        'pps': pps,
      });
      textureId = id;
      decoderType = 'native';
      return id ?? -1;
    } on MissingPluginException {
      textureId = -1;
      return -1;
    }
  }

  void _startTexturePolling() {
    _pollTimer?.cancel();
    int attempts = 0;
    _pollTimer = Timer.periodic(const Duration(milliseconds: 100), (timer) async {
      attempts++;
      if (attempts > 50) {
        timer.cancel();
        return;
      }
      try {
        final tid = await _channel.invokeMethod<int>('getTextureId');
        if (tid != null && tid >= 0) {
          timer.cancel();
          textureId = tid;
          onTextureReady?.call();
        }
      } catch (e) {
        timer.cancel();
      }
    });
  }

  void feed(Uint8List nal,
      {required bool keyframe, required int ptsMs}) {
    _channel.invokeMethod('feed', {
      'nal': nal,
      'keyframe': keyframe,
      'pts': ptsMs,
    });
  }

  Future<void> dispose() async {
    _pollTimer?.cancel();
    _pollTimer = null;
    try {
      await _channel.invokeMethod('dispose');
    } on MissingPluginException {}
    textureId = null;
    decoderType = null;
  }
}
