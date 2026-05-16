import 'dart:io';
import 'dart:typed_data';

import 'package:file_picker/file_picker.dart';
import 'package:flutter/material.dart';

import '../net/protocol.dart';
import '../state/app_state.dart';
import 'dialogs.dart';
import 'theme.dart';

class Sidebar extends StatelessWidget {
  final AppState state;
  const Sidebar({super.key, required this.state});

  @override
  Widget build(BuildContext context) {
    return Container(
      decoration: const BoxDecoration(
        color: AppColors.surface,
        border: Border(left: BorderSide(color: AppColors.border)),
      ),
      child: ListView(
        padding: const EdgeInsets.all(12),
        children: [
          _Card(
            icon: Icons.archive_outlined,
            title: '应用安装',
            subtitle: 'INSTALL .HAP',
            child: _InstallPanel(state: state),
          ),
          const SizedBox(height: 10),
          _Card(
            icon: Icons.delete_outline,
            title: '应用卸载',
            subtitle: 'UNINSTALL APP',
            initiallyExpanded: false,
            child: _UninstallPanel(state: state),
          ),
          const SizedBox(height: 10),
          _Card(
            icon: Icons.settings_remote_outlined,
            title: '设备控制',
            subtitle: 'DEVICE CONTROL',
            child: _ControlPanel(state: state),
          ),
          const SizedBox(height: 10),
          _Card(
            icon: Icons.keyboard_outlined,
            title: '文本输入',
            subtitle: 'TEXT INPUT',
            initiallyExpanded: false,
            child: _TextInputPanel(state: state),
          ),
          const SizedBox(height: 10),
          _Card(
            icon: Icons.terminal,
            title: '终端',
            subtitle: 'SHELL · HDC',
            initiallyExpanded: false,
            child: _TerminalPanel(state: state),
          ),
        ],
      ),
    );
  }
}

class _Card extends StatefulWidget {
  final IconData icon;
  final String title;
  final String subtitle;
  final Widget child;
  final bool initiallyExpanded;

  const _Card({
    required this.icon,
    required this.title,
    required this.subtitle,
    required this.child,
    this.initiallyExpanded = true,
  });

  @override
  State<_Card> createState() => _CardState();
}

class _CardState extends State<_Card> {
  late bool _expanded = widget.initiallyExpanded;

  @override
  Widget build(BuildContext context) {
    return Container(
      decoration: BoxDecoration(
        color: AppColors.surfaceAlt,
        border: Border.all(color: AppColors.border),
        borderRadius: BorderRadius.circular(AppRadius.md),
      ),
      child: Column(
        children: [
          InkWell(
            onTap: () => setState(() => _expanded = !_expanded),
            borderRadius: BorderRadius.circular(AppRadius.md),
            child: Padding(
              padding: const EdgeInsets.fromLTRB(12, 10, 8, 10),
              child: Row(
                children: [
                  Icon(widget.icon, size: 14, color: AppColors.accent),
                  const SizedBox(width: 8),
                  Expanded(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text(
                          widget.title,
                          style: const TextStyle(
                            fontSize: 13,
                            fontWeight: FontWeight.w600,
                            color: AppColors.textPrimary,
                          ),
                        ),
                        const SizedBox(height: 2),
                        Text(
                          widget.subtitle,
                          style: const TextStyle(
                            fontSize: 9,
                            color: AppColors.textFaint,
                            letterSpacing: 1.2,
                            fontWeight: FontWeight.w600,
                            fontFamily: kMonoFontFamily,
                          ),
                        ),
                      ],
                    ),
                  ),
                  AnimatedRotation(
                    turns: _expanded ? 0.0 : -0.25,
                    duration: const Duration(milliseconds: 180),
                    child: const Icon(Icons.expand_more,
                        size: 18, color: AppColors.textMuted),
                  ),
                ],
              ),
            ),
          ),
          AnimatedCrossFade(
            firstChild: const SizedBox.shrink(),
            secondChild: Padding(
              padding: const EdgeInsets.fromLTRB(12, 0, 12, 12),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  Container(height: 1, color: AppColors.border),
                  const SizedBox(height: 12),
                  widget.child,
                ],
              ),
            ),
            crossFadeState: _expanded ? CrossFadeState.showSecond : CrossFadeState.showFirst,
            duration: const Duration(milliseconds: 180),
          ),
        ],
      ),
    );
  }
}

