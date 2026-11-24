import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:material_ui/material_ui.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:fqapp/pages/boss_key_settings_page.dart';
import 'package:fqapp/pages/settings_page.dart';
import 'package:fqapp/services/app_theme.dart';
import 'package:fqapp/services/app_theme_style.dart';
import 'package:fqapp/services/boss_key_preferences.dart';
import 'package:fqapp/services/boss_key_service.dart';
import 'package:fqapp/widgets/app_ui/app_ui_scope.dart';
import 'package:fqapp/widgets/desktop_settings_body.dart';
import 'package:fqapp/widgets/settings/settings_widgets.dart';

class _FakeBossKeyBridge implements BossKeyNativeBridge {
  bool globalHotkey = true;
  String backend = 'win32';
  PlatformException? nextRegisterError;
  final List<BossKeyShortcut> registeredHistory = [];
  BossKeyShortcut? active;
  int unregisterCalls = 0;
  Future<void> Function()? _onTriggered;

  @override
  Future<({bool globalHotkey, String backend})> capabilities() async =>
      (globalHotkey: globalHotkey, backend: backend);

  @override
  Future<void> register(BossKeyShortcut shortcut) async {
    final error = nextRegisterError;
    if (error != null) {
      nextRegisterError = null;
      throw error;
    }
    registeredHistory.add(shortcut);
    active = shortcut;
  }

  @override
  Future<void> unregister() async {
    unregisterCalls++;
    active = null;
  }

  @override
  void setTriggerHandler(Future<void> Function()? onTriggered) {
    _onTriggered = onTriggered;
  }

  Future<void> trigger() async {
    await _onTriggered?.call();
  }
}

class _FakeWindowControl implements BossKeyWindowControl {
  bool visible = true;
  int hideCalls = 0;
  int restoreCalls = 0;

  @override
  Future<bool> isVisible() async => visible;

  @override
  Future<void> hide() async {
    hideCalls++;
    visible = false;
  }

  @override
  Future<void> restore() async {
    restoreCalls++;
    visible = true;
  }
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  late _FakeBossKeyBridge bridge;
  late _FakeWindowControl windowControl;
  late DateTime now;
  late int pauseCalls;
  bool throwOnPause = false;

  setUp(() {
    SharedPreferences.setMockInitialValues({});
    BossKeyPreferences.instance.resetForTest();
    bridge = _FakeBossKeyBridge();
    windowControl = _FakeWindowControl();
    now = DateTime(2026, 11, 20, 12, 0, 0);
    pauseCalls = 0;
    throwOnPause = false;
    BossKeyService.instance.resetForTest(
      bridge: bridge,
      windowControl: windowControl,
      pausePlayback: () async {
        pauseCalls++;
        if (throwOnPause) throw StateError('pause failed');
      },
      clock: () => now,
      platformSupported: () => true,
    );
  });

  tearDown(() {
    debugDefaultTargetPlatformOverride = null;
    BossKeyService.instance.resetForTest();
    BossKeyPreferences.instance.resetForTest();
  });

