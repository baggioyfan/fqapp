import 'package:material_ui/material_ui.dart';

import 'home_design.dart';

/// 首页 / 搜索 / 分类共用的胶囊筛选 chip（替换 Material 默认 ChoiceChip）。
///
/// 规格取自搜索页的分类条：soft 底、ink 实心选中、StadiumBorder、无勾、
/// 13sp。Material 默认 chip 在墨水屏下选中态用 `secondaryContainer`（白）
/// 会和未选中态撞色，选中态直接消失；这里显式给出墨水屏分支：选中 =
/// 黑底白字，未选中 = 白底黑字 + 1px 黑描边，保证可区分。
///
/// 视觉高度 32dp，触控高度不小于 48dp（Material 补足透明触控区域）。
class HomeChip extends StatelessWidget {
  const HomeChip({
    super.key,
    required this.label,
    required this.selected,
    required this.onTap,
    this.semanticLabel,
    this.horizontalPadding = 14,
  });

  /// 视觉胶囊高度；触控高度见 [minTapTarget]。
  static const double height = 32;

  /// 触控区域最小高度（比视觉高度多出的部分是透明留白）。
  static const double minTapTarget = 48;

  final String label;
  final bool selected;
  final VoidCallback? onTap;
  final String? semanticLabel;
  final double horizontalPadding;

  @override
  Widget build(BuildContext context) {
    final palette = HomePalette.of(context);
    // eink 下 palette.ink = 黑、palette.canvas = 白，下面两行自然得到
    // 黑底白字 / 白底黑字；非 eink 沿用搜索页的 soft → ink 选中。
    final background = selected ? palette.ink : palette.soft;
    final foreground = selected ? palette.canvas : palette.ink;
    final side = palette.eink && !selected
        ? const BorderSide(color: Colors.black)
        : BorderSide.none;
    return Semantics(
      label: semanticLabel,
      selected: selected,
      child: TextButton(
        onPressed: onTap,
        clipBehavior: Clip.antiAlias,
        style: TextButton.styleFrom(
          backgroundColor: background,
          foregroundColor: foreground,
          disabledBackgroundColor: background,
          disabledForegroundColor: foreground,
          minimumSize: const Size(minTapTarget, height),
          padding: EdgeInsets.symmetric(
            horizontal: horizontalPadding,
            vertical: 6,
          ),
          tapTargetSize: MaterialTapTargetSize.padded,
          visualDensity: VisualDensity.standard,
          shape: StadiumBorder(side: side),
          textStyle: const TextStyle(
            fontSize: 13,
            height: 1.2,
            fontWeight: FontWeight.w600,
          ),
        ).copyWith(side: WidgetStatePropertyAll(side)),
        child: Text(label, maxLines: 1, overflow: TextOverflow.ellipsis),
      ),
    );
  }
}
