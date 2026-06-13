import 'dart:async';
import 'dart:typed_data';

import 'package:flutter/foundation.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../decoder/video_decoder.dart';
import '../hdc/device.dart';
import '../hdc/hdc_client.dart';
import '../net/protocol.dart';
import '../net/stream_client.dart';
import '../terminal/pty_availability.dart';
import '../terminal/pty_session.dart';

const int kDevicePort = 53535;

enum ConnState { idle, connecting, connected, error }

class AppActionResult {
  final bool ok;
  final String message;
  const AppActionResult.ok(this.message) : ok = true;
  const AppActionResult.fail(this.message) : ok = false;
}

class AppState extends ChangeNotifier {
  final HdcClient hdc = HdcClient();
  final StreamClient stream = StreamClient();
  late final VideoDecoder decoder = VideoDecoder()
    ..onTextureReady = notifyListeners
    ..onEncoderState = _onEncoderState;

  List<HdcDevice> devices = [];
  HdcDevice? selectedDevice;

  ConnState connState = ConnState.idle;
  String statusMessage = '未连接';

  // 最后一次触摸的设备坐标，用于 uitest inputText
  int lastTouchX = 0;
  int lastTouchY = 0;

  int? localPort;
  VideoConfig? videoConfig;
  int frames = 0;
  DateTime? firstFrameAt;
  // 实时 FPS（基于 1Hz 采样窗口），未连接 / 无新帧时为 0
  double fps = 0;
  int _framesAtLastTick = 0;
  Timer? _statsTimer;

  // 视频参数（仅 H264 模式生效）
  int targetMaxShort = 1080;
  int targetBitrate = 4 * 1000 * 1000;
  int targetFps = 15;

  // 用户偏好持久化
  static const _prefKeyMaxShort = 'video_max_short';
  static const _prefKeyFps = 'video_fps';
  SharedPreferences? _prefs;
  bool _prefsLoaded = false;

  /// 初始化 SharedPreferences（应在 app 启动时调用一次）
  Future<void> initPrefs() async {
    try {
      _prefs = await SharedPreferences.getInstance();
      _prefsLoaded = true;
      final savedMaxShort = _prefs!.getInt(_prefKeyMaxShort);
      final savedFps = _prefs!.getInt(_prefKeyFps);
      if (savedMaxShort != null) targetMaxShort = savedMaxShort;
      if (savedFps != null) targetFps = savedFps;
      // 码率根据保存的分辨率联动
      targetBitrate = targetMaxShort <= 1080 ? 4 * 1000 * 1000 : 6 * 1000 * 1000;
      debugPrint('[prefs] loaded maxShort=$targetMaxShort, fps=$targetFps, bitrate=$targetBitrate');
    } catch (e) {
      debugPrint('[prefs] init failed: $e');
    }
  }

  /// 保存用户手动选择的视频参数
  void _saveVideoPrefs() {
    if (!_prefsLoaded || _prefs == null) return;
    _prefs!.setInt(_prefKeyMaxShort, targetMaxShort);
    _prefs!.setInt(_prefKeyFps, targetFps);
    debugPrint('[prefs] saved maxShort=$targetMaxShort, fps=$targetFps');
  }

  Timer? _heartbeatTimer;
  Timer? _heartbeatCheckTimer;
  DateTime? _lastHeartbeatAt;

  static const _heartbeatInterval = Duration(seconds: 10);
  static const _heartbeatTimeout = Duration(seconds: 30);

  StreamSubscription<Packet>? _sub;
  Future<void> _packetChain = Future.value();

  // Apps
  List<AppEntry> apps = [];
  bool appsLoading = false;

  // Terminal (P2)
  bool terminalOpen = false;
  double terminalHeight = 240;
  PtySession? terminal;
  bool get terminalSupported => PtyAvailability.isSupported;
  String? get terminalUnsupportedReason => PtyAvailability.reason;

  Future<void> refreshDevices() async {
    try {
      final list = await hdc.devices();
      devices = list;
      if (selectedDevice != null && !list.contains(selectedDevice)) {
        selectedDevice = null;
      }
      selectedDevice ??= list.isNotEmpty ? list.first : null;
      notifyListeners();
    } catch (e) {
      statusMessage = '设备列表失败: $e';
      notifyListeners();
    }
  }