  group('BossKeyShortcut', () {
    test('default shortcut encodes, decodes, and maps to Win32 and X11', () {
      const def = BossKeyShortcut.defaultShortcut;
      expect(def.encode(), 'alt+Q');
      expect(BossKeyShortcut.tryDecode('alt+Q'), def);
      expect(def.formatLabel(platform: TargetPlatform.windows), 'Alt + Q');
      expect(def.winVirtualKey, 0x51);
      expect(def.x11KeySym, 0x0071);
      expect(def.isValid, isTrue);
    });

    test('formats Meta as Win on Windows and Super on Linux', () {
      const shortcut = BossKeyShortcut(ctrl: true, meta: true, key: 'H');
      expect(
        shortcut.formatLabel(platform: TargetPlatform.windows),
        'Ctrl + Win + H',
      );
      expect(
        shortcut.formatLabel(platform: TargetPlatform.linux),
        'Ctrl + Super + H',
      );
      expect(BossKeyShortcut.tryDecode(shortcut.encode()), shortcut);
    });

    test('maps every bindable key to a macOS Carbon key code', () {
      // macOS 的键码和 ASCII 没有对应关系，漏一个就有一个键在 Mac 上按不动，
      // 所以这里逐个核对，而不是抽查。
      const macCodes = <String, int>{
        'A': 0x00,
        'S': 0x01,
        'B': 0x0B,
        'Q': 0x0C,
        'T': 0x11,
        '1': 0x12,
        '0': 0x1D,
        'Equal': 0x18,
        'Space': 0x31,
        'Escape': 0x35,
        'F1': 0x7A,
        'F12': 0x6F,
        'Delete': 0x75,
        'ArrowUp': 0x7E,
      };
      for (final entry in macCodes.entries) {
        expect(
          BossKeyShortcut(key: entry.key).macVirtualKey,
          entry.value,
          reason: 'macOS 键码不对：${entry.key}',
        );
      }

      // 每个能录进设置的键都必须有 macOS 键码；`Insert` 是唯一的例外
      // （Mac 键盘上没有这个键），约定用 -1 表示不支持。
      const keys = <String>[
        'A', 'B', 'C', 'D', 'E', 'F', 'G', 'H', 'I', 'J', 'K', 'L', 'M', 'N',
        'O', 'P', 'Q', 'R', 'S', 'T', 'U', 'V', 'W', 'X', 'Y', 'Z',
        '0', '1', '2', '3', '4', '5', '6', '7', '8', '9',
        'F1', 'F2', 'F3', 'F4', 'F5', 'F6', 'F7', 'F8', 'F9', 'F10', 'F11',
        'F12', 'Space', 'Tab', 'Escape', 'Backquote', 'Minus', 'Equal',
        'BracketLeft', 'BracketRight', 'Semicolon', 'Quote', 'Comma', 'Period',
        'Slash', 'Backslash', 'Delete', 'Home', 'End', 'PageUp', 'PageDown',
        'ArrowUp', 'ArrowDown', 'ArrowLeft', 'ArrowRight',
      ];
      for (final key in keys) {
        expect(
          BossKeyShortcut(key: key).macVirtualKey,
          isNot(-1),
          reason: '$key 在 macOS 上没有键码',
        );
      }
      expect(const BossKeyShortcut(key: 'Insert').macVirtualKey, -1);
      expect(const BossKeyShortcut(key: 'a').macVirtualKey, -1);
    });

    test('formats Meta as ⌘ on macOS', () {
      const shortcut = BossKeyShortcut(meta: true, shift: true, key: 'H');
      expect(
        shortcut.formatLabel(platform: TargetPlatform.macOS),
        'Shift + ⌘ + H',
      );
    });

    test('sends the macOS key code in the platform args', () {
      const shortcut = BossKeyShortcut(alt: true, key: 'Q');
      expect(shortcut.toPlatformArgs()['macVk'], 0x0C);
      expect(shortcut.toPlatformArgs()['winVk'], 0x51);
    });

    test('validates modifiers, function keys, and reserved shortcuts', () {
      expect(const BossKeyShortcut(key: 'Q').isValid, isFalse);
      expect(const BossKeyShortcut(shift: true, key: 'Q').isValid, isFalse);
      expect(const BossKeyShortcut(key: 'F9').isValid, isTrue);
      expect(
        const BossKeyShortcut(ctrl: true, shift: true, key: 'H').isValid,
        isTrue,
      );
      expect(const BossKeyShortcut(alt: true, key: 'F4').isValid, isFalse);
      expect(const BossKeyShortcut(alt: true, key: 'Tab').isValid, isFalse);
      expect(
        const BossKeyShortcut(ctrl: true, alt: true, key: 'Delete').isValid,
        isFalse,
      );
      expect(const BossKeyShortcut(meta: true, key: 'L').isValid, isFalse);
      expect(BossKeyShortcut.tryDecode('invalid++key'), isNull);
      expect(BossKeyShortcut.tryDecode('Q'), isNull);
    });
  });

