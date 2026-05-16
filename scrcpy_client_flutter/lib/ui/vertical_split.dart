import 'package:flutter/material.dart';

import 'theme.dart';

/// 主体 + 底部抽屉 的可拖拽布局。bottom 为 null 时退化为只渲染 top。
class VerticalSplit extends StatefulWidget {
  final Widget top;
  final Widget? bottom;
  final double bottomHeight;
  final double minTop;
  final double minBottom;
  final ValueChanged<double>? onResize;

  const VerticalSplit({
    super.key,
    required this.top,
    required this.bottom,
    required this.bottomHeight,
    this.minTop = 240,
    this.minBottom = 140,
    this.onResize,
  });

  @override
  State<VerticalSplit> createState() => _VerticalSplitState();
}

class _VerticalSplitState extends State<VerticalSplit> {
  bool _hover = false;
  bool _dragging = false;

  @override
  Widget build(BuildContext context) {
    final bottom = widget.bottom;
    if (bottom == null) {
      return widget.top;
    }
    return LayoutBuilder(
      builder: (context, c) {
        final maxBottom =
            (c.maxHeight - widget.minTop).clamp(widget.minBottom, c.maxHeight);
        final h = widget.bottomHeight.clamp(widget.minBottom, maxBottom);
        final active = _hover || _dragging;
        return Column(
          children: [
            Expanded(child: widget.top),
            MouseRegion(
              cursor: SystemMouseCursors.resizeRow,
              onEnter: (_) => setState(() => _hover = true),
              onExit: (_) => setState(() => _hover = false),
              child: GestureDetector(
                behavior: HitTestBehavior.opaque,
                onVerticalDragStart: (_) => setState(() => _dragging = true),
                onVerticalDragEnd: (_) => setState(() => _dragging = false),
                onVerticalDragUpdate: (d) {
                  final next = (h - d.delta.dy).clamp(widget.minBottom, maxBottom);
                  widget.onResize?.call(next);
                },
                child: AnimatedContainer(
                  duration: const Duration(milliseconds: 150),
                  height: 4,
                  color:
                      active ? AppColors.accent.withOpacity(0.6) : AppColors.divider,
                ),
              ),
            ),
            SizedBox(height: h, child: bottom),
          ],
        );
      },
    );
  }
}