  void selectDevice(HdcDevice d) {
    final old = selectedDevice?.serial;
    selectedDevice = d;
    apps = [];
    notifyListeners();
    if (terminal != null && d.serial != old) {
      // 抽屉里弹一行系统提示并自动重启 shell
      hdc.resolvedPath().then((p) => terminal!.rebind(d.serial, hdcPath: p));
    }
  }

  /// 打开/关闭终端抽屉。首次打开时 lazy 创建 PtySession 并启动 hdc shell。
  Future<void> setTerminalOpen(bool open) async {
    if (open && !terminalSupported) return;
    terminalOpen = open;
    if (open && terminal == null) {
      terminal = PtySession();
      final dev = selectedDevice;
      if (dev != null) {
        final p = await hdc.resolvedPath();
        await terminal!.start(dev.serial, hdcPath: p);
      }
    }
    notifyListeners();
  }

  void setTerminalHeight(double h) {
    terminalHeight = h.clamp(140.0, 1200.0);
    notifyListeners();
  }

  Future<void> restartTerminal() async {
    final t = terminal;
    final dev = selectedDevice;
    if (t == null || dev == null) return;
    final p = await hdc.resolvedPath();
    await t.start(dev.serial, hdcPath: p);
  }

  void clearTerminal() {
    terminal?.clear();
    notifyListeners();
  }

  Future<void> connect() async {
    final dev = selectedDevice;
    if (dev == null) return;
    if (connState == ConnState.connecting || connState == ConnState.connected) return;
    // 清理上一次残留的端口转发（error 状态重连 / 异常断开）
    await _cleanupForward();
    _setState(ConnState.connecting, '正在端口转发…');
    try {
      final lp = await hdc.forwardPort(dev.serial, kDevicePort);
      localPort = lp;
      _setState(ConnState.connecting, '正在连接 127.0.0.1:$lp …');
      await stream.connect('127.0.0.1', lp);
      _sub = stream.packets.listen((p) {
        _packetChain = _packetChain.then((_) => _onPacket(p));
      }, onError: (e) {
        _setState(ConnState.error, '连接错误: $e');
      });
      _setState(ConnState.connected, '已连接，等待视频流…');
      _startHeartbeat();
      _startStatsTicker();
      // 根据连接类型设置默认视频参数并下发
      final isWifi = dev.connection == 'TCP';
      // WiFi: 2160p / 6Mbps / 15fps；USB: 2160p / 12Mbps / 15fps
      targetMaxShort = 2160;
      targetBitrate = isWifi ? 6 * 1000 * 1000 : 12 * 1000 * 1000;
      targetFps = 15;
      // 若用户有手动保存的偏好，优先使用保存值
      if (_prefsLoaded && _prefs != null) {
        final savedMaxShort = _prefs!.getInt(_prefKeyMaxShort);
        final savedFps = _prefs!.getInt(_prefKeyFps);
        if (savedMaxShort != null) {
          targetMaxShort = savedMaxShort;
          targetBitrate = savedMaxShort <= 1080 ? 4 * 1000 * 1000 : (isWifi ? 6 * 1000 * 1000 : 12 * 1000 * 1000);
        }
        if (savedFps != null) targetFps = savedFps;
      }
      _sendVideoParams();
      // 连接成功后自动拉一次可卸载应用列表
      requestAppList();
    } catch (e) {
      // 连接失败时也清理刚创建的端口转发
      await _cleanupForward();
      _setState(ConnState.error, '连接失败: $e');
    }
  }

  Future<void> disconnect() async {
    _packetChain = Future.value();
    await _sub?.cancel();
    _sub = null;
    _stopHeartbeat();
    _stopStatsTicker();
    await stream.disconnect();
    await decoder.dispose();
    await _cleanupForward();
    videoConfig = null;
    frames = 0;
    firstFrameAt = null;
    fps = 0;
    _framesAtLastTick = 0;
    _setState(ConnState.idle, '已断开');
  }

  void _onPacket(Packet p) async {
    _lastHeartbeatAt = DateTime.now();
    switch (p.type) {
      case PacketType.heartbeat:
        break;
      case PacketType.videoConfig:
        final cfg = VideoConfig.parse(p.payload);
        final old = videoConfig;
        if (old != null &&
            old.codec == cfg.codec &&
            old.width == cfg.width &&
            old.height == cfg.height &&
            old.sps.length == cfg.sps.length &&
            old.pps.length == cfg.pps.length) {
          break;
        }
        videoConfig = cfg;
        await decoder.dispose();
        await decoder.init(
            codec: cfg.codec,
            width: cfg.width,
            height: cfg.height,
            sps: cfg.sps,
            pps: cfg.pps);
        notifyListeners();
        break;
      case PacketType.videoFrame:
        final f = VideoFrame.parse(p.payload);
        frames++;
        if (firstFrameAt == null) {
          firstFrameAt = DateTime.now();
          _setState(ConnState.connected, '已连接，镜像中');
        }
        decoder.feed(f.nal, keyframe: f.keyframe, ptsMs: f.ptsMs);
        break;
      case PacketType.deviceStatus:
        _onDeviceStatus(p.payload);
        break;
    }
  }

