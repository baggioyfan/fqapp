import 'dart:async';

import 'package:flutter_test/flutter_test.dart';
import 'package:fqapp/services/app_log.dart';
import 'package:fqapp/services/logging/log_viewer_controller.dart';

void main() {
  setUp(() => AppLog.instance.resetForTest());
  tearDown(() => AppLog.instance.resetForTest());

  test(
    'frozen snapshots count new entries at capacity and clear explicitly',
    () {
      for (var i = 0; i < AppLog.defaultCapacity; i++) {
        AppLog.i('api', 'entry-$i');
      }
      final logs = LogViewerController();
      addTearDown(logs.dispose);
      logs.pauseFollowing();
      final frozen = logs.displayEntries;
      AppLog.i('api', 'new-entry');
      expect(logs.entries.length, AppLog.defaultCapacity);
      expect(identical(logs.displayEntries, frozen), isTrue);
      expect(logs.pendingCount, 1);
      logs.clearAppView();
      expect(logs.entries, isEmpty);
      expect(logs.displayEntries, isEmpty);
      expect(logs.pendingCount, 0);
      expect(logs.following, isFalse);
    },
  );

  test('query and diagnostics filter by tag without changing source data', () {
    AppLog.i('network', 'mentions player-load');
    AppLog.w('player-load', 'Timeout');
    final logs = LogViewerController();
    addTearDown(logs.dispose);
    logs.setQuery('  TIMEOUT  ');
    expect(logs.displayEntries.single.message, 'Timeout');
    expect(logs.entries, hasLength(2));
    logs.setQuery('');
    logs.setPlayerOnly(true);
    expect(logs.displayEntries.single.tag, 'player-load');
    logs.setFilters(const LogFilterSelection(level: LogLevel.info));
    expect(logs.displayEntries, isEmpty);
  });

  test('stale Rust completion cannot overwrite application source', () async {
    final pending = Completer<String?>();
    final logs = LogViewerController(rustReader: () => pending.future);
    addTearDown(logs.dispose);
    AppLog.i('app', 'application');
    logs.selectSource(LogSource.rust);
    final loading = logs.refreshRust();
    logs.selectSource(LogSource.app);
    pending.complete('[I] 2026-01-01T00:00:00Z core: stale\n');
    await loading;
    expect(logs.source, LogSource.app);
    expect(logs.displayEntries.single.message, 'application');
  });

  test(
    'returning to Rust during a pending read refreshes the current generation',
    () async {
      final pending = Completer<String?>();
      var reads = 0;
      final logs = LogViewerController(
        rustReader: () async {
          if (++reads == 1) return pending.future;
          return '[I] 2026-01-01T00:00:01Z core: current\n';
        },
      );
      addTearDown(logs.dispose);
      logs.selectSource(LogSource.rust);
      final first = logs.refreshRust();
      logs.selectSource(LogSource.app);
      logs.selectSource(LogSource.rust);
      pending.complete('[I] 2026-01-01T00:00:00Z core: stale\n');
      await first;
      await logs.refreshRust();
      expect(reads, 2);
      expect(logs.displayEntries.single.message, 'current');
    },
  );

  test(
    'background completion is fenced and resumed Rust refreshes immediately',
    () async {
      final pending = Completer<String?>();
      var reads = 0;
      final logs = LogViewerController(
        rustReader: () async {
          if (++reads == 1) return pending.future;
          return '[I] 2026-01-01T00:00:01Z core: resumed\n';
        },
      );
      addTearDown(logs.dispose);
      logs.selectSource(LogSource.rust);
      final first = logs.refreshRust();
      logs.setActive(false);
      pending.complete('[I] 2026-01-01T00:00:00Z core: background\n');
      await first;
      expect(logs.displayEntries, isEmpty);
      expect(reads, 1);
      logs.setActive(true);
      await logs.refreshRust();
      expect(reads, 2);
      expect(logs.displayEntries.single.message, 'resumed');
    },
  );

  test('Rust polling preserves identities of duplicate entries', () async {
    const line = '[I] 2026-01-01T00:00:00Z core: repeated\n';
    var text = '$line$line';
    final logs = LogViewerController(rustReader: () async => text);
    addTearDown(logs.dispose);
    logs.selectSource(LogSource.rust);
    await logs.refreshRust();
    final first = logs.entries;
    expect(first, hasLength(2));
    expect(identical(first[0], first[1]), isFalse);
    logs.pauseFollowing();
    text += line;
    await logs.refreshRust();
    expect(identical(logs.entries[0], first[0]), isTrue);
    expect(identical(logs.entries[1], first[1]), isTrue);
    expect(logs.pendingCount, 1);
    logs.followLatest();
    expect(logs.displayEntries, hasLength(3));
    expect(logs.pendingCount, 0);
  });

  test(
    'recent core filter accepts legacy UTC timestamps without a suffix',
    () async {
      final now = DateTime.utc(2026, 11, 18, 19, 28);
      final logs = LogViewerController(
        clock: () => now,
        rustReader: () async =>
            '[W] 2026-11-18T19:27:26 core: recent\n'
            '[I] 2026-11-18T18:00:00 core: old\n',
      );
      addTearDown(logs.dispose);
      logs.selectSource(LogSource.rust);
      await logs.refreshRust();
      logs.setFilters(
        const LogFilterSelection(timeWindow: Duration(minutes: 5)),
      );
      expect(logs.displayEntries.single.message, 'recent');
      expect(logs.displayEntries.single.time.isUtc, isTrue);
    },
  );

  testWidgets('time-filter entries expire without another log arriving', (
    tester,
  ) async {
    var now = DateTime.utc(2026);
    final logs = LogViewerController(
      clock: () => now,
      rustRefresh: const Duration(hours: 1),
      rustReader: () async => '[I] 2026-01-01T00:00:00Z core: recent\n',
    );
    addTearDown(logs.dispose);
    logs.selectSource(LogSource.rust);
    await tester.pump();
    logs.setFilters(const LogFilterSelection(timeWindow: Duration(seconds: 1)));
    expect(logs.displayEntries, hasLength(1));
    now = now.add(const Duration(seconds: 2));
    await tester.pump(const Duration(seconds: 2));
    expect(logs.displayEntries, isEmpty);
  });

  test(
    'disposing during a read never publishes or schedules more work',
    () async {
      final pending = Completer<String?>();
      var notifications = 0;
      final logs = LogViewerController(rustReader: () => pending.future);
      logs.addListener(() => notifications++);
      logs.selectSource(LogSource.rust);
      final loading = logs.refreshRust();
      final before = notifications;
      logs.dispose();
      pending.complete('[I] 2026-01-01T00:00:00Z core: late\n');
      await loading;
      expect(notifications, before);
    },
  );
}
