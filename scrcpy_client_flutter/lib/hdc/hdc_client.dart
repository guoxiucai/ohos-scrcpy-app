import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'device.dart';

/// 包装系统 hdc CLI。优先使用应用内嵌的 hdc，其次查找系统 PATH。
class HdcClient {
  String _hdcPath;
  bool _resolved = false;

  HdcClient({String hdcPath = 'hdc'}) : _hdcPath = hdcPath;

  String get hdcPath => _hdcPath;

  /// 触发路径解析并返回绝对路径；供 PTY 启动时使用（GUI 进程 PATH 受限，必须传绝对路径）。
  Future<String> resolvedPath() async {
    await _resolveHdc();
    return _hdcPath;
  }
  /// Finder/Dock 启动的 GUI 进程 PATH 只有 `/usr/bin:/bin:/usr/sbin:/sbin`，
  /// 直接 `Process.run('hdc')` 会 No such file or directory。
  /// 先 `which`，再借用户登录 shell（继承 ~/.zshrc 的 PATH），最后扫常见 SDK 路径。
  Future<void> _resolveHdc() async {
    if (_resolved) return;
    _resolved = true;
    if (_hdcPath != 'hdc' && await File(_hdcPath).exists()) return;

    // 优先使用应用内嵌的 hdc
    final bundled = _bundledHdcPath();
    if (bundled != null && await File(bundled).exists()) {
      _hdcPath = bundled;
      return;
    }

    Future<String?> tryRun(String exe, List<String> args) async {
      try {
        final r = await Process.run(exe, args);
        if (r.exitCode == 0) {
          final out = (r.stdout as String).trim();
          if (out.isNotEmpty && await File(out.split('\n').first).exists()) {
            return out.split('\n').first;
          }
        }
      } catch (_) {}
      return null;
    }

    final which = await tryRun('/usr/bin/which', ['hdc']);
    if (which != null) { _hdcPath = which; return; }

    if (Platform.isWindows) {
      final where = await tryRun('where', ['hdc']);
      if (where != null) { _hdcPath = where; return; }
    }

    if (Platform.isMacOS || Platform.isLinux) {
      final shell = Platform.environment['SHELL'] ?? '/bin/zsh';
      final viaShell = await tryRun(shell, ['-l', '-i', '-c', 'command -v hdc']);
      if (viaShell != null) { _hdcPath = viaShell; return; }
    }

    final home = Platform.environment['HOME'] ?? '';
    final localAppData = Platform.environment['LOCALAPPDATA'] ?? '';
    final programFiles = Platform.environment['ProgramFiles'] ?? '';
    final candidates = <String>[
      if (home.isNotEmpty) ...[
        '$home/Library/OpenHarmony/Sdk/12/toolchains/hdc',
        '$home/Library/OpenHarmony/Sdk/20/toolchains/hdc',
        '$home/Library/Huawei/Sdk/openharmony/12/toolchains/hdc',
      ],
      '/Applications/DevEco-Studio.app/Contents/sdk/default/openharmony/toolchains/hdc',
      if (programFiles.isNotEmpty) ...[
        '$programFiles\\Huawei\\DevEco Studio\\sdk\\default\\openharmony\\toolchains\\hdc.exe',
      ],
      if (localAppData.isNotEmpty) ...[
        '$localAppData\\Huawei\\Sdk\\openharmony\\12\\toolchains\\hdc.exe',
        '$localAppData\\Huawei\\Sdk\\openharmony\\20\\toolchains\\hdc.exe',
      ],
    ];
    for (final p in candidates) {
      if (await File(p).exists()) { _hdcPath = p; return; }
    }
  }

  String? _bundledHdcPath() {
    final exe = Platform.resolvedExecutable;
    if (Platform.isMacOS) {
      final idx = exe.indexOf('/Contents/');
      if (idx < 0) return null;
      return '${exe.substring(0, idx)}/Contents/Resources/hdc';
    } else if (Platform.isWindows) {
      return '${File(exe).parent.path}\\tools\\hdc.exe';
    } else if (Platform.isLinux) {
      return '${File(exe).parent.path}/tools/hdc';
    }
    return null;
  }

