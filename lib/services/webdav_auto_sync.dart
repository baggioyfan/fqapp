import 'dart:async';

import 'app_log.dart';
import 'library_store.dart';
import 'secret_store.dart';
import 'webdav_client.dart';
import 'webdav_config.dart';
import 'webdav_sync_service.dart';

/// 一次「云端比本机新」的判断结果。只在真的需要提示时才存在。
class WebdavRemoteUpdate {
  const WebdavRemoteUpdate({
    required this.config,
    required this.password,
    required this.remoteModified,
    required this.lastSyncedAt,
  });

  final WebdavConfig config;
  final String password;

  /// 云端快照的 `Last-Modified`。
  final DateTime remoteModified;

  /// 本机上次成功同步的时刻；从未同步过时为 null。
  final DateTime? lastSyncedAt;
}

/// 打开时检查云端有没有更新，以及退到后台时自动同步一次。
///
/// 判据照 legado 的「闸门一」（`AppWebDav.downloadAllBookProgress`）：
/// 云端 `Last-Modified` 比本机上次成功同步的时刻更新，才认为「云端有更新」。
///
/// 不叫「本地旧」是有原因的：谁更新这件事读不出来 —— 进度是双闸门、收藏与
/// 已看是并集，真要判断就得把云端下载下来逐条合并，而那已经等于同步本身了。
/// 所以提示的语义只能是「云端可能有更新」。
class WebdavAutoSync {
  /// [service] 与 [transport] 可注入，测试用它们替换真实服务器；
  /// 配置与凭据走真正的单例（两者都是私有构造，没有别的实例可换）。
  WebdavAutoSync({
    WebdavSyncService? service,
    WebdavTransportFactory? transport,
  }) : _service = service ?? WebdavSyncService(),
       _transport = transport ?? _webdavTransport;

  /// 可替换，测试注入假 store / 假传输层。
  static WebdavAutoSync instance = WebdavAutoSync();

  /// HTTP 日期只精确到秒，两台设备的时钟也可能差几秒；这个窗口内算「就是
  /// 本机刚做的那一次」，不必提示。
  static const tolerance = Duration(seconds: 60);

  /// 两次自动同步之间至少隔这么久 —— 切一下通知栏也会触发 paused，
  /// 没有这个间隔就会把同步连成一串。
  static const minInterval = Duration(seconds: 30);

  /// 写入会停的场景用防抖：翻页、退出阅读、改书架都是「一阵一阵」的，
  /// 最后一次写入之后静默这么久才真正同步，中间的写入全部合并成一次。
  static const debounceWindow = Duration(minutes: 3);

  /// 暂停即同步：播放期间写入不会停，但「暂停」会让写入流断掉，这正是防抖
  /// 适用的场景（见 [markPlaybackPaused]）。暂停后短防抖再发，用来吸收
  /// 「播完 → 下一集」的 `false→true` 抖动，以及缓冲造成的假暂停。
  static const pauseDebounce = Duration(seconds: 20);

  /// 持续播放的安全兜底：播放从不暂停（后台听书、连播、投屏）时，进度只靠
  /// 这个间隔兜底上传。它是崩溃/被杀时的最大丢失窗口，所以不必太短 —— 本地
  /// 每 2 秒就落盘，换设备看也只是「下一次同步」的事，不必为它付出每 5 分钟
  /// 一次的上云流量。暂停推送会重置这个计时，连播时它不会和暂停抢着触发。
  static const playbackThrottle = Duration(minutes: 15);

  /// 整包（`fqapp-sync.json`）的最小间隔。
  ///
  /// 进度是秒级的，其余五项是分钟~天级的，所以整包不必跟着每次退到后台走。
  /// 到期只由三件事打断：冷数据改过（书架增删）、上次整包同步已经隔了一天、
  /// 或者从来没同步过。中间的退出全部只推 `progress.json`。
  ///
  /// 阅读时长虽然在整包里，但它按天累计，一天一次足够 —— 真按秒推，等于
  /// 把「翻一页」变成「上传整个书库」。
  static const fullSyncInterval = Duration(hours: 24);

