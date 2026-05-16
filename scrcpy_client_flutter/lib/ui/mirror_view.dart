import 'dart:io';
import 'dart:typed_data';

import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../net/protocol.dart';
import '../state/app_state.dart';
import 'empty_state.dart';
import 'theme.dart';

class MirrorView extends StatefulWidget {
  final AppState state;
  const MirrorView({super.key, required this.state});

  @override
  State<MirrorView> createState() => _MirrorViewState();
}

class _MirrorViewState extends State<MirrorView> {
  final GlobalKey _viewKey = GlobalKey();
  final Map<int, int> _pointerButtonMap = {};
  final FocusNode _focusNode = FocusNode();
  bool _trackpadScrolling = false;

  @override
  void dispose() {
    _focusNode.dispose();
    super.dispose();
  }

  int? _mapKey(LogicalKeyboardKey key) {
    if (key == LogicalKeyboardKey.space) return OhKeyCode.space;
    if (key == LogicalKeyboardKey.enter) return OhKeyCode.enter;
    if (key == LogicalKeyboardKey.tab) return OhKeyCode.tab;
    if (key == LogicalKeyboardKey.escape) return OhKeyCode.escape;
    if (key == LogicalKeyboardKey.backspace) return OhKeyCode.del;
    if (key == LogicalKeyboardKey.delete) return OhKeyCode.forwardDel;
    if (key == LogicalKeyboardKey.arrowUp) return OhKeyCode.dpadUp;
    if (key == LogicalKeyboardKey.arrowDown) return OhKeyCode.dpadDown;
    if (key == LogicalKeyboardKey.arrowLeft) return OhKeyCode.dpadLeft;
    if (key == LogicalKeyboardKey.arrowRight) return OhKeyCode.dpadRight;
    if (key == LogicalKeyboardKey.shiftLeft) return OhKeyCode.shiftLeft;
    if (key == LogicalKeyboardKey.shiftRight) return OhKeyCode.shiftRight;
    if (key == LogicalKeyboardKey.controlLeft) return OhKeyCode.ctrlLeft;
    if (key == LogicalKeyboardKey.controlRight) return OhKeyCode.ctrlRight;
    if (key == LogicalKeyboardKey.altLeft) return OhKeyCode.altLeft;
    if (key == LogicalKeyboardKey.capsLock) return OhKeyCode.capsLock;
    if (key == LogicalKeyboardKey.minus) return OhKeyCode.minus;
    if (key == LogicalKeyboardKey.equal) return OhKeyCode.equals;
    if (key == LogicalKeyboardKey.bracketLeft) return OhKeyCode.leftBracket;
    if (key == LogicalKeyboardKey.bracketRight) return OhKeyCode.rightBracket;
    if (key == LogicalKeyboardKey.backslash) return OhKeyCode.backslash;
    if (key == LogicalKeyboardKey.semicolon) return OhKeyCode.semicolon;
    if (key == LogicalKeyboardKey.quoteSingle) return OhKeyCode.apostrophe;
    if (key == LogicalKeyboardKey.comma) return OhKeyCode.comma;
    if (key == LogicalKeyboardKey.period) return OhKeyCode.period;
    if (key == LogicalKeyboardKey.slash) return OhKeyCode.slash;
    if (key == LogicalKeyboardKey.backquote) return OhKeyCode.grave;
    // A-Z
    final keyId = key.keyId;
    if (keyId >= LogicalKeyboardKey.keyA.keyId &&
        keyId <= LogicalKeyboardKey.keyZ.keyId) {
      return OhKeyCode.a + (keyId - LogicalKeyboardKey.keyA.keyId);
    }
    // 0-9
    if (keyId >= LogicalKeyboardKey.digit0.keyId &&
        keyId <= LogicalKeyboardKey.digit9.keyId) {
      return OhKeyCode.key0 + (keyId - LogicalKeyboardKey.digit0.keyId);
    }
    // F1-F12
    if (keyId >= LogicalKeyboardKey.f1.keyId &&
        keyId <= LogicalKeyboardKey.f12.keyId) {
      return OhKeyCode.f1 + (keyId - LogicalKeyboardKey.f1.keyId);
    }
    return null;
  }