  void _onDeviceStatus(Uint8List payload) {
    if (payload.isEmpty) return;
    final sub = payload[0];
    final body = Uint8List.sublistView(payload, 1);
    if (sub == DeviceStatusSubType.appList) {
      apps = parseAppList(body);
      appsLoading = false;
      notifyListeners();
    }
  }

  void sendControl(int subType, Uint8List body) {
    if (connState != ConnState.connected) return;
    stream.send(PacketType.control, encodeControl(subType, body));
  }

  void changeVideoParams({int? maxShort, int? bitrate, int? fps}) {
    if (maxShort != null) {
      targetMaxShort = maxShort;
      // 码率跟随分辨率档位联动：≤1080p → 4Mbps，2160p → 6Mbps
      targetBitrate = maxShort <= 1080 ? 4 * 1000 * 1000 : 6 * 1000 * 1000;
    }
    if (fps != null) targetFps = fps;
    // 保存用户手动选择的视频参数
    _saveVideoPrefs();
    notifyListeners();
    _sendVideoParams();
  }

  void _sendVideoParams() {
    sendControl(
      ControlSubType.changeVideoParams,
      encodeVideoParams(targetMaxShort, targetBitrate, targetFps),
    );
  }

  void _onEncoderState(bool paused) {
    sendControl(
      paused ? ControlSubType.pauseEncoder : ControlSubType.resumeEncoder,
      Uint8List(0),
    );
  }

  void _startHeartbeat() {
    _lastHeartbeatAt = DateTime.now();
    _heartbeatTimer = Timer.periodic(_heartbeatInterval, (_) => _sendHeartbeat());
    _heartbeatCheckTimer = Timer.periodic(const Duration(seconds: 5), (_) => _checkHeartbeatTimeout());
  }

  void _stopHeartbeat() {
    _heartbeatTimer?.cancel();
    _heartbeatTimer = null;
    _heartbeatCheckTimer?.cancel();
    _heartbeatCheckTimer = null;
  }

  void _startStatsTicker() {
    _framesAtLastTick = frames;
    _statsTimer?.cancel();
    _statsTimer = Timer.periodic(const Duration(seconds: 1), (_) {
      final delta = frames - _framesAtLastTick;
      _framesAtLastTick = frames;
      fps = delta.toDouble();
      notifyListeners();
    });
  }

  void _stopStatsTicker() {
    _statsTimer?.cancel();
    _statsTimer = null;
  }

  void _sendHeartbeat() {
    if (connState != ConnState.connected) return;
    final ts = DateTime.now().millisecondsSinceEpoch;
    final payload = Uint8List(8);
    final bd = ByteData.sublistView(payload);
    bd.setUint64(0, ts, Endian.big);
    stream.send(PacketType.heartbeat, payload);
  }

  void _checkHeartbeatTimeout() {
    if (connState != ConnState.connected) return;
    final last = _lastHeartbeatAt;
    if (last == null) return;
    final elapsed = DateTime.now().difference(last);
    if (elapsed > _heartbeatTimeout) {
      _setState(ConnState.error, '心跳超时，断开连接');
      disconnect();
    }
  }

  Future<void> installHap(String hapPath) async {
    // 已迁移：UI 直接 await installApp() 拿 InstallResult。
    // 保留空实现避免历史调用方编译失败。
    await installApp(hapPath);
  }

  /// 安装 hap，强制 -r。返回结构化结果供 UI 弹窗。
  Future<AppActionResult> installApp(String hapPath) async {
    final dev = selectedDevice;
    if (dev == null) return const AppActionResult.fail('未选择设备');
    try {
      final out = await hdc.installHap(dev.serial, hapPath);
      // 安装可能产生新的可卸载应用，刷新列表
      requestAppList();
      return AppActionResult.ok(out);
    } catch (e) {
      return AppActionResult.fail(e is HdcException ? e.message : e.toString());
    }
  }

