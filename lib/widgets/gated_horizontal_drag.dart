import 'package:flutter/gestures.dart';

/// 只在 [accepts] 放行的按下点参与的横向拖动识别器。
///
/// **为什么需要它。** 手势竞技场里没有优先级：同一个指针上挂着两个横向拖动
/// 识别器时，谁先越过 slop 谁赢，而事件是从最内层往外发的——内层总是先收到，
/// 也就总是先赢。所以「一块区域归我、另一块归别人」不能靠抢，只能让两边
/// **互斥地**决定参不参与：[isPointerAllowed] 在按下这一刻就问一次，被拒的
/// 识别器根本不进竞技场。
///
/// 两个使用方刚好互补：短剧竖滑播放流的卡片上，左右滑是官方调进度
/// （`o.java:K6`），它只吃中间；[TabSwipeArea] 在同一页只吃左右边缘带。
class GatedHorizontalDragGestureRecognizer
    extends HorizontalDragGestureRecognizer {
  GatedHorizontalDragGestureRecognizer({required this.accepts});

  /// 按下点（本识别器所在 render box 的局部横坐标）是否归它管。
  final bool Function(double localDx) accepts;

  @override
  bool isPointerAllowed(PointerDownEvent event) =>
      super.isPointerAllowed(event) && accepts(event.localPosition.dx);
}
