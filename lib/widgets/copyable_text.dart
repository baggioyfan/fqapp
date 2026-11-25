import 'package:material_ui/material_ui.dart';
import 'package:flutter/physics.dart';

import '../services/app_theme.dart' show einkModeNotifier;

/// 详情页里可长按选中、由系统菜单复制的文本（#477）。
///
/// 长按弹出的是系统的选择手柄与「复制 / 全选」菜单，不是自造的提示条；
/// 复制动作、剪贴板写入和菜单文案都交给平台，输入法无障碍细节也一致。
///
/// 这里额外接管长按，是为了让默认选区就是整段：Flutter 的中文长按按单字扩展
/// 选区（实测长按书名《开局废弃宗门，我召唤了大帝长老》只选中「大」这一个字），
/// 直接用 SelectionArea 会得到“菜单弹出来了但只有一个字可复制”的结果。长按后
/// 主动调用 `selectAll(SelectionChangedCause.toolbar)` 会把整段选中并连同手柄
/// 一起显示，用户仍可拖动手柄缩小到需要的片段。
class CopyableText extends StatefulWidget {
  const CopyableText(
    this.text, {
    super.key,
    this.textKey,
    this.style,
    this.maxLines,
    this.overflow,
    this.textAlign,
    this.onTap,
    this.pressFeedback = false,
    this.child,
  });

  final String text;

  /// 可选中区里的实际渲染体，用于内容带表情等段落（如 `CommentEmojiText`）。
  /// 为空时按 [text] 建一个普通 `Text`；非空时 [text] 只作选区文案来源，
  /// [textKey]/[style]/[maxLines]/[overflow]/[textAlign] 都不再生效。
  final Widget? child;

  /// 落在内部 `Text` 上的 key。页面与测试按它取原 `Text`（`maxLines`、样式），
  /// 所以 key 不能挂在外层包装上，否则 `tester.widget<Text>` 会拿不到。
  final Key? textKey;

  final TextStyle? style;
  final int? maxLines;
  final TextOverflow? overflow;

  final TextAlign? textAlign;

  /// 点按动作（可空）。必须由本控件自己接，不能让外层按钮接：
  /// `SelectableRegion` 比外层 `InkWell`/`GestureDetector` 更深，点按会在
  /// 手势竞技场里先被选区拿走，作者行的「跳作者主页」和简介的「点按展开」
  /// 就会失效。把 onTap 放进 region 内部的识别器，点按和长按都稳定命中。
  final VoidCallback? onTap;

  /// 按下时给一点回弹缩放，仅用于看起来像按钮的文本（如作者行）。
  /// 手感与 `HomePressable` 一致，但由 `Listener` 的原始指针事件驱动：
  /// `InkWell` 的按下动画靠点击手势，选中区域会把点击抢走，动画就不再触发。
  final bool pressFeedback;

  @override
  State<CopyableText> createState() => _CopyableTextState();
}

class _CopyableTextState extends State<CopyableText>
    with SingleTickerProviderStateMixin {
  final _areaKey = GlobalKey<SelectionAreaState>();
  final _focus = FocusNode(debugLabel: 'CopyableText');

  /// 与 `HomePressable` 相同的弹簧参数，按下缩小 2.8%。
  late final AnimationController _scale = AnimationController.unbounded(
    vsync: this,
    value: 1,
  );
  bool _pressed = false;

  @override
  void dispose() {
    _scale.dispose();
    _focus.dispose();
    super.dispose();
  }

  void _setPressed(bool pressed) {
    if (!widget.pressFeedback || _pressed == pressed) return;
    _pressed = pressed;
    if (einkModeNotifier.value || MediaQuery.disableAnimationsOf(context)) {
      _scale.stop();
      _scale.value = 1;
      return;
    }
    _scale.animateWith(
      SpringSimulation(
        const SpringDescription(mass: 1, stiffness: 420, damping: 30),
        _scale.value,
        pressed ? 0.972 : 1,
        0,
      ),
    );
  }

  void _selectAll() {
    final area = _areaKey.currentState;
    if (area == null) return;
    // 长按已转为选区，缩放要回到原位，别让文字一直缩着。
    _setPressed(false);
    // `toolbar` 这个 cause 会让选区落定后再补上手柄和菜单，本平台没有菜单时
    // 就只剩选区，不会额外弹我们自己的提示条。
    _focus.requestFocus();
    area.selectableRegion.selectAll(SelectionChangedCause.toolbar);
  }

  @override
  Widget build(BuildContext context) {
    final plain =
        widget.child ??
        Text(
          widget.text,
          key: widget.textKey,
          style: widget.style,
          maxLines: widget.maxLines,
          overflow: widget.overflow,
          textAlign: widget.textAlign,
        );
    // 空文本没有可选内容，也不该为它拦下长按。
    if (widget.child == null && widget.text.trim().isEmpty) return plain;
    Widget content = GestureDetector(
      // 文本本身不参与命中测试，opaque 才能让长按落在整块文字范围内。
      behavior: HitTestBehavior.opaque,
      onTap: widget.onTap,
      onLongPress: _selectAll,
      child: plain,
    );
    if (widget.pressFeedback) {
      content = AnimatedBuilder(
        animation: _scale,
        builder: (context, child) =>
            Transform.scale(scale: _scale.value, child: child),
        child: content,
      );
    }
    final area = SelectionArea(
      key: _areaKey,
      focusNode: _focus,
      child: content,
    );
    if (!widget.pressFeedback) return area;
    // Listener 不参与手势竞技场，所以按住不会影响长按选区与点按。
    return Listener(
      onPointerDown: (_) => _setPressed(true),
      onPointerUp: (_) => _setPressed(false),
      onPointerCancel: (_) => _setPressed(false),
      child: area,
    );
  }
}
