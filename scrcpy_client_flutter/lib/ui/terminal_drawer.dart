import 'dart:io' show Platform;

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:xterm/xterm.dart';

import '../state/app_state.dart';
import '../terminal/pty_session.dart';
import 'theme.dart';

/// 底部终端抽屉：标题条 + xterm TerminalView。
class TerminalDrawer extends StatelessWidget {
  final AppState state;
  const TerminalDrawer({super.key, required this.state});

  @override
  Widget build(BuildContext context) {
    final session = state.terminal;
    return Container(
      decoration: const BoxDecoration(
        color: AppColors.surface,
        border: Border(top: BorderSide(color: AppColors.border)),
      ),
      child: Column(
        children: [
          _Header(state: state),
          Expanded(
            child: session == null
                ? const _Idle()
                : _TerminalBody(session: session),
          ),
        ],
      ),
    );
  }
}

class _Header extends StatelessWidget {
  final AppState state;
  const _Header({required this.state});

  @override
  Widget build(BuildContext context) {
    final session = state.terminal;
    final running = session?.isRunning ?? false;
    final dotColor = session == null
        ? AppColors.idle
        : running
            ? AppColors.success
            : AppColors.warning;
    final boundSn = session?.boundSn ?? state.selectedDevice?.serial ?? '—';

    return Container(
      height: 32,
      padding: const EdgeInsets.symmetric(horizontal: 12),
      decoration: const BoxDecoration(
        color: AppColors.surfaceAlt,
        border: Border(bottom: BorderSide(color: AppColors.border)),
      ),
      child: Row(
        children: [
          Container(
            width: 7, height: 7,
            decoration: BoxDecoration(
              color: dotColor,
              shape: BoxShape.circle,
              boxShadow: [BoxShadow(color: dotColor.withOpacity(0.6), blurRadius: 6)],
            ),
          ),
          const SizedBox(width: 8),
          const Icon(Icons.terminal, size: 13, color: AppColors.textSecondary),
          const SizedBox(width: 6),
          const Text(
            'hdc shell',
            style: TextStyle(
              fontSize: 12,
              color: AppColors.textPrimary,
              fontWeight: FontWeight.w600,
              fontFamily: kMonoFontFamily,
            ),
          ),
          const SizedBox(width: 8),
          Container(width: 1, height: 14, color: AppColors.border),
          const SizedBox(width: 8),
          Flexible(
            child: Text(
              boundSn,
              overflow: TextOverflow.ellipsis,
              style: const TextStyle(
                fontSize: 11,
                color: AppColors.textMuted,
                fontFamily: kMonoFontFamily,
              ),
            ),
          ),
          const Spacer(),
          _HeaderBtn(
            icon: Icons.refresh,
            tooltip: '重启 shell',
            onPressed: state.selectedDevice == null ? null : () => state.restartTerminal(),
          ),
          const SizedBox(width: 4),
          _HeaderBtn(
            icon: Icons.cleaning_services_outlined,
            tooltip: '清屏',
            onPressed: session == null ? null : () => state.clearTerminal(),
          ),
          const SizedBox(width: 4),
          _HeaderBtn(
            icon: Icons.close,
            tooltip: '收起 (会话保留)',
            onPressed: () => state.setTerminalOpen(false),
          ),
        ],
      ),
    );
  }
}

class _HeaderBtn extends StatelessWidget {
  final IconData icon;
  final String tooltip;
  final VoidCallback? onPressed;
  const _HeaderBtn({required this.icon, required this.tooltip, this.onPressed});

  @override
  Widget build(BuildContext context) {
    return SizedBox(
      width: 24, height: 24,
      child: IconButton(
        tooltip: tooltip,
        onPressed: onPressed,
        padding: EdgeInsets.zero,
        icon: Icon(icon, size: 14),
        style: IconButton.styleFrom(
          foregroundColor: AppColors.textSecondary,
          shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(AppRadius.sm)),
        ),
      ),
    );
  }
}

class _Idle extends StatelessWidget {
  const _Idle();
  @override
  Widget build(BuildContext context) {
    return Container(
      color: const Color(0xFF050810),
      alignment: Alignment.center,
      child: const Text(
        '终端会话未启动',
        style: TextStyle(
          color: AppColors.textFaint,
          fontSize: 12,
          fontFamily: kMonoFontFamily,
        ),
      ),
    );
  }
}

class _TerminalBody extends StatefulWidget {
  final PtySession session;
  const _TerminalBody({required this.session});

  @override
  State<_TerminalBody> createState() => _TerminalBodyState();
}

class _TerminalBodyState extends State<_TerminalBody> {
  final FocusNode _focusNode = FocusNode();

  @override
  void dispose() {
    _focusNode.dispose();
    super.dispose();
  }

  static const _theme = TerminalTheme(
    cursor: AppColors.accent,
    selection: Color(0x4022D3EE),
    foreground: Color(0xFFCBD5E1),
    background: Color(0xFF050810),
    black: Color(0xFF1E293B),
    red: Color(0xFFEF4444),
    green: Color(0xFF22C55E),
    yellow: Color(0xFFF59E0B),
    blue: Color(0xFF3B82F6),
    magenta: Color(0xFFA855F7),
    cyan: Color(0xFF22D3EE),
    white: Color(0xFFE2E8F0),
    brightBlack: Color(0xFF334155),
    brightRed: Color(0xFFF87171),
    brightGreen: Color(0xFF4ADE80),
    brightYellow: Color(0xFFFBBF24),
    brightBlue: Color(0xFF60A5FA),
    brightMagenta: Color(0xFFC084FC),
    brightCyan: Color(0xFF67E8F9),
    brightWhite: Color(0xFFF8FAFC),
    searchHitBackground: Color(0xFF334155),
    searchHitBackgroundCurrent: Color(0xFF22D3EE),
    searchHitForeground: Color(0xFF0B1120),
  );

  /// 自带一份 shortcuts，避免 xterm 内部触发 TargetPlatform 的 switch
  /// （fork 的 Flutter 加了 ohos 枚举，xterm 4.0.0 没覆盖会编译报错）。
  Map<ShortcutActivator, Intent> _shortcuts() {
    final isApple = Platform.isMacOS || Platform.isIOS;
    final mod = isApple
        ? const SingleActivator(LogicalKeyboardKey.keyC, meta: true)
        : const SingleActivator(LogicalKeyboardKey.keyC, control: true, shift: true);
    final modV = isApple
        ? const SingleActivator(LogicalKeyboardKey.keyV, meta: true)
        : const SingleActivator(LogicalKeyboardKey.keyV, control: true);
    final modA = isApple
        ? const SingleActivator(LogicalKeyboardKey.keyA, meta: true)
        : const SingleActivator(LogicalKeyboardKey.keyA, control: true);
    return {
      mod: CopySelectionTextIntent.copy,
      modV: const PasteTextIntent(SelectionChangedCause.keyboard),
      modA: const SelectAllTextIntent(SelectionChangedCause.keyboard),
    };
  }

  @override
  Widget build(BuildContext context) {
    return GestureDetector(
      onTap: () => _focusNode.requestFocus(),
      child: ColoredBox(
        color: _theme.background,
        child: TerminalView(
          widget.session.terminal,
          focusNode: _focusNode,
          theme: _theme,
          textStyle: const TerminalStyle(
            fontFamily: kMonoFontFamily,
            fontSize: 12,
          ),
          padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 6),
          autofocus: true,
          hardwareKeyboardOnly: true,
          cursorType: TerminalCursorType.block,
          autoResize: true,
          backgroundOpacity: 1,
          shortcuts: _shortcuts(),
        ),
      ),
    );
  }
}
