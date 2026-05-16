import 'dart:async';
import 'dart:io';
import 'dart:typed_data';

import 'protocol.dart';

class StreamClient {
  Socket? _socket;
  final PacketParser _parser = PacketParser();

  final _packetCtrl = StreamController<Packet>.broadcast();
  Stream<Packet> get packets => _packetCtrl.stream;

  bool get connected => _socket != null;

  Future<void> connect(String host, int port) async {
    // 新连接前必须清掉上次残留的半包字节，否则首批字节会被错位解析。
    _parser.reset();
    final s = await Socket.connect(host, port, timeout: const Duration(seconds: 5));
    s.setOption(SocketOption.tcpNoDelay, true);
    _socket = s;
    s.listen(
      (data) {
        for (final p in _parser.feed(Uint8List.fromList(data))) {
          _packetCtrl.add(p);
        }
      },
      onError: (e, st) => _packetCtrl.addError(e, st),
      onDone: () => disconnect(),
      cancelOnError: true,
    );
  }

  void send(int type, Uint8List payload) {
    final s = _socket;
    if (s == null) return;
    s.add(encodePacket(type, payload).asUint8List());
  }

  Future<void> disconnect() async {
    final s = _socket;
    _socket = null;
    _parser.reset();
    if (s != null) {
      try {
        await s.close();
      } catch (_) {}
    }
  }

  Future<void> dispose() async {
    await disconnect();
    await _packetCtrl.close();
  }
}
