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

  /// 写入不会停的场景用节流：后台播放每 2~5 秒就写一次进度，防抖永远等不到
  /// 静默。这里按固定间隔放行，和 [debounceWindow] 是两个不同的东西 ——
  /// 「写入会停 → 防抖；写入不会停 → 节流」。
  static const playbackThrottle = Duration(minutes: 5);

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
  bool _dirty = false;

  /// 本机是否有还没推上去的改动。
  bool get isDirty => _dirty;

  /// 内容变了，安排一次防抖同步。
  ///
  /// 只标记、不立刻发请求：一次阅读会写入几十次进度，每次都同步等于把
  /// 整包反复 PUT。真正兜底的是应用退到后台那一次（见 [syncOnBackground]）。
  /// [delay] 让「用户主动操作」（改书架）比「连续写入」（翻页）更快落地。
  void markDirty({Duration delay = debounceWindow}) {
    _dirty = true;
    _debounce?.cancel();
    _debounce = Timer(delay, () {
      _debounce = null;
      unawaited(syncOnBackground(reason: 'debounce'));
    });
  }

  /// 后台播放专用的节流入口：写入不会停，所以按固定间隔放行。
  void markPlaybackWrite() {
    _dirty = true;
    final now = DateTime.now();
    final last = _lastPlaybackAt;
    if (last != null && now.difference(last) < playbackThrottle) return;
    _lastPlaybackAt = now;
    _debounce?.cancel();
    _debounce = null;
    unawaited(syncOnBackground(reason: 'playback'));
  }

  /// 离开阅读/播放页面时调用：取消防抖，立刻同步一次。
  ///
  /// 页面在离开前已经把进度落盘（`_persistProgress`），所以这里读到的是
  /// 最新值。`minInterval` 仍然生效，连续进出页面不会连成一串。
  Future<bool> syncOnLeave() {
    _debounce?.cancel();
    _debounce = null;
    return syncOnBackground(reason: 'leave');
  }

  /// 应用退到后台或即将被回收时调用：把待发的改动立刻推上去。
  Future<bool> flush() => syncOnLeave();

  void dispose() {
    _debounce?.cancel();
    _debounce = null;
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
    return report;
  }

  Future<void> dismiss(WebdavRemoteUpdate update) =>
      _config.markDismissed(update.remoteModified);

  /// 退到后台 / 离开页面 / 防抖到期时静默同步一次（用户点「回到桌面」、
  /// 切走应用、翻完一章离开阅读页都会走到这里）。
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
      // 先等本机排队中的写入落盘：页面在 dispose/paused 里提交的进度是异步
      // 排队的，不等就会把上一秒的进度推上去。
      await LibraryStore.instance.idle();
      final report = await _service.sync(config, password: await _password());
      await _config.markSynced(DateTime.now());
      _dirty = false;
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
