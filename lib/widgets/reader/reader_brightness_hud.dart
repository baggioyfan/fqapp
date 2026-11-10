import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter_lucide/flutter_lucide.dart';

/// 阅读页「上下滑调亮度」的浮层。
///
/// [value] 由手势层喂入 0.02–1 的亮度，`null` 表示这一轮手势结束；浮层收到
/// 非空值就显示并重置自动隐藏计时，到时自己淡出。
///
/// 刻意用 [ValueListenable] 而不是 setState 驱动：阅读页每次重建都要重排
/// 整章文字，而拖动期间一秒要更新几十次，只能让浮层自己重建。
class ReaderBrightnessHud extends StatefulWidget {
  const ReaderBrightnessHud({
    super.key,
    required this.value,
    this.autoHide = const Duration(milliseconds: 900),
  });

  /// 当前亮度（0.02–1）；`null` = 立即隐藏。
  final ValueListenable<double?> value;

  /// 松手后多久自动淡出。
  final Duration autoHide;

  @override
  State<ReaderBrightnessHud> createState() => _ReaderBrightnessHudState();
}

class _ReaderBrightnessHudState extends State<ReaderBrightnessHud> {
  /// 最后一次收到的亮度：淡出过程中要停在原地，不能跳回 0。
  double _last = .5;
  bool _visible = false;
  Timer? _hideTimer;

  @override
  void initState() {
    super.initState();
    widget.value.addListener(_onValue);
    // 初值直接落到字段上：initState 里走 setState 既没必要也会被 lint 盯上。
    final initial = widget.value.value;
    if (initial != null) {
      _last = initial.clamp(0.0, 1.0);
      _visible = true;
      // 挂载时就非空（页面重建、浮层被重新插入）也必须自己淡出：这里只设
      // `_visible` 不排计时，浮层会一直挡着正文，直到下一次手势来救。
      _scheduleHide();
    }
  }

  @override
  void didUpdateWidget(covariant ReaderBrightnessHud oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (identical(oldWidget.value, widget.value)) return;
    oldWidget.value.removeListener(_onValue);
    widget.value.addListener(_onValue);
  }

  @override
  void dispose() {
    widget.value.removeListener(_onValue);
    _hideTimer?.cancel();
    super.dispose();
  }

  void _scheduleHide() {
    _hideTimer?.cancel();
    _hideTimer = Timer(widget.autoHide, () {
      if (mounted) setState(() => _visible = false);
    });
  }

  void _onValue() {
    final level = widget.value.value;
    if (level == null) {
      _hideTimer?.cancel();
      _hideTimer = null;
      if (mounted && _visible) setState(() => _visible = false);
      return;
    }
    _scheduleHide();
    if (!mounted) return;
    setState(() {
      _last = level.clamp(0.0, 1.0);
      _visible = true;
    });
  }

  @override
  Widget build(BuildContext context) {
    final percent = '${(_last * 100).round()}%';
    return IgnorePointer(
      child: Align(
        alignment: const Alignment(0, -.35),
        child: AnimatedOpacity(
          opacity: _visible ? 1 : 0,
          duration: const Duration(milliseconds: 160),
          curve: Curves.easeOut,
          child: DecoratedBox(
            decoration: BoxDecoration(
              color: const Color(0xD11C1C1C),
              borderRadius: BorderRadius.circular(18),
            ),
            child: Padding(
              padding: const EdgeInsets.fromLTRB(16, 12, 18, 12),
              child: Row(
                mainAxisSize: MainAxisSize.min,
                children: [
                  const Icon(
                    LucideIcons.sun,
                    size: 20,
                    color: Colors.white,
                  ),
                  const SizedBox(width: 12),
                  SizedBox(
                    width: 128,
                    child: ClipRRect(
                      borderRadius: BorderRadius.circular(3),
                      child: LinearProgressIndicator(
                        value: _last,
                        minHeight: 6,
                        backgroundColor: Colors.white24,
                        valueColor: const AlwaysStoppedAnimation<Color>(
                          Colors.white,
                        ),
                      ),
                    ),
                  ),
                  const SizedBox(width: 12),
                  SizedBox(
                    width: 42,
                    child: Text(
                      percent,
                      textAlign: TextAlign.right,
                      style: const TextStyle(
                        color: Colors.white,
                        fontSize: 14,
                        fontFeatures: [FontFeature.tabularFigures()],
                      ),
                    ),
                  ),
                ],
              ),
            ),
          ),
        ),
      ),
    );
  }
}
