import 'package:flutter/material.dart';

import 'theme.dart';

/// 可拖拽分隔条：左侧 flex，右侧固定宽度。
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

class _SplitViewState extends State<SplitView> {
  late double rightWidth = widget.initialRightWidth;
  bool _hovering = false;
  bool _dragging = false;

  @override
  Widget build(BuildContext context) {
    return LayoutBuilder(
      builder: (context, c) {
        final maxRight = (c.maxWidth - widget.minLeft).clamp(widget.minRight, c.maxWidth);
        final right = rightWidth.clamp(widget.minRight, maxRight);
        final active = _hovering || _dragging;
        return Row(
          children: [
            Expanded(child: widget.left),
            MouseRegion(
              cursor: SystemMouseCursors.resizeColumn,
              onEnter: (_) => setState(() => _hovering = true),
              onExit: (_) => setState(() => _hovering = false),
              child: GestureDetector(
                behavior: HitTestBehavior.opaque,
                onHorizontalDragStart: (_) => setState(() => _dragging = true),
                onHorizontalDragEnd: (_) => setState(() => _dragging = false),
                onHorizontalDragUpdate: (d) {
                  setState(() {
                    rightWidth = (rightWidth - d.delta.dx).clamp(widget.minRight, maxRight);
                  });
                },
                child: AnimatedContainer(
                  duration: const Duration(milliseconds: 150),
                  width: 4,
                  color: active ? AppColors.accent.withOpacity(0.6) : AppColors.divider,
                ),
              ),
            ),
            SizedBox(width: right, child: widget.right),
          ],
        );
      },
    );
  }
}