class _TerminalPanel extends StatelessWidget {
  final AppState state;
  const _TerminalPanel({required this.state});

  @override
  Widget build(BuildContext context) {
    final supported = state.terminalSupported;
    final reason = state.terminalUnsupportedReason;
    final hasDevice = state.selectedDevice != null;
    final isOpen = state.terminalOpen;

    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Container(
          padding: const EdgeInsets.all(10),
          decoration: BoxDecoration(
            color: AppColors.bg,
            border: Border.all(color: AppColors.border),
            borderRadius: BorderRadius.circular(AppRadius.sm),
          ),
          child: Row(
            children: [
              Icon(
                supported ? Icons.check_circle_outline : Icons.error_outline,
                size: 14,
                color: supported ? AppColors.success : AppColors.warning,
              ),
              const SizedBox(width: 8),
              Expanded(
                child: Text(
                  supported
                      ? 'PTY 后端已就绪 · ${_backendName()}'
                      : (reason ?? '当前平台不支持嵌入式终端'),
                  style: const TextStyle(
                    fontSize: 11,
                    color: AppColors.textSecondary,
                    height: 1.4,
                  ),
                ),
              ),
            ],
          ),
        ),
        const SizedBox(height: 10),
        SizedBox(
          height: 34,
          child: FilledButton.icon(
            onPressed: !supported || !hasDevice
                ? null
                : () => state.setTerminalOpen(!isOpen),
            icon: Icon(isOpen ? Icons.unfold_less : Icons.terminal, size: 14),
            label: Text(isOpen ? '收起终端' : '打开终端'),
          ),
        ),
        if (!hasDevice && supported) ...[
          const SizedBox(height: 8),
          const Text(
            '请先在顶栏选择设备',
            style: TextStyle(fontSize: 10, color: AppColors.textFaint),
          ),
        ],
      ],
    );
  }

  String _backendName() {
    if (Platform.isMacOS) return 'forkpty (macOS)';
    if (Platform.isLinux) return 'forkpty (Linux)';
    if (Platform.isWindows) return 'ConPTY';
    return 'unknown';
  }
}

class _InstallPanel extends StatefulWidget {
  final AppState state;
  const _InstallPanel({required this.state});

  @override
  State<_InstallPanel> createState() => _InstallPanelState();
}

class _InstallPanelState extends State<_InstallPanel> {
  bool _busy = false;

  Future<void> _pick() async {
    final state = widget.state;
    if (state.selectedDevice == null) return;
    final res = await FilePicker.platform.pickFiles(
      type: FileType.custom,
      allowedExtensions: ['hap', 'hsp'],
    );
    final path = res?.files.single.path;
    if (path == null) return;

    setState(() => _busy = true);
    final result = await state.installApp(path);
    if (!mounted) return;
    setState(() => _busy = false);

    final fileName = path.split(Platform.pathSeparator).last;
    if (result.ok) {
      await showResultDialog(context,
          ok: true, title: '安装成功', detail: fileName);
    } else {
      await showResultDialog(context,
          ok: false, title: '安装失败：$fileName', detail: result.message);
    }
  }

  @override
  Widget build(BuildContext context) {
    final canInstall = widget.state.selectedDevice != null && !_busy;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        SizedBox(
          height: 34,
          child: OutlinedButton.icon(
            onPressed: canInstall ? _pick : null,
            icon: _busy
                ? const SizedBox(
                    width: 12, height: 12,
                    child: CircularProgressIndicator(strokeWidth: 1.5, color: AppColors.accent),
                  )
                : const Icon(Icons.upload_file, size: 14),
            label: Text(_busy ? '安装中…' : '选择 .hap 文件'),
          ),
        ),
        if (widget.state.selectedDevice == null) ...[
          const SizedBox(height: 8),
          const Text(
            '请先在顶栏选择设备',
            style: TextStyle(fontSize: 10, color: AppColors.textFaint),
          ),
        ],
      ],
    );
  }
}