  group('BossKeyPreferences', () {
    test('loads persisted values and falls back on corrupt shortcut', () async {
      SharedPreferences.setMockInitialValues({
        BossKeyPreferences.enabledKey: true,
        BossKeyPreferences.shortcutKey: 'ctrl+shift+H',
      });
      await BossKeyPreferences.instance.load();
      expect(BossKeyPreferences.instance.enabled.value, isTrue);
      expect(
        BossKeyPreferences.instance.shortcut.value,
        const BossKeyShortcut(ctrl: true, shift: true, key: 'H'),
      );

      BossKeyPreferences.instance.resetForTest();
      SharedPreferences.setMockInitialValues({
        BossKeyPreferences.enabledKey: false,
        BossKeyPreferences.shortcutKey: 'corrupted-value',
      });
      await BossKeyPreferences.instance.load();
      expect(
        BossKeyPreferences.instance.shortcut.value,
        BossKeyShortcut.defaultShortcut,
      );
    });
  });

  group('BossKeyService', () {
    test('enabling registers hotkey and persists preference', () async {
      await BossKeyService.instance.initialize();
      final result = await BossKeyService.instance.setEnabled(true);
      expect(result.ok, isTrue);
      expect(BossKeyPreferences.instance.enabled.value, isTrue);
      expect(bridge.active, BossKeyShortcut.defaultShortcut);
      expect(BossKeyService.instance.status.value.registered, isTrue);

      final sp = await SharedPreferences.getInstance();
      expect(sp.getBool(BossKeyPreferences.enabledKey), isTrue);
    });

    test('conflict during enable keeps toggle off and reports error', () async {
      await BossKeyService.instance.initialize();
      bridge.nextRegisterError = PlatformException(
        code: 'HOTKEY_CONFLICT',
        message: 'occupied',
      );
      final result = await BossKeyService.instance.setEnabled(true);
      expect(result.ok, isFalse);
      expect(result.errorMessage, contains('已被其他应用占用'));
      expect(BossKeyPreferences.instance.enabled.value, isFalse);
      expect(BossKeyService.instance.status.value.registered, isFalse);
    });

    test(
      'conflict during shortcut update preserves previous shortcut',
      () async {
        await BossKeyService.instance.initialize();
        expect((await BossKeyService.instance.setEnabled(true)).ok, isTrue);

        const candidate = BossKeyShortcut(ctrl: true, alt: true, key: 'B');
        bridge.nextRegisterError = PlatformException(code: 'HOTKEY_CONFLICT');
        final result = await BossKeyService.instance.updateShortcut(candidate);
        expect(result.ok, isFalse);
        expect(
          BossKeyPreferences.instance.shortcut.value,
          BossKeyShortcut.defaultShortcut,
        );
        expect(bridge.active, BossKeyShortcut.defaultShortcut);
      },
    );

    test('recording suspends hotkey and restores on cancel', () async {
      await BossKeyService.instance.initialize();
      await BossKeyService.instance.setEnabled(true);
      expect(bridge.active, BossKeyShortcut.defaultShortcut);

      await BossKeyService.instance.beginRecording();
      expect(bridge.active, isNull);
      expect(BossKeyService.instance.status.value.registered, isFalse);

      // Triggers while recording are ignored.
      await bridge.trigger();
      expect(windowControl.hideCalls, 0);

      final resumed = await BossKeyService.instance.endRecording();
      expect(resumed.ok, isTrue);
      expect(bridge.active, BossKeyShortcut.defaultShortcut);
      expect(BossKeyService.instance.status.value.registered, isTrue);
    });

    test(
      'trigger hides window, pauses playback, debounces, then restores',
      () async {
        await BossKeyService.instance.initialize();
        await BossKeyService.instance.setEnabled(true);

        await bridge.trigger();
        expect(pauseCalls, 1);
        expect(windowControl.hideCalls, 1);
        expect(windowControl.visible, isFalse);
        expect(BossKeyService.instance.status.value.hidden, isTrue);

        // Debounced within 300ms.
        now = now.add(const Duration(milliseconds: 150));
        await bridge.trigger();
        expect(windowControl.restoreCalls, 0);
        expect(windowControl.visible, isFalse);

        // After 300ms, restores window without calling pause again.
        now = now.add(const Duration(milliseconds: 300));
        await bridge.trigger();
        expect(pauseCalls, 1);
        expect(windowControl.restoreCalls, 1);
        expect(windowControl.visible, isTrue);
        expect(BossKeyService.instance.status.value.hidden, isFalse);
      },
    );

    test('playback pause failure still hides window', () async {
      await BossKeyService.instance.initialize();
      await BossKeyService.instance.setEnabled(true);
      throwOnPause = true;

      await bridge.trigger();
      expect(pauseCalls, 1);
      expect(windowControl.hideCalls, 1);
      expect(windowControl.visible, isFalse);
    });

    test('Wayland session blocks enabling and surfaces warning', () async {
      bridge
        ..globalHotkey = false
        ..backend = 'wayland';
      await BossKeyService.instance.initialize();

      expect(
        BossKeyService.instance.status.value.globalHotkeySupported,
        isFalse,
      );
      final result = await BossKeyService.instance.setEnabled(true);
      expect(result.ok, isFalse);
      expect(result.errorMessage, contains('Wayland'));
      expect(BossKeyPreferences.instance.enabled.value, isFalse);
    });

    test('shutdown unregisters active hotkey', () async {
      await BossKeyService.instance.initialize();
      await BossKeyService.instance.setEnabled(true);
      await BossKeyService.instance.shutdown();
      expect(bridge.active, isNull);
      expect(BossKeyService.instance.status.value.registered, isFalse);
    });
  });