  Future<ProcessResult> _run(List<String> args, {Duration? timeout}) async {
    await _resolveHdc();
    try {
      final fut = Process.run(_hdcPath, args, stdoutEncoding: utf8, stderrEncoding: utf8);
      return timeout == null ? await fut : await fut.timeout(timeout);
    } on ProcessException {
      throw HdcException('找不到 hdc 命令，请重新安装应用。');
    }
  }

  /// `hdc list targets` -> [HdcDevice]，设备名通过 `hdc shell param get const.product.name` 获取
  Future<List<HdcDevice>> devices() async {
    final r = await _run(['list', 'targets'], timeout: const Duration(seconds: 5));
    if (r.exitCode != 0) {
      throw HdcException('list targets failed: ${r.stderr}');
    }
    final lines = (r.stdout as String).split(RegExp(r'\r?\n'));
    final out = <HdcDevice>[];
    for (final raw in lines) {
      final line = raw.trim();
      if (line.isEmpty || line.startsWith('[Empty]') || line.startsWith('[Info]')) continue;
      // 例： "1234567890ABCDEF    Connected"
      final parts = line.split(RegExp(r'\s+'));
      if (parts.isEmpty) continue;
      final serial = parts[0];
      final state = parts.length > 1 ? parts[1] : 'Unknown';
      // 判断连接类型：包含 "." 通常是网络，否则 USB
      final connection = serial.contains('.') ? 'TCP' : 'USB';

      // 获取设备名
      String name = '';
      try {
        final nameResult = await _run(['-t', serial, 'shell', 'param get const.product.name'],
            timeout: const Duration(seconds: 5));
        name = (nameResult.stdout as String).trim();
        // 清理可能的空字节或多余空白
        name = name.replaceAll('\u{0000}', '').replaceAll(RegExp(r'\s+'), ' ');
      } catch (_) {
        // 忽略名称获取失败
      }

      out.add(HdcDevice(serial: serial, state: state, connection: connection, name: name));
    }
    return out;
  }

  /// `hdc -t SN fport tcp:0 tcp:devicePort` —— 让系统挑随机端口，解析回显得到本机端口。
  /// 若 hdc 不支持 tcp:0，则随机本机端口后重试。
  Future<int> forwardPort(String serial, int devicePort) async {
    int? localPort = await _tryFport(serial, 0, devicePort);
    if (localPort != null) return localPort;
    // fallback: 随机一个高端口
    final rand = 49152 + (DateTime.now().microsecondsSinceEpoch % 16000);
    for (var p = rand; p < rand + 50; p++) {
      final ok = await _tryFport(serial, p, devicePort);
      if (ok != null) return ok;
    }
    throw HdcException('forwardPort 全部失败');
  }

  Future<int?> _tryFport(String serial, int localPort, int devicePort) async {
    final r = await _run([
      '-t', serial, 'fport',
      'tcp:$localPort', 'tcp:$devicePort'
    ], timeout: const Duration(seconds: 5));
    if (r.exitCode != 0) return null;
    final stdout = (r.stdout as String) + (r.stderr as String);
    if (localPort != 0) {
      // 根据返回判断是否成功
      if (stdout.contains('Forwardport result:OK') || stdout.contains('forward')) {
        return localPort;
      }
      return null;
    }
    final m = RegExp(r'tcp:(\d+)\s+tcp:').firstMatch(stdout);
    if (m != null) return int.parse(m.group(1)!);
    final m2 = RegExp(r'localhost:(\d+)').firstMatch(stdout);
    if (m2 != null) return int.parse(m2.group(1)!);
    return null;
  }

