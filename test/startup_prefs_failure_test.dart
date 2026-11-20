// #421: SharedPreferences is a required item on the local-data startup gate.
// A failed read must reach the retryable failure page instead of silently
// degrading like the optional preferences do.

import 'dart:io';

import 'package:material_ui/material_ui.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:fqapp/main.dart' as app;
import 'package:fqapp/services/digg_store.dart';
import 'package:fqapp/services/drama_download_store.dart';
import 'package:fqapp/services/player_style_config.dart';
import 'package:fqapp/services/shelf_group_store.dart';
import 'package:fqapp/services/shelf_store.dart';
import 'package:fqapp/services/swipe_guide_store.dart';
import 'package:hive_ce/hive.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:shared_preferences_platform_interface/shared_preferences_platform_interface.dart';

void main() {
  testWidgets(
    'a prefs read failure reaches the retryable gate and the retry reopens '
    'local data',
    (tester) async {
      final tempRoot = Directory.systemTemp.absolute;
      late Directory directory;
      await tester.runAsync(() async {
        directory = await tempRoot.createTemp('fqapp-prefs-failure-');
        Hive.init(directory.path);
        // Pre-open every box the real bootstrap opens. On the widget test's
        // fake-async path an unopened openBox never completes, which would hang
        // the gate instead of failing it.
        await Hive.openBox<dynamic>('history');
        await Hive.openBox<dynamic>('read_time');
        await ShelfStore.instance.init();
        await ShelfGroupStore.instance.init();
        await DiggStore.instance.init();
        await SwipeGuideStore.instance.init();
        await SwipeGuideStore.instance.markShown();
        await Hive.openBox<dynamic>('home_feed_cache_v1');
        await Hive.openBox<dynamic>('rank_cache_v1');
        await Hive.openBox<dynamic>('watched_episodes');
        await Hive.openBox<dynamic>('drama_download_v1');
        await HiveDramaDownloadStore.instance.warmUp();
        // Read the bundled player config up front so the asset load never lands
        // on the fake-async path either.
        await PlayerStyleConfig.load();
      });
      const channel = MethodChannel('plugins.flutter.io/path_provider');
      final messenger =
          TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
      messenger.setMockMethodCallHandler(channel, (_) async => directory.path);

      final original = SharedPreferencesStorePlatform.instance;
      final platform = _FailingReads();
      SharedPreferencesStorePlatform.instance = platform;
      SharedPreferences.resetStatic();
      addTearDown(() async {
        await tester.pumpWidget(const SizedBox.shrink());
        messenger.setMockMethodCallHandler(channel, null);
        SharedPreferences.resetStatic();
        SharedPreferencesStorePlatform.instance = original;
        await tester.runAsync(() async {
          await Hive.close();
          if (directory.absolute.parent.path != tempRoot.path) {
            throw StateError('Temporary directory escaped its parent');
          }
          await directory.delete(recursive: true);
        });
      });

      await tester.pumpWidget(
        const MaterialApp(
          home: app.AppBootstrap(child: Text('local data ready')),
        ),
      );
      await tester.pumpAndSettle();

      // Prefs reads failed, and prefs is not optional: the gate stops on the
      // failure page instead of continuing with defaults.
      expect(platform.reads, greaterThan(0));
      expect(find.text('无法读取本地数据'), findsOneWidget);
      expect(find.text('local data ready'), findsNothing);

      // Recover the store, then prove the retry entry re-runs the whole chain.
      platform.fail = false;
      await tester.tap(find.text('重试'));
      await tester.pumpAndSettle();

      expect(platform.reads, greaterThan(1));
      expect(find.text('local data ready'), findsOneWidget);
      expect(find.text('无法读取本地数据'), findsNothing);
      expect(tester.takeException(), isNull);
    },
  );
}

/// Fails every `getAll()` until [fail] is cleared, so the failing phase is
/// independent of how many consumers re-request SharedPreferences.
class _FailingReads extends InMemorySharedPreferencesStore {
  _FailingReads() : super.withData(const <String, Object>{});

  bool fail = true;
  int reads = 0;

  @override
  Future<Map<String, Object>> getAll() async {
    reads++;
    if (fail) {
      throw PlatformException(code: 'read-failed', message: 'cannot read');
    }
    return super.getAll();
  }
}