class _UninstallPanel extends StatefulWidget {
  final AppState state;
  const _UninstallPanel({required this.state});

  @override
  State<_UninstallPanel> createState() => _UninstallPanelState();
}

class _UninstallPanelState extends State<_UninstallPanel> {
  final TextEditingController _ctrl = TextEditingController();
  bool _busy = false;

  @override
  void initState() {
    super.initState();
    _ctrl.addListener(_onInputChanged);
  }

  @override
  void dispose() {
    _ctrl.removeListener(_onInputChanged);
    _ctrl.dispose();
    super.dispose();
  }

  void _onInputChanged() => setState(() {});

  String get _inputBundle => _ctrl.text.trim();

  bool get _canSubmit => !_busy && _inputBundle.isNotEmpty;

  List<AppEntry> _filteredApps() {
    final q = _inputBundle.toLowerCase();
    final apps = widget.state.apps;
    if (q.isEmpty) return apps;
    return apps.where((a) => a.bundle.toLowerCase().contains(q)).toList();
  }

  Future<void> _doUninstall() async {
    final bundle = _inputBundle;
    if (bundle.isEmpty) return;
    final confirmed = await showConfirmDialog(
      context,
      title: '卸载应用',
      message: '确定卸载\n$bundle\n此操作不可撤销。',
      confirmLabel: '卸载',
      destructive: true,
    );
    if (!mounted || !confirmed) return;
    setState(() => _busy = true);
    final result = await widget.state.uninstallApp(bundle);
    if (!mounted) return;
    setState(() {
      _busy = false;
      if (result.ok) {
        _ctrl.clear();
      }
    });
    if (result.ok) {
      await showResultDialog(context,
          ok: true, title: '卸载成功', detail: bundle);
    } else {
      await showResultDialog(context,
          ok: false, title: '卸载失败：$bundle', detail: result.message);
    }
  }

  @override
  Widget build(BuildContext context) {
    final state = widget.state;
    final connected = state.connState == ConnState.connected;
    final loading = state.appsLoading;
    final filtered = _filteredApps();

    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        // 输入区：始终可用
        Row(
          children: [
            Expanded(child: _BundleInput(controller: _ctrl)),
            const SizedBox(width: 6),
            SizedBox(
              width: 32, height: 32,
              child: IconButton(
                tooltip: '刷新应用列表',
                onPressed: connected && !loading ? () => state.requestAppList() : null,
                padding: EdgeInsets.zero,
                icon: loading
                    ? const SizedBox(
                        width: 12, height: 12,
                        child: CircularProgressIndicator(strokeWidth: 1.5, color: AppColors.accent),
                      )
                    : const Icon(Icons.refresh, size: 14),
                style: IconButton.styleFrom(
                  backgroundColor: AppColors.bg,
                  side: const BorderSide(color: AppColors.borderStrong),
                  shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(AppRadius.sm)),
                ),
              ),
            ),
          ],
        ),
        const SizedBox(height: 8),
        // 设备应用列表：依赖连接状态
        _DeviceAppList(
          apps: filtered,
          totalApps: state.apps.length,
          connected: connected,
          loading: loading,
          onTap: (a) {
            _ctrl.text = a.bundle;
            _ctrl.selection = TextSelection.fromPosition(
              TextPosition(offset: a.bundle.length),
            );
          },
        ),
        const SizedBox(height: 8),
        // 卸载按钮：不依赖连接状态
        SizedBox(
          height: 34,
          child: FilledButton.icon(
            onPressed: _canSubmit ? _doUninstall : null,
            icon: _busy
                ? const SizedBox(
                    width: 12, height: 12,
                    child: CircularProgressIndicator(strokeWidth: 1.5, color: Colors.white),
                  )
                : const Icon(Icons.delete_outline, size: 14),
            label: Text(_busy ? '卸载中…' : '卸载'),
            style: FilledButton.styleFrom(
              backgroundColor: AppColors.danger,
              foregroundColor: Colors.white,
              disabledBackgroundColor: AppColors.elevated,
              disabledForegroundColor: AppColors.textMuted,
            ),
          ),
        ),
      ],
    );
  }
}

