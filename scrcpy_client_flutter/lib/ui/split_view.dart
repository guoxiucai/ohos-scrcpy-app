import 'package:flutter/material.dart';

import 'theme.dart';

/// 可拖拽分隔条：左侧 flex，右侧固定宽度。右侧面板支持折叠/展开。
class SplitView extends StatefulWidget {
  final Widget left;
  final Widget right;
  final double initialRightWidth;
  final double minLeft;
  final double minRight;

  const SplitView({
    super.key,
    required this.left,
    required this.right,
    this.initialRightWidth = 360,
    this.minLeft = 600,
    this.minRight = 320,
  });

  @override
  State<SplitView> createState() => _SplitViewState();
}

class _SplitViewState extends State<SplitView>
    with SingleTickerProviderStateMixin {
  late double _rightWidth = widget.initialRightWidth;
  bool _hovering = false;
  bool _dragging = false;
  bool _collapsed = false;

  late final AnimationController _animCtrl = AnimationController(
    vsync: this,
    duration: const Duration(milliseconds: 200),
  );
  late Animation<double> _widthAnim;

  @override
  void initState() {
    super.initState();
    _widthAnim = Tween<double>(begin: _rightWidth, end: 0).animate(
      CurvedAnimation(parent: _animCtrl, curve: Curves.easeInOut),
    );
    _animCtrl.addListener(() => setState(() {}));
  }

  @override
  void dispose() {
    _animCtrl.dispose();
    super.dispose();
  }

  void _toggleCollapse() {
    setState(() {
      _collapsed = !_collapsed;
      if (_collapsed) {
        _animCtrl.forward();
      } else {
        _animCtrl.reverse();
      }
    });
  }

  @override
  Widget build(BuildContext context) {
    return LayoutBuilder(
      builder: (context, c) {
        final maxRight =
            (c.maxWidth - widget.minLeft).clamp(widget.minRight, c.maxWidth);
        final right =
            _rightWidth.clamp(widget.minRight, maxRight);
        final active = _hovering || _dragging;

        final effectiveRight = _collapsed
            ? _widthAnim.value.clamp(0.0, right)
            : right;

        return Row(
          children: [
            Expanded(child: widget.left),

            // 分隔条 + 折叠按钮
            _DividerGutter(
              hovering: _hovering,
              active: active,
              collapsed: _collapsed,
              onToggle: _toggleCollapse,
              onEnter: () => setState(() => _hovering = true),
              onExit: () => setState(() => _hovering = false),
              onDragStart: _collapsed
                  ? null
                  : (_) => setState(() => _dragging = true),
              onDragEnd: _collapsed
                  ? null
                  : (_) => setState(() => _dragging = false),
              onDragUpdate: _collapsed
                  ? null
                  : (d) {
                      setState(() {
                        _rightWidth = (_rightWidth - d.delta.dx)
                            .clamp(widget.minRight, maxRight);
                      });
                    },
            ),

            // 右侧面板（折叠时宽度为 0）
            if (!_collapsed)
              SizedBox(width: effectiveRight, child: widget.right),
          ],
        );
      },
    );
  }
}

/// 分隔条 + 折叠/展开按钮。
class _DividerGutter extends StatelessWidget {
  final bool hovering;
  final bool active;
  final bool collapsed;
  final VoidCallback onToggle;
  final VoidCallback onEnter;
  final VoidCallback onExit;
  final GestureDragStartCallback? onDragStart;
  final GestureDragEndCallback? onDragEnd;
  final GestureDragUpdateCallback? onDragUpdate;

  const _DividerGutter({
    required this.hovering,
    required this.active,
    required this.collapsed,
    required this.onToggle,
    required this.onEnter,
    required this.onExit,
    this.onDragStart,
    this.onDragEnd,
    this.onDragUpdate,
  });

  @override
  Widget build(BuildContext context) {
    final barColor = active
        ? AppColors.accent.withValues(alpha: 0.6)
        : hovering
            ? AppColors.accent.withValues(alpha: 0.3)
            : AppColors.divider;

    return MouseRegion(
      cursor: collapsed
          ? SystemMouseCursors.click
          : SystemMouseCursors.resizeColumn,
      onEnter: (_) => onEnter(),
      onExit: (_) => onExit(),
      child: GestureDetector(
        behavior: HitTestBehavior.opaque,
        onTap: collapsed ? () => onToggle() : null,
        onHorizontalDragStart: onDragStart,
        onHorizontalDragEnd: onDragEnd,
        onHorizontalDragUpdate: onDragUpdate,
        child: AnimatedContainer(
          duration: const Duration(milliseconds: 150),
          width: collapsed ? 24 : 4,
          decoration: BoxDecoration(
            color: barColor,
            borderRadius: collapsed
                ? const BorderRadius.only(
                    topLeft: Radius.circular(AppRadius.sm),
                    bottomLeft: Radius.circular(AppRadius.sm),
                  )
                : null,
          ),
          alignment: Alignment.center,
          child: _ToggleIcon(
            collapsed: collapsed,
            barHovered: hovering || active,
            onToggle: onToggle,
          ),
        ),
      ),
    );
  }
}

/// 折叠/展开图标。
class _ToggleIcon extends StatelessWidget {
  final bool collapsed;
  final bool barHovered;
  final VoidCallback onToggle;

  const _ToggleIcon({
    required this.collapsed,
    required this.barHovered,
    required this.onToggle,
  });

  @override
  Widget build(BuildContext context) {
    if (collapsed) {
      // 折叠状态：显示向左箭头（点击展开），始终可见
      return const Icon(Icons.chevron_left, size: 16, color: AppColors.accent);
    }

    // 展开状态：hover 时显示向右箭头（点击折叠）
    return AnimatedOpacity(
      opacity: barHovered ? 1.0 : 0.0,
      duration: const Duration(milliseconds: 120),
      child: GestureDetector(
        onTap: () => onToggle(),
        child: Container(
          width: 18,
          height: 48,
          decoration: BoxDecoration(
            color: AppColors.surfaceAlt,
            border: Border.all(color: AppColors.borderStrong),
            borderRadius: BorderRadius.circular(3),
          ),
          alignment: Alignment.center,
          child: const Icon(Icons.chevron_right,
              size: 14, color: AppColors.textSecondary),
        ),
      ),
    );
  }
}