  KeyEventResult _onKeyEvent(FocusNode node, KeyEvent event) {
    if (widget.state.connState != ConnState.connected) {
      return KeyEventResult.ignored;
    }
    final ohKey = _mapKey(event.logicalKey);
    if (ohKey == null) return KeyEventResult.ignored;
    final isDown = event is KeyDownEvent || event is KeyRepeatEvent;
    final isUp = event is KeyUpEvent;
    if (!isDown && !isUp) return KeyEventResult.ignored;
    widget.state.sendControl(
      ControlSubType.keyEvent,
      encodeKeyEvent(isDown, ohKey),
    );
    return KeyEventResult.handled;
  }  // pointer -> button type (0=touch, 2=right, 1=middle)

  Uint8List _touchPayload(Offset local, Size renderSize, int devW, int devH, int pointerId) {
    final x = (local.dx / renderSize.width  * devW).clamp(0.0, devW.toDouble() - 1);
    final y = (local.dy / renderSize.height * devH).clamp(0.0, devH.toDouble() - 1);
    widget.state.lastTouchX = x.toInt();
    widget.state.lastTouchY = y.toInt();
    return encodeTouch(x, y, pointerId);
  }

  Uint8List _mousePayload(Offset local, Size renderSize, int devW, int devH,
      int action, int button, {double axisValue = 0}) {
    final x = (local.dx / renderSize.width  * devW).clamp(0.0, devW.toDouble() - 1);
    final y = (local.dy / renderSize.height * devH).clamp(0.0, devH.toDouble() - 1);
    return encodeMouseEvent(action, button, x, y, axisValue);
  }

  Size _renderedSize() {
    final ctx = _viewKey.currentContext;
    if (ctx == null) return Size.zero;
    final box = ctx.findRenderObject();
    if (box is RenderBox && box.hasSize) return box.size;
    return Size.zero;
  }

  @override
  Widget build(BuildContext context) {
    final state = widget.state;
    final cfg = state.videoConfig;
    final id = state.decoder.textureId;
    final connected = state.connState == ConnState.connected;

    return Listener(
      onPointerSignal: (e) {
        if (e is PointerScrollEvent) {
          if (!connected || cfg == null) return;
          final size = _renderedSize();
          if (size.isEmpty) return;
          final devW = cfg.width;
          final devH = cfg.height;
          final devX = (e.localPosition.dx / size.width * devW).clamp(0.0, devW.toDouble() - 1).toInt();
          final devY = (e.localPosition.dy / size.height * devH).clamp(0.0, devH.toDouble() - 1).toInt();
          widget.state.scrollAtPosition(devX, devY, e.scrollDelta.dy);
        }
      },
      onPointerPanZoomStart: (e) {
        _trackpadScrolling = true;
      },
      onPointerPanZoomEnd: (e) {
        _trackpadScrolling = false;
      },
      onPointerPanZoomUpdate: (e) {
        if (!connected || cfg == null) return;
        if (e.panDelta.dy.abs() < 2) return;
        final size = _renderedSize();
        if (size.isEmpty) return;
        final devW = cfg.width;
        final devH = cfg.height;
        final devX = (e.localPosition.dx / size.width * devW).clamp(0.0, devW.toDouble() - 1).toInt();
        final devY = (e.localPosition.dy / size.height * devH).clamp(0.0, devH.toDouble() - 1).toInt();
        // panDelta.dy 正值=手指向下滑=内容向上滚，与 scrollDelta 方向一致
        widget.state.scrollAtPosition(devX, devY, e.panDelta.dy);
      },
      child: Focus(
      focusNode: _focusNode,
      autofocus: true,
      onKeyEvent: _onKeyEvent,
      child: Container(
          color: AppColors.bg,
          child: Column(
        children: [
          Expanded(
            child: Container(
              margin: const EdgeInsets.all(12),
              decoration: BoxDecoration(
                color: Colors.black,
                border: Border.all(color: AppColors.borderStrong),
                borderRadius: BorderRadius.circular(AppRadius.md),
                gradient: const RadialGradient(
                  center: Alignment.center,
                  radius: 1.0,
                  colors: [Color(0xFF0F172A), Colors.black],
                ),
              ),
              clipBehavior: Clip.antiAlias,
              child: Center(
                child: !connected
                    ? const EmptyState(message: '请选择设备并点击「连接」')
                    : (cfg == null
                        ? const _Waiting(message: '等待视频流…')
                        : _buildMirror(cfg, id)),
              ),
            ),
          ),
          _StatusBar(state: state),
        ],
      ),
    ),
    ),
    );
  }

