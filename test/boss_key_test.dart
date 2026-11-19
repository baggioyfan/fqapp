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
