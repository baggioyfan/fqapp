import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:hive_ce/hive.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:fqapp/models/library_backup.dart';
import 'package:fqapp/models/media_item.dart';
import 'package:fqapp/services/library_backup_service.dart';
import 'package:fqapp/services/library_store.dart';
import 'package:fqapp/services/media_history_store.dart';
import 'package:fqapp/services/shelf_store.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  late Directory directory;
  final library = LibraryStore.instance;
  final shelf = ShelfStore.instance;

  setUp(() async {
    SharedPreferences.setMockInitialValues({});
    directory = await Directory.systemTemp.createTemp('fqapp-backup-test-');
    Hive.init(directory.path);
    await library.init();
    await shelf.init();
  });

  tearDown(() async {
    await Hive.close();
    await directory.delete(recursive: true);
  });

  test(
    'portable backup retains progress units and excludes local data',
    () async {
      await library.addHistory({
        'id': '123',
        'kind': 'book',
        'chapterId': 'chapter-1',
        'positionVersion': 2,
        'textOffset': 431,
        'position': 120.0,
        'cover': '/private/cover.jpg',
        'unexpectedSecret': 'never-export',
      });
      await scopedHistoryStore(library, 'audio').addHistory({
        'id': '123',
        'chapterId': 'audio-1',
        'position': 38.5,
        'toneId': 'voice-1',
        'rate': 1.5,
      });
      await scopedHistoryStore(library, 'manga').addHistory({
        'id': '123',
        'chapterId': 'comic-1',
        'position': 4.25,
        'positionUnit': 'comic-page',
      });
      await library.addHistory({'id': 'local_100_abcd', 'kind': 'book'});
      await shelf.add(_item('local_100_abcd'));
      final service = LibraryBackupService();
      final bytes = (await service.capture()).encode();
      final restored = LibraryBackup.decode(bytes);
      expect(restored.excludedLocalRecords, 2);
      expect(restored.shelf, isEmpty);
      expect(restored.history, hasLength(3));
      expect(utf8.decode(bytes), isNot(contains('never-export')));
      expect(utf8.decode(bytes), isNot(contains('/private/')));
      final novel = restored.history.singleWhere((e) => e['kind'] == 'book');
      expect(novel['textOffset'], 431);
      expect(novel['positionVersion'], 2);
      final manga = restored.history.singleWhere((e) => e['kind'] == 'manga');
      expect(manga['positionUnit'], 'comic-page');

      await library.clearHistory();
      await service.restore(restored);
      expect((await library.historyEntry('123'))?['textOffset'], 431);
      expect(
        (await scopedHistoryStore(
          library,
          'audio',
        ).historyEntry('123'))?['position'],
        38.5,
      );
      expect(
        (await scopedHistoryStore(
          library,
          'manga',
        ).historyEntry('123'))?['position'],
        4.25,
      );
    },
  );

  test(
    'the sync snapshot drops history, the manual export keeps it',
    () async {
      for (var i = 0; i < 20; i++) {
        await library.addHistory({
          'id': 'book-$i',
          'kind': 'book',
          'chapterId': 'chapter-$i',
          'position': 0.5,
          'time': 1000 + i,
        });
      }
      final snapshot = await LibraryBackupService().capture();
      final full = snapshot.encode();
      final lean = snapshot.encode(includeHistory: false);
      final fullJson = jsonDecode(utf8.decode(full)) as Map<String, dynamic>;
      final leanJson = jsonDecode(utf8.decode(lean)) as Map<String, dynamic>;

      expect(fullJson['version'], 5);
      expect(fullJson['history'], hasLength(20));
      // WebDAV 整包（includeHistory: false）不写这个键，云端因此不再把同一份
      // 进度存两遍；解出来是空表，合并空表不会动本机进度。
      expect(leanJson.containsKey('history'), isFalse);
      expect(lean.length, lessThan(full.length));
      expect(LibraryBackup.decode(lean).history, isEmpty);
      // 手动导出（默认参数）仍然自包含：换机时一个文件就够。
      expect(LibraryBackup.decode(full).history, hasLength(20));
    },
  );

  test(
    'merge keeps current records, unions legacy watched data, and can retry',
    () async {
      await library.addHistory({'id': 'same', 'kind': 'book', 'episode': 9});
      await shelf.add(_item('same', title: '本机标题'));
      final localAddedAt = shelf.records().single.addedAt;
      await Hive.box('watched_episodes').put('series-1', ['ep-1']);
      final backup = LibraryBackup.capture(
        shelf: [
          ShelfRecord(
            item: _item('same', title: '旧标题'),
            addedAt: DateTime(2020),
          ),
          ShelfRecord(item: _item('new'), addedAt: DateTime(2020)),
        ],
        shelfRemoved: const {},
        history: [
          {'id': 'same', 'kind': 'book', 'episode': 1},
          for (var i = 0; i < 110; i++) {'id': 'new-$i', 'kind': 'book'},
        ],
        watched: {
          'series-1': {'ep-1': 100, 'ep-2': 200},
        },
        daily: const {},
        books: const [],
        searchHistory: const [],
      );
      final service = LibraryBackupService();
      expect(await service.restore(backup), (
        shelf: 1,
        history: 110,
        episodes: 1,
        readTime: 0,
        searchHistory: 0,
      ));
      expect(library.historySnapshot(), hasLength(111));
      expect((await library.historyEntry('same'))?['episode'], 9);
      expect(await library.watchedEpisodeIds('series-1'), {'ep-1', 'ep-2'});
      final current = shelf.records().singleWhere((e) => e.item.id == 'same');
      expect(current.item.title, '本机标题');
      expect(current.addedAt, localAddedAt);
      expect(await service.restore(backup), (
        shelf: 0,
        history: 0,
        episodes: 0,
        readTime: 0,
        searchHistory: 0,
      ));
      expect(library.historySnapshot(), hasLength(111));
    },
  );

  test(
    'file validation rejects malformed final records before any writes',
    () async {
      final json =
          jsonDecode(
                LibraryBackup.capture(
                  shelf: [],
                  shelfRemoved: const {},
                  history: [
                    {'id': 'valid', 'kind': 'book'},
                  ],
                  watched: {},
                  daily: const {},
        books: const [],
                  searchHistory: const [],
                ).encodeAsText(),
              )
              as Map<String, dynamic>;
      (json['history'] as List).add({
        'id': 'bad',
        'kind': 'book',
        'position': -1,
      });
      expect(
        () => LibraryBackup.decode(
          Uint8List.fromList(utf8.encode(jsonEncode(json))),
        ),
        throwsFormatException,
      );
      expect(library.historySnapshot(), isEmpty);
      json['history'] = [
        {'id': 'local_100_abcd', 'kind': 'book'},
      ];
      expect(
        () => LibraryBackup.decode(
          Uint8List.fromList(utf8.encode(jsonEncode(json))),
        ),
        throwsFormatException,
      );
      json['version'] = 999;
      expect(
        () => LibraryBackup.decode(
          Uint8List.fromList(utf8.encode(jsonEncode(json))),
        ),
        throwsFormatException,
      );
    },
  );

  test('内容指纹只比内容：忽略 createdAt 与键序', () {
    // 同步要不要写回云端，靠这个指纹判断。每次 encode 都会写新的 createdAt，
    // 键序也会随「本机 capture」与「云端 decode」不同，两者都不该影响结论 ——
    // 否则每趟同步都判成「内容变了」，两边就会一直互相触发「云端有更新」。
    final base = LibraryBackup.capture(
      shelf: [
        ShelfRecord(item: _item('1'), addedAt: DateTime(2026, 10, 27)),
      ],
      shelfRemoved: const {},
      history: const [],
      watched: const {},
      daily: {
        '2026-10-27': const {'dev-a': 60.0},
      },
      books: const [],
      searchHistory: const [],
    );
    final decoded = jsonDecode(base.encodeAsText()) as Map<String, dynamic>;
    decoded['createdAt'] = 1;
    final reordered = Uint8List.fromList(
      utf8.encode(
        jsonEncode({
          for (final key in decoded.keys.toList().reversed) key: decoded[key],
        }),
      ),
    );

    final other = LibraryBackup.decode(reordered);
    // 字节确实不同（createdAt 改了、键序也换了），指纹却必须相同。
    expect(other.encode(), isNot(equals(base.encode())));
    expect(other.contentFingerprint(), base.contentFingerprint());

    final changed = LibraryBackup.capture(
      shelf: [
        ShelfRecord(item: _item('1'), addedAt: DateTime(2026, 10, 27)),
        ShelfRecord(item: _item('2'), addedAt: DateTime(2026, 10, 27)),
      ],
      shelfRemoved: const {},
      history: const [],
      watched: const {},
      daily: {
        '2026-10-27': const {'dev-a': 60.0},
      },
      books: const [],
      searchHistory: const [],
    );
    expect(changed.contentFingerprint(), isNot(base.contentFingerprint()));
  });
}

MediaItem _item(String id, {String title = '作品'}) => MediaItem(
  id: id,
  title: title,
  cover: '',
  author: '',
  badge: '',
  ep: '',
  kind: 'book',
);

extension on LibraryBackup {
  String encodeAsText() => utf8.decode(encode());
}
