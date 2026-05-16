
import 'package:flutter/material.dart';

import '../state/app_state.dart';
import '../hdc/device.dart';
import 'theme.dart';

class TopBar extends StatelessWidget {
  final AppState state;
  const TopBar({super.key, required this.state});

  Color _statusColor() {
    switch (state.connState) {
      case ConnState.idle:       return AppColors.idle;
      case ConnState.connecting: return AppColors.warning;
      case ConnState.connected:  return AppColors.success;
      case ConnState.error:      return AppColors.danger;
    }
  }

  String _statusLabel() {
    switch (state.connState) {
      case ConnState.idle:       return 'IDLE';
      case ConnState.connecting: return 'CONNECTING';
      case ConnState.connected:  return 'CONNECTED';
      case ConnState.error:      return 'ERROR';
    }
  }

  @override
  Widget build(BuildContext context) {
    final connected = state.connState == ConnState.connected;
    return Container(
      height: 52,
      padding: const EdgeInsets.symmetric(horizontal: 16),
      decoration: const BoxDecoration(
        color: AppColors.surface,
        border: Border(bottom: BorderSide(color: AppColors.border)),
      ),
      child: Row(
        children: [
          // Brand mark
          Container(
            width: 26,
            height: 26,
            decoration: BoxDecoration(
              gradient: const LinearGradient(
                begin: Alignment.topLeft,
                end: Alignment.bottomRight,
                colors: [AppColors.accent, AppColors.accentDim],
              ),
              borderRadius: BorderRadius.circular(AppRadius.sm),
            ),
            alignment: Alignment.center,
            child: const Icon(Icons.smartphone, size: 16, color: Color(0xFF062831)),
          ),
          const SizedBox(width: 10),
          const Text(
            '鸿镜',
            style: TextStyle(
              fontSize: 14,
              fontWeight: FontWeight.w700,
              color: AppColors.textPrimary,
              letterSpacing: 1.0,
            ),
          ),
          const SizedBox(width: 20),
          Container(width: 1, height: 22, color: AppColors.border),
          const SizedBox(width: 12),

          // Refresh
          _IconAction(
            icon: Icons.refresh,
            tooltip: '刷新设备列表',
            onPressed: () => state.refreshDevices(),
          ),
          const SizedBox(width: 8),

          // Device dropdown
          _DeviceSelector(state: state),
          const SizedBox(width: 12),

          // Connect button
          SizedBox(
            height: 32,
            child: connected
                ? OutlinedButton.icon(
                    onPressed: () => state.disconnect(),
                    icon: const Icon(Icons.link_off, size: 14, color: AppColors.danger),
                    label: const Text('断开'),
                    style: OutlinedButton.styleFrom(
                      foregroundColor: AppColors.danger,
                      side: const BorderSide(color: AppColors.danger),
                    ),
                  )
                : FilledButton.icon(
                    onPressed: state.selectedDevice == null ? null : () => state.connect(),
                    icon: const Icon(Icons.play_arrow, size: 14),
                    label: const Text('连接'),
                  ),
          ),

          const SizedBox(width: 8),

          const Spacer(),

          // Status pill
          _StatusPill(
            color: _statusColor(),
            label: _statusLabel(),
            blinking: state.connState == ConnState.connecting,
          ),
          const SizedBox(width: 12),
          ConstrainedBox(
            constraints: const BoxConstraints(maxWidth: 360),
            child: Text(
              state.statusMessage,
              overflow: TextOverflow.ellipsis,
              style: const TextStyle(
                fontSize: 11,
                color: AppColors.textSecondary,
                fontFamily: kMonoFontFamily,
              ),
            ),
          ),
        ],
      ),
    );
  }
}

class _DeviceSelector extends StatelessWidget {
  final AppState state;
  const _DeviceSelector({required this.state});

  @override
  Widget build(BuildContext context) {
    return Container(
      width: 380,
      height: 32,
      padding: const EdgeInsets.symmetric(horizontal: 10),
      decoration: BoxDecoration(
        color: AppColors.bg,
        border: Border.all(color: AppColors.borderStrong),
        borderRadius: BorderRadius.circular(AppRadius.sm),
      ),
      child: Row(
        children: [
          const Icon(Icons.devices_other, size: 14, color: AppColors.textMuted),
          const SizedBox(width: 8),
          Expanded(
            child: DropdownButtonHideUnderline(
              child: DropdownButton<HdcDevice>(
                isExpanded: true,
                isDense: true,
                value: state.selectedDevice,
                hint: const Text(
                  '请选择设备',
                  style: TextStyle(fontSize: 12, color: AppColors.textMuted),
                ),
                icon: const Icon(Icons.expand_more, size: 16, color: AppColors.textSecondary),
                dropdownColor: AppColors.elevated,
                style: const TextStyle(
                  fontSize: 12,
                  color: AppColors.textPrimary,
                  fontFamily: kMonoFontFamily,
                ),
                borderRadius: BorderRadius.circular(AppRadius.sm),
                items: state.devices
                    .map((d) => DropdownMenuItem(
                          value: d,
                          child: Text(d.displayName, overflow: TextOverflow.ellipsis),
                        ))
                    .toList(),
                onChanged: (d) {
                  if (d != null) state.selectDevice(d);
                },
              ),
            ),
          ),
        ],
      ),
    );
  }
}

class _IconAction extends StatelessWidget {
  final IconData icon;
  final String tooltip;
  final VoidCallback? onPressed;
  const _IconAction({required this.icon, required this.tooltip, this.onPressed});

  @override
  Widget build(BuildContext context) {
    return SizedBox(
      width: 32, height: 32,
      child: IconButton(
        tooltip: tooltip,
        onPressed: onPressed,
        icon: Icon(icon, size: 16),
        style: IconButton.styleFrom(
          backgroundColor: AppColors.bg,
          side: const BorderSide(color: AppColors.borderStrong),
          shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(AppRadius.sm)),
        ),
      ),
    );
  }
}

class _StatusPill extends StatefulWidget {
  final Color color;
  final String label;
  final bool blinking;
  const _StatusPill({required this.color, required this.label, this.blinking = false});

  @override
  State<_StatusPill> createState() => _StatusPillState();
}

class _StatusPillState extends State<_StatusPill> with SingleTickerProviderStateMixin {
  late final AnimationController _ctrl = AnimationController(
    vsync: this,
    duration: const Duration(milliseconds: 900),
  )..repeat(reverse: true);

  @override
  void dispose() {
    _ctrl.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return Container(
      height: 24,
      padding: const EdgeInsets.symmetric(horizontal: 8),
      decoration: BoxDecoration(
        color: widget.color.withOpacity(0.10),
        border: Border.all(color: widget.color.withOpacity(0.35)),
        borderRadius: BorderRadius.circular(AppRadius.sm),
      ),
      child: Row(
        children: [
          AnimatedBuilder(
            animation: _ctrl,
            builder: (_, __) => Container(
              width: 7, height: 7,
              decoration: BoxDecoration(
                color: widget.color.withOpacity(widget.blinking ? (0.4 + 0.6 * _ctrl.value) : 1.0),
                shape: BoxShape.circle,
                boxShadow: [
                  BoxShadow(color: widget.color.withOpacity(0.6), blurRadius: 6),
                ],
              ),
            ),
          ),
          const SizedBox(width: 6),
          Text(
            widget.label,
            style: TextStyle(
              fontSize: 10,
              fontWeight: FontWeight.w700,
              letterSpacing: 0.6,
              color: widget.color,
              fontFamily: kMonoFontFamily,
            ),
          ),
        ],
      ),
    );
  }
}
