import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:integration_test/integration_test.dart';
import 'package:scrcpy_client_flutter/main.dart' as app;
import 'package:scrcpy_client_flutter/state/app_state.dart';
import 'package:scrcpy_client_flutter/ui/top_bar.dart';

Future<void> _waitUntil(
  WidgetTester tester,
  bool Function() condition, {
  required String description,
  Duration timeout = const Duration(seconds: 30),
}) async {
  final stopwatch = Stopwatch()..start();
  while (!condition()) {
    if (stopwatch.elapsed >= timeout) {
      throw TestFailure('等待超时：$description');
    }
    await Future<void>.delayed(const Duration(milliseconds: 200));
    await tester.pump();
  }
}

void main() {
  IntegrationTestWidgetsFlutterBinding.ensureInitialized();

  testWidgets('真机录制 MP4 与截图 PNG', (tester) async {
    await app.main();
    await tester.pump();

    await _waitUntil(
      tester,
      () => find.byType(TopBar).evaluate().isNotEmpty,
      description: '客户端主界面完成初始化',
    );
    final state = tester.widget<TopBar>(find.byType(TopBar)).state;
    await state.refreshDevices();
    expect(state.devices, isNotEmpty);
    expect(state.selectedDevice, isNotNull);
    await state.connect();
    await tester.pump();

    await _waitUntil(
      tester,
      () => state.canStartRecording,
      description: '视频首帧到达并启用录制',
      timeout: const Duration(seconds: 45),
    );
    final notices = <MediaNotice>[];
    final noticeSubscription = state.mediaNotices.listen(notices.add);

    final startResult = await state.startRecording();
    expect(startResult.ok, isTrue, reason: startResult.message);
    await tester.pump();

    await _waitUntil(
      tester,
      () => state.recordingState == RecordingState.recording,
      description: '收到 IDR 并进入录制状态',
      timeout: const Duration(seconds: 10),
    );

    await Future<void>.delayed(const Duration(seconds: 5));
    await tester.pump();
    final stopResult = await state.stopRecording();
    expect(stopResult.ok, isTrue, reason: stopResult.message);
    await tester.pump();

    await _waitUntil(
      tester,
      () => notices.any((notice) => notice.kind == MediaKind.recording),
      description: 'MP4 完成收尾并返回保存结果',
      timeout: const Duration(seconds: 20),
    );
    final recordingNotice =
        notices.lastWhere((notice) => notice.kind == MediaKind.recording);
    expect(
      recordingNotice.result.ok,
      isTrue,
      reason: recordingNotice.result.error,
    );
    final recordingPath = recordingNotice.result.path;
    expect(recordingPath, isNotNull);
    expect(recordingPath, endsWith('.mp4'));
    expect(File(recordingPath!).lengthSync(), greaterThan(1024));
    debugPrint('E2E_RECORDING_PATH=$recordingPath');

    final screenshotResult = await state.captureScreenshot();
    expect(screenshotResult.ok, isTrue, reason: screenshotResult.message);
    await tester.pump();

    await _waitUntil(
      tester,
      () => notices.any((notice) => notice.kind == MediaKind.screenshot),
      description: 'PNG 编码完成并返回保存结果',
      timeout: const Duration(seconds: 20),
    );
    final screenshotNotice =
        notices.lastWhere((notice) => notice.kind == MediaKind.screenshot);
    expect(
      screenshotNotice.result.ok,
      isTrue,
      reason: screenshotNotice.result.error,
    );
    final screenshotPath = screenshotNotice.result.path;
    expect(screenshotPath, isNotNull);
    expect(screenshotPath, endsWith('.png'));
    final png = File(screenshotPath!).readAsBytesSync();
    expect(png.length, greaterThan(1024));
    expect(
      png.take(8).toList(),
      <int>[0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A],
    );
    debugPrint('E2E_SCREENSHOT_PATH=$screenshotPath');

    await noticeSubscription.cancel();
    await state.disconnect();
  });
}
