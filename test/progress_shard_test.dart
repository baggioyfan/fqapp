import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:hive_ce/hive.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:fqapp/models/library_backup.dart';
import 'package:fqapp/models/progress_shard.dart';
import 'package:fqapp/services/library_store.dart';
import 'package:fqapp/services/shelf_store.dart';
import 'package:fqapp/services/webdav_auto_sync.dart';
import 'package:fqapp/services/webdav_client.dart';
import 'package:fqapp/services/webdav_config.dart';
import 'package:fqapp/services/webdav_sync_service.dart';

/// 热路径分片：进度单独一个文件，退出阅读页只推它。
///
/// 这里验的是两件事 ——
/// 1. 分片自己的编解码（它和整包**不共享**版本号，读不懂就必须停手）；
/// 2. 三级闸门到底发了几个请求：云端没变且本机没改就一个都不发，本机改过
///    就跳过 GET 直传。后者是分片存在的理由，断言的是「GET 次数为 0」。
///
/// 版本标识用递增的假 ETag 模拟：每次写入换一个值，读写时按 `If-Match`
/// 校验 —— 也就是真实服务端条件写的行为。
class _ShardTransport implements WebdavTransport {
  /// 整包（`name == null`）。
  Uint8List? full;
  DateTime? fullModified;

  /// 分片，键是文件名。
  final Map<String, Uint8List> files = {};
  final Map<String, DateTime> stamps = {};

  /// 每个文件当前的 ETag（键：null 记成空串）。
  final Map<String, String> etags = {};

  /// 每次 PUT 的目标；null 记成空串，用来断言「只推了分片」。
  final List<String> puts = [];

  /// 每次 GET 的目标（只记正文下载，PROPFIND 不算）。
  final List<String> gets = [];

  /// 每次 PUT 带上的 `If-Match`，与 [puts] 一一对应。
  final List<String?> ifMatches = [];

  String? receivedPassword;
  bool ensured = false;
  bool closed = false;

  var _counter = 0;

  String _key(String? name) => name ?? '';

  bool _exists(String? name) =>
      name == null ? full != null : files.containsKey(name);

  /// 当前 ETag；文件不存在时抛错，调用方应先判断存在性。
  String tagOf(String? name) {
    final key = _key(name);
    return etags[key] ??= 'etag-${++_counter}';
  }

  @override
  Future<void> ensureCollection() async => ensured = true;

  @override
  Future<({Uint8List bytes, DateTime? modified, String? versionKey})?>
  download({String? name}) async {
    gets.add(_key(name));
    final bytes = name == null ? full : files[name];
    if (bytes == null) return null;
    return (
      bytes: bytes,
      modified: name == null ? fullModified : stamps[name],
      versionKey: tagOf(name),
    );
  }

  @override
  Future<RemoteFile?> remoteFile({String? name}) async {
    if (!_exists(name)) return null;
    final bytes = name == null ? full! : files[name]!;
    return RemoteFile(
      etag: tagOf(name),
      size: bytes.length,
      modified: name == null ? fullModified : stamps[name],
    );
  }

  @override
  Future<String?> upload(
    Uint8List bytes, {
    String? name,
    String? ifMatch,
  }) async {
    // 条件写：给的值和当前版本不一致就拒绝，与真实服务端一致。
    if (ifMatch != null && _exists(name) && ifMatch != tagOf(name)) {
      throw const WebdavException('云端已被其它设备更新', statusCode: 412);
    }
    puts.add(_key(name));
    ifMatches.add(ifMatch);
    if (name == null) {
      full = bytes;
      fullModified = DateTime.now().toUtc();
    } else {
      files[name] = bytes;
      stamps[name] = DateTime.now().toUtc();
    }
    final next = 'etag-${++_counter}';
    etags[_key(name)] = next;
    return next;
  }

