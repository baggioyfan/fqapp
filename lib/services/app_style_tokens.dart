import 'package:flutter/material.dart';

import 'app_theme_style.dart';

/// Shared appearance tokens. Layout preferences and reading typography remain
/// owned by their existing stores; a style switch changes presentation only.
@immutable
class AppStyleTokens extends ThemeExtension<AppStyleTokens> {
  const AppStyleTokens({
    required this.style,
    required this.panelRadius,
    required this.coverRadius,
    required this.panelPadding,
    required this.pageGutter,
    required this.sectionGap,
    required this.entryGap,
    required this.showDecorativeCodes,
  });

  const AppStyleTokens.archive()
    : style = AppThemeStyle.archive,
      panelRadius = 4,
      coverRadius = 3,
      panelPadding = 16,
      pageGutter = 24,
      sectionGap = 24,
      entryGap = 14,
      showDecorativeCodes = true;

  const AppStyleTokens.classic()
    : style = AppThemeStyle.classic,
      panelRadius = 16,
      coverRadius = 10,
      panelPadding = 12,
      pageGutter = 16,
      sectionGap = 16,
      entryGap = 8,
      showDecorativeCodes = false;

  factory AppStyleTokens.forStyle(AppThemeStyle style) => switch (style) {
    AppThemeStyle.classic => const AppStyleTokens.classic(),
    AppThemeStyle.archive => const AppStyleTokens.archive(),
  };

  /// 兜底仍是档案度量，**不是**生产路径：`main.dart` 用 `AppUiScope` 包住整棵
  /// 树，`app_theme.dart` 又总会挂上本 extension，真实运行取不到这里的兜底。
  /// 会走到它的只有「只 pump 单页、不装 scope」的 widget 测试 —— 那批用例正是
  /// 以档案版式为基线写的（208 个），改成 classic 会把它们整体翻成经典布局。
  /// 动这一行要先迁移测试基线，属 P1b 的完整收敂范围。
  static AppStyleTokens of(BuildContext context) =>
      Theme.of(context).extension<AppStyleTokens>() ??
      const AppStyleTokens.archive();

  final AppThemeStyle style;
  final double panelRadius;
  final double coverRadius;
  final double panelPadding;
  final double pageGutter;
  final double sectionGap;
  final double entryGap;
  final bool showDecorativeCodes;

  bool get isClassic => style == AppThemeStyle.classic;

  @override
  AppStyleTokens copyWith({
    AppThemeStyle? style,
    double? panelRadius,
    double? coverRadius,
    double? panelPadding,
    double? pageGutter,
    double? sectionGap,
    double? entryGap,
    bool? showDecorativeCodes,
  }) => AppStyleTokens(
    style: style ?? this.style,
    panelRadius: panelRadius ?? this.panelRadius,
    coverRadius: coverRadius ?? this.coverRadius,
    panelPadding: panelPadding ?? this.panelPadding,
    pageGutter: pageGutter ?? this.pageGutter,
    sectionGap: sectionGap ?? this.sectionGap,
    entryGap: entryGap ?? this.entryGap,
    showDecorativeCodes: showDecorativeCodes ?? this.showDecorativeCodes,
  );

  @override
  AppStyleTokens lerp(AppStyleTokens? other, double t) {
    if (other == null) return this;
    double blend(double a, double b) => a + (b - a) * t;
    return AppStyleTokens(
      style: t < .5 ? style : other.style,
      panelRadius: blend(panelRadius, other.panelRadius),
      coverRadius: blend(coverRadius, other.coverRadius),
      panelPadding: blend(panelPadding, other.panelPadding),
      pageGutter: blend(pageGutter, other.pageGutter),
      sectionGap: blend(sectionGap, other.sectionGap),
      entryGap: blend(entryGap, other.entryGap),
      showDecorativeCodes: t < .5
          ? showDecorativeCodes
          : other.showDecorativeCodes,
    );
  }
}
