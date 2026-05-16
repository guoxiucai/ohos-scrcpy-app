import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:flutter_pty/flutter_pty.dart';
import 'package:xterm/xterm.dart';

/// 单个终端会话：负责绑定一个 [Terminal] 与 PTY 子进程的双向流。
///
/// - macOS/Linux：PTY 启动 `hdc -t <sn> shell`，真交互式 shell。
/// - Windows：PTY 启动 `powershell.exe`，类似 VSCode 内嵌终端，用户自行输入命令。
///
/// 生命周期：[start] → ([resize] / 输入) → [kill] / [rebind]。
/// 关闭抽屉不杀进程；切设备走 [rebind]；应用退出走 [kill]。
class PtySession {
  PtySession({Terminal? terminal})
      : terminal = terminal ??
            Terminal(maxLines: 5000, inputHandler: defaultInputHandler);

  final Terminal terminal;

  Pty? _pty;
  String? _boundSn;
  StreamSubscription<Uint8List>? _outSub;
  bool _terminalWired = false;
  bool _starting = false;

  String? get boundSn => _boundSn;
  bool get isRunning => _pty != null;

  /// 以新 SN 启动终端；若已有进程会被先 kill。
  /// macOS/Linux：启动 `hdc -t <sn> shell`
  /// Windows：启动 `powershell.exe`（hdc 不支持 ConPTY 交互式 shell）
  Future<void> start(String sn, {int rows = 24, int cols = 80, String hdcPath = 'hdc'}) async {
    if (_starting) return;
    if (!_isValidSn(sn)) {
      _writeLine('[invalid serial: $sn]');
      return;
    }
    _starting = true;
    try {
      await kill();
      try {
        if (Platform.isWindows) {
          _startWindowsPty(sn, rows, cols, hdcPath: hdcPath);
        } else {
          _writeLine('[starting $hdcPath -t $sn shell ...]');
          _startPty(hdcPath, sn, rows, cols);
        }
      } catch (e) {
        _pty = null;
        _boundSn = null;
        if (_isHdcMissing(e)) {
          _writeLine('[hdc not found in PATH]');
        } else {
          _writeLine('[start failed: $e]');
        }
      }
    } finally {
      _starting = false;
    }
  }

  /// macOS/Linux：PTY 启动 hdc shell
  void _startPty(String hdcPath, String sn, int rows, int cols) {
    final pty = Pty.start(
      hdcPath,
      arguments: ['-t', sn, 'shell'],
      rows: rows,
      columns: cols,
    );
    _pty = pty;
    _boundSn = sn;

    _outSub = pty.output.listen(
      (chunk) => terminal.write(_decode(chunk)),
      onError: (e) => _writeLine('[pty error: $e]'),
    );

    _wireTerminal();

    unawaited(pty.exitCode.then((code) {
      if (identical(_pty, pty)) {
        _pty = null;
        _boundSn = null;
        _writeLine('[process exited code=$code]');
      }
    }).catchError((e) {
      _writeLine('[process error: $e]');
    }));
  }

  /// Windows：PTY 启动 cmd.exe，自动进入 hdc shell
  void _startWindowsPty(String sn, int rows, int cols, {String hdcPath = 'hdc'}) {
    final env = Map<String, String>.from(Platform.environment);
    final pty = Pty.start(
      'cmd.exe',
      arguments: [],
      rows: rows,
      columns: cols,
      environment: env,
    );
    _pty = pty;
    _boundSn = sn;

    _outSub = pty.output.listen(
      (chunk) => terminal.write(_decode(chunk)),
      onError: (e) => _writeLine('[pty error: $e]'),
    );

    _wireTerminal();

    // 设置 UTF-8 编码后自动进入 hdc shell
    pty.write(Uint8List.fromList(utf8.encode('chcp 65001 >nul\r')));
    pty.write(Uint8List.fromList(utf8.encode('$hdcPath -t $sn shell\r')));

    unawaited(pty.exitCode.then((code) {
      if (identical(_pty, pty)) {
        _pty = null;
        _boundSn = null;
        _writeLine('[process exited code=$code]');
      }
    }).catchError((e) {
      _writeLine('[process error: $e]');
    }));
  }

  void _wireTerminal() {
    if (_terminalWired) return;
    terminal.onOutput = (data) {
      final p = _pty;
      if (p == null) return;
      try {
        p.write(Uint8List.fromList(utf8.encode(data)));
      } catch (_) {}
    };
    terminal.onResize = (w, h, pw, ph) {
      final p = _pty;
      if (p == null) return;
      try {
        p.resize(h.clamp(1, 1000), w.clamp(10, 1000));
      } catch (_) {}
    };
    _terminalWired = true;
  }

  /// 切设备：杀旧 shell 后启新 shell。
  Future<void> rebind(String newSn, {int rows = 24, int cols = 80, String hdcPath = 'hdc'}) async {
    if (newSn == _boundSn && isRunning) return;
    if (_boundSn != null) {
      _writeLine('[device changed: $_boundSn → $newSn, restarting shell]');
    }
    await start(newSn, rows: rows, cols: cols, hdcPath: hdcPath);
  }

  /// 主动重启（用户点 restart 按钮）。
  Future<void> restart({int rows = 24, int cols = 80, String hdcPath = 'hdc'}) async {
    final sn = _boundSn;
    if (sn == null) return;
    await start(sn, rows: rows, cols: cols, hdcPath: hdcPath);
  }

  void resize(int rows, int cols) {
    final p = _pty;
    if (p == null) return;
    try {
      p.resize(rows.clamp(1, 1000), cols.clamp(10, 1000));
    } catch (_) {}
  }

  /// 终止子进程；不抛异常。
  Future<void> kill() async {
    final p = _pty;
    final sub = _outSub;
    _pty = null;
    _outSub = null;
    if (sub != null) {
      try { await sub.cancel(); } catch (_) {}
    }
    if (p != null) {
      try { p.kill(ProcessSignal.sigterm); } catch (_) {}
      try { await p.exitCode.timeout(const Duration(seconds: 2)); } catch (_) {}
    }
    _boundSn = null;
  }

  void clear() {
    terminal.buffer.clear();
    terminal.buffer.setCursor(0, 0);
  }

  String _decode(List<int> chunk) {
    try {
      return utf8.decode(chunk, allowMalformed: true);
    } catch (_) {
      return String.fromCharCodes(chunk);
    }
  }

  void _writeLine(String s) {
    terminal.write('\x1b[90m$s\x1b[0m\r\n');
  }

  static bool _isValidSn(String sn) =>
      sn.isNotEmpty && RegExp(r'^[A-Za-z0-9._:\-]+$').hasMatch(sn);

  static bool _isHdcMissing(Object e) {
    final msg = e.toString().toLowerCase();
    return msg.contains('no such file') ||
        msg.contains('not found') ||
        msg.contains('cannot find') ||
        msg.contains('enoent');
  }
}
