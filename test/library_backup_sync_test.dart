import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:hive/hive.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:fqapp/models/library_backup.dart';
import 'package:fqapp/services/library_backup_service.dart';
import 'package:fqapp/services/library_store.dart';
import 'package:fqapp/services/search_history_store.dart';
import 'package:fqapp/services/shelf_store.dart';

/// Covers the multi-device merge rules: the two sync gates on progress, the
/// per-day maximum on read time, and the union on search history.
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  late Directory directory;
  final library = LibraryStore.instance;
  final service = LibraryBackupService();

  setUp(() async {
    SharedPreferences.setMockInitialValues({});
    directory = await Directory.systemTemp.createTemp('fqapp-sync-test-');
    Hive.init(directory.path);
    await library.init();
    await ShelfStore.instance.init();
  });

  tearDown(() async {
    await Hive.close();
    await directory.delete(recursive: true);
  });

  LibraryBackup backupWith({
    List<Map<String, dynamic>> history = const [],
    Map<String, Map<String, int>> watched = const {},
    List<({String id, String kind, Map<String, double> days})> readTime =
        const [],
    List<String> searchHistory = const [],
  }) => LibraryBackup.capture(
    shelf: const [],
    shelfRemoved: const {},
    history: history,
    watched: watched,
    readTime: readTime,
    searchHistory: searchHistory,
  );

  group('progress gates', () {
    test('adopts an incoming record that is newer and further along', () async {
      await library.addHistory({
        'id': 'book-1',
        'kind': 'book',
        'episode': 50,
        'progress': 0.2,
        'time': 100,
      });
      final backup = backupWith(
        history: [
          {
            'id': 'book-1',
            'kind': 'book',
            'episode': 100,
            'progress': 0.1,
            'time': 200,
          },
        ],
      );
      expect((await service.restore(backup)).history, 1);
      expect((await library.historyEntry('book-1'))?['episode'], 100);
    });

    test('keeps the local record when the incoming one is older', () async {
      await library.addHistory({
        'id': 'book-1',
        'kind': 'book',
        'episode': 100,
        'time': 200,
      });
      final backup = backupWith(
        history: [
          {'id': 'book-1', 'kind': 'book', 'episode': 50, 'time': 100},
        ],
      );
      expect((await service.restore(backup)).history, 0);
      expect((await library.historyEntry('book-1'))?['episode'], 100);
    });

    test('never moves backwards even when the incoming record is newer', () async {
      await library.addHistory({
        'id': 'book-1',
        'kind': 'book',
        'episode': 100,
        'time': 200,
      });
      final backup = backupWith(
        history: [
          {'id': 'book-1', 'kind': 'book', 'episode': 50, 'time': 300},
        ],
      );
      expect((await service.restore(backup)).history, 0);
      expect((await library.historyEntry('book-1'))?['episode'], 100);
    });

    test('a same-instant record keeps the local copy', () async {
      await library.addHistory({
        'id': 'book-1',
        'kind': 'book',
        'episode': 100,
        'time': 200,
      });
      final backup = backupWith(
        history: [
          {'id': 'book-1', 'kind': 'book', 'episode': 101, 'time': 200},
        ],
      );
      expect((await service.restore(backup)).history, 0);
      expect((await library.historyEntry('book-1'))?['episode'], 100);
    });

    test('advances within the same chapter when progress grows', () async {
      await library.addHistory({
        'id': 'book-1',
        'kind': 'book',
        'episode': 7,
        'progress': 0.3,
        'time': 100,
      });
      final backup = backupWith(
        history: [
          {
            'id': 'book-1',
            'kind': 'book',
            'episode': 7,
            'progress': 0.6,
            'time': 200,
          },
        ],
      );
      expect((await service.restore(backup)).history, 1);
      expect((await library.historyEntry('book-1'))?['progress'], 0.6);
    });

    test('a record without an episode falls back to last-write-wins', () async {
      await library.addHistory({
        'id': 'book-1',
        'kind': 'book',
        'episode': 100,
        'time': 200,
      });
      final backup = backupWith(
        history: [
          {'id': 'book-1', 'kind': 'book', 'progress': 0.5, 'time': 300},
        ],
      );
      expect((await service.restore(backup)).history, 1);
      expect((await library.historyEntry('book-1'))?['progress'], 0.5);
    });

    test('a bare key owned by another kind is never overwritten', () async {
      await library.addHistory({
        'id': 'shared',
        'kind': 'book',
        'episode': 1,
        'time': 100,
      });
      final backup = backupWith(
        history: [
          {'id': 'shared', 'kind': 'video', 'episode': 9, 'time': 200},
        ],
      );
      expect((await service.restore(backup)).history, 0);
      expect((await library.historyEntry('shared'))?['kind'], 'book');
    });
  });

  group('read time merge', () {
    test('capture carries the user-visible totals out of the app store', () async {
      await Hive.box('read_time').put('book-1', {
        '2026-1-5': 1800.0,
        '_media_kind_v1': 'book',
      });
      await SearchHistoryStore.instance.add('本机词');
      final backup = await service.capture();
      expect(backup.readTime, hasLength(1));
      expect(backup.readTime.single['id'], 'book-1');
      expect(backup.readTime.single['kind'], 'book');
      expect(backup.readTime.single['days'], {'2026-1-5': 1800.0});
      expect(backup.searchHistory, ['本机词']);
    });

    test('takes the per-day maximum and stays idempotent', () async {
      await Hive.box('read_time').put('book-1', {
        '2026-1-5': 1800.0,
        '_media_kind_v1': 'book',
      });
      final backup = backupWith(
        readTime: [
          (
            id: 'book-1',
            kind: 'book',
            days: {'2026-1-5': 1200.0, '2026-1-6': 600.0},
          ),
        ],
      );
      expect((await service.restore(backup)).readTime, 1);
      expect(library.readTimeSnapshot()['book-1'], {
        '2026-1-5': 1800.0,
        '2026-1-6': 600.0,
      });
      expect((await service.restore(backup)).readTime, 1);
      expect(library.readTimeSnapshot()['book-1'], {
        '2026-1-5': 1800.0,
        '2026-1-6': 600.0,
      });
    });

    test('skips identities whose buckets were re-assigned to another kind', () async {
      await Hive.box('read_time').put('shared', {
        '2026-1-5': 900.0,
        '_allocated_media_time_v1': {'2026-1-5': 600.0},
      });
      final backup = backupWith(
        readTime: [
          (id: 'shared', kind: 'book', days: {'2026-1-5': 5000.0}),
        ],
      );
      expect((await service.restore(backup)).readTime, 0);
      final stored = Hive.box('read_time').get('shared') as Map;
      expect(stored['2026-1-5'], 900.0);
      expect(stored['_allocated_media_time_v1'], {'2026-1-5': 600.0});
    });

    test('creates an identity the device has never tracked', () async {
      final backup = backupWith(
        readTime: [
          // A content ID, not the scoped storage key.
          (id: 'new', kind: 'audio', days: {'2026-2-1': 300.0}),
        ],
      );
      expect((await service.restore(backup)).readTime, 1);
      expect(library.readTimeSnapshot()['audio:new'], {'2026-2-1': 300.0});
      expect(library.readTimeKindSnapshot()['audio:new'], 'audio');
    });

    test('round-trips a scoped identity through its content ID', () async {
      await Hive.box('read_time').put('audio:series-9', {
        '2026-3-2': 420.0,
        '_media_kind_v1': 'audio',
      });
      final backup = await service.capture();
      expect(backup.readTime, hasLength(1));
      expect(backup.readTime.single['id'], 'series-9');
      expect(backup.readTime.single['kind'], 'audio');
      await Hive.box('read_time').delete('audio:series-9');
      expect((await service.restore(backup)).readTime, 1);
      expect(library.readTimeSnapshot()['audio:series-9'], {'2026-3-2': 420.0});
      expect(library.readTimeKindSnapshot()['audio:series-9'], 'audio');
    });
  });

  group('search history merge', () {
    test('unions, keeps local order, caps at twenty and is idempotent', () async {
      await SearchHistoryStore.instance.add('本机词');
      final backup = backupWith(
        searchHistory: [
          '云端词',
          '本机词',
          for (var i = 0; i < 25; i++) '词$i',
        ],
      );
      final first = await service.restore(backup);
      expect(first.searchHistory, greaterThan(0));
      final merged = await SearchHistoryStore.instance.load();
      expect(merged, hasLength(20));
      expect(merged.first, '本机词');
      final second = await service.restore(backup);
      expect(second.searchHistory, 0);
      expect(await SearchHistoryStore.instance.load(), merged);
    });
  });

  group('version compatibility', () {
    test('a version 1 snapshot still imports with empty new lists', () async {
      final json = {
        'format': 'fqapp.library-backup',
        'version': 1,
        'createdAt': 1700000000000,
        'shelf': <dynamic>[],
        'history': [
          {'id': 'book-1', 'kind': 'book', 'episode': 3, 'time': 100},
        ],
        'watched': <dynamic>[],
        'excludedLocalRecords': 0,
      };
      final backup = LibraryBackup.decode(
        Uint8List.fromList(utf8.encode(jsonEncode(json))),
      );
      expect(backup.readTime, isEmpty);
      expect(backup.searchHistory, isEmpty);
      expect((await service.restore(backup)).history, 1);
      expect((await library.historyEntry('book-1'))?['episode'], 3);
      // Exports move forward: a v1 file is re-encoded as the current version.
      final encoded = jsonDecode(utf8.decode(backup.encode())) as Map;
      expect(encoded['version'], 3);
      expect(encoded['shelfRemoved'], isEmpty);
      expect(encoded['readTime'], isEmpty);
      expect(encoded['searchHistory'], isEmpty);
    });

    test('rejects an unsupported version and malformed read time', () {
      Map<String, dynamic> snapshot() => {
        'format': 'fqapp.library-backup',
        'version': 2,
        'createdAt': 1700000000000,
        'shelf': <dynamic>[],
        'history': <dynamic>[],
        'watched': <dynamic>[],
        'readTime': [
          {
            'id': 'book-1',
            'kind': 'book',
            'days': {'2026-1-5': 1800.0},
          },
        ],
        'searchHistory': <dynamic>[],
        'excludedLocalRecords': 0,
      };
      final json = snapshot();
      json['version'] = 4;
      expect(
        () => LibraryBackup.decode(
          Uint8List.fromList(utf8.encode(jsonEncode(json))),
        ),
        throwsFormatException,
      );
      final badKind = snapshot();
      ((badKind['readTime'] as List).first as Map)['kind'] = 'podcast';
      expect(
        () => LibraryBackup.decode(
          Uint8List.fromList(utf8.encode(jsonEncode(badKind))),
        ),
        throwsFormatException,
      );
      final badDay = snapshot();
      final entry = (badDay['readTime'] as List).first as Map;
      (entry['days'] as Map)['not-a-day'] = 10.0;
      expect(
        () => LibraryBackup.decode(
          Uint8List.fromList(utf8.encode(jsonEncode(badDay))),
        ),
        throwsFormatException,
      );
    });
  });
}
