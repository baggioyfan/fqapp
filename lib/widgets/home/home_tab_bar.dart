import 'package:flutter/material.dart';

import '../../services/desktop_platform.dart';
import 'home_design.dart';

class HomeCategory {
  final String label;
  final IconData icon;

  const HomeCategory(this.label, this.icon);
}

const homeCategories = [
  HomeCategory('推荐', Icons.circle),
  HomeCategory('小说', Icons.circle),
  HomeCategory('短剧', Icons.circle),
  HomeCategory('漫剧', Icons.circle),
  HomeCategory('漫画', Icons.circle),
  HomeCategory('听书', Icons.circle),
];

/// 官方书城顶部 tab 条（`res/layout/alx.xml` 的 `SlidingTabLayout aj0`）。
///
/// 尺寸取自反编译布局，只有左右内边距按用户要求收口：
/// * 高度 38dp，paddingBottom 10dp；
/// * 选中字号 `av5` = 24sp，未选中字号 `avq` = 16sp；
/// * 选中色 `aui` 与未选中色 `avn` 都是 `skin_color_black_light`(#000000)
///   —— 官方不靠颜色区分，只靠字号、字重（两态都粗体）和未选中 0.4 透明度；
/// * tab 间距 `avb` = 20dp（`SlidingTabLayout.O()` 里
///   `setMargins(0, 0, this.K, 0)`，`this.K` 就是 `avb`），tab 高 `avc` = 34dp；
/// * 指示器：`aup` = 0dp（高度 0）。`onDraw` 里 `if (this.s > 0.0f)` 才绘制，
///   所以官方书城顶栏**没有下划线**。`auw` = 16dp 是宽度，高度为 0 时无效。
///
/// 左右内边距官方是 `paddingStart` 20dp / `paddingEnd` 13dp——**本来就不对称**，
/// 贴上去后「推荐」左侧的空隙明显大于末位 tab 右侧（用户 2026-10-25 指出）。
/// 首页的栏距是搜索框那对 16dp（`HomeHero` 的 `fua`），短剧频道条也用同一对
/// 16dp，所以这里跟着收口成对称 16dp，让条带与它正上方的搜索框对齐。
///
/// 只收口 padding 还不够：六个分类在 361dp 的手机上只有 308dp 宽，右边多出来
/// 的空间是**剩余空间**而不是 padding，所以末位 tab 右缘照样离屏 40dp。条带放
/// 得下时会把富余按间隔平摊（见 [_gapWidth]），两端才同时落在 [sidePadding] 那
/// 条竖线上。
///
/// 桌面端另走一套（见 [desktopBarHeight] 起的一组常量）：上面那套几何是为
/// 375dp 竖屏调的，搬到 1280dp 窗口里会同时踩三个坑——
/// 1. 选中项 24sp、未选中 16sp，点一下整行文字就重排跳动；
/// 2. 灰色 0.4 透明度的 16sp 字和下方排行榜条（16/14sp 全粗体）撞成同一个
///    层级，两行看不出谁是一级；
/// 3. 没有 hover、没有指针光标，桌面上摸不出「这是可点的」。
/// 所以桌面改成等字号胶囊：选中项 accent 淡底 + accentStrong 文字，未选中
/// muted 文字、hover 出浅底、光标变手型。手机端保持官方形态不动。
class HomeTabBarDelegate extends SliverPersistentHeaderDelegate {
  static const double barHeight = 38;
  // `alx.xml` 为 10dp；2026-10-24 用户拍板不对齐官方——顶栏与排行榜条
  // 的距离按视觉收紧（与区块头 margin 联动，见 _rankStripTopMargin）。
  static const double bottomPadding = 4;
  static const double selectedSize = 24;
  static const double unselectedSize = 16;
  static const double tabSpacing = 20;

  /// 条带的左右栏距：与 [HomeHero] 搜索框一致（官方 20/13 的不对称见类注释）。
  static const double sidePadding = 16;

  /// 放得下时每个间隔最多再撑这么多：桌面宽窗里若按富余等比摊开，六个分类会被
  /// 摊到整屏两端，比留白更难看。
  static const double maxExtraSpacing = 12;

