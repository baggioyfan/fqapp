import 'dart:async';
import 'dart:isolate';
import 'dart:typed_data';

import '../models/library_backup.dart';
import '../models/progress_shard.dart';
import 'library_backup_service.dart';
import 'webdav_client.dart';
import 'webdav_config.dart';

/// What one sync did, in the shape the settings page reports.
typedef WebdavSyncReport = ({
  bool remoteExisted,
  DateTime? remoteModified,
  int uploadedBytes,
  int shelf,
  int history,
  int episodes,
  int readTime,
  int searchHistory,
});

/// 进度分片的一次同步：合并了几条、写上去多少字节。
typedef ProgressSyncReport = ({int history, int uploadedBytes});

/// Builds the transport for one sync, so tests can substitute an in-memory
/// server for a real one.
typedef WebdavTransportFactory = WebdavTransport Function(
  WebdavConfig config,
  String password,
);

/// Two-way sync of one snapshot file: pull, merge, push.
///
/// The merge rules live in `LibraryBackupService.restore`, so this only has to
/// order the steps: read the remote file, merge it into this device's data, and
/// write the merged snapshot back. Writing back unconditionally is what makes
/// a second device converge - the remote ends up holding the union of both
/// devices instead of whichever one synced last.
///
/// The merged snapshot never overwrites a remote file that could not be read:
/// a truncated or foreign file aborts the sync before the upload, so a bad
/// upload on one device cannot propagate to the other.
class WebdavSyncService {
  WebdavSyncService({
    LibraryBackupService? backups,
    WebdavTransportFactory? transport,
  }) : _backups = backups ?? LibraryBackupService(),
       _transport = transport ?? _webdavTransport;

  static WebdavTransport _webdavTransport(
    WebdavConfig config,
    String password,
  ) => WebdavClient(config: config, password: password);

  final LibraryBackupService _backups;
  final WebdavTransportFactory _transport;
  final _config = WebdavConfigStore.instance;

  /// HTTP 日期只精确到秒，两台设备的时钟也可能差几秒。
  static const clockTolerance = Duration(seconds: 60);

  /// 只同步进度分片（热路径），最多两个往返。
  ///
  /// 三级闸门：
  /// 1. 云端比本机上次进度同步新 → GET + 合并 + PUT（3 个往返，但只在真的
  ///    有另一台设备写过时发生）；
  /// 2. 云端没变、本机也没改 → PROPFIND 之后直接返回（1 个往返）；
  /// 3. 云端没变、本机改过 → 跳过 GET 直传（2 个往返，离开阅读页的常态）。
  ///
  /// 第 3 条是分片真正的收益：进度是「指针」，值可以被覆盖，只要确认云端
  /// 没被别人改过就不必先读回来。整包里的书架/已看是并集语义，做不到这一点。
  Future<ProgressSyncReport> syncProgress(
    WebdavConfig config, {
    required String password,
    required bool localDirty,
  }) async {
    final transport = _transport(config, password);
    try {
      await transport.ensureCollection();
      final remoteModified = await transport.remoteModified(
        name: ProgressShard.fileName,
      );
      var merged = 0;
      if (remoteModified == null) {
        // 迁移：云端还没有分片，但整包里可能已经有另一台设备的进度。
        // 先合并进来再写分片，否则第一台升级的设备会把对方覆盖掉。
        final legacy = await transport.download();
        if (legacy != null) merged += await _restoreFullHistory(legacy.bytes);
      } else {
        final last = await _config.progressSyncedAt();
        final cloudAhead =
            last == null || remoteModified.isAfter(last.add(clockTolerance));
        if (cloudAhead) {
          final remote = await transport.download(
            name: ProgressShard.fileName,
          );
          if (remote != null) merged += await _restoreProgress(remote.bytes);
        } else if (!localDirty) {
          return (history: 0, uploadedBytes: 0);
        }
      }
      final history = await _backups.captureProgress();
      final bytes = await Isolate.run(
        () => ProgressShard.capture(history).encode(),
      );
      await transport.upload(bytes, name: ProgressShard.fileName);
      await _config.markProgressSynced(DateTime.now());
      return (history: merged, uploadedBytes: bytes.length);
    } finally {
      transport.close();
    }
  }

  Future<int> _restoreProgress(Uint8List bytes) async {
    try {
      final shard = await Isolate.run(() => ProgressShard.decode(bytes));
      return _backups.restoreHistory(shard.history);
    } on FormatException catch (error) {
      throw WebdavException(
        '云端的进度文件无法识别（${error.message}），已停止同步，云端文件未被改动',
      );
    }
  }

