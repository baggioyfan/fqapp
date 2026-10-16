import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:hive/hive.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:fqapp/models/library_backup.dart';
import 'package:fqapp/models/media_item.dart';
import 'package:fqapp/services/library_store.dart';
import 'package:fqapp/services/shelf_store.dart';
import 'package:fqapp/services/webdav_client.dart';
import 'package:fqapp/services/webdav_config.dart';
import 'package:fqapp/services/webdav_sync_service.dart';

/// The sync service only needs four calls, so the transport is faked here and
/// the assertions can be about what was uploaded rather than about HTTP.
class _FakeTransport implements WebdavTransport {
  Uint8List? remote;
  DateTime? remoteModified;
  Uint8List? uploaded;
  String? receivedPassword;
  bool ensured = false;
  bool closed = false;

  @override
  Future<void> ensureCollection() async => ensured = true;

  @override
  Future<({Uint8List bytes, DateTime? modified})?> download() async =>
      remote == null ? null : (bytes: remote!, modified: remoteModified);

  @override
  Future<void> upload(Uint8List bytes) async => uploaded = bytes;

  @override
  void close() => closed = true;
}

/// Cross-device behaviour of one sync: what the remote becomes, and what the
/// local device keeps when the remote is older or unreadable.
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  const config = WebdavConfig(
    collectionUrl: 'https://dav.example.com/dav/',
    username: 'reader',
    fileName: 'fqapp-sync.json',
  );

  late Directory directory;
  late _FakeTransport transport;
  late WebdavSyncService service;
  final library = LibraryStore.instance;

  setUp(() async {
    SharedPreferences.setMockInitialValues({});
    directory = await Directory.systemTemp.createTemp('fqapp-webdav-sync-');
    Hive.init(directory.path);
    await library.init();
    await ShelfStore.instance.init();
    transport = _FakeTransport();
    service = WebdavSyncService(
      transport: (config, password) {
        transport.receivedPassword = password;
        return transport;
      },
    );
  });

  tearDown(() async {
    await Hive.close();
    await directory.delete(recursive: true);
  });

  LibraryBackup snapshot({
    List<ShelfRecord> shelf = const [],
    List<Map<String, dynamic>> history = const [],
  }) => LibraryBackup.capture(
    shelf: shelf,
    history: history,
    watched: const {},
    readTime: const [],
    searchHistory: const [],
  );

  test('uploads local data when the remote file does not exist yet', () async {
    await ShelfStore.instance.add(_item('local-1'));

    final report = await service.sync(config, password: 'hunter2');

    expect(transport.ensured, isTrue);
    expect(transport.closed, isTrue);
    expect(transport.receivedPassword, 'hunter2');
    expect(report.remoteExisted, isFalse);
    expect(report.shelf, 0);
    expect(report.uploadedBytes, transport.uploaded!.length);
    expect(
      LibraryBackup.decode(transport.uploaded!).shelf.map((r) => r.item.id),
      ['local-1'],
    );
  });

  test('merges the remote into this device and writes the union back', () async {
    await ShelfStore.instance.add(_item('local-1'));
    transport.remote = snapshot(
      shelf: [
        ShelfRecord(
          item: _item('remote-1'),
          addedAt: DateTime.fromMillisecondsSinceEpoch(1000),
        ),
      ],
    ).encode();
    transport.remoteModified = DateTime.utc(2026, 1, 2);

    final report = await service.sync(config, password: 'hunter2');

    expect(report.remoteExisted, isTrue);
    expect(report.remoteModified, DateTime.utc(2026, 1, 2));
    // One record was new here; the local one was already present.
    expect(report.shelf, 1);
    expect(
      ShelfStore.instance.records().map((record) => record.item.id).toSet(),
      {'local-1', 'remote-1'},
    );
    expect(
      LibraryBackup.decode(transport.uploaded!).shelf
          .map((record) => record.item.id)
          .toSet(),
      {'local-1', 'remote-1'},
    );
  });

  test('keeps the local position when the remote one is older', () async {
    await library.addHistory({
      'id': 'book-1',
      'kind': 'book',
      'episode': 10,
      'progress': 0.5,
      'time': 2000,
    });
    transport.remote = snapshot(
      history: [
        {
          'id': 'book-1',
          'kind': 'book',
          'episode': 5,
          'progress': 0.9,
          'time': 1000,
        },
      ],
    ).encode();

    final report = await service.sync(config, password: 'hunter2');

    expect(report.history, 0);
    final record = LibraryBackup.decode(transport.uploaded!).history.single;
    expect(record['episode'], 10);
    expect(record['time'], 2000);
  });

  test('a remote file that is not a snapshot stops the sync', () async {
    await ShelfStore.instance.add(_item('local-1'));
    transport.remote = Uint8List.fromList(utf8.encode('{"version":2}'));

    await expectLater(
      service.sync(config, password: 'hunter2'),
      throwsA(
        isA<WebdavException>().having(
          (error) => error.message,
          'message',
          contains('无法识别'),
        ),
      ),
    );
    // The decisive part: the unreadable remote is left exactly as it was.
    expect(transport.uploaded, isNull);
    expect(transport.closed, isTrue);
  });

  test('a truncated remote file stops the sync', () async {
    transport.remote = Uint8List.fromList(utf8.encode('{ not json'));

    await expectLater(
      service.sync(config, password: 'hunter2'),
      throwsA(isA<WebdavException>()),
    );
    expect(transport.uploaded, isNull);
  });

  test('a failed upload surfaces and still closes the transport', () async {
    final failing = WebdavSyncService(
      transport: (config, password) => _FailingTransport(transport),
    );
    await expectLater(
      failing.sync(config, password: 'hunter2'),
      throwsA(isA<WebdavException>()),
    );
    expect(transport.closed, isTrue);
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

class _FailingTransport implements WebdavTransport {
  _FailingTransport(this.inner);

  final _FakeTransport inner;

  @override
  Future<void> ensureCollection() => inner.ensureCollection();

  @override
  Future<({Uint8List bytes, DateTime? modified})?> download() =>
      inner.download();

  @override
  Future<void> upload(Uint8List bytes) async {
    throw const WebdavException('上传云端备份失败：服务器返回 500');
  }

  @override
  void close() => inner.close();
}