  group('BossKeySettingsPage & SettingsPage integration', () {
    Widget wrapApp(Widget home, {AppThemeStyle style = AppThemeStyle.archive}) {
      final store = AppThemeStyleStore()..value = style;
      addTearDown(store.dispose);
      return AppUiScope(
        store: store,
        child: MaterialApp(
          theme: AppTheme.createTheme(Brightness.light, style: style),
          home: home,
        ),
      );
    }

    testWidgets('hides boss key entry on Android settings page', (
      tester,
    ) async {
      debugDefaultTargetPlatformOverride = TargetPlatform.android;
      try {
        await tester.pumpWidget(wrapApp(const SettingsPage()));
        await tester.pumpAndSettle();
        expect(find.text('老板键'), findsNothing);
      } finally {
        debugDefaultTargetPlatformOverride = null;
      }
    });

    testWidgets(
      'shows boss key entry on Windows settings page in two-pane mode',
      (tester) async {
        debugDefaultTargetPlatformOverride = TargetPlatform.windows;
        try {
          tester.view.physicalSize = const Size(1280, 800);
          tester.view.devicePixelRatio = 1;
          addTearDown(tester.view.reset);

          await BossKeyService.instance.initialize();
          await tester.pumpWidget(wrapApp(const SettingsPage()));
          await tester.pumpAndSettle();

          final entry = find.widgetWithText(SettingsRow, '老板键');
          expect(entry, findsOneWidget);
          await tester.tap(entry);
          await tester.pumpAndSettle();

          expect(find.byType(BossKeySettingsPage), findsOneWidget);
          expect(find.text('启用老板键'), findsOneWidget);
          expect(find.text('Alt + Q'), findsOneWidget);
        } finally {
          debugDefaultTargetPlatformOverride = null;
        }
      },
    );

    testWidgets('shows boss key entry on macOS settings page', (tester) async {
      // 69b6f52a 的决定：老板键覆盖 macOS，三个桌面端全开。上游只做了
      // Windows/Linux，平台门是 isMediaDesktop（不含 macOS），换基底时这行
      // 被覆盖回来过一次 —— 服务层认 macOS 会注册热键、设置页却不给入口，
      // 用户有热键却看不到也改不了。这条守着那个门。
      debugDefaultTargetPlatformOverride = TargetPlatform.macOS;
      try {
        tester.view.physicalSize = const Size(1280, 800);
        tester.view.devicePixelRatio = 1;
        addTearDown(tester.view.reset);

        await BossKeyService.instance.initialize();
        await tester.pumpWidget(wrapApp(const SettingsPage()));
        await tester.pumpAndSettle();

        // macOS 和 Windows 一样走两栏 DesktopSettingsBody（Linux 走经典单列）。
        expect(find.byType(DesktopSettingsBody), findsOneWidget);
        final entry = find.widgetWithText(SettingsRow, '老板键');
        expect(entry, findsOneWidget);
        await tester.tap(entry);
        await tester.pumpAndSettle();

        expect(find.byType(BossKeySettingsPage), findsOneWidget);
        expect(find.text('启用老板键'), findsOneWidget);
      } finally {
        debugDefaultTargetPlatformOverride = null;
      }
    });

    testWidgets('shows boss key entry on Linux classic settings page', (
      tester,
    ) async {
      debugDefaultTargetPlatformOverride = TargetPlatform.linux;
      try {
        await tester.binding.setSurfaceSize(const Size(600, 900));
        addTearDown(() => tester.binding.setSurfaceSize(null));

        await BossKeyService.instance.initialize();
        await tester.pumpWidget(
          wrapApp(const SettingsPage(), style: AppThemeStyle.classic),
        );
        await tester.pumpAndSettle();

        final entry = find.byKey(const ValueKey('settings-entry-老板键'));
        expect(entry, findsOneWidget);
        await tester.tap(entry);
        await tester.pumpAndSettle();

        expect(find.byType(BossKeySettingsPage), findsOneWidget);
        expect(find.text('启用老板键'), findsOneWidget);
      } finally {
        debugDefaultTargetPlatformOverride = null;
      }
    });

    testWidgets(
      'enables boss key, records custom shortcut, and resets to default',
      (tester) async {
        debugDefaultTargetPlatformOverride = TargetPlatform.windows;
        try {
          await BossKeyService.instance.initialize();
          await tester.pumpWidget(wrapApp(const BossKeySettingsPage()));
          await tester.pumpAndSettle();

          // Enable boss key.
          await tester.tap(
            find.byKey(const ValueKey('settings-boss-key-toggle')),
          );
          await tester.pumpAndSettle();
          expect(BossKeyPreferences.instance.enabled.value, isTrue);
          expect(bridge.active, BossKeyShortcut.defaultShortcut);

          // Open recorder dialog and record Ctrl + Shift + H.
          await tester.tap(
            find.byKey(const ValueKey('settings-boss-key-shortcut')),
          );
          await tester.pumpAndSettle();
          expect(find.text('设置老板键'), findsOneWidget);
          expect(bridge.active, isNull); // Suspended while recording.

          await tester.sendKeyDownEvent(LogicalKeyboardKey.controlLeft);
          await tester.sendKeyDownEvent(LogicalKeyboardKey.shiftLeft);
          await tester.sendKeyDownEvent(LogicalKeyboardKey.keyH);
          await tester.sendKeyUpEvent(LogicalKeyboardKey.keyH);
          await tester.sendKeyUpEvent(LogicalKeyboardKey.shiftLeft);
          await tester.sendKeyUpEvent(LogicalKeyboardKey.controlLeft);
          await tester.pumpAndSettle();

          expect(
            find.descendant(
              of: find.byKey(const ValueKey('boss-key-recorder-display')),
              matching: find.text('Ctrl + Shift + H'),
            ),
            findsOneWidget,
          );

          await tester.tap(
            find.byKey(const ValueKey('boss-key-recorder-save')),
          );
          await tester.pumpAndSettle();

          const expected = BossKeyShortcut(ctrl: true, shift: true, key: 'H');
          expect(BossKeyPreferences.instance.shortcut.value, expected);
          expect(bridge.active, expected);
          expect(find.text('Ctrl + Shift + H'), findsOneWidget);

          // Reset to default.
          final resetRow = find.byKey(
            const ValueKey('settings-boss-key-reset'),
          );
          expect(resetRow, findsOneWidget);
          await tester.tap(resetRow);
          await tester.pumpAndSettle();

          expect(
            BossKeyPreferences.instance.shortcut.value,
            BossKeyShortcut.defaultShortcut,
          );
          expect(bridge.active, BossKeyShortcut.defaultShortcut);
          expect(find.text('Alt + Q'), findsOneWidget);
        } finally {
          debugDefaultTargetPlatformOverride = null;
        }
      },
    );
  });
}
