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

  /// 整包替换用的临时文件与上一版，与主文件同目录。
  ///
  /// 后缀放在末尾（`fqapp-sync.json.tmp`）：目录里一眼能看出它属于哪个文件，
  /// 而且不会和用户自己配的文件名撞上（配置项必须以 `.json` 结尾）。
  static const tempSuffix = '.tmp';
  static const backupSuffix = '.bak';

  /// 另一台设备正在做三步替换时，主文件会短暂不存在。
  ///
  /// 读取方撞上 404 后等这么久再看一次，而不是立刻当成「首次同步」——后者
  /// 会无条件把本机数据推上去，正好盖掉对方刚写的那一份。
  static const replaceWindowRetry = Duration(milliseconds: 400);

  static String siblingOf(WebdavConfig config, String suffix) =>
      '${config.fileName}$suffix';

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
      // 同 _syncOnce：412 会重新读合并，上一轮合并进本机的条目不会在下一轮
      // 再出现，计数必须跨轮累加。
      var carried = 0;
      var attempt = 0;
      while (true) {
        final prepared = await _progressPrepare(
          transport,
          localDirty: localDirty,
        );
        carried += prepared.merged;
        final bytes = prepared.bytes;
        if (bytes == null) {
          return (history: carried, uploadedBytes: 0);
        }
        try {
          await _progressWrite(
            transport,
            bytes,
            ifMatch: prepared.ifMatch,
          );
          await _config.markProgressSynced(DateTime.now());
          return (history: carried, uploadedBytes: bytes.length);
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

  /// 读云端分片并合并；`bytes` 为 null 表示「云端没变、本机也没改」，
  /// 这一趟什么都不用写。
  Future<({int merged, Uint8List? bytes, String? ifMatch})> _progressPrepare(
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
        if (!localDirty) return (merged: merged, bytes: null, ifMatch: null);
        ifMatch = remote.versionKey;
      }
    }
    final history = await _backups.captureProgress();
    final bytes = await Isolate.run(
      () => ProgressShard.capture(history).encode(),
    );
    return (merged: merged, bytes: bytes, ifMatch: ifMatch);
  }

  /// 写分片并记下新版本。
  ///
  /// 服务器不回 ETag（坚果云就不回）时回读一次。多一个往返，换来下一次
  /// 同步能直接走「版本相同直传」那条闸门；不回读的话本机永远不知道
  /// 「刚写的是哪一版」，于是每次都会退化成完整读回。
  Future<void> _progressWrite(
    WebdavTransport transport,
    Uint8List bytes, {
    String? ifMatch,
  }) async {
    var version = await transport.upload(
      bytes,
      name: ProgressShard.fileName,
      ifMatch: ifMatch,
    );
    version ??= (await transport.remoteFile(
      name: ProgressShard.fileName,
    ))?.versionKey;
    await _config.markProgressVersion(version);
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
      // 412 之后会「重新读、重新合并、再写」，而上一轮合并进本机的条目
      // 不会在下一轮的 merge 里再出现一次 —— 所以计数必须跨轮累加，
      // 否则重试过的同步会少报（极端情况下报成 0，看起来像什么都没同步）。
      var carried = (
        shelf: 0,
        history: 0,
        episodes: 0,
        readTime: 0,
        searchHistory: 0,
      );
      var remoteExisted = false;
      DateTime? remoteModified;
      var attempt = 0;
      while (true) {
        final prepared = await _prepare(transport, config);
        carried = (
          shelf: carried.shelf + prepared.merged.shelf,
          history: carried.history + prepared.merged.history,
          episodes: carried.episodes + prepared.merged.episodes,
          readTime: carried.readTime + prepared.merged.readTime,
          searchHistory: carried.searchHistory + prepared.merged.searchHistory,
        );
        remoteExisted = prepared.remoteExisted;
        remoteModified = prepared.remoteModified;
        try {
          await _commit(
            transport,
            config,
            bytes: prepared.bytes,
            history: prepared.snapshot.history,
            ifMatch: prepared.versionKey,
          );
          return (
            remoteExisted: remoteExisted,
            remoteModified: remoteModified,
            uploadedBytes: prepared.bytes.length,
            shelf: carried.shelf,
            history: carried.history,
            episodes: carried.episodes,
            readTime: carried.readTime,
            searchHistory: carried.searchHistory,
          );
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

  /// 不管云端是什么，直接用本机数据覆盖它。
  ///
  /// 坏文件的最后出口：主文件读不懂、`.bak` 也没有（或也坏了）时，自动回退
  /// 救不回来，用户至少还能把本机这份好的推上去。没有这个按钮，唯一的办法
  /// 是去网盘网页端手动删文件 —— 而多数用户既不知道该删哪个，也不知道删掉
  /// 之后另一台设备会怎样。
  ///
  /// 不带 `If-Match`：这是用户明确要求的「以本机为准」，不是并发写，不该被
  /// 一次版本不符挡回去。旧文件仍然会被挪进 `.bak`，所以还能取回。
  Future<WebdavSyncReport> overwriteRemote(
    WebdavConfig config, {
    required String password,
  }) async {
    final transport = _transport(config, password);
    try {
      await transport.ensureCollection();
      final snapshot = await _backups.capture();
      final bytes = await Isolate.run(snapshot.encode);
      final version = await _writeAtomically(transport, config, bytes);
      await _config.markFullVersion(version);
      final progressBytes = await Isolate.run(
        () => ProgressShard.capture(snapshot.history).encode(),
      );
      final writtenProgress = await transport.upload(
        progressBytes,
        name: ProgressShard.fileName,
      );
      await _config.markProgressVersion(
        writtenProgress ??
            (await transport.remoteFile(
              name: ProgressShard.fileName,
            ))?.versionKey,
      );
      final now = DateTime.now();
      await _config.markSynced(now);
      await _config.markProgressSynced(now);
      return (
        remoteExisted: true,
        remoteModified: (await transport.remoteFile())?.modified ?? now,
        uploadedBytes: bytes.length,
        shelf: snapshot.shelf.length,
        history: snapshot.history.length,
        episodes: snapshot.watched.length,
        readTime: snapshot.daily.length,
        searchHistory: snapshot.searchHistory.length,
      );
    } finally {
      transport.close();
    }
  }

  /// 读云端、合并进本机，并算出这次要写上去的字节。
  ///
  /// 与写回分开，是为了让 412 重试时能「重新读一遍再合并」—— 上一轮的合并
  /// 结果已经在本地数据里，所以每一轮都必须重新 capture，不能复用上一次的
  /// 字节。
  ///
  /// 读回带两层兜底：撞上替换窗口时等一下再看（[_downloadPrimary]），主文件
  /// 读不懂时退到上一版（[_decodeWithBackup]）。这两条合起来，才让「一次失败
  /// 的上传」不再等于「两台设备永远锁死」。
  Future<({
    LibraryBackup snapshot,
    Uint8List bytes,
    ({int shelf, int history, int episodes, int readTime, int searchHistory})
    merged,
    String? versionKey,
    bool remoteExisted,
    DateTime? remoteModified,
  })>
  _prepare(WebdavTransport transport, WebdavConfig config) async {
    final primary = await _downloadPrimary(transport, config);
    var merged = (
      shelf: 0,
      history: 0,
      episodes: 0,
      readTime: 0,
      searchHistory: 0,
    );
    if (primary != null) {
      merged = await _backups.restore(
        await _decodeWithBackup(transport, config, primary),
      );
    }
    final snapshot = await _backups.capture();
    final bytes = await Isolate.run(snapshot.encode);
    return (
      snapshot: snapshot,
      bytes: bytes,
      merged: merged,
      versionKey: primary?.versionKey,
      remoteExisted: primary != null,
      remoteModified: primary?.modified,
    );
  }

  /// 把合并后的快照原子写回，并顺手刷新热路径分片。
  Future<void> _commit(
    WebdavTransport transport,
    WebdavConfig config, {
    required Uint8List bytes,
    required List<Map<String, dynamic>> history,
    String? ifMatch,
  }) async {
    final version = await _writeAtomically(
      transport,
      config,
      bytes,
      ifMatch: ifMatch,
    );
    await _config.markFullVersion(version);
    // 整包里也带着进度，顺手把热路径分片写成同一份内容。
    // 不这么做的话，刚同步完整包、进度分片还停在旧值，下一次「离开阅读页」
    // 会推一份过期数据上去。
    //
    // 分片不走三步替换：它只有几十 KB、频率高，多三个往返不值得；而且它
    // 的内容能从整包重建，坏掉不是灾难 —— 整包才是。
    final progressBytes = await Isolate.run(
      () => ProgressShard.capture(history).encode(),
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
    final now = DateTime.now();
    await _config.markSynced(now);
    await _config.markProgressSynced(now);
  }

  /// 读整包；撞上「别人正在替换」的窗口时等一下重看一次。
  ///
  /// 三步替换中间有一个极短的时间窗，主文件被挪走、新文件还没挪回来。
  /// 把那个 404 当成「云端没有备份」会触发无条件上传，正好盖掉对方刚写的
  /// 数据 —— 所以这里用 `.bak` 是否存在来区分「第一次同步」和「正在替换」。
  Future<({Uint8List bytes, DateTime? modified, String? versionKey})?>
  _downloadPrimary(WebdavTransport transport, WebdavConfig config) async {
    final first = await transport.download();
    if (first != null) return first;
    final backupName = siblingOf(config, backupSuffix);
    if (await transport.remoteFile(name: backupName) == null) return null;
    await Future<void>.delayed(replaceWindowRetry);
    return transport.download();
  }

  /// 主文件读不懂时退到上一版。
  ///
  /// 这是「一次坏上传永久锁死」的出口：没有它，两台设备会各自在这里抛
  /// `FormatException` 并拒绝同步，而设置页只有「立即同步」和「清除配置」，
  /// 用户在应用里没有任何办法把云端那份坏文件换掉。
  Future<LibraryBackup> _decodeWithBackup(
    WebdavTransport transport,
    WebdavConfig config,
    ({Uint8List bytes, DateTime? modified, String? versionKey}) primary,
  ) async {
    try {
      return await _decode(primary.bytes);
    } on WebdavException {
      final backup = await transport.download(
        name: siblingOf(config, backupSuffix),
      );
      if (backup == null) rethrow;
      final snapshot = await _decode(backup.bytes);
      AppLog.w('webdav-sync', '云端主文件无法识别，已回退到上一版（.bak）继续合并');
      return snapshot;
    }
  }

  /// 三步替换：任何一步中断都不会留下被截断的主文件。
  ///
  /// 顺序是按坚果云的真实行为排的（实测：MOVE 不能覆盖已存在目标，回 409；
  /// `Overwrite` 头也不认）：
  ///
  ///   ① `PUT ${name}.tmp`      主文件全程不受影响，其它设备读到的还是旧版
  ///   ② `MOVE ${name}` → `.bak`  目标已删，能成功
  ///   ③ `MOVE .tmp` → `${name}`  此刻目标不存在，能成功
  ///
  /// 直接 PUT 主文件的问题不是「可能失败」，而是失败时**留下被截断的目标
  /// 文件**：连接在传输中途断掉，服务端保留半截内容，之后两台设备都读不懂
  /// 它，同步就此永久停摆。三步替换把最坏情况换成「主文件短暂不存在」，
  /// 而 `.bak` 与 `.tmp` 在任何时刻至少有一份是完整的。
  Future<String?> _writeAtomically(
    WebdavTransport transport,
    WebdavConfig config,
    Uint8List bytes, {
    String? ifMatch,
  }) async {
    final primaryName = config.fileName;
    final tempName = siblingOf(config, tempSuffix);
    final backupName = siblingOf(config, backupSuffix);

    await transport.upload(bytes, name: tempName);
    final written = await transport.remoteFile(name: tempName);
    final size = written?.size;
    if (size != null && size != bytes.length) {
      await _deleteQuietly(transport, tempName);
      throw WebdavException(
        '上传被截断：云端只收到 $size 字节，应为 ${bytes.length} 字节，'
        '已放弃本次替换，云端文件保持原样',
      );
    }

    // MOVE 不评估 If-Match（坚果云对任何 MOVE 都回 409，分不清是「目标存在」
    // 还是「版本不符」），所以条件检查只能在这里显式做一次。
    final current = await transport.remoteFile(name: primaryName);
    if (ifMatch != null && current != null && current.versionKey != ifMatch) {
      await _deleteQuietly(transport, tempName);
      throw const WebdavException(
        '云端文件已被其它设备更新，本次写入已取消，稍后会自动重试',
        statusCode: 412,
      );
    }

    // 上一轮的 .bak 还在的话，MOVE 会因为目标存在而 409。
    await _deleteQuietly(transport, backupName);
    var movedAside = false;
    try {
      if (current != null) {
        await transport.move(from: primaryName, to: backupName);
        movedAside = true;
      }
      await transport.move(from: tempName, to: primaryName);
    } catch (error) {
      // 主文件已经挪走、新文件没挪回来：把它挪回去，不留下空洞。
      if (movedAside) {
        try {
          await transport.move(from: backupName, to: primaryName);
        } on WebdavException {
          // 连恢复都失败，至少 .bak 还在 —— 页面上「用本机覆盖云端」还救得回来。
          AppLog.w('webdav-sync', '替换失败且无法自动恢复，旧数据仍在 .bak 里', error: error);
        }
      }
      await _deleteQuietly(transport, tempName);
      rethrow;
    }
    return (await transport.remoteFile(name: primaryName))?.versionKey;
  }

  Future<void> _deleteQuietly(WebdavTransport transport, String name) async {
    try {
      await transport.delete(name: name);
    } on WebdavException {
      // 清理失败不该盖掉真正的原因。
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
