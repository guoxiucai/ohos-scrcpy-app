import 'package:flutter/foundation.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:integration_test/integration_test.dart';
import 'package:scrcpy_client_flutter/main.dart' as app;
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

  testWidgets('真机视频帧率双向切换', (tester) async {
    await app.main();
    await tester.pump();
    await _waitUntil(
      tester,
      () => find.byType(TopBar).evaluate().isNotEmpty,
      description: '客户端主界面初始化',
    );

    final state = tester.widget<TopBar>(find.byType(TopBar)).state;
    try {
      await state.refreshDevices();
      expect(state.devices, isNotEmpty);
      await state.connect();
      await _waitUntil(
        tester,
        () => state.canStartRecording,
        description: '首批视频帧',
        timeout: const Duration(seconds: 45),
      );

      debugPrint(
        'FPS_E2E_INITIAL=${state.videoConfig?.fps},frames=${state.frames}',
      );
      final initialFps = state.videoConfig?.fps;
      final targetFpsList = initialFps == 15
          ? const <int>[20, 15]
          : const <int>[15, 20];
      for (final targetFps in targetFpsList) {
        final framesBefore = state.frames;
        final result = state.changeVideoParams(fps: targetFps);
        expect(result.ok, isTrue, reason: result.message);
        await _waitUntil(
          tester,
          () =>
              state.videoConfig?.fps == targetFps &&
              state.frames > framesBefore,
          description: '切换至 ${targetFps}fps 后收到新配置和视频帧',
          timeout: const Duration(seconds: 25),
        );
        debugPrint(
          'FPS_E2E_SWITCHED=${state.videoConfig?.fps},frames=${state.frames}',
        );
      }
    } finally {
      await state.disconnect();
    }
  });
}