  Future<void> removeForward(String serial, int localPort, {int devicePort = 53535}) async {
    await _run(['-t', serial, 'fport', 'rm', 'tcp:$localPort', 'tcp:$devicePort'], timeout: const Duration(seconds: 5));
  }

  /// 安装 hap（默认覆盖安装 -r）。成功返回 stdout，失败抛 [HdcException] 带 stderr。
  Future<String> installHap(String serial, String hapPath, {bool replace = true}) async {
    final args = <String>['-t', serial, 'install'];
    if (replace) args.add('-r');
    args.add(hapPath);
    final r = await _run(args, timeout: const Duration(seconds: 60));
    final stdout = (r.stdout as String).trim();
    final stderr = (r.stderr as String).trim();
    final combined = [stdout, stderr].where((s) => s.isNotEmpty).join('\n');
    // hdc 在某些场景退出码为 0 但 stdout 含 "fail" / "Failed" 字样
    final lower = combined.toLowerCase();
    final fail = r.exitCode != 0 ||
        lower.contains('install fail') ||
        lower.contains('install failed') ||
        lower.contains('failure[');
    if (fail) {
      throw HdcException(combined.isEmpty ? 'install exit=${r.exitCode}' : combined);
    }
    return combined.isEmpty ? 'install ok' : combined;
  }

  /// 卸载应用。成功返回 stdout，失败抛 [HdcException]。
  Future<String> uninstall(String serial, String bundle) async {
    final r = await _run(
      ['-t', serial, 'uninstall', bundle],
      timeout: const Duration(seconds: 30),
    );
    final stdout = (r.stdout as String).trim();
    final stderr = (r.stderr as String).trim();
    final combined = [stdout, stderr].where((s) => s.isNotEmpty).join('\n');
    final lower = combined.toLowerCase();
    final fail = r.exitCode != 0 ||
        lower.contains('uninstall fail') ||
        lower.contains('uninstall failed') ||
        lower.contains('failure[');
    if (fail) {
      throw HdcException(combined.isEmpty ? 'uninstall exit=${r.exitCode}' : combined);
    }
    return combined.isEmpty ? 'uninstall ok' : combined;
  }

  Future<String> shell(String serial, String cmd, {Duration timeout = const Duration(seconds: 10)}) async {
    final r = await _run(['-t', serial, 'shell', cmd], timeout: timeout);
    return ((r.stdout as String) + (r.stderr as String)).trim();
  }

  /// 通过 uitest uiInput inputText 注入文本到设备指定坐标的输入框。
  /// 格式：hdc shell uitest uiInput inputText x y text
  /// 多行文本自动拆分，行间发送 Enter 键(2054)。
  Future<void> uitestInputText(int x, int y, String text) async {
    if (text.contains('\n')) {
      final lines = text.split('\n');
      for (int i = 0; i < lines.length; i++) {
        if (lines[i].isNotEmpty) {
          await _run(['shell', 'uitest', 'uiInput', 'inputText', '$x', '$y', lines[i]],
              timeout: const Duration(seconds: 10));
        }
        if (i < lines.length - 1) {
          await _run(['shell', 'uitest', 'uiInput', 'keyEvent', '2054'],
              timeout: const Duration(seconds: 5));
        }
      }
    } else {
      await _run(['shell', 'uitest', 'uiInput', 'inputText', '$x', '$y', text],
          timeout: const Duration(seconds: 10));
    }
  }

  /// 通过 uitest uiInput swipe 执行滑动操作。
  /// velocity 范围 200-40000，默认 600。
  Future<void> uitestSwipe(int x1, int y1, int x2, int y2, {int velocity = 600}) async {
    await _run([
      'shell', 'uitest', 'uiInput', 'swipe',
      '$x1', '$y1', '$x2', '$y2', '$velocity',
    ], timeout: const Duration(seconds: 10));
  }
}

class HdcException implements Exception {
  final String message;
  HdcException(this.message);
  @override
  String toString() => 'HdcException: $message';
}