  Widget _buildMirror(VideoConfig cfg, int? textureId) {
    final ratio = cfg.width / cfg.height;
    final child = (textureId == null || textureId < 0)
        ? Container(
            color: AppColors.elevated,
            alignment: Alignment.center,
            child: Text(
              Platform.isWindows ? '等待解码器就绪…' : '原生解码插件未实现，占位渲染',
              style: const TextStyle(color: AppColors.textMuted, fontSize: 12),
            ),
          )
        : Texture(textureId: textureId);
    return AspectRatio(
      aspectRatio: ratio,
      child: Listener(
        key: _viewKey,
        behavior: HitTestBehavior.opaque,
        onPointerDown: (e) {
          if (_trackpadScrolling) return;
          _focusNode.requestFocus();
          final size = _renderedSize();
          if (size.isEmpty) return;
          if (e.buttons & kSecondaryButton != 0) {
            _pointerButtonMap[e.pointer] = MouseButton.right;
            widget.state.sendControl(
              ControlSubType.mouseEvent,
              _mousePayload(e.localPosition, size, cfg.width, cfg.height,
                  MouseAction.buttonDown, MouseButton.right));
          } else if (e.buttons & kTertiaryButton != 0) {
            _pointerButtonMap[e.pointer] = MouseButton.middle;
            widget.state.sendControl(
              ControlSubType.mouseEvent,
              _mousePayload(e.localPosition, size, cfg.width, cfg.height,
                  MouseAction.buttonDown, MouseButton.middle));
          } else {
            _pointerButtonMap[e.pointer] = -1;
            widget.state.sendControl(
              ControlSubType.touchDown,
              _touchPayload(e.localPosition, size, cfg.width, cfg.height, e.pointer & 0xFFFF));
          }
        },
        onPointerMove: (e) {
          final size = _renderedSize();
          if (size.isEmpty) return;
          final btn = _pointerButtonMap[e.pointer] ?? -1;
          if (btn >= 0) return;
          widget.state.sendControl(
            ControlSubType.touchMove,
            _touchPayload(e.localPosition, size, cfg.width, cfg.height, e.pointer & 0xFFFF));
        },
        onPointerUp: (e) {
          final size = _renderedSize();
          if (size.isEmpty) return;
          final btn = _pointerButtonMap.remove(e.pointer) ?? -1;
          if (btn >= 0) {
            widget.state.sendControl(
              ControlSubType.mouseEvent,
              _mousePayload(e.localPosition, size, cfg.width, cfg.height,
                  MouseAction.buttonUp, btn));
          } else {
            widget.state.sendControl(
              ControlSubType.touchUp,
              _touchPayload(e.localPosition, size, cfg.width, cfg.height, e.pointer & 0xFFFF));
          }
        },
        onPointerCancel: (e) {
          final size = _renderedSize();
          if (size.isEmpty) return;
          widget.state.sendControl(
            ControlSubType.touchUp,
            _touchPayload(e.localPosition, size, cfg.width, cfg.height, e.pointer & 0xFFFF));
        },
        child: child,
      ),
    );
  }
}

class _Waiting extends StatelessWidget {
  final String message;
  const _Waiting({required this.message});
  @override
  Widget build(BuildContext context) {
    return Column(
      mainAxisSize: MainAxisSize.min,
      children: [
        const SizedBox(
          width: 32, height: 32,
          child: CircularProgressIndicator(strokeWidth: 2.0, color: AppColors.accent),
        ),
        const SizedBox(height: 14),
        Text(
          message,
          style: const TextStyle(color: AppColors.textSecondary, fontSize: 12),
        ),
        const SizedBox(height: 4),
        const Text(
          'STREAMING...',
          style: TextStyle(
            color: AppColors.textFaint,
            fontSize: 10,
            letterSpacing: 1.4,
            fontWeight: FontWeight.w600,
            fontFamily: kMonoFontFamily,
          ),
        ),
      ],
    );
  }
}

class _StatusBar extends StatelessWidget {
  final AppState state;
  const _StatusBar({required this.state});

