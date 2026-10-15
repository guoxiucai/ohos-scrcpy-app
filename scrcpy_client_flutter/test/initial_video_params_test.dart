import 'dart:io';
import 'dart:typed_data';

import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:scrcpy_client_flutter/hdc/device.dart';
import 'package:scrcpy_client_flutter/hdc/hdc_client.dart';
import 'package:scrcpy_client_flutter/net/protocol.dart';
import 'package:scrcpy_client_flutter/state/app_state.dart';

class _LocalForward extends HdcClient {
  _LocalForward(this.port);

  final int port;
  int forwardCount = 0;
  int removeCount = 0;

  @override
  Future<int> forwardPort(String serial, int devicePort) async {
    forwardCount++;
    return port;
  }

  @override
  Future<void> removeForward(
    String serial,
    int localPort, {
    int devicePort = 53535,
  }) async {
    removeCount++;
  }
}

Uint8List _displayStatusPayload(int width, int height, int rotation) {
  final payload = Uint8List(10);
  final view = ByteData.sublistView(payload);
  payload[0] = DeviceStatusSubType.displayInfo;
  view.setUint32(1, width, Endian.big);
  view.setUint32(5, height, Endian.big);
  view.setUint8(9, rotation);
  return payload;
}

Uint8List _h264ConfigPayload({
  int width = 720,
  int height = 1152,
  int fps = 10,
}) {
  final config = Uint8List(17);
  final view = ByteData.sublistView(config);
  view.setUint32(1, width, Endian.big);
  view.setUint32(5, height, Endian.big);
  view.setUint32(9, fps, Endian.big);
  return config;
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  const decoderChannel = MethodChannel('scrcpy/decoder');

  setUp(() {
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(decoderChannel, (call) async {
          if (call.method == 'init') {
            if (Platform.isWindows) {
              return <String, Object>{'textureId': -1, 'decoderType': 'cpu'};
            }
            return -1;
          }
          return null;
        });
  });

  tearDown(() {
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(decoderChannel, null);
  });

  test('USB 首次连接请求显示信息并切换为设备原始分辨率', () async {
    SharedPreferences.setMockInitialValues({});
    final server = await ServerSocket.bind(InternetAddress.loopbackIPv4, 0);
    final controls = <int>[];
    final sockets = <Socket>[];
    final config = _h264ConfigPayload();
    final subscription = server.listen((socket) {
      sockets.add(socket);
      socket.add(encodePacket(PacketType.videoConfig, config).asUint8List());
      final parser = PacketParser();
      socket.listen((data) {
        for (final packet in parser.feed(Uint8List.fromList(data))) {
          if (packet.type == PacketType.heartbeat) {
            socket.add(
              encodePacket(PacketType.heartbeat, packet.payload).asUint8List(),
            );
          }
          if (packet.type == PacketType.control) {
            controls.add(packet.payload.first);
            if (packet.payload.first == ControlSubType.getDisplayInfo) {
              socket.add(
                encodePacket(
                  PacketType.deviceStatus,
                  _displayStatusPayload(1280, 800, 3),
                ).asUint8List(),
              );
            }
          }
        }
      });
    });
    final state = AppState(hdc: _LocalForward(server.port));
    state.selectedDevice = const HdcDevice(
      serial: 'TEST',
      state: 'Connected',
      connection: 'USB',
    );

    try {
      await state.initPrefs();
      await state.connect();
      for (
        var i = 0;
        i < 20 &&
            (state.videoConfig == null ||
                state.displayInfo == null ||
                !controls.contains(ControlSubType.changeVideoParams));
        i++
      ) {
        await Future<void>.delayed(const Duration(milliseconds: 20));
      }
      expect(controls.take(2), [
        ControlSubType.getDisplayInfo,
        ControlSubType.listApps,
      ]);
      expect(state.videoConfig?.codec, VideoCodec.h264);
      expect(state.displayInfo?.logicalWidth, 1280);
      expect(state.displayInfo?.logicalHeight, 800);
      expect(state.displayInfo?.rotation, 3);
      expect(state.targetMaxShort, 800);
      expect(state.targetFps, 10);
      expect(controls, contains(ControlSubType.changeVideoParams));
    } finally {
      await state.disconnect();
      state.dispose();
      for (final socket in sockets) {
        socket.destroy();
      }
      await subscription.cancel();
      await server.close();
    }
  });

  test('TCP 首次连接默认保持短边 720', () async {
    SharedPreferences.setMockInitialValues({});
    final server = await ServerSocket.bind(InternetAddress.loopbackIPv4, 0);
    final controls = <int>[];
    final sockets = <Socket>[];
    final subscription = server.listen((socket) {
      sockets.add(socket);
      socket.add(
        encodePacket(
          PacketType.videoConfig,
          _h264ConfigPayload(),
        ).asUint8List(),
      );
      final parser = PacketParser();
      socket.listen((data) {
        for (final packet in parser.feed(Uint8List.fromList(data))) {
          if (packet.type == PacketType.heartbeat) {
            socket.add(
              encodePacket(PacketType.heartbeat, packet.payload).asUint8List(),
            );
          }
          if (packet.type == PacketType.control) {
            controls.add(packet.payload.first);
            if (packet.payload.first == ControlSubType.getDisplayInfo) {
              socket.add(
                encodePacket(
                  PacketType.deviceStatus,
                  _displayStatusPayload(1280, 800, 3),
                ).asUint8List(),
              );
            }
          }
        }
      });
    });
    final state = AppState(hdc: _LocalForward(server.port));
    state.selectedDevice = const HdcDevice(
      serial: 'TEST',
      state: 'Connected',
      connection: 'TCP',
    );

    try {
      await state.initPrefs();
      await state.connect();
      for (
        var i = 0;
        i < 20 && (state.videoConfig == null || state.displayInfo == null);
        i++
      ) {
        await Future<void>.delayed(const Duration(milliseconds: 20));
      }
      expect(state.targetMaxShort, 720);
      expect(state.targetFps, 10);
      expect(controls.take(2), [
        ControlSubType.getDisplayInfo,
        ControlSubType.listApps,
      ]);
      expect(controls, isNot(contains(ControlSubType.changeVideoParams)));
    } finally {
      await state.disconnect();
      state.dispose();
      for (final socket in sockets) {
        socket.destroy();
      }
      await subscription.cancel();
      await server.close();
    }
  });

  test('显式保存的分辨率优先于 TCP 默认值', () async {
    SharedPreferences.setMockInitialValues({
      'video_max_short': 1080,
      'video_fps': 15,
    });
    final server = await ServerSocket.bind(InternetAddress.loopbackIPv4, 0);
    final controls = <Uint8List>[];
    final sockets = <Socket>[];
    final subscription = server.listen((socket) {
      sockets.add(socket);
      socket.add(
        encodePacket(
          PacketType.videoConfig,
          _h264ConfigPayload(),
        ).asUint8List(),
      );
      final parser = PacketParser();
      socket.listen((data) {
        for (final packet in parser.feed(Uint8List.fromList(data))) {
          if (packet.type == PacketType.heartbeat) {
            socket.add(
              encodePacket(PacketType.heartbeat, packet.payload).asUint8List(),
            );
          }
          if (packet.type == PacketType.control) {
            controls.add(Uint8List.fromList(packet.payload));
            if (packet.payload.first == ControlSubType.getDisplayInfo) {
              socket.add(
                encodePacket(
                  PacketType.deviceStatus,
                  _displayStatusPayload(1280, 800, 3),
                ).asUint8List(),
              );
            }
          }
        }
      });
    });
    final state = AppState(hdc: _LocalForward(server.port));
    state.selectedDevice = const HdcDevice(
      serial: 'TEST',
      state: 'Connected',
      connection: 'TCP',
    );

    try {
      await state.initPrefs();
      await state.connect();
      for (
        var i = 0;
        i < 20 && (state.videoConfig == null || state.displayInfo == null);
        i++
      ) {
        await Future<void>.delayed(const Duration(milliseconds: 20));
      }
      expect(state.targetMaxShort, 1080);
      expect(state.targetFps, 15);
      final change = controls.firstWhere(
        (payload) => payload.first == ControlSubType.changeVideoParams,
      );
      expect(ByteData.sublistView(change, 1).getInt32(0, Endian.big), 1080);
    } finally {
      await state.disconnect();
      state.dispose();
      for (final socket in sockets) {
        socket.destroy();
      }
      await subscription.cancel();
      await server.close();
    }
  });

  test('首次连接被重置后重新转发并完成心跳握手', () async {
    SharedPreferences.setMockInitialValues({});
    final server = await ServerSocket.bind(InternetAddress.loopbackIPv4, 0);
    final sockets = <Socket>[];
    final subscription = server.listen((socket) {
      sockets.add(socket);
      final parser = PacketParser();
      socket.listen((data) {
        for (final packet in parser.feed(Uint8List.fromList(data))) {
          if (sockets.length == 1) {
            socket.destroy();
            return;
          }
          if (packet.type == PacketType.heartbeat) {
            socket.add(
              encodePacket(PacketType.heartbeat, packet.payload).asUint8List(),
            );
          }
        }
      });
    });
    final hdc = _LocalForward(server.port);
    final state = AppState(hdc: hdc);
    state.selectedDevice = const HdcDevice(
      serial: 'TEST',
      state: 'Connected',
      connection: 'USB',
    );

    try {
      await state.connect().timeout(const Duration(seconds: 4));
      expect(state.connState, ConnState.connected);
      expect(sockets.length, 2);
      expect(hdc.forwardCount, 2);
      expect(hdc.removeCount, 1);
    } finally {
      await state.disconnect();
      state.dispose();
      for (final socket in sockets) {
        socket.destroy();
      }
      await subscription.cancel();
      await server.close();
    }
  });

  test('心跳握手持续失败后给出错误并清理端口转发', () async {
    SharedPreferences.setMockInitialValues({});
    final server = await ServerSocket.bind(InternetAddress.loopbackIPv4, 0);
    final subscription = server.listen((socket) {
      socket.listen((_) => socket.destroy());
    });
    final hdc = _LocalForward(server.port);
    final state = AppState(hdc: hdc);
    state.selectedDevice = const HdcDevice(
      serial: 'TEST',
      state: 'Connected',
      connection: 'USB',
    );

    try {
      await state.connect().timeout(const Duration(seconds: 4));
      expect(state.connState, ConnState.error);
      expect(state.statusMessage, contains('连接失败'));
      expect(hdc.forwardCount, 3);
      expect(hdc.removeCount, 3);
      expect(state.localPort, isNull);
    } finally {
      await state.disconnect();
      state.dispose();
      await subscription.cancel();
      await server.close();
    }
  });

  test('心跳握手成功后的断线显示错误且不再自动重试', () async {
    SharedPreferences.setMockInitialValues({});
    final server = await ServerSocket.bind(InternetAddress.loopbackIPv4, 0);
    final sockets = <Socket>[];
    final subscription = server.listen((socket) {
      sockets.add(socket);
      final parser = PacketParser();
      socket.listen((data) {
        for (final packet in parser.feed(Uint8List.fromList(data))) {
          if (packet.type == PacketType.heartbeat) {
            socket.add(
              encodePacket(PacketType.heartbeat, packet.payload).asUint8List(),
            );
          }
        }
      });
    });
    final hdc = _LocalForward(server.port);
    final state = AppState(hdc: hdc);
    state.selectedDevice = const HdcDevice(
      serial: 'TEST',
      state: 'Connected',
      connection: 'USB',
    );

    try {
      await state.connect();
      expect(state.connState, ConnState.connected);
      sockets.single.destroy();
      for (var i = 0; i < 30 && state.connState != ConnState.error; i++) {
        await Future<void>.delayed(const Duration(milliseconds: 20));
      }
      expect(state.connState, ConnState.error);
      expect(state.statusMessage, contains('连接错误'));
      expect(hdc.forwardCount, 1);
      expect(hdc.removeCount, 1);
    } finally {
      await state.disconnect();
      state.dispose();
      for (final socket in sockets) {
        socket.destroy();
      }
      await subscription.cancel();
      await server.close();
    }
  });

  const target = String.fromEnvironment('HONGJING_TARGET');
  test(
    '真机服务返回心跳后客户端才进入已连接状态',
    () async {
      const decoderChannel = MethodChannel('scrcpy/decoder');
      var decoderFeedCount = 0;
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
          .setMockMethodCallHandler(decoderChannel, (call) async {
            if (call.method == 'init') {
              if (Platform.isWindows) {
                return <String, Object>{'textureId': -1, 'decoderType': 'cpu'};
              }
              return -1;
            }
            if (call.method == 'feed') decoderFeedCount++;
            return null;
          });
      final state = AppState();
      state.selectedDevice = const HdcDevice(
        serial: target,
        state: 'Connected',
        connection: 'USB',
      );
      try {
        await state.hdc.shell(
          target,
          'aa start -a ScrcpyService -b com.ohos.scrcpy.server',
        );
        await state.connect();
        expect(
          state.connState,
          ConnState.connected,
          reason: state.statusMessage,
        );
        expect(state.localPort, isNotNull);
        for (var i = 0; i < 400 && state.frames == 0; i++) {
          await Future<void>.delayed(const Duration(milliseconds: 50));
        }
        expect(state.videoConfig?.codec, VideoCodec.h264);
        expect(state.videoConfig?.width, 720);
        expect(state.videoConfig?.height, 1152);
        expect(state.videoConfig?.fps, 10);
        expect(state.frames, greaterThan(0));
        expect(state.firstFrameAt, isNotNull);
        expect(decoderFeedCount, greaterThan(0));
      } finally {
        await state.disconnect();
        state.dispose();
        TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
            .setMockMethodCallHandler(decoderChannel, null);
      }
    },
    skip: target.isEmpty,
    timeout: const Timeout(Duration(seconds: 60)),
  );
}
