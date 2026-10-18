import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:hive_ce/hive.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:fqapp/models/library_backup.dart';
import 'package:fqapp/models/media_item.dart';
import 'package:fqapp/services/library_store.dart';
import 'package:fqapp/services/shelf_store.dart';
import 'package:fqapp/services/webdav_client.dart';
import 'package:fqapp/services/webdav_config.dart';
import 'package:fqapp/services/webdav_sync_service.dart';

/// The sync service only needs a handful of calls, so the transport is faked
/// here and the assertions can be about what was uploaded rather than about
/// HTTP.
///
/// 版本标识用递增的假 ETag：写入换新值、读时给出当前值、`If-Match` 对不上
/// 就抛 412 —— 真实条件写的行为，重试循环才测得到。
class _FakeTransport implements WebdavTransport {
  Uint8List? remote;
  DateTime? modified;
  Uint8List? uploaded;
  String? receivedPassword;
  bool ensured = false;
  bool closed = false;

  /// 分片文件（`progress.json` 等）单独放，键是文件名。整包继续用上面那三个
  /// 字段，老用例的断言不用改。
  final Map<String, Uint8List> shards = {};
  final Map<String, DateTime> shardStamps = {};

  /// 每个文件当前的 ETag（null 记为 ''）。
  final Map<String, String> etags = {};

  /// 每次 PUT 的目标文件名，null 记成空串 —— 用来断言「只推了分片」。
  final List<String> puts = [];

  /// 让下一次写入假装「已被别的设备抢先」：服务端回 412，客户端应当重新
  /// 读、重新合并、再写一次。
  int conflictsToInject = 0;

  /// 注入的冲突让云端内容也前进一版（模拟另一台设备真的写了东西）。
  Uint8List? conflictReplacement;

  var _counter = 0;

  String _key(String? name) => name ?? '';

  bool _exists(String? name) =>
      name == null ? remote != null : shards.containsKey(name);

  String tagOf(String? name) {
    final key = _key(name);
    return etags[key] ??= 'etag-${++_counter}';
  }

  @override
  Future<void> ensureCollection() async => ensured = true;

  @override
  Future<({Uint8List bytes, DateTime? modified, String? versionKey})?>
  download({String? name}) async {
    if (name != null) {
      final bytes = shards[name];
      if (bytes == null) return null;
      return (
        bytes: bytes,
        modified: shardStamps[name],
        versionKey: tagOf(name),
      );
    }
    if (remote == null) return null;
    return (bytes: remote!, modified: modified, versionKey: tagOf(null));
  }

  @override
  Future<RemoteFile?> remoteFile({String? name}) async {
    if (!_exists(name)) return null;
    return RemoteFile(
      etag: tagOf(name),
      size: (name == null ? remote! : shards[name]!).length,
      modified: name == null ? modified : shardStamps[name],
    );
  }

