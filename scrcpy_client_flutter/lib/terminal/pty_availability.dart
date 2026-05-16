import 'dart:io';

/// 平台 PTY 可用性检测。
///
/// macOS / Linux：直接 true（forkpty 一直可用）。
/// Windows：要求 build >= 17763（Win10 1809+，ConPTY API 起始版本）。
class PtyAvailability {
  static bool? _cached;
  static String? _reason;

  /// 是否支持嵌入 PTY 终端。
  static bool get isSupported {
    _cached ??= _detect();
    return _cached!;
  }

  /// 不支持时的原因（i18n 暂直接中文短句）。
  static String? get reason => _reason;

  static bool _detect() {
    if (Platform.isMacOS || Platform.isLinux) return true;
    if (Platform.isWindows) {
      final build = _windowsBuild();
      if (build == null) {
        _reason = '无法识别 Windows 版本';
        return false;
      }
      if (build < 17763) {
        _reason = '终端需要 Windows 10 1809 (Build 17763) 或更高，当前 Build $build';
        return false;
      }
      return true;
    }
    _reason = '当前平台不支持 PTY';
    return false;
  }

  /// 解析 Platform.operatingSystemVersion 中的 Build 号。
  /// macOS/Linux 上从不会被调用。
  static int? _windowsBuild() {
    final v = Platform.operatingSystemVersion;
    final m = RegExp(r'Build\s+(\d+)', caseSensitive: false).firstMatch(v);
    if (m != null) return int.tryParse(m.group(1)!);
    final parts = v.split('.');
    if (parts.length >= 3) {
      final b = int.tryParse(parts[2]);
      if (b != null) return b;
    }
    return null;
  }
}
