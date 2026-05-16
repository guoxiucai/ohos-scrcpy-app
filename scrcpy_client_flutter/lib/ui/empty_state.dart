import 'package:flutter/material.dart';

import 'theme.dart';

class EmptyState extends StatelessWidget {
  final String message;
  const EmptyState({super.key, required this.message});

  @override
  Widget build(BuildContext context) {
    return Column(
      mainAxisSize: MainAxisSize.min,
      children: [
        Container(
          width: 96,
          height: 96,
          decoration: BoxDecoration(
            color: AppColors.surface,
            border: Border.all(color: AppColors.borderStrong),
            borderRadius: BorderRadius.circular(AppRadius.lg),
          ),
          alignment: Alignment.center,
          child: const Icon(Icons.smartphone, size: 40, color: AppColors.textFaint),
        ),
        const SizedBox(height: 20),
        Text(
          message,
          style: const TextStyle(
            color: AppColors.textSecondary,
            fontSize: 13,
            letterSpacing: 0.2,
          ),
        ),
        const SizedBox(height: 8),
        const Text(
          'WAITING FOR DEVICE',
          style: TextStyle(
            color: AppColors.textFaint,
            fontSize: 10,
            letterSpacing: 1.4,
            fontWeight: FontWeight.w600,
            fontFamily: kMonoFontFamily,
          ),
        ),
        const SizedBox(height: 14),
        const Text(
          '请通过 USB 或网络连接 OpenHarmony 设备',
          style: TextStyle(
            color: AppColors.textMuted,
            fontSize: 11,
            height: 1.5,
          ),
        ),
        const SizedBox(height: 2),
        const Text(
          '连接后点击上方「连接」按钮开始投屏',
          style: TextStyle(
            color: AppColors.textFaint,
            fontSize: 10,
            height: 1.5,
          ),
        ),
      ],
    );
  }
}