  @override
  void close() => closed = true;
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  group('ProgressShard', () {
    Map<String, dynamic> record(String id, {int time = 1000}) => {
      'id': id,
      'kind': 'book',
      'title': '书 $id',
      'time': time,
      'episode': 3,
      'progress': 0.25,
    };

    test('round-trips the history it captured', () {
      final bytes = ProgressShard.capture([record('a'), record('b')]).encode();
      final decoded = ProgressShard.decode(bytes);

      expect(decoded.history.map((e) => e['id']), ['a', 'b']);
      expect(decoded.history.first['episode'], 3);
      expect(decoded.createdAt.isAfter(DateTime(2000)), isTrue);
    });

    test('starts with a UTF-8 BOM-tolerant decoder', () {
      // 有些服务端会在 PUT 之后回吐带 BOM 的内容，别为此判成「读不懂」。
      final body = utf8.encode(
        jsonEncode({
          'format': ProgressShard.format,
          'version': ProgressShard.version,
          'createdAt': 1,
          'history': [record('a')],
        }),
      );
      final decoded = ProgressShard.decode(
        Uint8List.fromList([0xEF, 0xBB, 0xBF, ...body]),
      );

      expect(decoded.history, hasLength(1));
    });

    test('refuses a file that is not ours', () {
      expect(
        () => ProgressShard.decode(
          Uint8List.fromList(utf8.encode('{"format":"other","version":1}')),
        ),
        throwsA(isA<FormatException>()),
      );
    });

    test('refuses an unknown version instead of guessing', () {
      // 版本号独立于整包：将来分片加字段时，老版本必须停手而不是按老格式读。
      expect(
        () => ProgressShard.decode(
          Uint8List.fromList(
            utf8.encode(
              jsonEncode({
                'format': ProgressShard.format,
                'version': ProgressShard.version + 1,
                'createdAt': 1,
                'history': const [],
              }),
            ),
          ),
        ),
        throwsA(isA<FormatException>()),
      );
    });

    test('refuses a broken record rather than dropping it', () {
      // 与整包共用同一套字段校验：静默丢弃会让「云端比本机全」这句话变假。
      expect(
        () => ProgressShard.decode(
          Uint8List.fromList(
            utf8.encode(
              jsonEncode({
                'format': ProgressShard.format,
                'version': ProgressShard.version,
                'createdAt': 1,
                'history': [
                  {'id': 'a', 'kind': 'book', 'title': 'A', 'progress': 9},
                ],
              }),
            ),
          ),
        ),
        throwsA(isA<FormatException>()),
      );
    });

    test('refuses duplicates that would make the merge ambiguous', () {
      expect(
        () => ProgressShard.decode(
          Uint8List.fromList(
            utf8.encode(
              jsonEncode({
                'format': ProgressShard.format,
                'version': ProgressShard.version,
                'createdAt': 1,
                'history': [record('a'), record('a', time: 2000)],
              }),
            ),
          ),
        ),
        throwsA(isA<FormatException>()),
      );
    });
  });

