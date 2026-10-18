import 'dart:async';
import 'dart:isolate';
import 'dart:typed_data';

import 'package:http/http.dart' as http;

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

/// 内容指纹，用来回答「云端那份还是我上次写上去的那份吗」。
///
/// 不用服务端 etag：它只有服务端算得出来，而写操作（PUT/MOVE）实测都不
/// 回传 ETag —— 想知道「刚写的是哪一版」就得再问一次服务端。写出去的
/// 字节在本机手里，自己算一个就够：下次 GET 回来算一遍，相同即同一份。
///
/// 这里是两条独立的 32 位 FNV-1a（不同初值）拼起来，共 64 位。全程在
/// 32 位内运算：不依赖 64 位溢出的回绕语义，也不受 Dart web 上 int 只有
/// 53 位精度的影响。用途只是「相同 / 不同」，不是抗碰撞 —— 没人有动机
/// 构造一份指纹相同但内容不同的备份。
String digestOf(Uint8List bytes) {
  var a = 0x811c9dc5;
  var b = 0x9e3779b9;
  for (final byte in bytes) {
    a = ((a ^ byte) * 0x01000193) & 0xffffffff;
    b = ((b ^ byte) * 0x01000193) & 0xffffffff;
  }
  return '${bytes.length}-${a.toRadixString(16)}-${b.toRadixString(16)}';
}

/// 同步队列的状态。
///
/// 以前只有一个 `isSyncing` 布尔量，页面上能表达的只有「在跑 / 没跑」。
/// 拆开之后「排队中」可以说出口：用户点了按钮却看着上一个任务收尾，那里
/// 本来该显示「排队中」，而不是让按钮一直转圈。
enum SyncRunState { idle, queued, running }

/// 谁发起的这次同步。
///
/// 只在排队时起作用：手动同步（设置页按钮、打开应用时的提示弹窗）会把
/// **还在排队、尚未开始**的后台任务直接作废 —— 手动这次会把它们要做的事
/// 一起做掉，让用户等一个后台任务收尾没有意义。
///
/// 已经在跑的任务不会被抢断：「读 → 合并 → 写」中途换人，正是这套闸门
/// 一开始要防的那种交错。
enum SyncPriority { manual, background }

/// 队列里的一个位置。
class _SyncJob {
  _SyncJob(this.priority);

  final SyncPriority priority;

  /// 轮到自己跑完了（或没跑就被作废）。排在后面的任务等的是它。
  final Completer<void> finished = Completer<void>();

  /// 还没开始就被手动同步取代了。
  ///
  /// 单独一个信号，是为了让被取代的那个**立刻**醒来：它当时正挂着等前一个
  /// 任务，如果只能等那个 future 完成，用户还是得看完整整一轮后台同步才会
  /// 收到「已跳过」。
  final Completer<void> cancelled = Completer<void>();