class _BundleInput extends StatelessWidget {
  final TextEditingController controller;
  const _BundleInput({required this.controller});

  @override
  Widget build(BuildContext context) {
    return Container(
      height: 32,
      decoration: BoxDecoration(
        color: AppColors.bg,
        border: Border.all(color: AppColors.borderStrong),
        borderRadius: BorderRadius.circular(AppRadius.sm),
      ),
      padding: const EdgeInsets.symmetric(horizontal: 8),
      child: Row(
        children: [
          const Icon(Icons.search, size: 12, color: AppColors.textMuted),
          const SizedBox(width: 6),
          Expanded(
            child: TextField(
              controller: controller,
              style: const TextStyle(
                fontSize: 12,
                color: AppColors.textPrimary,
                fontFamily: kMonoFontFamily,
              ),
              cursorColor: AppColors.accent,
              cursorWidth: 1.4,
              decoration: const InputDecoration(
                border: InputBorder.none,
                isDense: true,
                contentPadding: EdgeInsets.zero,
                hintText: '输入包名 / 从下方列表选择',
                hintStyle: TextStyle(fontSize: 12, color: AppColors.textMuted),
              ),
            ),
          ),
          if (controller.text.isNotEmpty)
            GestureDetector(
              onTap: () => controller.clear(),
              child: const Icon(Icons.close, size: 12, color: AppColors.textMuted),
            ),
        ],
      ),
    );
  }
}

class _DeviceAppList extends StatelessWidget {
  final List<AppEntry> apps;
  final int totalApps;
  final bool connected;
  final bool loading;
  final ValueChanged<AppEntry> onTap;

  const _DeviceAppList({
    required this.apps,
    required this.totalApps,
    required this.connected,
    required this.loading,
    required this.onTap,
  });

  @override
  Widget build(BuildContext context) {
    String? hint;
    if (!connected) {
      hint = '未连接 · 列表为空，可手动输入包名卸载';
    } else if (loading) {
      hint = '加载中…';
    } else if (totalApps == 0) {
      hint = '无可卸载应用';
    } else if (apps.isEmpty) {
      hint = '无匹配项（共 $totalApps 项）';
    }

    return Container(
      height: 160,
      decoration: BoxDecoration(
        color: AppColors.bg,
        border: Border.all(color: AppColors.border),
        borderRadius: BorderRadius.circular(AppRadius.sm),
      ),
      child: hint != null
          ? Center(
              child: Padding(
                padding: const EdgeInsets.all(12),
                child: Text(
                  hint,
                  textAlign: TextAlign.center,
                  style: const TextStyle(
                    fontSize: 11,
                    color: AppColors.textFaint,
                    height: 1.5,
                  ),
                ),
              ),
            )
          : Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                Padding(
                  padding: const EdgeInsets.fromLTRB(10, 6, 10, 4),
                  child: Text(
                    '${apps.length} / $totalApps',
                    style: const TextStyle(
                      fontSize: 9,
                      color: AppColors.textFaint,
                      letterSpacing: 1.0,
                      fontWeight: FontWeight.w600,
                      fontFamily: kMonoFontFamily,
                    ),
                  ),
                ),
                Container(height: 1, color: AppColors.border),
                Expanded(
                  child: ListView.builder(
                    padding: const EdgeInsets.symmetric(vertical: 2),
                    itemCount: apps.length,
                    itemBuilder: (ctx, i) {
                      final a = apps[i];
                      return _BundleRow(bundle: a.bundle, onTap: () => onTap(a));
                    },
                  ),
                ),
              ],
            ),
    );
  }
}

