import 'package:flutter/foundation.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:material_ui/material_ui.dart';

import 'package:fqapp/services/app_theme.dart';
import 'package:fqapp/services/app_theme_style.dart';
import 'package:fqapp/services/desktop_platform.dart';
import 'package:fqapp/widgets/desktop_app_frame.dart';
import 'package:fqapp/widgets/desktop_shell_scope.dart';
import 'support/app_ui_host.dart';

void main() {
  setUp(() {
    desktopTab.value = 0;
    DesktopPlatform.fullscreen.value = false;
    DesktopPlatform.maximized.value = false;
    DesktopShellState.reset();
    einkModeNotifier.value = false;
    oledModeNotifier.value = false;
  });

  tearDown(() {
    desktopTab.value = 0;
    DesktopPlatform.fullscreen.value = false;
    DesktopPlatform.maximized.value = false;
    DesktopShellState.reset();
    einkModeNotifier.value = false;
    oledModeNotifier.value = false;
  });

  testWidgets('frame title is 什锦铺; global search hides on the drama tab', (
    tester,
  ) async {
    await tester.pumpWidget(
      const MaterialApp(home: DesktopAppFrame(child: SizedBox.expand())),
    );
    await tester.pump();

    expect(find.text('什锦铺'), findsOneWidget);
    expect(find.text('番茄小铺'), findsNothing);
    expect(find.byKey(const Key('desktop-search')), findsOneWidget);

    // 短剧分区自带搜索入口：壳层全局搜索隐藏，只留一处搜索。
    desktopTab.value = 1;
    await tester.pump();
    expect(find.byKey(const Key('desktop-search')), findsNothing);
    expect(find.text('什锦铺'), findsOneWidget);

    // 切回其它分区，全局搜索恢复。
    desktopTab.value = 0;
    await tester.pump();
    expect(find.byKey(const Key('desktop-search')), findsOneWidget);
    await tester.pumpWidget(const SizedBox.shrink());
  });

  testWidgets('window bar caption buttons and back state react cleanly', (
    tester,
  ) async {
    debugDefaultTargetPlatformOverride = TargetPlatform.windows;
    await tester.binding.setSurfaceSize(const Size(1280, 800));
    try {
      await tester.pumpWidget(
        const MaterialApp(home: DesktopAppFrame(child: SizedBox.expand())),
      );
      await tester.pump();

      expect(find.byKey(const Key('desktop-window-bar')), findsOneWidget);
      expect(find.byKey(const Key('desktop-back')), findsOneWidget);
      expect(find.byKey(const Key('desktop-window-minimize')), findsOneWidget);
      expect(find.byKey(const Key('desktop-window-maximize')), findsOneWidget);
      expect(find.byKey(const Key('desktop-window-close')), findsOneWidget);
      expect(find.byTooltip('最大化'), findsOneWidget);

      DesktopPlatform.maximized.value = true;
      await tester.pump();
      expect(find.byTooltip('还原'), findsOneWidget);

      await tester.pumpWidget(const SizedBox.shrink());
    } finally {
      await tester.binding.setSurfaceSize(null);
      debugDefaultTargetPlatformOverride = null;
    }
  });

  testWidgets('navigation pane adapts to window width and toggles cleanly', (
    tester,
  ) async {
    debugDefaultTargetPlatformOverride = TargetPlatform.windows;
    try {
      await tester.binding.setSurfaceSize(const Size(960, 700));
      await tester.pumpWidget(
        const MaterialApp(home: DesktopAppFrame(child: SizedBox.expand())),
      );
      await tester.pumpAndSettle();
      expect(
        tester.getSize(find.byKey(const Key('desktop-nav-pane'))).width,
        68,
      );
      expect(find.byKey(const Key('desktop-sidebar-toggle')), findsNothing);

      await tester.binding.setSurfaceSize(const Size(1280, 800));
      await tester.pumpAndSettle();
      expect(
        tester.getSize(find.byKey(const Key('desktop-nav-pane'))).width,
        200,
      );
      expect(find.byKey(const Key('desktop-sidebar-toggle')), findsOneWidget);

      await tester.tap(find.byKey(const Key('desktop-sidebar-toggle')));
      await tester.pumpAndSettle();
      expect(
        tester.getSize(find.byKey(const Key('desktop-nav-pane'))).width,
        68,
      );

      await tester.tap(find.byKey(const Key('desktop-sidebar-toggle')));
      await tester.pumpAndSettle();
      expect(
        tester.getSize(find.byKey(const Key('desktop-nav-pane'))).width,
        200,
      );

      await tester.pumpWidget(const SizedBox.shrink());
    } finally {
      await tester.binding.setSurfaceSize(null);
      debugDefaultTargetPlatformOverride = null;
    }
  });

  testWidgets('shell hides search bar when active route is SearchPage', (
    tester,
  ) async {
    await tester.pumpWidget(
      const MaterialApp(home: DesktopAppFrame(child: SizedBox.expand())),
    );
    await tester.pump();
    expect(find.byKey(const Key('desktop-search')), findsOneWidget);

    DesktopShellState.enterSearch();
    await tester.pump();
    expect(find.byKey(const Key('desktop-search')), findsNothing);

    DesktopShellState.exitSearch();
    await tester.pump();
    expect(find.byKey(const Key('desktop-search')), findsOneWidget);
    await tester.pumpWidget(const SizedBox.shrink());
  });

  testWidgets('Fluent shell renders all themes without exceptions', (
    tester,
  ) async {
    debugDefaultTargetPlatformOverride = TargetPlatform.windows;
    await tester.binding.setSurfaceSize(const Size(1280, 800));
    final store = AppThemeStyleStore();
    try {
      for (final config in [
        (style: AppThemeStyle.archive, oled: false, eink: false),
        (style: AppThemeStyle.classic, oled: false, eink: false),
        (style: AppThemeStyle.archive, oled: true, eink: false),
        (style: AppThemeStyle.archive, oled: false, eink: true),
      ]) {
        store.value = config.style;
        oledModeNotifier.value = config.oled;
        einkModeNotifier.value = config.eink;
        await tester.pumpWidget(
          AppUiHost(
            store: store,
            home: const DesktopAppFrame(child: SizedBox.expand()),
          ),
        );
        await tester.pumpAndSettle();
        expect(tester.takeException(), isNull);
        expect(find.byKey(const Key('desktop-window-bar')), findsOneWidget);
      }
      await tester.pumpWidget(const SizedBox.shrink());
    } finally {
      store.dispose();
      await tester.binding.setSurfaceSize(null);
      debugDefaultTargetPlatformOverride = null;
    }
  });

  testWidgets(
    'reader chrome hides nav pane, syncs dark colors, and restores on clear',
    (tester) async {
      debugDefaultTargetPlatformOverride = TargetPlatform.windows;
      await tester.binding.setSurfaceSize(const Size(1280, 800));
      final owner = Object();
      var toggled = false;
      const darkBarBg = Color(0xFF1E1E1E);
      try {
        await tester.pumpWidget(
          const MaterialApp(home: DesktopAppFrame(child: SizedBox.expand())),
        );
        await tester.pump();

        expect(find.byKey(const Key('desktop-nav-pane')), findsOneWidget);
        expect(find.byKey(const Key('desktop-search')), findsOneWidget);

        DesktopShellState.setReaderChrome(
          DesktopReaderChrome(
            owner: owner,
            title: '测试书名',
            isDark: true,
            isEink: false,
            barBackground: darkBarBg,
            surface: const Color(0xFF282828),
            hoverBackground: const Color(0x18FFFFFF),
            border: const Color(0x1FD2D2D2),
            ink: const Color(0xFFD2D2D2),
            muted: const Color(0xA6D2D2D2),
            accent: const Color(0xFFE9AD82),
            canToggleSidebar: true,
            sidebarOpen: true,
            canToggleFullscreen: true,
            onToggleSidebar: () => toggled = true,
          ),
        );
        await tester.pump();

        expect(find.byKey(const Key('desktop-nav-pane')), findsNothing);
        expect(find.byKey(const Key('desktop-sidebar-toggle')), findsNothing);
        expect(find.byKey(const Key('desktop-search')), findsNothing);
        expect(find.byKey(const Key('desktop-back')), findsOneWidget);
        expect(find.byKey(const Key('desktop-reader-title')), findsOneWidget);
        expect(find.text('测试书名'), findsOneWidget);
        expect(
          find.byKey(const Key('desktop-reader-toc-toggle')),
          findsOneWidget,
        );
        expect(
          find.byKey(const Key('desktop-reader-fullscreen-toggle')),
          findsOneWidget,
        );

        final bar = tester.widget<Container>(
          find.byKey(const Key('desktop-window-bar')),
        );
        expect(bar.color, darkBarBg);

        await tester.tap(find.byKey(const Key('desktop-reader-toc-toggle')));
        await tester.pump();
        expect(toggled, isTrue);

        DesktopShellState.clearReaderChrome(owner);
        await tester.pump();
        expect(find.byKey(const Key('desktop-nav-pane')), findsOneWidget);
        expect(find.byKey(const Key('desktop-search')), findsOneWidget);
        expect(find.byKey(const Key('desktop-reader-title')), findsNothing);

        await tester.pumpWidget(const SizedBox.shrink());
      } finally {
        await tester.binding.setSurfaceSize(null);
        debugDefaultTargetPlatformOverride = null;
      }
    },
  );
}
