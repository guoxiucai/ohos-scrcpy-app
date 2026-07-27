import 'dart:async';

import 'package:flutter/material.dart';

import 'theme.dart';

OverlayEntry? _activeToast;
Timer? _activeToastTimer;

/// 在应用中央显示轻量提示；连续触发时只保留最新一条。
void showCenterToast(
  BuildContext context,
  String message, {
  Duration duration = const Duration(milliseconds: 1500),
}) {
  _activeToastTimer?.cancel();
  if (_activeToast?.mounted ?? false) {
    _activeToast!.remove();
  }

  final overlay = Overlay.of(context, rootOverlay: true);
  late final OverlayEntry entry;
  entry = OverlayEntry(
    builder: (_) => Positioned.fill(
      child: IgnorePointer(
        child: Center(
          child: Material(
            color: Colors.transparent,
            child: Container(
              constraints: const BoxConstraints(maxWidth: 420),
              padding: const EdgeInsets.symmetric(horizontal: 18, vertical: 11),
              decoration: BoxDecoration(
                color: const Color(0xE61F2937),
                border: Border.all(color: AppColors.borderStrong),
                borderRadius: BorderRadius.circular(AppRadius.md),
                boxShadow: const [
                  BoxShadow(
                    color: Colors.black45,
                    blurRadius: 12,
                    offset: Offset(0, 4),
                  ),
                ],
              ),
              child: Text(
                message,
                textAlign: TextAlign.center,
                style: const TextStyle(
                  color: AppColors.textPrimary,
                  fontSize: 12,
                  height: 1.35,
                ),
              ),
            ),
          ),
        ),
      ),
    ),
  );

  _activeToast = entry;
  overlay.insert(entry);
  _activeToastTimer = Timer(duration, () {
    if (!identical(_activeToast, entry)) return;
    if (entry.mounted) entry.remove();
    _activeToast = null;
    _activeToastTimer = null;
  });
}
