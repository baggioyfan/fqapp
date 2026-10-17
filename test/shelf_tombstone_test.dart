import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:hive_ce/hive.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:fqapp/models/library_backup.dart';
import 'package:fqapp/models/media_item.dart';
import 'package:fqapp/services/shelf_store.dart';

/// 书架删除的语义：删掉的条目必须能传播出去，而且不能被自己那次同步复活。
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  late Directory directory;
  final shelf = ShelfStore.instance;

  setUp(() async {
    SharedPreferences.setMockInitialValues({});
    directory = await Directory.systemTemp.createTemp('fqapp-shelf-removed-');
    Hive.init(directory.path);
    await shelf.init();
  });

  tearDown(() async {
    await Hive.close();
    await directory.delete(recursive: true);
  });

  test('a merged backup cannot bring a removed entry back', () async {
    // 这就是用户遇到的场景：移出之后点同步，云端那份又被合并回本机。
    await shelf.add(_item('gone'));
    await shelf.add(_item('keep'));
    await shelf.removeKeys([ShelfStore.keyOf(_item('gone'))]);

    final tombstone = shelf.tombstones();
    expect(tombstone.keys, [ShelfStore.keyOf(_item('gone'))]);

    await shelf.mergeBackup(
      [
        ShelfRecord(
          item: _item('gone'),
          addedAt: DateTime.fromMillisecondsSinceEpoch(1000),
        ),
        ShelfRecord(
          item: _item('keep'),
          addedAt: DateTime.fromMillisecondsSinceEpoch(1000),
        ),
      ],
      removed: tombstone,
    );

    expect(
      shelf.records().map((record) => record.item.id),
      ['keep'],
      reason: '删除比云端那条收藏更晚，并集不该把它搬回来',
    );
  });

  test('an entry added again after the removal is kept', () async {
    await shelf.add(_item('again'));
    await shelf.mergeBackup(
      const [],
      removed: {
        ShelfStore.keyOf(_item('again')): DateTime.now().subtract(
          const Duration(days: 2),
        ),
      },
    );

    expect(
      shelf.records().map((record) => record.item.id),
      ['again'],
      reason: '删掉之后又加回来，收藏时间更新，应当保留',
    );
    expect(
      shelf.tombstones(),
      isEmpty,
      reason: '已经不成立的墓碑不该继续上传，否则对方的记录会被误删',
    );
  });

  test('a remote tombstone removes the local entry', () async {
    await shelf.add(_item('theirs'));
    await shelf.mergeBackup(
      const [],
      removed: {
        ShelfStore.keyOf(_item('theirs')): DateTime.now().add(
          const Duration(minutes: 1),
        ),
      },
    );

    expect(shelf.records(), isEmpty);
    expect(shelf.tombstones().keys, [ShelfStore.keyOf(_item('theirs'))]);
  });

  test('undoing a removal also drops the tombstone', () async {
    await shelf.add(_item('edited'));
    final record = shelf.records().single;
    await shelf.removeKeys([ShelfStore.keyOf(_item('edited'))]);

    await shelf.restoreAll([record]);

    expect(shelf.records().map((entry) => entry.item.id), ['edited']);
    expect(shelf.tombstones(), isEmpty, reason: '撤销之后再同步不该又被删一遍');
  });

  test('clearing the shelf leaves a tombstone for every entry', () async {
    await shelf.add(_item('one'));
    await shelf.add(_item('two'));

    await shelf.clear();

    expect(shelf.records(), isEmpty);
    expect(shelf.tombstones().length, 2);
  });

  test('a v3 snapshot carries the removals and reads back', () {
    final backup = LibraryBackup.capture(
      shelf: const [],
      shelfRemoved: {
        ShelfStore.keyOf(_item('gone')): DateTime.fromMillisecondsSinceEpoch(
          1700000000000,
        ),
      },
      history: const [],
      watched: const {},
      daily: const {},
      books: const [],
      searchHistory: const [],
    );

    final decoded = LibraryBackup.decode(backup.encode());

    expect(
      decoded.shelfRemoved,
      {'book:gone': DateTime.fromMillisecondsSinceEpoch(1700000000000)},
    );
    expect(
      decoded.shelfTombstones.keys,
      [ShelfStore.keyOf(_item('gone'))],
    );
  });

  test('a v2 snapshot without removals still reads', () {
    // 旧版本导出的文件不能因为缺字段就变成「无法识别」。
    final backup = LibraryBackup.capture(
      shelf: [ShelfRecord(item: _item('old'), addedAt: DateTime(2020))],
      shelfRemoved: {
        ShelfStore.keyOf(_item('other')): DateTime(2020),
      },
      history: const [],
      watched: const {},
      daily: const {},
      books: const [],
      searchHistory: const [],
    );
    final map = jsonDecode(utf8.decode(backup.encode())) as Map<String, dynamic>
      ..remove('shelfRemoved')
      ..['version'] = 2;

    final decoded = LibraryBackup.decode(
      Uint8List.fromList(utf8.encode(jsonEncode(map))),
    );

    expect(decoded.shelf.map((record) => record.item.id), ['old']);
    expect(decoded.shelfRemoved, isEmpty);
  });
}

MediaItem _item(String id) => MediaItem(
  id: id,
  title: id,
  cover: '',
  author: '测试作者',
  badge: '',
  ep: '120',
  kind: 'book',
);
