import 'dart:async';
import 'dart:isolate';
import 'dart:typed_data';

import '../models/library_backup.dart';
import '../models/progress_shard.dart';
import 'app_log.dart';
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

  /// 条件写被拒（412）后最多重来几次。
  ///
  /// 412 不是故障：它的意思正是「你读到的版本已经不是最新」，也就是我们
  /// 想要的那种保护起作用了。重来一次就会读到对方的版本、合并、再写；
  /// 连续两次都撞上说明两台设备在密集交替写，那种情况下再重试也只是延长
  /// 竞争，交给下一次触发更划算。
  static const maxConditionalRetries = 2;

  /// 只同步进度分片（热路径），理想情况两个往返。
  ///
  /// 三级闸门（判据是**版本字符串是否相同**，不是谁的时间更新）：
  /// 1. 云端版本与本机记录的不一样 → GET + 合并 + PUT（3 个往返，只在真的
  ///    有另一台设备写过、或本机还不知道云端是哪一版时发生）；
  /// 2. 版本相同、本机也没改 → PROPFIND 之后直接返回（1 个往返）；
  /// 3. 版本相同、本机改过 → 带 `If-Match` 直传（2 个往返，离开阅读页的常态）。
  ///
  /// 第 3 条是分片真正的收益：进度是「指针」，值可以被覆盖，只要确认云端
  /// 没被别人改过就不必先读回来。整包里的书架/已看是并集语义，做不到这一点。
  ///
  /// `If-Match` 是第 3 条的安全网：PROPFIND 与 PUT 之间仍有一个窗口期，
  /// 服务器如果认这个头，就会在那一刻返回 412，于是我们退回第 1 条重来。
  Future<ProgressSyncReport> syncProgress(
    WebdavConfig config, {
    required String password,
    required bool localDirty,
  }) async {
    final transport = _transport(config, password);
    try {
      await transport.ensureCollection();
      var attempt = 0;
      while (true) {
        try {
          return await _progressPass(transport, localDirty: localDirty);
        } on WebdavException catch (error) {
          if (error.statusCode != 412 || attempt >= maxConditionalRetries) {
            rethrow;
          }
          attempt++;
          AppLog.i(
            'webdav-sync',
            '进度写回时云端已被改动，重新合并后重试（第 $attempt 次）',
          );
        }
      }
    } finally {
      transport.close();
    }
  }

  Future<ProgressSyncReport> _progressPass(
    WebdavTransport transport, {
    required bool localDirty,
  }) async {
    final remote = await transport.remoteFile(name: ProgressShard.fileName);
    var merged = 0;
    String? ifMatch;
    if (remote == null) {
      // 迁移：云端还没有分片，但整包里可能已经有另一台设备的进度。
      // 先合并进来再写分片，否则第一台升级的设备会把对方覆盖掉。
      final legacy = await transport.download();
      if (legacy != null) merged += await _restoreFullHistory(legacy.bytes);
    } else {
      final known = await _config.progressVersion();
      final sameVersion = known != null && known == remote.versionKey;
      if (!sameVersion) {
        // 云端可能被别的设备改过，也可能只是本机不知道它是哪一版。两种
        // 情况都读回来合并：合并是并集语义，多读一次不会丢东西。
        final latest = await transport.download(name: ProgressShard.fileName);
        if (latest != null) merged += await _restoreProgress(latest.bytes);
        ifMatch = latest?.versionKey ?? remote.versionKey;
      } else {
        if (!localDirty) return (history: 0, uploadedBytes: 0);
        ifMatch = remote.versionKey;
      }
    }
    final history = await _backups.captureProgress();
    final bytes = await Isolate.run(
      () => ProgressShard.capture(history).encode(),
    );
    var version = await transport.upload(
      bytes,
      name: ProgressShard.fileName,
      ifMatch: ifMatch,
    );
    // 服务器不回 ETag（坚果云就不回）时回读一次。多一个往返，换来下一次
    // 同步能直接走第 3 条闸门；不回读的话本机永远不知道「刚写的是哪一版」，
    // 于是每次都会退化成第 1 条的完整读回。
    version ??= (await transport.remoteFile(
      name: ProgressShard.fileName,
    ))?.versionKey;
    await _config.markProgressVersion(version);
    await _config.markProgressSynced(DateTime.now());
    return (history: merged, uploadedBytes: bytes.length);
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
      var attempt = 0;
      while (true) {
        try {
          return await _fullPass(transport);
        } on WebdavException catch (error) {
          if (error.statusCode != 412 || attempt >= maxConditionalRetries) {
            rethrow;
          }
          attempt++;
          AppLog.i(
            'webdav-sync',
            '整包写回时云端已被改动，重新合并后重试（第 $attempt 次）',
          );
        }
      }
    } finally {
      transport.close();
    }
  }

  /// 一次「读云端 → 合并 → 带版本写回」。
  ///
  /// `If-Match` 用刚读到的那一版：如果另一台设备在这期间写了，服务器回
  /// 412，[_syncOnce] 会重新进来读一遍再合并。这不是重试网络错误，而是
  /// 把「谁后写谁赢」换成「后写的人先看到对方的改动」。
  Future<WebdavSyncReport> _fullPass(WebdavTransport transport) async {
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
    var version = await transport.upload(bytes, ifMatch: remote?.versionKey);
    version ??= (await transport.remoteFile())?.versionKey;
    await _config.markFullVersion(version);
    // 整包里也带着进度，顺手把热路径分片写成同一份内容。
    // 不这么做的话，刚同步完整包、进度分片还停在旧值，下一次「离开阅读页」
    // 会推一份过期数据上去。
    final progressBytes = await Isolate.run(
      () => ProgressShard.capture(snapshot.history).encode(),
    );
    final progressRemote = await transport.remoteFile(
      name: ProgressShard.fileName,
    );
    var progressVersion = await transport.upload(
      progressBytes,
      name: ProgressShard.fileName,
      ifMatch: progressRemote?.versionKey,
    );
    progressVersion ??= (await transport.remoteFile(
      name: ProgressShard.fileName,
    ))?.versionKey;
    await _config.markProgressVersion(progressVersion);
    await _config.markSynced(DateTime.now());
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