  static WebdavTransport _webdavTransport(
    WebdavConfig config,
    String password,
  ) => WebdavClient(config: config, password: password);

  final WebdavSyncService _service;
  final WebdavTransportFactory _transport;
  final _config = WebdavConfigStore.instance;
  final _secrets = SecretStore.instance;

  DateTime? _lastAutoAt;
  DateTime? _lastPlaybackAt;
  Timer? _debounce;
  Timer? _pauseDebounce;
  bool _dirty = false;

  /// 冷数据（书架、墓碑、已看、阅读时长、搜索历史）改过，整包需要重写一次。
  bool _coldDirty = false;
  bool _progressBusy = false;

  /// 本机是否有还没推上去的进度改动。
  bool get isDirty => _dirty;

  /// 内容变了，安排一次防抖同步。
  ///
  /// 只标记、不立刻发请求：一次阅读会写入几十次进度，每次都同步等于把
  /// 整包反复 PUT。真正兜底的是应用退到后台那一次（见 [syncOnBackground]）。
  ///
  /// [delay] 让「用户主动操作」（改书架）比「连续写入」（翻页）更快落地。
  /// [full] 表示这次改动落在冷数据里（书架/已看），必须走整包同步。
  void markDirty({Duration delay = debounceWindow, bool full = false}) {
    _dirty = true;
    _coldDirty = _coldDirty || full;
    _debounce?.cancel();
    _debounce = Timer(delay, () {
      _debounce = null;
      unawaited(syncOnBackground(reason: 'debounce'));
    });
  }

  /// 后台播放专用的节流入口：写入不会停，所以按固定间隔放行。这是「从不暂停」
  /// 场景（后台听书、连播、投屏）的安全兜底，详见 [playbackThrottle]。
  void markPlaybackWrite() {
    _dirty = true;
    final now = DateTime.now();
    final last = _lastPlaybackAt;
    if (last != null && now.difference(last) < playbackThrottle) return;
    _lastPlaybackAt = now;
    _debounce?.cancel();
    _debounce = null;
    unawaited(syncProgressNow(reason: 'playback'));
  }

  /// 播放 → 暂停的跃迁：写入流断了，这是天然的结账点，比「每 5 分钟推一次」
  /// 更及时也更省流量。短防抖吸收抖动；若 20 秒内又播起来了，这次推送就取消
  /// （见 [cancelPlaybackPause]）。
  ///
  /// 暂停同时重置 [playbackThrottle] 的计时，所以连播（每集之间必有暂停/播完）
  /// 时兜底不会和暂停重复触发 —— 一集只推一次，而不是每 15 分钟再补一次。
  void markPlaybackPaused() {
    _dirty = true;
    _lastPlaybackAt = DateTime.now();
    _pauseDebounce?.cancel();
    _pauseDebounce = Timer(pauseDebounce, () {
      _pauseDebounce = null;
      unawaited(syncProgressNow(reason: 'pause'));
    });
  }

  /// 取消待发的「暂停推送」。两个时机：
  ///
  /// - 播放恢复：进度马上又会开始变化，20 秒前那次暂停不再是结账点；
  /// - 播放页关闭：`syncOnLeave` 已经立刻推过了，定时器成了纯冗余。
  void cancelPlaybackPause() {
    _pauseDebounce?.cancel();
    _pauseDebounce = null;
  }

  /// 离开阅读/播放页面时调用：取消防抖，立刻同步进度分片。
  ///
  /// 页面在离开前已经把进度落盘（`_persistProgress`），所以这里读到的是
  /// 最新值。只碰 `progress.json`，一次 PROPFIND + 一次 PUT。
  ///
  /// **必须自己置脏**：`_dirty` 只有 [markDirty] 和 [markPlaybackWrite] 会写，
  /// 而阅读页只在「切到后台」时才调 [markDirty]。正常读完按返回键离开走的是
  /// 这里，不置位的话三级闸门会落到「云端没动 + 本机没改」那条短路 ——
  /// 云端有分片、`progressSyncedAt` 又是上一次推送的时刻，于是这一页的进度
  /// 一条都推不上去，而且看起来一切正常。
  Future<bool> syncOnLeave() {
    _debounce?.cancel();
    _debounce = null;
    _dirty = true;
    return syncProgressNow(reason: 'leave');
  }