class _BundleRow extends StatefulWidget {
  final String bundle;
  final VoidCallback onTap;
  const _BundleRow({required this.bundle, required this.onTap});

  @override
  State<_BundleRow> createState() => _BundleRowState();
}

class _BundleRowState extends State<_BundleRow> {
  bool _hover = false;

  @override
  Widget build(BuildContext context) {
    return MouseRegion(
      cursor: SystemMouseCursors.click,
      onEnter: (_) => setState(() => _hover = true),
      onExit: (_) => setState(() => _hover = false),
      child: GestureDetector(
        onTap: widget.onTap,
        behavior: HitTestBehavior.opaque,
        child: Container(
          padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 5),
          color: _hover ? AppColors.accent.withOpacity(0.12) : Colors.transparent,
          child: Text(
            widget.bundle,
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
            style: TextStyle(
              fontSize: 11,
              color: _hover ? AppColors.accent : AppColors.textPrimary,
              fontFamily: kMonoFontFamily,
            ),
          ),
        ),
      ),
    );
  }
}

class _ControlPanel extends StatelessWidget {
  final AppState state;
  const _ControlPanel({required this.state});

  void _send(int sub) => state.sendControl(sub, Uint8List(0));

  @override
  Widget build(BuildContext context) {
    final on = state.connState == ConnState.connected;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        _Group(label: '导航', children: [
          _CtlBtn(icon: Icons.arrow_back, label: '返回',
              onPressed: on ? () => _send(ControlSubType.backKey) : null),
          _CtlBtn(icon: Icons.home_outlined, label: '主页',
              onPressed: on ? () => _send(ControlSubType.homeKey) : null),
        ]),
        const SizedBox(height: 10),
        _Group(label: '音量', children: [
          _CtlBtn(icon: Icons.volume_down, label: '减小',
              onPressed: on ? () => _send(ControlSubType.volumeDown) : null),
          _CtlBtn(icon: Icons.volume_up, label: '增大',
              onPressed: on ? () => _send(ControlSubType.volumeUp) : null),
        ]),
        const SizedBox(height: 10),
        _Group(label: '亮度', children: [
          _CtlBtn(icon: Icons.brightness_low, label: '降低',
              onPressed: on ? () => _send(ControlSubType.brightnessDown) : null),
          _CtlBtn(icon: Icons.brightness_high, label: '提高',
              onPressed: on ? () => _send(ControlSubType.brightnessUp) : null),
        ]),
      ],
    );
  }
}

class _Group extends StatelessWidget {
  final String label;
  final List<Widget> children;
  const _Group({required this.label, required this.children});

  @override
  Widget build(BuildContext context) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(
          label,
          style: const TextStyle(
            fontSize: 10,
            color: AppColors.textFaint,
            letterSpacing: 1.2,
            fontWeight: FontWeight.w600,
            fontFamily: kMonoFontFamily,
          ),
        ),
        const SizedBox(height: 6),
        Row(
          children: [
            for (var i = 0; i < children.length; i++) ...[
              if (i > 0) const SizedBox(width: 6),
              Expanded(child: children[i]),
            ],
          ],
        ),
      ],
    );
  }
}

class _CtlBtn extends StatefulWidget {
  final IconData icon;
  final String label;
  final VoidCallback? onPressed;
  const _CtlBtn({required this.icon, required this.label, required this.onPressed});

  @override
  State<_CtlBtn> createState() => _CtlBtnState();
}

class _CtlBtnState extends State<_CtlBtn> {
  bool _hover = false;
  bool _pressed = false;

