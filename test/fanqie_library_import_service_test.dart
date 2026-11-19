import 'dart:async';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:hive_ce/hive.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:fqapp/models/fanqie_library_capture.dart';
import 'package:fqapp/models/media_item.dart';
import 'package:fqapp/services/backend_transport.dart';
import 'package:fqapp/services/fanqie_library_import_service.dart';
import 'package:fqapp/services/library_store.dart';
import 'package:fqapp/services/shelf_store.dart';

Map<String, dynamic> _source(String resource, dynamic data) => {
  'resource': resource,
  'status': 'received',
  'payload': {'code': 0, 'data': data},
};

/// [books] 本小说，每本都带一个已知 chapterId，预览阶段会去拉目录核对。
FanqieLibraryCapture _capture(int books) {
  final ids = [for (var i = 1; i <= books; i++) '$i'];
  return FanqieLibraryCapture({
    'parts': <String>[],
    'sources': <Map<String, dynamic>>[
      _source('history', {
        'data_list': [
          for (final id in ids)
            {
              'book_id': id,
              'book_type': 0,
              'book_name': 'Book $id',
              'read_timestamp_ms': 1,
            },
        ],
      }),
      _source('progress_list', [
        for (final id in ids)
          {
            'book_id': id,
            'book_type': 0,
            // item_id 必须是纯数字，导入模型才会把它当作章节 ID。
            'item_id': '80$id',
            'read_timestamp_ms': 1,
          },
      ]),
    ],
  });
}

List<List<Chapter>> _chapters(String bookId) => [
  [Chapter(itemId: '80$bookId', title: 'Chapter', volumeName: '')],
];

void main() {
  test('preview resolves directories with bounded concurrency', () async {
    const books = 12;
    var active = 0;
    var peak = 0;
    final started = <String>[];
    final progress = <String>[];

    final preview = await FanqieLibraryImportService().prepare(
      _capture(books),
      BackendRequest(),
      progress.add,
      directoryLoader: (bookId) async {
        active++;
        if (active > peak) peak = active;
        started.add(bookId);
        await Future<void>.delayed(const Duration(milliseconds: 5));
        active--;
        return _chapters(bookId);
      },
    );

    // 并发而不是串行，但最多 4 个目录请求同时在途。
    expect(peak, greaterThan(1));
    expect(peak, lessThanOrEqualTo(4));
    expect(started, hasLength(books));
    expect(preview.matched, books);
    expect(preview.unresolved, 0);
    expect(preview.records, hasLength(books));
    expect(progress, hasLength(books));
  });

  test('preview stops issuing directory requests when cancelled', () async {
    final request = BackendRequest();
    final started = <String>[];
    final fourStarted = Completer<void>();

    final future = FanqieLibraryImportService().prepare(
      _capture(50),
      request,
      (_) {},
      directoryLoader: (bookId) {
        started.add(bookId);
        if (started.length == 4 && !fourStarted.isCompleted) {
          fourStarted.complete();
        }
        return request.whenCancelled.then<List<List<Chapter>>>(
          (_) => throw BackendRequestAborted('请求已取消'),
        );
      },
    );

    await fourStarted.future;
    request.cancel();
    await expectLater(future, throwsA(isA<BackendRequestAborted>()));
    // 取消后不再领取新书：只有已经在途的 4 个请求。
    expect(started, hasLength(4));
  });

  group('merge stores only shelved books into ShelfStore', () {
    late Directory directory;

    setUp(() async {
      SharedPreferences.setMockInitialValues({});
      directory = await Directory.systemTemp.createTemp(
        'fqapp-fanqie-import-svc-',
      );
      Hive.init(directory.path);
      await LibraryStore.instance.init();
      await ShelfStore.instance.init();
    });

    tearDown(() async {
      await Hive.close().timeout(
        const Duration(seconds: 10),
        onTimeout: () => const <void>[],
      );
      try {
        await directory.delete(recursive: true);
      } catch (_) {}
    });

    test(
      'prepare and merge put only shelved books on shelf and all books in history',
      () async {
        final capture = FanqieLibraryCapture({
          'parts': <String>[],
          'sources': <Map<String, dynamic>>[
            _source('shelf_list', {
              'book_shelf_info_all': [
                {'book_id': '1', 'book_type': 0, 'book_name': 'Shelved 1'},
                {'book_id': '2', 'book_type': 0, 'book_name': 'Shelved 2'},
              ],
            }),
            _source('history', {
              'data_list': [
                {
                  'book_id': '1',
                  'book_type': 0,
                  'book_name': 'Shelved 1',
                  'read_timestamp_ms': 1000,
                },
                {
                  'book_id': '3',
                  'book_type': 0,
                  'book_name': 'History Only 3',
                  'read_timestamp_ms': 2000,
                },
              ],
            }),
            _source('progress_list', [
              {
                'book_id': '1',
                'book_type': 0,
                'item_id': '801',
                'read_timestamp_ms': 1500,
              },
              {
                'book_id': '4',
                'book_type': 0,
                'book_name': 'Progress Only 4',
                'item_id': '804',
                'read_timestamp_ms': 3000,
              },
            ]),
          ],
        });

        final service = FanqieLibraryImportService();
        final preview = await service.prepare(
          capture,
          BackendRequest(),
          (_) {},
          directoryLoader: (bookId) async => _chapters(bookId),
        );

        expect(preview.shelfIds, {'1', '2'});
        expect(preview.shelfCount, 2);
        expect(preview.records.map((r) => r['id']), ['1', '2', '3', '4']);
        expect(preview.matched, 2);

        final result = await service.merge(preview);
        expect(result.shelf, 2);
        expect(result.history, 4);

        final shelfRecords = ShelfStore.instance.records();
        expect(shelfRecords.map((r) => r.item.id), unorderedEquals(['1', '2']));
        expect(
          shelfRecords.singleWhere((r) => r.item.id == '1').item.ep,
          '第 1 章',
        );

        final historyIds = LibraryStore.instance
            .historySnapshot()
            .map((r) => r['id'])
            .toList();
        expect(historyIds, unorderedEquals(['1', '2', '3', '4']));
      },
    );

    test(
      'merging a history-only preview writes zero entries to ShelfStore',
      () async {
        final service = FanqieLibraryImportService();
        final preview = await service.prepare(
          _capture(3),
          BackendRequest(),
          (_) {},
          directoryLoader: (bookId) async => _chapters(bookId),
        );

        expect(preview.shelfIds, isEmpty);
        expect(preview.shelfCount, 0);

        final result = await service.merge(preview);
        expect(result.shelf, 0);
        expect(result.history, 3);
        expect(ShelfStore.instance.records(), isEmpty);
        expect(LibraryStore.instance.historySnapshot(), hasLength(3));
      },
    );
  });
}
