import 'dart:async';
import 'dart:io';

import 'package:flutter/services.dart';

class MediaSaveResult {
  final bool ok;
  final String? path;
  final String? error;
  final int durationUs;
  final int frameCount;

  const MediaSaveResult({
    required this.ok,
    this.path,
    this.error,
    this.durationUs = 0,
    this.frameCount = 0,
  });

  factory MediaSaveResult.fromMap(Map<Object?, Object?>? map) {
    if (map == null) {
      return const MediaSaveResult(ok: false, error: '原生模块未返回结果');
    }
    return MediaSaveResult(
      ok: map['ok'] as bool? ?? false,
      path: map['path'] as String?,
      error: map['error'] as String?,
      durationUs: map['durationUs'] as int? ?? 0,
      frameCount: map['frameCount'] as int? ?? 0,
    );
  }
}

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

  /// 原生背压回调。source 为 decoder 或 recorder。
  void Function(String source, bool paused)? onEncoderState;

  /// 原生录制状态回调：recording / error。
  void Function(String state, String? error)? onRecordingState;

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

    _channel.setMethodCallHandler((call) async {
      if (call.method == 'encoderState') {
        final args = call.arguments as Map<Object?, Object?>? ?? const {};
        final paused = args['paused'] as bool? ?? false;
        final source = args['source'] as String? ?? 'decoder';
        onEncoderState?.call(source, paused);
      } else if (call.method == 'recordingState') {
        final args = call.arguments as Map<Object?, Object?>? ?? const {};
        onRecordingState?.call(
          args['state'] as String? ?? 'error',
          args['error'] as String?,
        );
      }
    });

    if (Platform.isWindows) {
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
    _pollTimer =
        Timer.periodic(const Duration(milliseconds: 100), (timer) async {
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

  void feed(Uint8List nal, {required bool keyframe, required int ptsUs}) {
    _channel.invokeMethod('feed', {
      'nal': nal,
      'keyframe': keyframe,
      'pts': ptsUs,
    });
  }

  Future<MediaSaveResult> startRecording({
    required int width,
    required int height,
    required int fps,
    required int bitrate,
    required Uint8List sps,
    required Uint8List pps,
  }) async {
    try {
      final reply = await _channel.invokeMethod<Map>('startRecording', {
        'width': width,
        'height': height,
        'fps': fps,
        'bitrate': bitrate,
        'sps': sps,
        'pps': pps,
      });
      return MediaSaveResult.fromMap(reply);
    } on MissingPluginException {
      return const MediaSaveResult(ok: false, error: '当前平台暂不支持录制');
    } on PlatformException catch (e) {
      return MediaSaveResult(ok: false, error: e.message ?? e.code);
    }
  }

  Future<MediaSaveResult> stopRecording() async {
    try {
      final reply = await _channel.invokeMethod<Map>('stopRecording');
      return MediaSaveResult.fromMap(reply);
    } on MissingPluginException {
      return const MediaSaveResult(ok: false, error: '当前平台暂不支持录制');
    } on PlatformException catch (e) {
      return MediaSaveResult(ok: false, error: e.message ?? e.code);
    }
  }

  Future<void> cancelRecording() async {
    try {
      await _channel.invokeMethod('cancelRecording');
    } on MissingPluginException {
      // Linux 等暂未实现的平台保留占位。
    }
  }

  Future<MediaSaveResult> capturePng() async {
    try {
      final reply = await _channel.invokeMethod<Map>('capturePng');
      return MediaSaveResult.fromMap(reply);
    } on MissingPluginException {
      return const MediaSaveResult(ok: false, error: '当前平台暂不支持截图');
    } on PlatformException catch (e) {
      return MediaSaveResult(ok: false, error: e.message ?? e.code);
    }
  }

  Future<MediaSaveResult> revealInFileManager(String path) async {
    try {
      final reply = await _channel.invokeMethod<Map>(
        'revealInFileManager',
        {'path': path},
      );
      return MediaSaveResult.fromMap(reply);
    } on MissingPluginException {
      return const MediaSaveResult(ok: false, error: '当前平台暂不支持打开路径');
    } on PlatformException catch (e) {
      return MediaSaveResult(ok: false, error: e.message ?? e.code);
    }
  }

  Future<void> dispose() async {
    _pollTimer?.cancel();
    _pollTimer = null;
    try {
      await _channel.invokeMethod('dispose');
    } on MissingPluginException {
      decoderType = null;
    }
    textureId = null;
    decoderType = null;
  }
}