  @override
  Widget build(BuildContext context) {
    final enabled = widget.onPressed != null;
    final bg = !enabled
        ? AppColors.bg
        : _pressed
            ? AppColors.accent.withOpacity(0.15)
            : _hover
                ? AppColors.elevated
                : AppColors.bg;
    final border = !enabled
        ? AppColors.border
        : _hover || _pressed
            ? AppColors.accent.withOpacity(0.6)
            : AppColors.borderStrong;
    final fg = !enabled
        ? AppColors.textFaint
        : _hover || _pressed
            ? AppColors.accent
            : AppColors.textPrimary;

    return MouseRegion(
      cursor: enabled ? SystemMouseCursors.click : SystemMouseCursors.basic,
      onEnter: (_) => setState(() => _hover = true),
      onExit: (_) => setState(() { _hover = false; _pressed = false; }),
      child: GestureDetector(
        onTapDown: enabled ? (_) => setState(() => _pressed = true) : null,
        onTapUp: enabled ? (_) => setState(() => _pressed = false) : null,
        onTapCancel: enabled ? () => setState(() => _pressed = false) : null,
        onTap: widget.onPressed,
        child: AnimatedContainer(
          duration: const Duration(milliseconds: 150),
          height: 36,
          decoration: BoxDecoration(
            color: bg,
            border: Border.all(color: border),
            borderRadius: BorderRadius.circular(AppRadius.sm),
          ),
          alignment: Alignment.center,
          child: Row(
            mainAxisAlignment: MainAxisAlignment.center,
            children: [
              Icon(widget.icon, size: 14, color: fg),
              const SizedBox(width: 6),
              Text(
                widget.label,
                style: TextStyle(
                  fontSize: 12,
                  color: fg,
                  fontWeight: FontWeight.w500,
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

class _TextInputPanel extends StatefulWidget {
  final AppState state;
  const _TextInputPanel({required this.state});

  @override
  State<_TextInputPanel> createState() => _TextInputPanelState();
}

class _TextInputPanelState extends State<_TextInputPanel> {
  final TextEditingController _ctrl = TextEditingController();
  bool _busy = false;

  @override
  void dispose() {
    _ctrl.dispose();
    super.dispose();
  }

  Future<void> _send() async {
    final text = _ctrl.text;
    if (text.isEmpty) return;
    setState(() => _busy = true);
    final result = await widget.state.inputText(text);
    if (!mounted) return;
    setState(() => _busy = false);
    if (result.ok) {
      _ctrl.clear();
    }
  }

  @override
  Widget build(BuildContext context) {
    final canSend = widget.state.selectedDevice != null;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        const Text(
          '输入文本后点击发送，内容将注入设备当前焦点输入框',
          style: TextStyle(fontSize: 10, color: AppColors.textFaint, height: 1.5),
        ),
        const SizedBox(height: 8),
        Container(
          decoration: BoxDecoration(
            color: AppColors.bg,
            border: Border.all(color: AppColors.borderStrong),
            borderRadius: BorderRadius.circular(AppRadius.sm),
          ),
          padding: const EdgeInsets.symmetric(horizontal: 8),
          child: TextField(
            controller: _ctrl,
            maxLines: 3,
            minLines: 2,
            style: const TextStyle(
              fontSize: 12,
              color: AppColors.textPrimary,
              fontFamily: kMonoFontFamily,
            ),
            cursorColor: AppColors.accent,
            cursorWidth: 1.4,
            decoration: const InputDecoration(
              border: InputBorder.none,
              isDense: true,
              contentPadding: EdgeInsets.symmetric(vertical: 8),
              hintText: '输入要发送的文本…',
              hintStyle: TextStyle(fontSize: 12, color: AppColors.textMuted),
            ),
            onSubmitted: canSend && !_busy ? (_) => _send() : null,
          ),
        ),
        const SizedBox(height: 8),
        SizedBox(
          height: 34,
          child: FilledButton.icon(
            onPressed: canSend && !_busy ? _send : null,
            icon: _busy
                ? const SizedBox(
                    width: 12, height: 12,
                    child: CircularProgressIndicator(strokeWidth: 1.5, color: Colors.white),
                  )
                : const Icon(Icons.send, size: 14),
            label: Text(_busy ? '发送中…' : '发送'),
          ),
        ),
      ],
    );
  }
}
