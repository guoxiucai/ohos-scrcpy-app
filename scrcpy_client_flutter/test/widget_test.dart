import 'dart:typed_data';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:scrcpy_client_flutter/decoder/video_decoder.dart';
import 'package:scrcpy_client_flutter/net/protocol.dart';
import 'package:scrcpy_client_flutter/state/app_state.dart';
import 'package:scrcpy_client_flutter/ui/sidebar.dart';
import 'package:scrcpy_client_flutter/ui/toast.dart';

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

  testWidgets('录制参数锁定使用居中 Toast 提示 1.5 秒', (tester) async {
    await tester.pumpWidget(
      MaterialApp(
        home: Builder(
          builder: (context) => TextButton(
            onPressed: () => showCenterToast(context, '录制过程中不允许切换分辨率或帧率'),
            child: const Text('显示提示'),
          ),
        ),
      ),
    );

    await tester.tap(find.text('显示提示'));
    await tester.pump();

    expect(find.text('录制过程中不允许切换分辨率或帧率'), findsOneWidget);
    expect(find.byType(SnackBar), findsNothing);

    await tester.pump(const Duration(milliseconds: 1499));
    expect(find.text('录制过程中不允许切换分辨率或帧率'), findsOneWidget);

    await tester.pump(const Duration(milliseconds: 1));
    expect(find.text('录制过程中不允许切换分辨率或帧率'), findsNothing);
  });

  testWidgets('冷启动时录制与截图区域默认折叠', (tester) async {
    final state = AppState();
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: SizedBox(
            width: 320,
            height: 900,
            child: Sidebar(state: state),
          ),
        ),
      ),
    );

    expect(find.text('录制与截图'), findsOneWidget);
    expect(find.text('开始录制').hitTestable(), findsNothing);

    await tester.tap(find.text('录制与截图'));
    await tester.pumpAndSettle();
    expect(find.text('开始录制').hitTestable(), findsOneWidget);

    state.dispose();
  });
}