  /// 应用退到后台或即将被回收时调用：该结账的结账，该省的就省。
  Future<bool> flush() => syncOnBackground(reason: 'flush');

  /// 只推进度分片。三级闸门在 [WebdavSyncService.syncProgress] 里。
  Future<bool> syncProgressNow({String reason = 'progress'}) async {
    if (_progressBusy) return false;
    // 整包同步正在跑时让位：它自己会把进度一起写上去。
    if (WebdavSyncService.isSyncing) return false;
    _progressBusy = true;
    try {
      final config = await _config.load();
      if (config == null) return false;
      // 先等本机排队中的写入落盘，否则推上去的是上一秒的进度。
      await LibraryStore.instance.idle();
      final report = await _service.syncProgress(
        config,
        password: await _password(),
        localDirty: _dirty,
      );
      if (report.uploadedBytes > 0) {
        _dirty = false;
      }
      // 三级闸门的第 2 条会「什么都没做」地返回，那种情况不写日志 ——
      // 否则每次退出阅读页都往日志里塞一条空记录。
      if (report.uploadedBytes > 0 || report.history > 0) {
        AppLog.i(
          'webdav-auto',
          '进度已同步（$reason）：合并 ${report.history} 条、'
              '写入 ${(report.uploadedBytes / 1024).toStringAsFixed(1)} KB',
        );
      }
      return true;
    } catch (error, stack) {
      AppLog.w(
        'webdav-auto',
        '进度同步失败（$reason）',
        error: error,
        stack: stack,
      );
      return false;
    } finally {
      _progressBusy = false;
    }
  }

  /// 取消所有挂起的定时任务（书架防抖、漏推补偿、暂停推送）。
  ///
  /// 两个调用方：[dispose]（测试与实例销毁）和 `syncOnBackground` 成功之后
  /// ——该推的已经推完，留着的定时器只会晚几分钟发一次空转的 PROPFIND；
  /// 而且现代 Android 会冻结后台进程，这些定时器大概率根本没机会触发。
  /// 同步**失败**时绝不调用：它们正是失败后的重试机会。
  void _cancelPendingTimers() {
    _debounce?.cancel();
    _debounce = null;
    _pauseDebounce?.cancel();
    _pauseDebounce = null;
  }

  void dispose() {
    _cancelPendingTimers();
  }

  /// 云端有更新时返回它，否则 null（没配置、没网、云端还没有文件、
  /// 已经是同步过的版本、用户点过忽略 —— 都是 null）。
  Future<WebdavRemoteUpdate?> check() async {
    try {
      final config = await _config.load();
      if (config == null) return null;
      final password = await _password();
      final remote = await _probe(config, password);
      if (remote == null) return null;
      final lastSyncedAt = await _config.lastSyncedAt();
      if (lastSyncedAt != null &&
          !remote.isAfter(lastSyncedAt.add(tolerance))) {
        return null;
      }
      // 同一个云端版本被忽略过就不再追问；云端再被改过才会重新提示。
      final dismissed = await _config.dismissedRemoteAt();
      if (dismissed != null && !remote.isAfter(dismissed)) return null;
      return WebdavRemoteUpdate(
        config: config,
        password: password,
        remoteModified: remote,
        lastSyncedAt: lastSyncedAt,
      );
    } catch (error, stack) {
      // 检查失败不该打扰用户：没网、地址写错、密码被改都在这里安静退场。
      AppLog.w('webdav-auto', '检查云端更新失败', error: error, stack: stack);
      return null;
    }
  }

