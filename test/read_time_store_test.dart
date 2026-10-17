import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:hive_ce/hive.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:fqapp/services/library_store.dart';
import 'package:fqapp/services/read_time_store.dart';

/// 阅读时长现在的模型是两张表：
/// - `daily`:  `day -> {deviceId: seconds}`，按天封顶 [ReadTimeStore.retentionDays]
/// - `books`:  `identity -> {kind, touched, devs}`，按书封顶 [ReadTimeStore.maxBooks]
///
/// 两张表都按设备分桶，合并规则统一为「同设备取大」。这一组测试覆盖的正是
/// 旧模型做不到的三件事：跨设备求和、淘汰不影响累计、以及旧交叉表的一次性折叠。
void main() {
  late Directory directory;

  setUp(() async {
    SharedPreferences.setMockInitialValues({});
    directory = await Directory.systemTemp.createTemp('fqapp-read-time-');
    Hive.init(directory.path);
    await LibraryStore.instance.init();
  });

  tearDown(() async {
    ReadTimeStore.instance.retentionDays = 365;
    ReadTimeStore.instance.maxBooks = 5000;
    await Hive.close();
    await directory.delete(recursive: true);
  });

  test('accumulating seconds fills both tables', () async {
    final store = LibraryStore.instance;
    await store.accumulateReadTime(
      'book-a',
      'book',
      90,
      at: DateTime(2026, 1, 5),
    );
    await store.accumulateReadTime(
      'book-a',
      'book',
      30,
      at: DateTime(2026, 1, 6),
    );

    expect(store.readTimeBookTotals(), {'book-a': 120.0});
    expect(store.readTimeDailyTotals(), {'2026-1-5': 90.0, '2026-1-6': 30.0});
    expect(store.readTimeKindSnapshot(), {'book-a': 'book'});
  });

  test('the daily table keeps only the newest retention window', () async {
    final store = LibraryStore.instance;
    ReadTimeStore.instance.retentionDays = 30;
    for (var i = 0; i < 40; i++) {
      await store.accumulateReadTime(
        'book-a',
        'book',
        1,
        at: DateTime(2026, 1, 1).add(Duration(days: i)),
      );
    }

    final daily = store.readTimeDailyTotals();
    expect(daily, hasLength(30));
    expect(daily.containsKey('2026-1-1'), isFalse);
    expect(daily.containsKey('2026-1-11'), isTrue);
    expect(daily.containsKey('2026-2-9'), isTrue);
    // 被截断的是明细，按书总数不受影响 —— 旧模型里 evict 会让累计一起变小。
    expect(store.readTimeBookTotals()['book-a'], 40.0);
  });

  test('the book cap evicts the least recently touched row only', () async {
    final store = LibraryStore.instance;
    for (final entry in [
      ('oldest', DateTime(2026, 1, 1)),
      ('middle', DateTime(2026, 1, 2)),
      ('newest', DateTime(2026, 1, 3)),
    ]) {
      await store.accumulateReadTime(
        entry.$1,
        'book',
        60,
        at: entry.$2,
      );
    }

    ReadTimeStore.instance.maxBooks = 2;
    // 再写一次触发淘汰；新写入的 touched 最新，被淘汰的应该是最早那本。
    await store.accumulateReadTime(
      'newest',
      'book',
      1,
      at: DateTime(2026, 1, 4),
    );

    expect(store.readTimeBookTotals().keys.toSet(), {'middle', 'newest'});
    // 累计总时长仍然包含被淘汰那本的 60 秒：按天表是独立的一份。
    final total = store.readTimeDailyTotals().values.fold<double>(
      0,
      (a, b) => a + b,
    );
    expect(total, 181.0);
  });

  test('merge takes the per-device maximum, so a second device adds up', () async {
    final store = LibraryStore.instance;
    final device = ReadTimeStore.instance.deviceId;
    await store.accumulateReadTime(
      'book-a',
      'book',
      1800,
      at: DateTime(2026, 1, 5),
    );

    // 另一台设备同一天读了 1200 秒：取大会丢掉它，求和才是 3000。
    final merged = await ReadTimeStore.instance.merge(
      {
        '2026-1-5': {'other-device': 1200.0},
      },
      [
        (id: 'book-a', kind: 'book', devices: {'other-device': 1200.0}),
      ],
    );
    expect(merged, greaterThan(0));
    expect(store.readTimeDailyTotals()['2026-1-5'], 3000.0);
    expect(store.readTimeBookTotals()['book-a'], 3000.0);

    // 同一份快照再来一次：同设备取大，所以一分不多。
    expect(
      await ReadTimeStore.instance.merge(
        {
          '2026-1-5': {'other-device': 1200.0},
        },
        [
          (id: 'book-a', kind: 'book', devices: {'other-device': 1200.0}),
        ],
      ),
      0,
    );
    expect(store.readTimeBookTotals()['book-a'], 3000.0);

    // 本机这一行只会被更大的值覆盖。
    await ReadTimeStore.instance.merge(
      {
        '2026-1-5': {device: 600.0},
      },
      [
        (id: 'book-a', kind: 'book', devices: {device: 600.0}),
      ],
    );
    expect(store.readTimeDailyTotals()['2026-1-5'], 3000.0);
  });

  test('the legacy cross-tab is folded into both tables once', () async {
    // 先按老形态写进去，再走一次 init，让迁移把它折叠掉。
    // setUp 那次 init 已经置过迁移标记，这里要清掉才会重跑。
    SharedPreferences.setMockInitialValues({});
    await Hive.close();
    Hive.init(directory.path);
    final legacy = await Hive.openBox('read_time');
    await legacy.put('book-a', {'2026-1-5': 90.0, '2026-1-6': 30.0});
    await legacy.put('audio:book-b', {'2026-1-6': 45.0});

    await LibraryStore.instance.init();

    final store = LibraryStore.instance;
    expect(store.readTimeBookTotals(), {'book-a': 120.0, 'audio:book-b': 45.0});
    expect(store.readTimeDailyTotals(), {'2026-1-5': 90.0, '2026-1-6': 75.0});
    // 迁移完成后旧盒清空，重复 init 不会把秒数再折一遍。
    await LibraryStore.instance.init();
    expect(store.readTimeBookTotals(), {'book-a': 120.0, 'audio:book-b': 45.0});
  });

  test('clearing reading data empties both tables', () async {
    final store = LibraryStore.instance;
    await store.accumulateReadTime(
      'book-a',
      'book',
      60,
      at: DateTime(2026, 1, 5),
    );
    await store.clearReadingData();

    expect(store.readTimeBookTotals(), isEmpty);
    expect(store.readTimeDailyTotals(), isEmpty);
  });

  test('damaged values are ignored rather than stored', () async {
    final store = LibraryStore.instance;
    await store.accumulateReadTime('book-a', 'book', double.nan);
    await store.accumulateReadTime('book-a', 'book', -5);
    await store.accumulateReadTime('', 'book', 10);

    expect(store.readTimeBookTotals(), isEmpty);
    expect(store.readTimeDailyTotals(), isEmpty);
  });
}
