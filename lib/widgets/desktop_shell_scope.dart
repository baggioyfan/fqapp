import 'package:flutter/scheduler.dart';
import 'package:material_ui/material_ui.dart';

/// Theme and control descriptor published by an active desktop reader route so
/// [DesktopAppFrame] and [DesktopWindowBar] can match the reader's surface.
@immutable
class DesktopReaderChrome {
  const DesktopReaderChrome({
    required this.owner,
    required this.title,
    required this.isDark,
    required this.isEink,
    required this.barBackground,
    required this.surface,
    required this.hoverBackground,
    required this.border,
    required this.ink,
    required this.muted,
    required this.accent,
    this.canToggleSidebar = false,
    this.sidebarOpen = false,
    this.canToggleFullscreen = false,
    this.onToggleSidebar,
  });

  final Object owner;
  final String title;
  final bool isDark;
  final bool isEink;
  final Color barBackground;
  final Color surface;
  final Color hoverBackground;
  final Color border;
  final Color ink;
  final Color muted;
  final Color accent;
  final bool canToggleSidebar;
  final bool sidebarOpen;
  final bool canToggleFullscreen;
  final VoidCallback? onToggleSidebar;

  @override
  bool operator ==(Object other) =>
      identical(this, other) ||
      other is DesktopReaderChrome &&
          identical(owner, other.owner) &&
          title == other.title &&
          isDark == other.isDark &&
          isEink == other.isEink &&
          barBackground == other.barBackground &&
          surface == other.surface &&
          hoverBackground == other.hoverBackground &&
          border == other.border &&
          ink == other.ink &&
          muted == other.muted &&
          accent == other.accent &&
          canToggleSidebar == other.canToggleSidebar &&
          sidebarOpen == other.sidebarOpen &&
          canToggleFullscreen == other.canToggleFullscreen &&
          (onToggleSidebar != null) == (other.onToggleSidebar != null);

  @override
  int get hashCode => Object.hash(
    identityHashCode(owner),
    title,
    isDark,
    isEink,
    barBackground,
    surface,
    hoverBackground,
    border,
    ink,
    muted,
    accent,
    canToggleSidebar,
    sidebarOpen,
    canToggleFullscreen,
    onToggleSidebar != null,
  );
}

/// Shared navigation and chrome state for the Windows Fluent desktop shell.
class DesktopShellState {
  DesktopShellState._();

  static final canPop = ValueNotifier<bool>(false);
  static final onSearchPage = ValueNotifier<bool>(false);
  static final onSettingsPage = ValueNotifier<bool>(false);
  static final sidebarExpanded = ValueNotifier<bool>(true);
  static final readerChrome = ValueNotifier<DesktopReaderChrome?>(null);

  static int _searchRoutes = 0;
  static int _settingsRoutes = 0;
  static DesktopReaderChrome? _pendingReaderChrome;

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

  static void setReaderChrome(DesktopReaderChrome chrome) {
    if (_pendingReaderChrome == chrome && readerChrome.value == chrome) return;
    _pendingReaderChrome = chrome;
    _publish(() {
      if (identical(_pendingReaderChrome, chrome) &&
          readerChrome.value != chrome) {
        readerChrome.value = chrome;
      }
    });
  }

  static void clearReaderChrome(Object owner) {
    if (_pendingReaderChrome == null ||
        !identical(_pendingReaderChrome!.owner, owner)) {
      return;
    }
    _pendingReaderChrome = null;
    _publish(() {
      if (_pendingReaderChrome == null && readerChrome.value != null) {
        readerChrome.value = null;
      }
    });
  }

  @visibleForTesting
  static void reset() {
    _searchRoutes = 0;
    _settingsRoutes = 0;
    _pendingReaderChrome = null;
    canPop.value = false;
    onSearchPage.value = false;
    onSettingsPage.value = false;
    sidebarExpanded.value = true;
    readerChrome.value = null;
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