  Future<WebdavSyncReport> syncNow(WebdavRemoteUpdate update) async {
    final report = await _service.sync(
      update.config,
      password: update.password,
    );
    await _config.markSynced(DateTime.now());
    // 手动同步是整包，冷数据已经结清；顺手把热路径的标记也清掉，免得
    // 下一次退出又把同一份进度推一遍。
    _coldDirty = false;
    _dirty = false;
    return report;
  }

  Future<void> dismiss(WebdavRemoteUpdate update) =>
      _config.markDismissed(update.remoteModified);

  /// 退到后台 / 防抖到期时静默同步一次（用户点「回到桌面」、切走应用、
  /// 翻完一章离开阅读页都会走到这里）。
  ///
  /// 先判断整包到不到期：不到期就只推进度分片（见 [syncProgressNow]），
  /// 这样「读了几页就退出」不会变成「上传整个书库」。
  ///
  /// 只写日志不弹窗：用户已经离开，失败提示没人看。返回是否真的跑了同步。
  /// [reason] 只进日志，用来区分是哪条触发路径出的问题。
  Future<bool> syncOnBackground({String reason = 'background'}) async {
    final now = DateTime.now();
    final last = _lastAutoAt;
    // 失败也占用这个窗口：一次断网不该让后面每次写入都再撞一次墙。
    if (last != null && now.difference(last) < minInterval) return false;
    // 手动同步正在进行时让位，别把两次「读-合并-写」交错在一起。
    if (WebdavSyncService.isSyncing) return false;
    _lastAutoAt = now;
    try {
      final config = await _config.load();
      if (config == null) return false;
      if (!await _fullSyncDue(now)) {
        // 冷数据没动、也没到每日那一次：整包里没有任何比进度更新的东西。
        // 走到这里说明没有待发的书架整包任务（那会置 `_coldDirty`），挂着的
        // 防抖只可能是「漏推补偿」——刚推成功，它就失去了存在意义。
        final pushed = await syncProgressNow(reason: reason);
        if (pushed) _cancelPendingTimers();
        return pushed;
      }
      // 先等本机排队中的写入落盘：页面在 dispose/paused 里提交的进度是异步
      // 排队的，不等就会把上一秒的进度推上去。
      await LibraryStore.instance.idle();
      final report = await _service.sync(config, password: await _password());
      await _config.markSynced(DateTime.now());
      _dirty = false;
      _coldDirty = false;
      // 整包把一切都推完了：挂着的防抖/暂停定时器全部成了空转——尤其别让
      // 它们在几分钟后把后台进程唤醒，只为发一次 PROPFIND。同步失败时不
      // 取消，那些定时器正是失败后的重试机会。
      _cancelPendingTimers();
      AppLog.i(
        'webdav-auto',
        '自动同步完成（$reason）：收藏 ${report.shelf} 条、进度 ${report.history} 条',
      );
      return true;
    } catch (error, stack) {
      AppLog.w(
        'webdav-auto',
        '自动同步失败（$reason）',
        error: error,
        stack: stack,
      );
      return false;
    }
  }

  /// 整包是否该跑了。
  ///
  /// 三条任一成立就跑：冷数据改过（书架增删，用户能立刻看见）、从来没同步过、
  /// 距上次整包同步已经一天。剩下的情况一律走热路径。
  Future<bool> _fullSyncDue(DateTime now) async {
    if (_coldDirty) return true;
    final lastFull = await _config.lastSyncedAt();
    if (lastFull == null) return true;
    return now.difference(lastFull) >= fullSyncInterval;
  }

  Future<String> _password() async {
    try {
      // 允许为空：服务器允许匿名访问时就是不填密码。
      return await _secrets.read(SecretStore.webdavPassword) ?? '';
    } on SecretStoreException {
      return '';
    }
  }

  Future<DateTime?> _probe(WebdavConfig config, String password) async {
    final transport = _transport(config, password);
    try {
      return await transport.remoteModified();
    } finally {
      transport.close();
    }
  }
}