  group('syncProgress', () {
    const config = WebdavConfig(
      collectionUrl: 'https://dav.example.com/dav/',
      username: 'reader',
      fileName: 'fqapp-sync.json',
    );

    late _ShardTransport transport;
    late WebdavSyncService service;
    final library = LibraryStore.instance;

    setUpAll(() async {
      final directory = await Directory.systemTemp.createTemp('fqapp-progress-');
      Hive.init(directory.path);
    });

    setUp(() async {
      SharedPreferences.setMockInitialValues({});
      await library.init();
      await ShelfStore.instance.init();
      transport = _ShardTransport();
      service = WebdavSyncService(
        transport: (config, password) {
          transport.receivedPassword = password;
          return transport;
        },
      );
    });

    test('the first sync writes the shard and marks it', () async {
      await library.addHistory({
        'id': 'first',
        'kind': 'book',
        'title': '第一本',
        'time': 1000,
        'episode': 2,
        'progress': 0.5,
      });

      final report = await service.syncProgress(
        config,
        password: '',
        localDirty: true,
      );

      expect(report.uploadedBytes, greaterThan(0));
      expect(transport.puts, [ProgressShard.fileName]);
      final decoded = ProgressShard.decode(
        transport.files[ProgressShard.fileName]!,
      );
      expect(decoded.history.map((e) => e['id']), contains('first'));
      expect(
        await WebdavConfigStore.instance.progressSyncedAt(),
        isNotNull,
      );
    });

    test('a cloud shard from another device is merged before writing', () async {
      transport.files[ProgressShard.fileName] = ProgressShard.capture([
        {
          'id': 'elsewhere',
          'kind': 'book',
          'title': '别的设备',
          'time': 2000,
          'episode': 4,
          'progress': 0.1,
        },
      ]).encode();
      // 本机从没同步过分片 —— 闸门认为云端更新，必须读回来。
      transport.stamps[ProgressShard.fileName] = DateTime.now().toUtc();

      final report = await service.syncProgress(
        config,
        password: '',
        localDirty: false,
      );

      expect(report.history, 1);
      expect(transport.gets, contains(ProgressShard.fileName));
      expect(
        (await library.history()).map((e) => e['id']),
        contains('elsewhere'),
      );
    });

    test('nothing changed anywhere means one round trip and no upload', () async {
      transport.files[ProgressShard.fileName] = ProgressShard.capture(
        const [],
      ).encode();
      transport.stamps[ProgressShard.fileName] = DateTime.now().toUtc();
      // 闸门比的是版本，不是时间：记下云端当前那一版。
      await WebdavConfigStore.instance.markProgressVersion(
        transport.tagOf(ProgressShard.fileName),
      );

      final report = await service.syncProgress(
        config,
        password: '',
        localDirty: false,
      );

      expect(report, (history: 0, uploadedBytes: 0));
      expect(transport.gets, isEmpty);
      expect(transport.puts, isEmpty);
    });

    test('a local change uploads without reading the cloud first', () async {
      // 这是分片的核心收益：进度是「指针」，确认云端没被别人改过就直接覆盖。
      transport.files[ProgressShard.fileName] = ProgressShard.capture(
        const [],
      ).encode();
      transport.stamps[ProgressShard.fileName] = DateTime.now().toUtc();
      // 闸门比的是版本，不是时间：记下云端当前那一版。
      await WebdavConfigStore.instance.markProgressVersion(
        transport.tagOf(ProgressShard.fileName),
      );

      final report = await service.syncProgress(
        config,
        password: '',
        localDirty: true,
      );

      expect(report.uploadedBytes, greaterThan(0));
      expect(transport.gets, isEmpty, reason: '本机改过就不该先 GET');
      expect(transport.puts, [ProgressShard.fileName]);
    });

    test('a cloud without the shard falls back to the full backup', () async {
      // 迁移路径：另一台设备还停在旧版本，进度只在整包里。直接写分片会把
      // 对方覆盖掉，所以必须先把它整包里的进度合并进来。
      final legacy = LibraryBackup.capture(
        shelf: const [],
        shelfRemoved: const {},
        history: [
          {
            'id': 'legacy-only',
            'kind': 'book',
            'title': '旧设备',
            'time': 3000,
            'episode': 6,
            'progress': 0.9,
          },
        ],
        watched: const {},
        daily: const {},
        books: const [],
        searchHistory: const [],
      );
      transport.full = legacy.encode();
      transport.fullModified = DateTime.now().toUtc();

      final report = await service.syncProgress(
        config,
        password: '',
        localDirty: false,
      );

      expect(report.history, 1);
      expect(
        (await library.history()).map((e) => e['id']),
        contains('legacy-only'),
      );
      final decoded = ProgressShard.decode(
        transport.files[ProgressShard.fileName]!,
      );
      expect(decoded.history.map((e) => e['id']), contains('legacy-only'));
    });

    test('a full sync also refreshes the shard', () async {
      // 整包里带着进度；不顺手刷新分片的话，下一次「离开阅读页」会把旧进度
      // 推上去，把刚同步的结果盖回去。
      await library.addHistory({
        'id': 'via-full',
        'kind': 'book',
        'title': '整包',
        'time': 4000,
        'episode': 1,
        'progress': 0.2,
      });

      await service.sync(config, password: '');

      expect(transport.puts, contains(ProgressShard.fileName));
      final decoded = ProgressShard.decode(
        transport.files[ProgressShard.fileName]!,
      );
      expect(decoded.history.map((e) => e['id']), contains('via-full'));
    });

    test('leaving a page uploads even when the cloud shard is unchanged', () async {
      // 第二次及以后离开阅读页时，云端已经有分片，`progressSyncedAt` 正好是
      // 上次推送的时刻。这时若 `_dirty` 仍是 false，三级闸门会落到「云端没动
      // + 本机没改」那条短路，这一页的进度永远推不上去，而且日志里一片安静。
      transport.files[ProgressShard.fileName] = ProgressShard.capture(
        const [],
      ).encode();
      transport.stamps[ProgressShard.fileName] = DateTime.now().toUtc();
      // 闸门比的是版本，不是时间：记下云端当前那一版。
      await WebdavConfigStore.instance.markProgressVersion(
        transport.tagOf(ProgressShard.fileName),
      );
      await WebdavConfigStore.instance.save(config);
      await library.addHistory({
        'id': 'left-page',
        'kind': 'book',
        'title': '读完退出',
        'time': 6000,
        'episode': 5,
        'progress': 0.6,
      });
      final auto = WebdavAutoSync(
        service: service,
        transport: (config, password) => transport,
      );
      addTearDown(auto.dispose);

      expect(await auto.syncOnLeave(), isTrue);

      expect(transport.puts, [ProgressShard.fileName]);
      final decoded = ProgressShard.decode(
        transport.files[ProgressShard.fileName]!,
      );
      expect(decoded.history.map((e) => e['id']), contains('left-page'));
    });

    test('a background exit within a day only pushes the shard', () async {
      // 整包已经同步过、冷数据没动 → 退出时只推进度。否则「读两页就退出」
      // 会把整个书库重传一遍。
      await WebdavConfigStore.instance.save(config);
      await WebdavConfigStore.instance.markSynced(DateTime.now());
      await library.addHistory({
        'id': 'exit-only',
        'kind': 'book',
        'title': '退出',
        'time': 5000,
        'episode': 2,
        'progress': 0.3,
      });
      final auto = WebdavAutoSync(
        service: service,
        transport: (config, password) => transport,
      );
      addTearDown(auto.dispose);

      await auto.flush();

      expect(transport.puts, [ProgressShard.fileName]);
    });

    test('a shelf change forces the whole snapshot out', () async {
      // 书架是冷数据，只推进度分片的话删掉的书要等一天才会上云。
      await WebdavConfigStore.instance.save(config);
      await WebdavConfigStore.instance.markSynced(DateTime.now());
      final auto = WebdavAutoSync(
        service: service,
        transport: (config, password) => transport,
      );
      addTearDown(auto.dispose);
      auto.markDirty(full: true);

      await auto.flush();

      expect(transport.puts, contains(''));
    });
  });
}
