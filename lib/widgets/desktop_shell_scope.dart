import 'package:flutter/scheduler.dart';
import 'package:material_ui/material_ui.dart';

/// Shared navigation and chrome state for the Windows Fluent desktop shell.
class DesktopShellState {
  DesktopShellState._();

  static final canPop = ValueNotifier<bool>(false);
  static final onSearchPage = ValueNotifier<bool>(false);
  static final onSettingsPage = ValueNotifier<bool>(false);
  static final sidebarExpanded = ValueNotifier<bool>(true);

  static int _searchRoutes = 0;
  static int _settingsRoutes = 0;

  static void _publish(VoidCallback fn) {
    final phase = WidgetsBinding.instance.schedulerPhase;
    if (phase == SchedulerPhase.idle ||
        phase == SchedulerPhase.postFrameCallbacks) {
      fn();
      return;
    }
    WidgetsBinding.instance.addPostFrameCallback((_) => fn());
  }

  static void setCanPop(bool value) {
    if (canPop.value == value) return;
    _publish(() => canPop.value = value);
  }

  static void enterSearch() {
    _searchRoutes++;
    final active = _searchRoutes > 0;
    if (onSearchPage.value != active) {
      _publish(() => onSearchPage.value = active);
    }
  }

  static void exitSearch() {
    if (_searchRoutes > 0) _searchRoutes--;
    final active = _searchRoutes > 0;
    if (onSearchPage.value != active) {
      _publish(() => onSearchPage.value = active);
    }
  }

  static void enterSettings() {
    _settingsRoutes++;
    final active = _settingsRoutes > 0;
    if (onSettingsPage.value != active) {
      _publish(() => onSettingsPage.value = active);
    }
  }

  static void exitSettings() {
    if (_settingsRoutes > 0) _settingsRoutes--;
    final active = _settingsRoutes > 0;
    if (onSettingsPage.value != active) {
      _publish(() => onSettingsPage.value = active);
    }
  }

  static void toggleSidebar() {
    sidebarExpanded.value = !sidebarExpanded.value;
  }

  @visibleForTesting
  static void reset() {
    _searchRoutes = 0;
    _settingsRoutes = 0;
    canPop.value = false;
    onSearchPage.value = false;
    onSettingsPage.value = false;
    sidebarExpanded.value = true;
  }
}

/// Tracks the root Navigator stack depth so the custom Windows title bar can
/// enable/disable its back button accurately.
class DesktopRouteObserver extends NavigatorObserver {
  int _depth = 0;

  void _sync() {
    DesktopShellState.setCanPop(_depth > 1);
  }

  @override
  void didPush(Route<dynamic> route, Route<dynamic>? previousRoute) {
    _depth++;
    _sync();
  }

  @override
  void didPop(Route<dynamic> route, Route<dynamic>? previousRoute) {
    if (_depth > 0) _depth--;
    _sync();
  }

  @override
  void didRemove(Route<dynamic> route, Route<dynamic>? previousRoute) {
    if (_depth > 0) _depth--;
    _sync();
  }

  @override
  void didReplace({Route<dynamic>? newRoute, Route<dynamic>? oldRoute}) {
    _sync();
  }
}

/// Marks whether a subtree is hosted inside [DesktopAppFrame], allowing
/// inner pages to avoid rendering duplicate headers or search bars on Windows.
class DesktopShellScope extends InheritedWidget {
  const DesktopShellScope({
    super.key,
    required this.hasFrame,
    required super.child,
  });

  final bool hasFrame;

  static bool hasFrameOf(BuildContext context) =>
      context
          .dependOnInheritedWidgetOfExactType<DesktopShellScope>()
          ?.hasFrame ??
      false;

  @override
  bool updateShouldNotify(DesktopShellScope oldWidget) =>
      hasFrame != oldWidget.hasFrame;
}