  /// 未选中项的透明度 `avr`（`SlidingTabLayout.a6`，`L2048 getFloat(55, 0.4f)`）。
  static const double unselectedAlpha = 0.4;

  // ---- 桌面（我们的适配，不对齐官方）----
  static const double desktopBarHeight = 46;
  static const double desktopBottomPadding = 8;
  static const double desktopFontSize = 14;

  /// 胶囊间距。比手机端的 20dp 小：有了底色之后不需要靠留白分组。
  static const double desktopTabGap = 6;

  /// 左右内边距：与上方搜索行（16）、下方排行榜区块（16）对齐成一条竖线。
  /// 官方是 20，桌面按这三层的共同左线收敛到 16。
  static const double desktopSidePadding = 16;
  static const double desktopPillRadius = 9;
  static const double desktopPillPaddingH = 14;
  static const double desktopPillPaddingV = 6;

  final int selectedIndex;
  final ValueChanged<int> onSelect;

  /// 顶栏分类。服务端下发 `tab_item` 时用服务端的，否则用 [homeCategories]。
  final List<HomeCategory> categories;
  final double extent;
  final bool dark;

  /// 墨水屏与 OLED 两档会换掉画布、线条和柔色，但都不改变 [dark]：OLED
  /// 只在深色下生效（深色仍是深色），墨水屏本身也是浅色外观。所以它们
  /// 必须各自单列进 [shouldRebuild]，否则切换后吸顶条会保留旧色板。
  final bool eink;
  final bool oled;

  /// 强制走某一端的形态。null 表示按运行平台判断（[isDesktopHost]）。
  /// 只为测试可断言，生产路径不要传。
  final bool? desktop;

  HomeTabBarDelegate({
    required this.selectedIndex,
    required this.onSelect,
    this.categories = homeCategories,
    this.extent = barHeight + bottomPadding,
    this.dark = false,
    this.eink = false,
    this.oled = false,
    this.desktop,
  });

  bool get _wide => desktop ?? isDesktopHost;

  /// pinned 头的总高。字号放大时必须同步长高：header 的 layoutExtent 要
  /// 等于 extent，否则 Flutter 报 "layoutExtent exceeds paintExtent"。
  static double extentFor(double textScale, {bool? desktop}) {
    final wide = desktop ?? isDesktopHost;
    final base = wide
        ? desktopBarHeight + desktopBottomPadding
        : barHeight + bottomPadding;
    return base + (textScale - 1).clamp(0, 2) * 16;
  }

  @override
  double get minExtent => extent;

  @override
  double get maxExtent => extent;

  @override
  Widget build(
    BuildContext context,
    double shrinkOffset,
    bool overlapsContent,
  ) {
    final palette = HomePalette.of(context);
    final wide = _wide;
    // pinned header 的 layoutExtent 必须等于 extent，否则 Flutter 报
    // "layoutExtent exceeds paintExtent"。字号随 textScale 长大时 extent
    // 同步变大，所以这里的高度必须从 extent 反推（见 [extentFor]）。
    final bottom = wide ? desktopBottomPadding : bottomPadding;
    final rowHeight = (extent - bottom).clamp(
      wide ? desktopBarHeight : barHeight,
      200.0,
    );
    return DecoratedBox(
      decoration: BoxDecoration(color: palette.canvas),
      child: wide
          ? _desktopBar(context, palette, rowHeight, bottom, overlapsContent)
          : _mobileBar(context, palette, rowHeight, bottom),
    );
  }

  /// 桌面形态：等字号胶囊 + hover，吸顶时补一条分隔线。
  Widget _desktopBar(
    BuildContext context,
    HomePalette palette,
    double rowHeight,
    double bottom,
    bool overlapsContent,
  ) => Stack(
    fit: StackFit.expand,
    children: [
      Padding(
        padding: EdgeInsets.fromLTRB(
          desktopSidePadding,
          0,
          desktopSidePadding,
          bottom,
        ),
        child: SizedBox(
          height: rowHeight,
          child: ListView.separated(
            padding: EdgeInsets.zero,
            scrollDirection: Axis.horizontal,
            itemCount: categories.length,
            separatorBuilder: (_, _) => const SizedBox(width: desktopTabGap),
            itemBuilder: (context, index) => Center(
              child: _DesktopTab(
                tabKey: ValueKey('home_category_$index'),
                label: categories[index].label,
                selected: index == selectedIndex,
                onTap: () => onSelect(index),
              ),
            ),
          ),
        ),
      ),
      // 吸顶时内容从胶囊底下穿过，没有分隔线会显得两行粘在一起。
      if (overlapsContent)
        Positioned(
          left: 0,
          right: 0,
          bottom: 0,
          child: SizedBox(
            height: 0.6,
            child: ColoredBox(color: palette.line),
          ),
        ),
    ],
  );