  bool get dropped => cancelled.isCompleted;
}

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
    this.budget = defaultBudget,
  }) : _backups = backups ?? LibraryBackupService(),
       _injected = transport;

  /// 一次同步的总时长上限。
  ///
  /// 单个请求已经各自有超时（见 `WebdavClient`），但一次整包同步最多六个
  /// 往返，三步替换还要再加两次 MOVE；逐个超时叠起来能到好几分钟。而
  /// 「很久」和「卡死」在页面上长得一样。这里给整趟一个预算，超了就中止
  /// 并关掉连接 —— 关连接会立刻打断挂起的请求，排队中的下一次同步才真正
  /// 开始得了。
  static const defaultBudget = Duration(seconds: 90);

  final Duration budget;

  final LibraryBackupService _backups;
  final WebdavTransportFactory? _injected;

  /// 延迟解析：没注入时才用自己那条连接，测试注入假 transport 时连
  /// `http.Client` 都不会创建。
  late final WebdavTransportFactory _transport = _injected ?? _ownTransport;

  /// 复用的底层连接。
  ///
  /// 以前每次同步都新建一个 `http.Client` 再关掉，也就是每次都要重做一次
  /// TCP + TLS 握手 —— 而热路径一共才三个往返，握手常常比它们加起来还贵，
  /// 手机上还会把射频从空闲唤醒一次。
  ///
  /// 懒建：只用假 transport 的测试根本不碰网络，不该为它创建连接。
  http.Client? _connection;

  http.Client get _httpClient => _connection ??= http.Client();

  /// 关掉复用的连接。之后再用会重新建一个，所以调用方不必操心顺序。
  void close() {
    _connection?.close();
    _connection = null;
  }

  WebdavTransport _ownTransport(WebdavConfig config, String password) =>
      WebdavClient(config: config, password: password, client: _httpClient);

  /// 超时后真的打断挂起的请求。
  ///
  /// 只调 `transport.close()` 是不够的：连接是复用的，`WebdavClient` 并不
  /// 拥有它，那一下什么都不会关，挂起的请求会一直留在后台 —— 队列看起来
  /// 空了，实际上下一次同步只是又接上了一条半死的连接。这里连复用连接
  /// 一起丢掉，下一次同步重建。
  void Function() _expireWith(WebdavTransport transport) => () {
    transport.close();
    close();
  };

  final _config = WebdavConfigStore.instance;

  /// 已经确认过（必要时创建过）的目录，形如 `url|文件名`。
  ///
  /// 「目录不在就建一个」是第一次连上时要干的事；之后每次同步再问一遍
  /// 纯属浪费一个往返，而这里连的从头到尾是同一个地址。目录真被删掉时，
  /// 后续请求会以 404/409 暴露出来 —— 失败路径会清掉这个标记，下一趟
  /// 重新确认。
  String? _readyCollection;

  Future<void> _ensureCollection(
    WebdavTransport transport,
    WebdavConfig config,
  ) async {
    final key = '${config.collectionUrl}|${config.fileName}';
    if (_readyCollection == key) return;
    await transport.ensureCollection();
    _readyCollection = key;
  }

  void _forgetCollection() => _readyCollection = null;

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
    SyncPriority priority = SyncPriority.manual,
  }) => _schedule(
    priority,
    () => _progressOnce(config, password: password, localDirty: localDirty),
  );

  Future<ProgressSyncReport> _progressOnce(
    WebdavConfig config, {
    required String password,
    required bool localDirty,
  }) async {
    final transport = _transport(config, password);
    try {
      return await _withBudget(
        () => _progressPasses(transport, config, localDirty: localDirty),
        onExpire: _expireWith(transport),
      );
    } on WebdavException {
      // 任何一次失败都可能是「目录真的没了」，让下一趟重新确认一遍。
      _forgetCollection();
      rethrow;
    } finally {
      transport.close();
    }
  }

  Future<ProgressSyncReport> _progressPasses(
    WebdavTransport transport,
    WebdavConfig config, {
    required bool localDirty,
  }) async {
    await _ensureCollection(transport, config);
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
  }

  /// 读云端分片并合并；`bytes` 为 null 表示「云端没变、本机也没改」，
  /// 这一趟什么都不用写。
  ///
  /// 只发一次 GET：内容、大小和版本标识一起回来（RFC 要求 GET 带 ETag，
  /// 坚果云实测有）。以前是「先 PROPFIND 判版本、需要时再 GET」，同一份
  /// 信息要两个往返才拿到 —— 而热路径本来就要读内容做并集合并。
  Future<({int merged, Uint8List? bytes, String? ifMatch})> _progressPrepare(
    WebdavTransport transport, {
    required bool localDirty,
  }) async {
    final latest = await transport.download(name: ProgressShard.fileName);
    var merged = 0;
    String? ifMatch;
    if (latest == null) {
      // 迁移：云端还没有分片，但整包里可能已经有另一台设备的进度。
      // 先合并进来再写分片，否则第一台升级的设备会把对方覆盖掉。
      final legacy = await transport.download();
      if (legacy != null) merged += await _restoreFullHistory(legacy.bytes);
    } else {
      // 个别服务器只在 PROPFIND 上给 ETag。那种情况下补问一次，不能拿
      // 一个空的条件去覆盖别人的写入。
      ifMatch =
          latest.versionKey ??
          (await transport.remoteFile(name: ProgressShard.fileName))?.versionKey;
      final known = await _config.progressDigest();
      if (known == null || known != digestOf(latest.bytes)) {
        // 云端不是本机上次写上去的那一份：可能别的设备改过，也可能本机
        // 不知道它是哪一版。两种都读回来合并 —— 合并是并集语义，多读一次
        // 不会丢东西。
        merged += await _restoreProgress(latest.bytes);
      } else if (!localDirty) {
        return (merged: merged, bytes: null, ifMatch: null);
      }
    }
    final history = await _backups.captureProgress();
    final bytes = await Isolate.run(
      () => ProgressShard.capture(history).encode(),
    );
    return (merged: merged, bytes: bytes, ifMatch: ifMatch);
  }

  /// 写分片并记下「写出去的是哪一份」。
  ///
  /// 服务器不回 ETag（坚果云就不回），所以以前要再 PROPFIND 一次才能知道
  /// 新版本号。现在不问了：记下这串字节的内容指纹，下次 GET 回来算一遍，
  /// 一样就说明云端还是自己写的那份。少一个往返，也不必去猜服务端的
  /// etag 算法 —— 坚果云的 etag 虽然由内容决定，但不是 md5，本地算不出来。
  Future<void> _progressWrite(
    WebdavTransport transport,
    Uint8List bytes, {
    String? ifMatch,
  }) async {
    await transport.upload(
      bytes,
      name: ProgressShard.fileName,
      ifMatch: ifMatch,
    );
    await _config.markProgressDigest(digestOf(bytes));
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
  ///
  /// 队列是静态的：配置和凭据本来就是全局单例，两台设备之间也好、页面和
  /// 后台任务之间也好，同一份 WebDAV 目录同时只该有一条同步在写。
  static final List<_SyncJob> _jobs = <_SyncJob>[];
  static _SyncJob? _running;

  /// 队列现在的样子，供页面显示「排队中」还是「正在同步」。
  static SyncRunState get state {
    if (_running != null) return SyncRunState.running;
    return _jobs.isEmpty ? SyncRunState.idle : SyncRunState.queued;
  }

  /// 有同步正在排队或进行中。自动同步用它让位于手动同步。
  static bool get isSyncing => state != SyncRunState.idle;

  /// 排进队列、轮到它时执行 [body]。
  ///
  /// 手动任务会把还没开始的后台任务标成 dropped 并移出队列 —— 它的
  /// future 等到轮到自己时才抛出「已被取代」，所以调用方仍然能拿到一个
  /// 明确的失败，而不是永远挂着。
  Future<T> _schedule<T>(
    SyncPriority priority,
    Future<T> Function() body,
  ) async {
    if (priority == SyncPriority.manual) {
      for (final job in _jobs) {
        if (job.priority != SyncPriority.background) continue;
        if (!job.cancelled.isCompleted) job.cancelled.complete();
        // 它不会再跑了，排在它后面的任务不该继续等它。
        if (!job.finished.isCompleted) job.finished.complete();
      }
      _jobs.removeWhere((job) => job.dropped);
    }
    final job = _SyncJob(priority);
    _jobs.add(job);
    // 排队的那一刻就把「前面有谁」定下来。队列之后还会变（手动同步会抽走
    // 后台任务），但每个任务的 future 只会完成一次，按快照等就不会漏。
    final ahead = _jobs.sublist(0, _jobs.length - 1);
    try {
      for (final other in ahead) {
        await Future.any([other.finished.future, job.cancelled.future]);
        if (job.dropped) break;
      }
      if (job.dropped) {
        throw const WebdavException('本次后台同步已被手动同步取代，已跳过');
      }
      _running = job;
      return await body();
    } finally {
      if (identical(_running, job)) _running = null;
      _jobs.remove(job);
      if (!job.finished.isCompleted) job.finished.complete();
    }
  }

  /// 给 [body] 一个总时长上限；超时先用 [onExpire] 打断它，再以
  /// [WebdavException] 结束 —— 调用方看到的是一次正常失败，而不是一个
  /// 永远不会完成的 future。
  Future<T> _withBudget<T>(
    Future<T> Function() body, {
    required void Function() onExpire,
  }) {
    final result = Completer<T>();
    final timer = Timer(budget, () {
      if (result.isCompleted) return;
      onExpire();
      result.completeError(
        WebdavException(
          '同步超过 ${budget.inSeconds} 秒仍未完成，已中止。'
          '请检查网络后重试；云端文件未被改动。',
        ),
      );
    });
    body().then(
      (value) {
        if (!result.isCompleted) result.complete(value);
      },
      onError: (Object error, StackTrace stack) {
        if (!result.isCompleted) result.completeError(error, stack);
      },
    );
    return result.future.whenComplete(timer.cancel);
  }

  /// [password] may be empty: a server that allows anonymous access needs no
  /// credentials, and an empty account is still sent as HTTP Basic.
  Future<WebdavSyncReport> sync(
    WebdavConfig config, {
    required String password,
    SyncPriority priority = SyncPriority.manual,
  }) => _schedule(
    priority,
    () => _syncOnce(config, password: password),
  );

  Future<WebdavSyncReport> _syncOnce(
    WebdavConfig config, {
    required String password,
  }) async {
    final transport = _transport(config, password);
    try {
      // 整趟放进预算里：超时先关掉 transport，把挂起的请求打断，队列里的
      // 下一次同步才真的能开始 —— 否则它只是在等一个不会回来的应答。
      return await _withBudget(
        () => _mergedPasses(transport, config),
        onExpire: _expireWith(transport),
      );
    } on WebdavException {
      _forgetCollection();
      rethrow;
    } finally {
      transport.close();
    }
  }

  /// 读云端 → 合并 → 写回，412 时重来。
  ///
  /// 与 [_syncOnce] 分开，只是因为「超时了谁来关连接」必须留在外层手里。
  Future<WebdavSyncReport> _mergedPasses(
    WebdavTransport transport,
    WebdavConfig config,
  ) async {
    await _ensureCollection(transport, config);
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
  ///
  /// 仍然走同步队列：它做的也是「三步替换 + 写分片」，和一次普通同步交错在
  /// 一起同样会互相踩。（以前它绕开队列，正好是那条路径唯一的例外。）
  Future<WebdavSyncReport> overwriteRemote(
    WebdavConfig config, {
    required String password,
  }) => _schedule(
    SyncPriority.manual,
    () => _overwriteOnce(config, password: password),
  );

  Future<WebdavSyncReport> _overwriteOnce(
    WebdavConfig config, {
    required String password,
  }) async {
    final transport = _transport(config, password);
    try {
      return await _withBudget(
        () => _overwritePasses(transport, config),
        onExpire: _expireWith(transport),
      );
    } finally {
      transport.close();
    }
  }

  Future<WebdavSyncReport> _overwritePasses(
    WebdavTransport transport,
    WebdavConfig config,
  ) async {
    await _ensureCollection(transport, config);
    final snapshot = await _backups.capture();
    final bytes = await Isolate.run(snapshot.encode);
    final version = await _writeAtomically(transport, config, bytes);
    await _config.markFullVersion(version);
    final progressBytes = await Isolate.run(
      () => ProgressShard.capture(snapshot.history).encode(),
    );
    await transport.upload(
      progressBytes,
      name: ProgressShard.fileName,
    );
    await _config.markProgressDigest(digestOf(progressBytes));
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
    await transport.upload(
      progressBytes,
      name: ProgressShard.fileName,
      ifMatch: progressRemote?.versionKey,
    );
    await _config.markProgressDigest(digestOf(progressBytes));
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
