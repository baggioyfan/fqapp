import 'package:flutter/foundation.dart';
import 'package:flutter/widgets.dart';

import '../../services/app_style_tokens.dart';
import '../../services/app_theme_style.dart';

/// Discrete presentation policy for the selected [AppThemeStyle].
///
/// A layout branch must decide once per selection, never from the in-between
/// value `AppStyleTokens.lerp` produces while `AnimatedTheme` animates. The
/// tokens here are the target style's own constants, so classic/archive
/// branches cannot flip back and forth mid-transition.
@immutable
class AppUiPresentation {
  const AppUiPresentation._(this.style, this.tokens);

  static AppUiPresentation forStyle(AppThemeStyle style) => switch (style) {
    AppThemeStyle.classic => const AppUiPresentation._(
      AppThemeStyle.classic,
      AppStyleTokens.classic(),
    ),
    AppThemeStyle.archive => const AppUiPresentation._(
      AppThemeStyle.archive,
      AppStyleTokens.archive(),
    ),
  };

  final AppThemeStyle style;

  /// Target-style constants, not the animated `ThemeExtension`.
  final AppStyleTokens tokens;

  bool get isClassic => style == AppThemeStyle.classic;

  bool get showDecorativeCodes => tokens.showDecorativeCodes;
}

/// One live, app-wide presentation scope for the current [AppThemeStyle].
///
/// `main.dart` installs it inside `MaterialApp.builder`, above the root
/// Navigator (and therefore above nested Navigators and every Overlay entry).
/// Displays read the discrete style from here; [AppThemeStyleStore] remains
/// the only state owner and the only thing that writes the preference.
///
/// The scope is a plain inherited scope, not an `InheritedTheme`: popup routes
/// that capture themes for reader paper still find it through their ancestors,
/// so an already-open sheet does not freeze the style it opened with.
///
/// Reading is harmless when the scope is absent (single-page widget tests and
/// compatibility call sites): it falls back to the surrounding
/// [AppStyleTokens]. Production entry points are expected to provide the
/// scope; [debugFallbackReads] makes a missing one measurable in tests.
class AppUiScope extends InheritedNotifier<AppThemeStyleStore> {
  const AppUiScope({
    super.key,
    required AppThemeStyleStore store,
    required super.child,
  }) : super(notifier: store);

  /// Number of fallback reads in debug builds. Reset it before exercising a
  /// production entry point to prove that tree never relies on the fallback.
  @visibleForTesting
  static int debugFallbackReads = 0;

  /// Subscribes to the live style and returns the scope, or null if absent.
  static AppUiScope? maybeOf(BuildContext context) =>
      context.dependOnInheritedWidgetOfExactType<AppUiScope>();

  /// Whether an [AppUiScope] is above [context]. Does not subscribe.
  static bool isAvailable(BuildContext context) =>
      context.getElementForInheritedWidgetOfExactType<AppUiScope>() != null;

  /// The live discrete style. Never the animated token value.
  ///
  /// fork 只保留经典界面，但收敂点在**取值来源**：产品的
  /// [AppThemeStyleStore.instance] 钉死 classic，所以这里读到的永远是 classic。
  /// 这一层仍按 scope 的真实值回报 —— 孤立 widget 测试会自己造 archive store，
  /// 恒报 classic 会把它们整体翻成经典布局。
  ///
  /// 缺 scope 时仍然走一次 [AppStyleTokens] 回退读取，好让
  /// [debugFallbackReads] 继续度量「有树没接 scope」的情况。
  static AppThemeStyle of(BuildContext context) {
    final scope = maybeOf(context);
    if (scope != null) return scope.notifier!.value;
    return _fallbackStyle(context);
  }

  /// Discrete target-style constants for layout branches.
  static AppUiPresentation presentationOf(BuildContext context) =>
      AppUiPresentation.forStyle(of(context));

  static bool isClassic(BuildContext context) =>
      of(context) == AppThemeStyle.classic;

  static AppThemeStyle _fallbackStyle(BuildContext context) {
    if (kDebugMode) debugFallbackReads++;
    return AppStyleTokens.of(context).style;
  }
}