  Future<int> _restoreFullHistory(Uint8List bytes) async =>
      _backups.restoreHistory((await _decode(bytes)).history);

  /// 同一时刻只跑一次同步。手动按钮与「退到后台自动同步」可能撞上，
  /// 两次「读云端 → 合并 → 写回」交错，结果就取决于谁最后上传。
  /// 排队而不是丢弃：手动那次不该被静默跳过。
  static Future<void> _queue = Future<void>.value();
  static int _pending = 0;

  /// 有同步正在排队或进行中。自动同步用它让位于手动同步。
  static bool get isSyncing => _pending > 0;

  /// [password] may be empty: a server that allows anonymous access needs no
  /// credentials, and an empty account is still sent as HTTP Basic.
  Future<WebdavSyncReport> sync(
    WebdavConfig config, {
    required String password,
  }) {
    final previous = _queue;
    final gate = Completer<void>();
    _queue = gate.future;
    _pending++;
    return _run(previous, gate, config, password);
  }

  Future<WebdavSyncReport> _run(
    Future<void> previous,
    Completer<void> gate,
    WebdavConfig config,
    String password,
  ) async {
    // previous 只可能是上一条 gate.future，永远不会带错误抛出。
    await previous;
    try {
      return await _syncOnce(config, password: password);
    } finally {
      _pending--;
      gate.complete();
    }
  }

  Future<WebdavSyncReport> _syncOnce(
    WebdavConfig config, {
    required String password,
  }) async {
    final transport = _transport(config, password);
    try {
      await transport.ensureCollection();
      final remote = await transport.download();
      var merged = (
        shelf: 0,
        history: 0,
        episodes: 0,
        readTime: 0,
        searchHistory: 0,
      );
      if (remote != null) {
        merged = await _backups.restore(await _decode(remote.bytes));
      }
      final snapshot = await _backups.capture();
      final bytes = await Isolate.run(snapshot.encode);
      await transport.upload(bytes);
      // 整包里也带着进度，顺手把热路径分片写成同一份内容。
      // 不这么做的话，刚同步完整包、进度分片还停在旧值，下一次「离开阅读页」
      // 会推一份过期数据上去。
      final progressBytes = await Isolate.run(
        () => ProgressShard.capture(snapshot.history).encode(),
      );
      await transport.upload(progressBytes, name: ProgressShard.fileName);
      await _config.markProgressSynced(DateTime.now());
      return (
        remoteExisted: remote != null,
        remoteModified: remote?.modified,
        uploadedBytes: bytes.length,
        shelf: merged.shelf,
        history: merged.history,
        episodes: merged.episodes,
        readTime: merged.readTime,
        searchHistory: merged.searchHistory,
      );
    } finally {
      transport.close();
    }
  }

  /// Decoding runs off the main isolate because a large snapshot is a lot of
  /// JSON; a file this device cannot read stops the sync instead of being
  /// replaced by local data.
  Future<LibraryBackup> _decode(Uint8List bytes) async {
    try {
      return await Isolate.run(() => LibraryBackup.decode(bytes));
    } on FormatException catch (error) {
      throw WebdavException(
        '云端的备份文件无法识别（${error.message}），已停止同步，云端文件未被改动',
      );
    }
  }
}

/// 「收藏 3 条、进度 2 条…」这一段。手动同步页和退到后台的自动同步共用同一份
/// 措辞，免得两处对同一次同步给出不同的说法。
String syncCounts(WebdavSyncReport report) =>
    '收藏 ${report.shelf} 条、进度 ${report.history} 条、'
    '已看 ${report.episodes} 集、阅读时长 ${report.readTime} 项、'
    '搜索历史 ${report.searchHistory} 条';

/// 一次同步的结果说明。`brief` 用于没有页面上下文的场合（自动同步的提示）。
String describeSyncReport(WebdavSyncReport report, {bool brief = false}) {
  final size = '${(report.uploadedBytes / 1024).toStringAsFixed(1)} KB';
  if (brief) {
    return report.remoteExisted
        ? '已同步：${syncCounts(report)}（$size 写回云端）'
        : '云端还没有备份文件，已把本机数据上传（共 $size）';
  }
  if (!report.remoteExisted) {
    // Nothing was merged, so every count in [report] is zero. Printing them
    // after "已把本机数据上传" would read as "nothing was uploaded", which is
    // the opposite of what happened.
    return '云端还没有备份文件，已把本机数据上传（共 $size）。'
        '在另一台手机打开本页点「立即同步」即可拿到这些数据。';
  }
  return '已从云端合并：${syncCounts(report)}；并把合并后的结果（$size）写回云端。'
      '同一作品保留读得更靠后的进度，收藏与已看取并集。';
}
