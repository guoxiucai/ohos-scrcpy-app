import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:scrcpy_client_flutter/decoder/video_decoder.dart';
import 'package:scrcpy_client_flutter/net/protocol.dart';
import 'package:scrcpy_client_flutter/state/app_state.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  test('视频帧时间戳按微秒解析', () {
    final payload = Uint8List(12);
    final data = ByteData.sublistView(payload);
    payload[0] = 1;
    data.setUint64(1, 1234567, Endian.big);
    payload.setAll(9, [0, 0, 1]);

    final frame = VideoFrame.parse(payload);

    expect(frame.keyframe, isTrue);
    expect(frame.ptsUs, 1234567);
    expect(frame.nal, [0, 0, 1]);
    expect(ControlSubType.requestKeyframe, 0x43);
  });

  test('原生媒体结果映射保留路径与统计信息', () {
    final result = MediaSaveResult.fromMap({
      'ok': true,
      'path': '/Desktop/HongJing_Recording.mp4',
      'durationUs': 2000000,
      'frameCount': 30,
    });

    expect(result.ok, isTrue);
    expect(result.path, endsWith('.mp4'));
    expect(result.durationUs, 2000000);
    expect(result.frameCount, 30);
  });

  test('录制状态从业务层阻止视频参数切换', () {
    final state = AppState();
    state.recordingState = RecordingState.recording;
    final oldFps = state.targetFps;

    final result = state.changeVideoParams(fps: 20);

    expect(result.ok, isFalse);
    expect(result.message, contains('录制过程中'));
    expect(state.targetFps, oldFps);
    state.dispose();
  });
}