  @override
  Future<String?> upload(
    Uint8List bytes, {
    String? name,
    String? ifMatch,
  }) async {
    if (conflictsToInject > 0) {
      conflictsToInject--;
      // 抢先写入：内容前进一版，版本也跟着变。
      if (conflictReplacement case final replacement?) {
        if (name == null) {
          remote = replacement;
        } else {
          shards[name] = replacement;
          shardStamps[name] = DateTime.now();
        }
        etags[_key(name)] = 'etag-${++_counter}';
      }
      throw const WebdavException('云端已被其它设备更新', statusCode: 412);
    }
    if (ifMatch != null && _exists(name) && ifMatch != tagOf(name)) {
      throw const WebdavException('云端已被其它设备更新', statusCode: 412);
    }
    puts.add(_key(name));
    if (name == null) {
      // 只有整包才更新 `uploaded`：分片 PUT 不该覆盖掉用例要断言的那份内容。
      uploaded = bytes;
      remote = bytes;
    } else {
      shards[name] = bytes;
      shardStamps[name] = DateTime.now();
    }
    final next = 'etag-${++_counter}';
    etags[_key(name)] = next;
    return next;
  }

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
    Map<String, DateTime> shelfRemoved = const {},
    List<Map<String, dynamic>> history = const [],
  }) => LibraryBackup.capture(
    shelf: shelf,
    shelfRemoved: shelfRemoved,
    history: history,
    watched: const {},
    daily: const {},
    books: const [],
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
    transport.modified = DateTime.utc(2026, 1, 2);

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

  test('a shelf removal survives its own sync', () async {
    // 用户报的那个 bug：移出书架后点同步，云端那份又被合并回本机。
    await ShelfStore.instance.add(_item('keep-1'));
    await ShelfStore.instance.add(_item('local-1'));
    await ShelfStore.instance.removeKeys([
      ShelfStore.keyOf(_item('local-1')),
    ]);

    await service.sync(config, password: 'hunter2');
    final uploaded = LibraryBackup.decode(transport.uploaded!);
    expect(uploaded.shelf.map((record) => record.item.id), ['keep-1']);
    expect(uploaded.shelfRemoved.keys, ['book:local-1']);

    // 第二次同步把这份上传结果当云端：删除必须仍然成立。
    transport.modified = DateTime.utc(2026, 1, 3);
    await service.sync(config, password: 'hunter2');

    expect(
      ShelfStore.instance.records().map((record) => record.item.id),
      ['keep-1'],
    );
    expect(
      LibraryBackup.decode(transport.uploaded!).shelf.map((r) => r.item.id),
      ['keep-1'],
    );
  });

  test('a remote tombstone deletes the local copy', () async {
    await ShelfStore.instance.add(_item('local-1'));
    transport.remote = snapshot(
      shelf: [
        ShelfRecord(
          item: _item('local-1'),
          addedAt: DateTime.fromMillisecondsSinceEpoch(1000),
        ),
      ],
      shelfRemoved: {
        ShelfStore.keyOf(_item('local-1')): DateTime.now().add(
          const Duration(minutes: 1),
        ),
      },
    ).encode();

    await service.sync(config, password: 'hunter2');

    expect(ShelfStore.instance.records(), isEmpty);
    // 墓碑要写回云端，另一台设备才会跟着删。
    expect(
      LibraryBackup.decode(transport.uploaded!).shelfRemoved.keys,
      ['book:local-1'],
    );
  });

  test('a shelf entry added after the removal survives', () async {
    await ShelfStore.instance.add(_item('local-1'));
    transport.remote = snapshot(
      shelfRemoved: {
        ShelfStore.keyOf(_item('local-1')): DateTime.now().subtract(
          const Duration(days: 1),
        ),
      },
    ).encode();

    await service.sync(config, password: 'hunter2');

    expect(
      ShelfStore.instance.records().map((record) => record.item.id),
      ['local-1'],
    );
    // 删除已经被「重新加入」赢过，不该再跟着上传。
    expect(LibraryBackup.decode(transport.uploaded!).shelfRemoved, isEmpty);
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

  test('a 412 from a concurrent write re-reads and merges before retrying', () async {
    // 这是条件写的意义所在：另一台设备在本机「读」与「写」之间提交了改动，
    // 服务器拒绝本次写。正确反应不是覆盖，而是重新读回来合并再写。
    await ShelfStore.instance.add(_item('local-1'));
    transport.remote = snapshot(
      shelf: [
        ShelfRecord(
          item: _item('remote-1'),
          addedAt: DateTime.fromMillisecondsSinceEpoch(1000),
        ),
      ],
    ).encode();
    transport.conflictsToInject = 1;

    final report = await service.sync(config, password: 'hunter2');

    // 重试后两边的条目都在云端，而不是「谁后写谁留」。
    expect(report.shelf, 1);
    expect(
      LibraryBackup.decode(transport.uploaded!)
          .shelf
          .map((record) => record.item.id)
          .toSet(),
      {'local-1', 'remote-1'},
    );
    expect(transport.closed, isTrue);
  });

  test('gives up after repeated conflicts instead of looping', () async {
    transport.remote = snapshot().encode();
    transport.conflictsToInject = 10;

    await expectLater(
      service.sync(config, password: 'hunter2'),
      throwsA(
        isA<WebdavException>().having(
          (error) => error.statusCode,
          'statusCode',
          412,
        ),
      ),
    );
    expect(transport.closed, isTrue);
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
  Future<({Uint8List bytes, DateTime? modified, String? versionKey})?>
  download({String? name}) => inner.download(name: name);

  @override
  Future<RemoteFile?> remoteFile({String? name}) =>
      inner.remoteFile(name: name);

  @override
  Future<String?> upload(
    Uint8List bytes, {
    String? name,
    String? ifMatch,
  }) async {
    throw const WebdavException('上传云端备份失败：服务器返回 500');
  }

  @override
  void close() => inner.close();
}
