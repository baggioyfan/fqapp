import 'package:flutter_test/flutter_test.dart';

import 'package:fqapp/models/library_backup.dart';

/// 契约守卫：**整包必须打得出来**。
///
/// 本机可能同时存着同一本书的两种键（`123` 与 `audio:123`：看书、听书记的是
/// 同一个作品），也可能存着同一天的两处写法（`2026-10-7` 与 `2026-10-07`）。
/// `capture` 把它们归一化之后会撞成同一条，而它自己的 `_fromJson` 自校验会把
/// 重复的 books 判成「重复的阅读时长」抛异常 —— 从那一刻起整包再也写不出去，
/// 同步和「用本机覆盖云端」全部作废，界面上只表现为「点了没反应」。
void main() {
  LibraryBackup capture({
    Map<String, Map<String, double>> daily = const {},
    List<({String id, String kind, Map<String, double> devices})> books =
        const [],
  }) => LibraryBackup.capture(
    shelf: const [],
    shelfRemoved: const {},
    history: const [],
    watched: const <String, Map<String, int>>{},
    daily: daily,
    books: books,
    searchHistory: const <String>[],
  );

  test('同一作品两种键：不抛异常，合并成一条并取较大的时长', () {
    final backup = capture(
      books: [
        // 看书记的裸键，听书记的作用域键——同一个作品。
        (id: '7673107019712187454', kind: 'book', devices: {'mac': 120.0}),
        (id: 'audio:7673107019712187454', kind: 'book', devices: {'mac': 90.0}),
      ],
    );

    expect(backup.books.length, 1);
    expect(backup.books.single.id, '7673107019712187454');
    // 同一天的两次快照取较大值，相加会把时长翻倍。
    expect(backup.books.single.devices['mac'], 120.0);
  });

  test('同一天两种写法：合并成一个不零填充的键', () {
    final backup = capture(
      daily: {
        '2026-10-7': {'mac': 600.0},
        '2026-10-07': {'mac': 300.0, 'phone': 200.0},
      },
    );

    expect(backup.daily.keys, ['2026-10-7']);
    expect(backup.daily['2026-10-7'], {'mac': 600.0, 'phone': 200.0});
  });

  test('撞车之后仍然是一份能被自己读回来的备份', () {
    final encoded = capture(
      daily: {
        '2026-10-7': {'mac': 60.0},
        '2026-10-07': {'mac': 30.0},
      },
      books: [
        (id: 'shared', kind: 'audio', devices: {'mac': 100.0}),
        (id: 'audio:shared', kind: 'audio', devices: {'mac': 50.0}),
      ],
    ).encode();

    // 以前这一句之前就抛了：整包打不出来。
    final decoded = LibraryBackup.decode(encoded);
    expect(decoded.books.single.id, 'shared');
    expect(decoded.books.single.devices['mac'], 100.0);
    expect(decoded.daily['2026-10-7'], {'mac': 60.0});
  });

  test('不相干的键各记各的，不因为归一化被并掉', () {
    final backup = capture(
      daily: {
        '2026-10-7': {'mac': 60.0},
        '2026-10-8': {'mac': 30.0},
      },
      books: [
        (id: 'one', kind: 'book', devices: {'mac': 100.0}),
        (id: 'audio:two', kind: 'audio', devices: {'mac': 50.0}),
      ],
    );

    expect(backup.daily.keys.toSet(), {'2026-10-7', '2026-10-8'});
    expect(backup.books.map((e) => e.id).toSet(), {'one', 'two'});
  });
}