  /// 手机形态：官方字号/透明度两态，间隔按剩余宽度平摊（见 [_gapWidth]）。
  Widget _mobileBar(
    BuildContext context,
    HomePalette palette,
    double rowHeight,
    double bottom,
  ) {
    final duration = MediaQuery.disableAnimationsOf(context)
        ? Duration.zero
        : const Duration(milliseconds: 180);
    return Padding(
      padding: EdgeInsets.only(bottom: bottom),
      child: SizedBox(
        height: rowHeight,
        child: LayoutBuilder(
          builder: (context, constraints) {
            final gap = _gapWidth(context, constraints.maxWidth, palette);
            return SingleChildScrollView(
              scrollDirection: Axis.horizontal,
              padding: const EdgeInsets.symmetric(horizontal: sidePadding),
              child: Row(
                mainAxisSize: MainAxisSize.min,
                children: [
                  for (var index = 0; index < categories.length; index++) ...[
                    if (index > 0) SizedBox(width: gap),
                    _tab(index, rowHeight, duration, palette),
                  ],
                ],
              ),
            );
          },
        ),
      ),
    );
  }

  /// tab 之间的间隔。
  ///
  /// 官方 `avb` = 20dp 是「条带一定放不下」的前提下的值。本地六个分类在手机宽
  /// 上放得下，此时右边露出来的空白是剩余空间，跟 padding 无关——所以要把它按
  /// 间隔平摊，首个 tab 的左缘与末位 tab 的右缘才同时落在 [sidePadding] 竖线上。
  /// 摊得太多（桌面宽窗）就封顶到 [maxExtraSpacing]，宁可留一边空白也不要把分类
  /// 扯散。
  double _gapWidth(
    BuildContext context,
    double availableWidth,
    HomePalette palette,
  ) {
    final gaps = categories.length - 1;
    if (gaps <= 0 || !availableWidth.isFinite) return tabSpacing;

    // 每个 tab 的宽度就是它那行字的宽度（Center 在 Row 里收缩包裹），用同一个
    // TextStyle + textScaler 量出来才算得准。
    final scaler = MediaQuery.textScalerOf(context);
    final textDirection = Directionality.of(context);
    var contentWidth = 0.0;
    for (var index = 0; index < categories.length; index++) {
      final painter = TextPainter(
        text: TextSpan(
          text: categories[index].label,
          style: _labelStyle(index == selectedIndex, palette),
        ),
        textDirection: textDirection,
        textScaler: scaler,
        maxLines: 1,
      )..layout();
      contentWidth += painter.width;
      painter.dispose();
    }

    final spare =
        availableWidth - 2 * sidePadding - contentWidth - gaps * tabSpacing;
    if (spare <= 0) return tabSpacing;
    return tabSpacing + (spare / gaps).clamp(0.0, maxExtraSpacing);
  }

  TextStyle _labelStyle(bool selected, HomePalette palette) => TextStyle(
    fontSize: selected ? selectedSize : unselectedSize,
    fontWeight: FontWeight.w700,
    color: palette.ink.withValues(alpha: selected ? 1 : unselectedAlpha),
    height: 1,
  );