  @override
  Widget build(BuildContext context) {
    final cfg = state.videoConfig;
    final isH264 = cfg != null && cfg.codec == VideoCodec.h264;
    final isConnected = state.connState == ConnState.connected;
    final canControl = isH264 && isConnected;

    final res = cfg == null ? '—' : '${cfg.width}×${cfg.height}';
    final cfgFps = cfg == null
        ? '—'
        : canControl
            ? '${state.targetFps}fps'
            : '${cfg.fps}fps';
    final liveFps = isConnected && cfg != null
        ? '${state.fps.toStringAsFixed(0)}fps'
        : '—';
    final codecLabel = cfg == null
        ? '—'
        : (cfg.codec == VideoCodec.rawRgba
            ? 'RAW'
            : cfg.codec == VideoCodec.h264
                ? 'H264'
                : cfg.codec == VideoCodec.jpeg
                    ? 'JPEG'
                    : 'CODEC ${cfg.codec}');

    return Container(
      height: 28,
      padding: const EdgeInsets.symmetric(horizontal: 14),
      decoration: const BoxDecoration(
        color: AppColors.surface,
        border: Border(top: BorderSide(color: AppColors.border)),
      ),
      alignment: Alignment.centerLeft,
      child: DefaultTextStyle.merge(
        style: const TextStyle(
          color: AppColors.textSecondary,
          fontSize: 11,
          fontFamily: kMonoFontFamily,
          letterSpacing: 0.2,
        ),
        child: Row(
          children: [
            _stat(Icons.memory, codecLabel),
            const _Sep(),
            _resolutionMenu(context, res, canControl),
            const _Sep(),
            _fpsMenu(context, '$liveFps / $cfgFps', canControl),
            const _Sep(),
            _stat(Icons.movie_filter_outlined, '${state.frames} frames'),
          ],
        ),
      ),
    );
  }

  Widget _resolutionMenu(BuildContext context, String label, bool enabled) {
    if (!enabled) return _stat(Icons.aspect_ratio, label);
    final current = state.targetMaxShort;
    return PopupMenuButton<int>(
      tooltip: '切换分辨率',
      offset: const Offset(0, -80),
      padding: EdgeInsets.zero,
      constraints: const BoxConstraints(),
      onSelected: (v) => state.changeVideoParams(maxShort: v),
      itemBuilder: (_) => [
        _menuItem(1080, '1080p  (最短边≤1080)', current),
        _menuItem(2160, '2160p  (最短边≤2160)', current),
      ],
      child: _stat(Icons.aspect_ratio, label,
          color: AppColors.accent, underline: true),
    );
  }

  Widget _fpsMenu(BuildContext context, String label, bool enabled) {
    if (!enabled) return _stat(Icons.speed, label);
    final current = state.targetFps;
    return PopupMenuButton<int>(
      tooltip: '切换帧率',
      offset: const Offset(0, -100),
      padding: EdgeInsets.zero,
      constraints: const BoxConstraints(),
      onSelected: (v) => state.changeVideoParams(fps: v),
      itemBuilder: (_) => [
        _menuItem(20, '20 fps', current),
        _menuItem(15, '15 fps', current),
        _menuItem(8, '8 fps', current),
      ],
      child: _stat(Icons.speed, label,
          color: AppColors.accent, underline: true),
    );
  }

  PopupMenuItem<int> _menuItem(int value, String text, int current) {
    return PopupMenuItem<int>(
      value: value,
      height: 36,
      child: Row(
        children: [
          Icon(
            value == current ? Icons.check : Icons.circle_outlined,
            size: 14,
            color: value == current ? AppColors.accent : AppColors.textMuted,
          ),
          const SizedBox(width: 8),
          Text(text,
              style: TextStyle(
                fontSize: 12,
                color: value == current
                    ? AppColors.accent
                    : AppColors.textSecondary,
              )),
        ],
      ),
    );
  }

  Widget _stat(IconData icon, String text,
      {Color? color, bool underline = false}) {
    final textColor = color ?? AppColors.textSecondary;
    return Row(
      children: [
        Icon(icon, size: 12, color: color ?? AppColors.textMuted),
        const SizedBox(width: 6),
        Text(text,
            style: TextStyle(
              color: textColor,
              decoration: underline ? TextDecoration.underline : null,
              decorationColor: textColor,
            )),
      ],
    );
  }
}

class _Sep extends StatelessWidget {
  const _Sep();
  @override
  Widget build(BuildContext context) {
    return Container(
      width: 1, height: 12,
      margin: const EdgeInsets.symmetric(horizontal: 12),
      color: AppColors.border,
    );
  }
}
