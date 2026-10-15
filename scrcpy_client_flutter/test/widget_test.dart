import 'dart:typed_data';

import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:scrcpy_client_flutter/decoder/video_decoder.dart';
import 'package:scrcpy_client_flutter/net/protocol.dart';
import 'package:scrcpy_client_flutter/state/app_state.dart';
import 'package:scrcpy_client_flutter/ui/sidebar.dart';
import 'package:scrcpy_client_flutter/ui/mirror_view.dart';
import 'package:scrcpy_client_flutter/ui/toast.dart';

class _ControlCall {
  final int subType;
  final Uint8List body;

  const _ControlCall(this.subType, this.body);
}

class _RecordingAppState extends AppState {
  final List<_ControlCall> controls = <_ControlCall>[];

  @override
  void sendControl(int subType, Uint8List body) {
    controls.add(_ControlCall(subType, Uint8List.fromList(body)));
  }
}

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
    expect(ControlSubType.restartEncoder, 0x43);
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
          body: SizedBox(width: 320, height: 900, child: Sidebar(state: state)),
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

  testWidgets('横屏显示设备与有效视频尺寸并旋转 Texture', (tester) async {
    final state = AppState();
    state.connState = ConnState.connected;
    state.displayInfo = const DisplayInfo(
      logicalWidth: 1280,
      logicalHeight: 800,
      rotation: 3,
    );
    state.videoConfig = VideoConfig(
      VideoCodec.h264,
      720,
      1152,
      10,
      Uint8List(0),
      Uint8List(0),
    );

    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: SizedBox(
            width: 900,
            height: 700,
            child: MirrorView(state: state),
          ),
        ),
      ),
    );

    expect(find.textContaining('设备 1280×800 横屏'), findsOneWidget);
    expect(find.textContaining('视频 1152×720（90%）'), findsOneWidget);
    final rotated = tester.widget<RotatedBox>(find.byType(RotatedBox));
    expect(rotated.quarterTurns, 3);

    state.dispose();
  });

  testWidgets('Windows 鼠标点击使用固定触点编号和有效视频坐标', (tester) async {
    final state = _RecordingAppState();
    state.connState = ConnState.connected;
    state.displayInfo = const DisplayInfo(
      logicalWidth: 1280,
      logicalHeight: 800,
      rotation: 3,
    );
    state.videoConfig = VideoConfig(
      VideoCodec.h264,
      720,
      1152,
      10,
      Uint8List(0),
      Uint8List(0),
    );

    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: SizedBox(
            width: 900,
            height: 700,
            child: MirrorView(state: state),
          ),
        ),
      ),
    );

    final mirror = find.byType(RotatedBox);
    final center = tester.getCenter(mirror);
    final gesture = await tester.createGesture(
      kind: PointerDeviceKind.mouse,
      pointer: 0x12345,
    );
    await gesture.addPointer(location: center);
    await gesture.down(center);
    await gesture.up();
    await tester.pump();

    expect(state.controls.map((_ControlCall call) => call.subType), <int>[
      ControlSubType.touchDown,
    ]);
    await tester.pump(const Duration(milliseconds: 119));
    expect(state.controls, hasLength(1));
    await tester.pump(const Duration(milliseconds: 1));
    expect(state.controls.map((_ControlCall call) => call.subType), <int>[
      ControlSubType.touchDown,
      ControlSubType.touchUp,
    ]);
    for (final call in state.controls) {
      final data = ByteData.sublistView(call.body);
      expect(data.getUint32(0, Endian.big), 576);
      expect(data.getUint32(4, Endian.big), 360);
      expect(data.getUint16(8, Endian.big), 0);
    }

    state.controls.clear();
    await gesture.down(center);
    await gesture.up();
    await tester.pump(const Duration(milliseconds: 60));
    await gesture.down(center);
    expect(state.controls.map((_ControlCall call) => call.subType), <int>[
      ControlSubType.touchDown,
      ControlSubType.touchUp,
      ControlSubType.touchDown,
    ]);
    await gesture.up();
    await tester.pump(const Duration(milliseconds: 120));
    expect(state.controls.map((_ControlCall call) => call.subType), <int>[
      ControlSubType.touchDown,
      ControlSubType.touchUp,
      ControlSubType.touchDown,
      ControlSubType.touchUp,
    ]);

    state.dispose();
  });

  testWidgets('竖屏显示有效视频尺寸且 Texture 不旋转', (tester) async {
    final state = AppState();
    state.connState = ConnState.connected;
    state.displayInfo = const DisplayInfo(
      logicalWidth: 800,
      logicalHeight: 1280,
      rotation: 0,
    );
    state.videoConfig = VideoConfig(
      VideoCodec.h264,
      720,
      1152,
      10,
      Uint8List(0),
      Uint8List(0),
    );

    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: SizedBox(
            width: 900,
            height: 700,
            child: MirrorView(state: state),
          ),
        ),
      ),
    );

    expect(find.textContaining('设备 800×1280 竖屏'), findsOneWidget);
    expect(find.textContaining('视频 720×1152（90%）'), findsOneWidget);
    final rotated = tester.widget<RotatedBox>(find.byType(RotatedBox));
    expect(rotated.quarterTurns, 0);

    state.dispose();
  });

  testWidgets('状态栏提供 720 短边和 10fps 选项', (tester) async {
    final state = AppState();
    state.connState = ConnState.connected;
    state.videoConfig = VideoConfig(
      VideoCodec.h264,
      720,
      1152,
      10,
      Uint8List(0),
      Uint8List(0),
    );
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: SizedBox(
            width: 900,
            height: 700,
            child: MirrorView(state: state),
          ),
        ),
      ),
    );

    await tester.tap(find.byTooltip('切换分辨率'));
    await tester.pumpAndSettle();
    expect(find.textContaining('720p'), findsOneWidget);

    await tester.tap(find.textContaining('720p'));
    await tester.pumpAndSettle();
    await tester.tap(find.byTooltip('切换帧率'));
    await tester.pumpAndSettle();
    expect(find.text('10 fps'), findsOneWidget);

    state.dispose();
  });
}