  Widget _tab(
    int index,
    double rowHeight,
    Duration duration,
    HomePalette palette,
  ) {
    final selected = index == selectedIndex;
    final category = categories[index];
    return Semantics(
      selected: selected,
      button: true,
      label: category.label,
      excludeSemantics: true,
      onTap: () => onSelect(index),
      child: GestureDetector(
        key: ValueKey('home_category_$index'),
        behavior: HitTestBehavior.opaque,
        onTap: () => onSelect(index),
        // 官方书城顶栏不画指示器：`alx.xml` 把 `aup`(指示器高度) 设成 0，
        // `SlidingTabLayout.onDraw` 只在 `s > 0` 时绘制。
        //
        // 选中态只差「字号 + 透明度」：`s0()` 对每一项都调 `setTypeface(a(1))`
        // （`R5 = getInt(53, 2)` 让 `z` 恒为真），所以两态都是粗体；未选中项再叠加
        // `alpha = a6` = 0.4（`avr`，`L2048 getFloat(55, 0.4f)`）。
        child: SizedBox(
          height: rowHeight,
          child: Center(
            child: AnimatedDefaultTextStyle(
              duration: duration,
              curve: Curves.easeOutCubic,
              style: _labelStyle(selected, palette),
              child: Text(category.label),
            ),
          ),
        ),
      ),
    );
  }

  // Note: pinned header 必须把主题算进 shouldRebuild — 见
  // .agents/notes/implemented/bug-fix/2026-09-18-home-geometry-and-backup.md
  @override
  bool shouldRebuild(HomeTabBarDelegate oldDelegate) =>
      selectedIndex != oldDelegate.selectedIndex ||
      extent != oldDelegate.extent ||
      onSelect != oldDelegate.onSelect ||
      categories != oldDelegate.categories ||
      dark != oldDelegate.dark ||
      eink != oldDelegate.eink ||
      oled != oldDelegate.oled ||
      desktop != oldDelegate.desktop;
}

/// 桌面分类胶囊。
///
/// 与手机端刻意不同：两态字号一致（14sp），只靠底色 / 字重 / 颜色区分，
/// 切换时整行不会重排；hover 有浅底反馈、光标是手型。
class _DesktopTab extends StatefulWidget {
  const _DesktopTab({
    required this.tabKey,
    required this.label,
    required this.selected,
    required this.onTap,
  });

  final Key tabKey;
  final String label;
  final bool selected;
  final VoidCallback onTap;

  @override
  State<_DesktopTab> createState() => _DesktopTabState();
}

class _DesktopTabState extends State<_DesktopTab> {
  bool _hover = false;

  @override
  Widget build(BuildContext context) {
    final palette = HomePalette.of(context);
    final duration = MediaQuery.disableAnimationsOf(context)
        ? Duration.zero
        : const Duration(milliseconds: 140);
    final selected = widget.selected;
    final Color background;
    if (selected) {
      background = HomePalette.accent.withValues(
        alpha: palette.dark ? 0.22 : 0.11,
      );
    } else if (_hover) {
      background = palette.soft;
    } else {
      background = Colors.transparent;
    }
    return Semantics(
      selected: selected,
      button: true,
      label: widget.label,
      excludeSemantics: true,
      onTap: widget.onTap,
      child: MouseRegion(
        cursor: SystemMouseCursors.click,
        onEnter: (_) => setState(() => _hover = true),
        onExit: (_) => setState(() => _hover = false),
        child: GestureDetector(
          key: widget.tabKey,
          behavior: HitTestBehavior.opaque,
          onTap: widget.onTap,
          child: AnimatedContainer(
            duration: duration,
            curve: Curves.easeOutCubic,
            padding: const EdgeInsets.symmetric(
              horizontal: HomeTabBarDelegate.desktopPillPaddingH,
              vertical: HomeTabBarDelegate.desktopPillPaddingV,
            ),
            decoration: BoxDecoration(
              color: background,
              borderRadius: BorderRadius.circular(
                HomeTabBarDelegate.desktopPillRadius,
              ),
            ),
            child: AnimatedDefaultTextStyle(
              duration: duration,
              curve: Curves.easeOutCubic,
              style: TextStyle(
                fontSize: HomeTabBarDelegate.desktopFontSize,
                // 墨水屏没有 accent 区分，选中项靠字重加粗补齐。
                fontWeight: selected ? FontWeight.w600 : FontWeight.w500,
                color: selected
                    ? (palette.eink ? palette.ink : palette.accentText)
                    : palette.muted,
                height: 1.1,
              ),
              child: Text(widget.label),
            ),
          ),
        ),
      ),
    );
  }
}
