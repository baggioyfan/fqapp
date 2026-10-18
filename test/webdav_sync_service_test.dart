import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:hive_ce/hive.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:fqapp/models/library_backup.dart';
import 'package:fqapp/models/media_item.dart';
import 'package:fqapp/models/progress_shard.dart';
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

  /// 让上传只落一半字节：模拟连接在传输中途断掉、服务端保留了半截文件。
  /// 三步替换的第一步就该发现它并放弃替换。
  bool truncateUploads = false;

  /// 卡住第一个请求不返回：用来测「超过总时长预算会中止」和「排队」。
  Completer<void>? hold;

  var _counter = 0;

  /// 主文件在假服务端里是 [remote]，也就是 `name == null` 那一路。
  ///
  /// 三步替换是按**文件名**称呼它的（`.tmp`/`.bak` 是它的兄弟），所以配置里
  /// 那个名字也要归一成主文件 —— 否则 `move` 会去找一个叫
  /// `fqapp-sync.json` 的分片，而那从来不存在，于是替换永远只走到一半。
  String _key(String? name) =>
      (name == null || name == WebdavConfig.defaultFileName) ? '' : name;

  Uint8List? _bytes(String key) => key.isEmpty ? remote : shards[key];

  DateTime? _stampOf(String key) => key.isEmpty ? modified : shardStamps[key];

  void _set(String key, Uint8List? bytes) {
    if (key.isEmpty) {
      remote = bytes;
    } else if (bytes == null) {
      shards.remove(key);
    } else {
      shards[key] = bytes;
    }
  }

  bool _exists(String? name) => _bytes(_key(name)) != null;

  String tagOf(String? name) {
    final key = _key(name);
    return etags[key] ??= 'etag-${++_counter}';
  }

  @override
  Future<void> ensureCollection() async {
    ensured = true;
    if (hold case final gate?) await gate.future;
  }

  @override
  Future<({Uint8List bytes, DateTime? modified, String? versionKey})?>
  download({String? name}) async {
    final key = _key(name);
    final bytes = _bytes(key);
    if (bytes == null) return null;
    return (bytes: bytes, modified: _stampOf(key), versionKey: tagOf(key));
  }

  @override
  Future<RemoteFile?> remoteFile({String? name}) async {
    final key = _key(name);
    final bytes = _bytes(key);
    if (bytes == null) return null;
    return RemoteFile(
      etag: tagOf(key),
      size: bytes.length,
      modified: _stampOf(key),
    );
  }

  @override
  Future<String?> upload(
    Uint8List bytes, {
    String? name,
    String? ifMatch,
  }) async {
    final key = _key(name);
    if (conflictsToInject > 0) {
      conflictsToInject--;
      // 抢先写入：内容前进一版，版本也跟着变。
      if (conflictReplacement case final replacement?) {
        _set(key, replacement);
        if (key.isNotEmpty) shardStamps[key] = DateTime.now();
        etags[key] = 'etag-${++_counter}';
      }
      throw const WebdavException('云端已被其它设备更新', statusCode: 412);
    }
    if (ifMatch != null && _exists(key) && ifMatch != tagOf(key)) {
      throw const WebdavException('云端已被其它设备更新', statusCode: 412);
    }
    puts.add(key);
    final stored = truncateUploads
        ? Uint8List.sublistView(bytes, 0, bytes.length ~/ 2)
        : bytes;
    _set(key, stored);
    if (key.isEmpty) {
      // 只有整包才更新 `uploaded`：分片 PUT 不该覆盖掉用例要断言的那份内容。
      uploaded = bytes;
    } else {
      shardStamps[key] = DateTime.now();
    }
    final next = 'etag-${++_counter}';
    etags[key] = next;
    return next;
  }

  @override
  Future<void> move({String? from, required String? to}) async {
    final sourceKey = _key(from);
    final targetKey = _key(to);
    final source = _bytes(sourceKey);
    if (source == null) {
      throw const WebdavException('无法重命名云端文件', statusCode: 404);
    }
    _set(targetKey, source);
    if (targetKey.isNotEmpty) shardStamps[targetKey] = DateTime.now();
    // 落到主文件位置的就是「云端现在这份快照」。三步替换之后它从来没被直接
    // PUT 过，`uploaded` 只能在这里补上，否则用例看到的永远是一份旧内容。
    if (targetKey.isEmpty) uploaded = source;
    etags[targetKey] = 'etag-${++_counter}';
    // 真实的 MOVE 是「挪走」，源不再存在 —— 三步替换依赖这一点。
    _set(sourceKey, null);
    etags.remove(sourceKey);
  }

  @override
  Future<void> delete({String? name}) async {
    final key = _key(name);
    _set(key, null);
    etags.remove(key);
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
    // v5 起整包不含进度，报的字节数是「整包 + 进度分片」两份之和。
    expect(
      report.uploadedBytes,
      transport.uploaded!.length +
          transport.shards[ProgressShard.fileName]!.length,
    );
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
    // v5 起整包不再写 history：同一份记录只走 progress.json，云端不再存两份。
    expect(LibraryBackup.decode(transport.uploaded!).history, isEmpty);
    final shard = ProgressShard.decode(
      transport.shards[ProgressShard.fileName]!,
    );
    final record = shard.history.single;
    expect(record['episode'], 10);
    expect(record['time'], 2000);
  });

  test('a full sync merges the progress shard before overwriting it', () async {
    // 刚装好的设备：本机一条进度都没有。整包（v5）也不再带 history，
    // 所以如果整包同步不单独合并一次分片，后面那次 `_commit` 就会用空的
    // 本机进度把云端的进度写成空表 —— 这是「设置 → 立即同步」的必经路径，
    // 它并不经过 syncProgress。
    await ShelfStore.instance.add(_item('local-1'));
    transport.remote = snapshot().encode(includeHistory: false);
    transport.shards[ProgressShard.fileName] = ProgressShard.capture(const [
      {'id': 'book-1', 'kind': 'book', 'episode': 7, 'time': 900},
    ]).encode();

    await service.sync(config, password: 'hunter2');

    expect(
      (await LibraryStore.instance.historyEntry('book-1'))?['episode'],
      7,
    );
    final written = ProgressShard.decode(
      transport.shards[ProgressShard.fileName]!,
    );
    expect(written.history.single['episode'], 7);
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

  group('atomic replacement', () {
    test('the first sync leaves no temp file behind', () async {
      await ShelfStore.instance.add(_item('local-1'));

      await service.sync(config, password: 'hunter2');

      expect(LibraryBackup.decode(transport.remote!).shelf.single.item.id, 'local-1');
      expect(transport.shards.containsKey('fqapp-sync.json.tmp'), isFalse);
      // 从来没有旧文件，就不该凭空造一个 .bak。
      expect(transport.shards.containsKey('fqapp-sync.json.bak'), isFalse);
    });

    test('a second sync keeps the previous version in .bak', () async {
      await ShelfStore.instance.add(_item('first'));
      await service.sync(config, password: 'hunter2');

      await ShelfStore.instance.add(_item('second'));
      await service.sync(config, password: 'hunter2');

      final backup = transport.shards['fqapp-sync.json.bak'];
      expect(backup, isNotNull, reason: '上一版必须留着，否则坏了就没得退');
      expect(
        LibraryBackup.decode(backup!).shelf.map((record) => record.item.id),
        ['first'],
      );
      expect(
        LibraryBackup.decode(transport.remote!).shelf.map((r) => r.item.id),
        // 书架是「后加的在前」：ShelfStore.records() 按 addedAt 倒序排，
        // 所以第二次同步写上去的并集是 second 在前。
        ['second', 'first'],
      );
      expect(transport.shards.containsKey('fqapp-sync.json.tmp'), isFalse);
    });

    test('a truncated upload is refused instead of replacing the file', () async {
      // 服务端只收到一半：直接 PUT 主文件的话，现在的云端就是这半截，
      // 两台设备从此都读不懂它。三步替换要求在这里就停下。
      await ShelfStore.instance.add(_item('local-1'));
      await service.sync(config, password: 'hunter2');
      final good = transport.remote;

      transport.truncateUploads = true;
      await ShelfStore.instance.add(_item('local-2'));

      await expectLater(
        service.sync(config, password: 'hunter2'),
        throwsA(
          isA<WebdavException>().having(
            (error) => error.message,
            'message',
            contains('上传被截断'),
          ),
        ),
      );

      expect(transport.remote, good, reason: '主文件必须还是上一次那份完整数据');
      expect(transport.shards.containsKey('fqapp-sync.json.tmp'), isFalse);
    });

    test('a corrupt primary falls back to the last good version', () async {
      // 云端主文件坏掉（历史上某次直传被截断留下的）。没有 .bak 就只能停；
      // 有 .bak 就必须用它继续，否则用户在这台设备上永远同步不了。
      await ShelfStore.instance.add(_item('local-1'));
      transport.remote = Uint8List.fromList(utf8.encode('{ not json'));
      transport.shards['fqapp-sync.json.bak'] = snapshot(
        shelf: [
          ShelfRecord(
            item: _item('from-backup'),
            addedAt: DateTime.fromMillisecondsSinceEpoch(1000),
          ),
        ],
      ).encode();

      final report = await service.sync(config, password: 'hunter2');

      expect(report.shelf, 1);
      expect(
        ShelfStore.instance.records().map((record) => record.item.id).toSet(),
        {'local-1', 'from-backup'},
      );
      // 坏文件已经被一次完整的替换覆盖掉。
      expect(
        LibraryBackup.decode(transport.remote!).shelf
            .map((record) => record.item.id)
            .toSet(),
        {'local-1', 'from-backup'},
      );
    });

    test('a corrupt primary without a backup still stops the sync', () async {
      await ShelfStore.instance.add(_item('local-1'));
      transport.remote = Uint8List.fromList(utf8.encode('{ not json'));

      await expectLater(
        service.sync(config, password: 'hunter2'),
        throwsA(isA<WebdavException>()),
      );
      // 没有可退的版本时，宁可停下也不要用本机数据盖掉那份坏文件 ——
      // 它可能只是暂时读不懂，用户还能去网盘取回来。
      expect(
        transport.remote,
        Uint8List.fromList(utf8.encode('{ not json')),
      );
    });
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

  group('time budget and queue', () {
    test('a sync that outlives its budget fails instead of hanging', () async {
      // 队列是串行的：一次永远不返回的同步会把之后每一次都堵住，
      // 页面上只剩「一直转圈」——没有错误，也没有出路。
      await ShelfStore.instance.add(_item('local-1'));
      transport.hold = Completer<void>();
      final shortBudget = WebdavSyncService(
        transport: (config, password) => transport,
        budget: const Duration(milliseconds: 120),
      );

      await expectLater(
        shortBudget.sync(config, password: 'hunter2'),
        throwsA(
          isA<WebdavException>().having(
            (error) => error.message,
            'message',
            contains('仍未完成'),
          ),
        ),
      );
      // 超时后必须自己把连接关掉：挂起的请求留在那儿，下一次同步只是
      // 换了个排队的人，问题没有消失。
      expect(transport.closed, isTrue);
      // 队列也确实空了 —— 后续同步能开始，而不是永远等在它后面。
      expect(WebdavSyncService.isSyncing, isFalse);
    });

    test('a manual sync drops a queued background job instead of waiting', () async {
      await ShelfStore.instance.add(_item('local-1'));
      final gate = Completer<void>();
      transport.hold = gate;

      // 第一个任务占住队列。
      final running = service.syncProgress(
        config,
        password: 'hunter2',
        localDirty: true,
        priority: SyncPriority.background,
      );
      // 第二个后台任务只能在后面排着。
      final queued = service.syncProgress(
        config,
        password: 'hunter2',
        localDirty: true,
        priority: SyncPriority.background,
      );
      expect(WebdavSyncService.state, SyncRunState.running);

      // 用户这时点了「立即同步」：排队那个已经没有意义了。
      final manual = service.sync(config, password: 'hunter2');

      await expectLater(
        queued,
        throwsA(
          isA<WebdavException>().having(
            (error) => error.message,
            'message',
            contains('已被手动同步取代'),
          ),
        ),
      );

      gate.complete();
      await running;
      await manual;
      expect(WebdavSyncService.isSyncing, isFalse);
    });
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
  Future<void> move({String? from, required String? to}) =>
      inner.move(from: from, to: to);

  @override
  Future<void> delete({String? name}) => inner.delete(name: name);

  @override
  void close() => inner.close();
}