  /// 卸载应用。成功后从本地 apps 中移除该项，并请求服务端刷新。
  Future<AppActionResult> uninstallApp(String bundle) async {
    final dev = selectedDevice;
    if (dev == null) return const AppActionResult.fail('未选择设备');
    try {
      final out = await hdc.uninstall(dev.serial, bundle);
      apps.removeWhere((a) => a.bundle == bundle);
      notifyListeners();
      requestAppList();
      return AppActionResult.ok(out);
    } catch (e) {
      return AppActionResult.fail(e is HdcException ? e.message : e.toString());
    }
  }

  /// 通过 scrcpy 协议 TEXT_INPUT（0x15）通道发送 UTF-8 文本到服务端。
  /// 服务端收到后以剪贴板粘贴方式注入当前焦点文本框。
  AppActionResult sendTextInput(String text) {
    if (connState != ConnState.connected) {
      return const AppActionResult.fail('未连接');
    }
    if (text.isEmpty) {
      return const AppActionResult.fail('文本为空');
    }
    debugPrint('[sendTextInput] text="$text"');
    stream.send(PacketType.control,
        encodeControl(ControlSubType.textInput, encodeTextInput(text)));
    return const AppActionResult.ok('文本已发送');
  }

  /// 通过 hdc uitest uiInput inputText 注入文本到设备焦点输入框。
  /// 保留作为备选方案，当前 UI 走 [sendTextInput] 协议通道。
  Future<AppActionResult> inputText(String text) async {
    final dev = selectedDevice;
    if (dev == null) return const AppActionResult.fail('未选择设备');
    debugPrint('[inputText] lastTouch=($lastTouchX, $lastTouchY) text="$text"');
    try {
      await hdc.uitestInputText(lastTouchX, lastTouchY, text);
      return const AppActionResult.ok('文本已发送');
    } catch (e) {
      debugPrint('[inputText] error: $e');
      return AppActionResult.fail(e is HdcException ? e.message : e.toString());
    }
  }

  /// 通过 hdc uitest uiInput swipe 模拟滚动。
  /// [scrollUp] true 表示内容向上滚（手指从下向上滑）。
  bool _scrollBusy = false;
  double _scrollAccum = 0;
  int _scrollX = 0;
  int _scrollY = 0;
  Timer? _scrollTimer;

  void scrollAtPosition(int devX, int devY, double deltaY) {
    final cfg = videoConfig;
    if (cfg == null) return;
    if (selectedDevice == null) return;
    _scrollX = devX;
    _scrollY = devY;
    _scrollAccum += deltaY;
    _scrollTimer?.cancel();
    _scrollTimer = Timer(const Duration(milliseconds: 100), () {
      _fireScroll(cfg.height);
    });
    if (!_scrollBusy) {
      _fireScroll(cfg.height);
    }
  }

  void _fireScroll(int devH) {
    if (_scrollAccum.abs() < 10) return;
    if (_scrollBusy) return;
    _scrollBusy = true;
    _scrollTimer?.cancel();
    final distance = (_scrollAccum * 2).clamp(-1200.0, 1200.0).toInt();
    _scrollAccum = 0;
    final y1 = _scrollY;
    final y2 = (y1 + distance).clamp(0, devH - 1);
    debugPrint('[scroll] fire swipe($_scrollX,$y1 -> $_scrollX,$y2)');
    hdc.uitestSwipe(_scrollX, y1, _scrollX, y2, velocity: 2000).whenComplete(() {
      _scrollBusy = false;
      if (_scrollAccum.abs() >= 10) {
        _fireScroll(devH);
      }
    });
  }

  /// 通过 0x10/0x30 控制包请求服务端下发可卸载应用列表。
  void requestAppList() {
    if (connState != ConnState.connected) return;
    appsLoading = true;
    notifyListeners();
    stream.send(PacketType.control, encodeControl(ControlSubType.listApps, Uint8List(0)));
  }

  Future<void> _cleanupForward() async {
    final dev = selectedDevice;
    final lp = localPort;
    if (dev != null && lp != null) {
      try {
        await hdc.removeForward(dev.serial, lp);
      } catch (_) {}
    }
    localPort = null;
  }

  void _setState(ConnState s, String msg) {
    connState = s;
    statusMessage = msg;
    notifyListeners();
  }

  @override
  void dispose() {
    _stopHeartbeat();
    _stopStatsTicker();
    disconnect();
    terminal?.kill();
    stream.dispose();
    super.dispose();
  }
}
