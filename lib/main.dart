import 'services/audio_downloader.dart';
import 'widgets/desktop_app_frame.dart';
import 'widgets/desktop_shell_scope.dart';
import 'services/native_player.dart';
import 'services/desktop_platform.dart';
import 'services/platform_capabilities.dart';
import 'services/platform_channel.dart';

import 'package:material_ui/material_ui.dart';
import 'package:flutter/foundation.dart'
    show LicenseRegistry, LicenseEntryWithLineBreaks;
import 'package:flutter/services.dart';
import 'package:connectivity_plus/connectivity_plus.dart';
import 'package:flutter_lucide/flutter_lucide.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:hive_ce_flutter/hive_flutter.dart';

import 'dart:async';


import 'pages/home_page.dart';
import 'pages/api_service_page.dart';
import 'pages/audio_page.dart';
import 'pages/cached_books_page.dart';
import 'pages/drama_page.dart';
import 'pages/library_page.dart';
import 'pages/mine_page.dart';
import 'services/app_log.dart';
import 'services/frame_stats.dart';
import 'services/shell_visibility.dart';
import 'services/app_theme.dart';
import 'services/app_theme_style.dart';
import 'services/appearance_prewarm.dart';
import 'services/app_style_tokens.dart';
import 'services/api_client.dart';
import 'services/audio_download_store.dart';
import 'services/audio_floating_routes.dart';
import 'services/drama_cache_preferences.dart';
import 'services/drama_feature_preferences.dart';
import 'services/audio_preferences.dart';
import 'services/player_panel_preferences.dart';
import 'services/player_preferences.dart';
import 'services/player_layout_preferences.dart';
import 'services/backend_service.dart';
import 'services/boss_key_preferences.dart';
import 'services/boss_key_service.dart';
import 'services/network_proxy_preferences.dart';
import 'services/digg_store.dart';
import 'services/drama_channel_preferences.dart';
import 'services/drama_download_store.dart';
import 'services/drama_downloader.dart';
import 'services/fair_memory.dart';
import 'services/connectivity_status.dart';
import 'services/home_feed_cache.dart';
import 'services/haptic_preferences.dart';
import 'services/library_store.dart';
import 'services/rank_cache.dart';
import 'services/player_style_config.dart';
import 'services/short_series_font_scale.dart';
import 'services/playlet_share.dart';
import 'services/poster_cache.dart';
import 'services/shelf_group_store.dart';
import 'services/shelf_store.dart';
import 'services/shelf_view_store.dart';
import 'services/swipe_guide_store.dart';
import 'services/third_party_licenses.dart';
import 'services/webdav_auto_sync.dart';
import 'services/webdav_client.dart' show WebdavException;
import 'services/webdav_sync_service.dart' show describeSyncReport;
import 'widgets/lazy_indexed_stack.dart';
import 'widgets/app_ui/app_ui_scope.dart';
import 'widgets/shell_dock.dart';
import 'widgets/unsupported_feature_page.dart';
import 'widgets/home/home_design.dart';
import 'widgets/home/home_skeleton.dart';
import 'widgets/home/classic_home_skeleton.dart';

Future<void> main() async {
  // 绑定初始化与 runApp 必须处在同一个 Zone：此前 `ensureInitialized` 在
  // Zone 外、`runApp` 在 `runZonedGuarded` 里，Flutter 每次冷启动都会断言
  // 「Zone mismatch」并把它当成框架异常抛出来（真机 app.log 每次启动一条
  // `[E] framework: Zone mismatch`，2026-10-25），把真正的异常淹没在启动
  // 噪声里。因此整条启动流程收进同一个受保护的 Zone。
  await runZonedGuarded(() async {
    WidgetsFlutterBinding.ensureInitialized();
    // 装配失败不许挡住界面：记一条错误后照常 runApp，各页面自行退化。
    try {
      await _prepareRuntime();
    } catch (error, stack) {
      AppLog.e('main', '启动装配失败，继续挂载界面', error: error, stack: stack);
    }
    // 首帧主题：本地数据还没读完就画骨架，会让「系统浅色 + 应用内强制深色 /
    // 墨水屏」的用户先闪一整屏浅色。外观偏好只有几个键，读它比整包本地数据
    // 快得多，所以先单独预热一次，再进 runApp。
    //
    // 但这条 I/O 走平台通道，不能无上限地挡住 runApp：超时就用默认值启动，
    // `_loadLocalData` 后面还会再读一次并纠正。
    await primeWithBudget(const Duration(milliseconds: 300));
    runApp(const ProviderScope(child: FqApp()));
  }, (error, stack) => AppLog.e('zone', '未捕获异步异常', error: error, stack: stack));
}

/// `runApp` 之前的运行时装配：桌面窗口回调、应用内日志、分享与 Rust 日志的桥。
/// 这些都不决定界面能不能起来，所以失败只记日志（见 [main]）。
Future<void> _prepareRuntime() async {
  registerPortedUiLicenses();
  LicenseRegistry.addLicense(() async* {
    yield LicenseEntryWithLineBreaks(const [
      'sync_storage',
    ], await rootBundle.loadString('assets/licenses/sync_storage.txt'));
  });
  if (isDesktopHost) await DesktopPlatform.instance.initialize();
  // 应用内日志：接管 debugPrint 与 FlutterError.onError，未处理异步异常由
  // [main] 的 runZonedGuarded 捕获；文件持久化异步开启，失败只退回内存模式。
  AppLog.instance.install();
  unawaited(AppLog.instance.startPersistence());
  // 帧耗时采样（debug/profile）：真机上唯一能拿到 UI/raster 拆分的手段。
  // release 里 install() 直接返回，不产生任何开销。
  FrameStats.install();
  // 短剧分享的「系统分享」走 Android 的 Intent.ACTION_SEND
  //（官方同一条路径）。桥不可用时 PlayletShare 自动降级为复制链接，
  // 不会把失败说成成功。
  // 插件回 false 表示没能调起选择器（没有可分享的应用），必须原样返回：
  // 「调不起来」与「已分享」是两件事。
  SharePlusLite.handler = ({required title, required text}) async {
    final launched = await const AppMethodChannel(
      'fqapp/share',
    ).invokeMethod<bool>('shareText', {'title': title, 'text': text});
    return launched ?? false;
  };
  // Rust 核心日志的读取入口：日志页「Rust」视图读 runtime_dir/rust.log。
  // 核心只在 Android 落盘（桌面/测试构建不装 logger），读不到时页面给空态。
  RustLogSource.reader = BackendService.instance.readRustLog;
  if (isDesktopHost) {
    DesktopPlatform.instance.beforeClose = () async {
          try {
            try {
              await BossKeyService.instance.shutdown();
            } catch (error, stack) {
              AppLog.w('exit', '退出前注销老板键失败', error: error, stack: stack);
            }
            DramaDownloader.instance.pauseAll();
            AudioDownloader.instance.pauseAll();
            await FairMemoryService.instance.flushForExit();
            try {
              if (isDesktopHost) await NativePlayer.pauseOthers();
            } catch (error, stack) {
              // 退出路径继续往下走，但失败要留痕：否则「关闭后还有声音」无从查起。
              AppLog.w('exit', '退出前暂停播放器失败', error: error, stack: stack);
            }
            try {
              await BackendService.instance.stop();
            } catch (error, stack) {
              AppLog.w('exit', '退出前停止后端失败', error: error, stack: stack);
            }
            // 桌面没有「退到后台」，关窗口是最后一次可靠的上云机会，且必须在
            // Hive.close() 之前（同步要读书架与进度）。给 5 秒上限：网络卡住时
            // 宁可丢这一页进度，也不能让窗口关不掉。
            await WebdavAutoSync.instance
                .flush()
                .timeout(const Duration(seconds: 5), onTimeout: () => false);
          } finally {
            await Hive.close();
          }
        };
  }
}

Future<void> _initializeLocalData() {
  // fork 不含 Linux 移植，没有 LinuxPlatform 承接这份初始化句柄。
  return _loadLocalData();
}

Future<void> _loadLocalData() async {
  await Hive.initFlutter();
  // 以下初始化互相独立（各开各的 box / 各读各的配置），串行等只会把
  // 磁盘 I/O 叠加到冷启动里；并行发起，失败语义与串行时一致：必需项
  // （书架/历史）失败仍使启动失败，可选项各自吞错退化。
  Future<void> optional(Future<void> Function() run) async {
    try {
      await run();
    } catch (error, stack) {
      // 可选项失败时启动照常继续，但必须留下可检索的记录，否则一个永远
      // 打不开的可选 box 会以「某功能默默不生效」的形式表现出来。
      AppLog.w('startup', '可选本地数据初始化失败，已跳过', error: error, stack: stack);
    }
  }

  // SharedPreferences 与主题样式原本串在并行段之后：闸门要等它们依次返回，
  // 冷启动因此多出两轮顺序 I/O。并入并行段后，闸门时长从「两段串行」变成
  // 「取最慢的一段」——等待感来自最慢的那项，不是项数之和（#318）。
  final spFuture = SharedPreferences.getInstance();
  final themeStyleFuture = AppThemeStyleStore.instance.load();

  await Future.wait<void>([
    // Load before interactive pages mount, so a saved opt-out applies at launch.
    optional(HapticPreferences.instance.load),
    LibraryStore.instance.init(),
    // The 加入书架 collection is optional data: a failure here must not block
    // startup, which is why it shares the retryable bootstrap with the history.
    ShelfStore.instance.init(),
    // 书架分组与视图偏好都在书架数据之后装配：页面首帧就能读到版式，
    // 分组只在就绪后参与筛选（未就绪时读 API 安全降级）。两者都是可选数据，
    // 打不开时页面退化为「全部 / 默认版式」而不是拖住启动。
    optional(ShelfGroupStore.instance.init),
    optional(ShelfViewStore.instance.load),
    // 短剧 feed 的 点赞 也是可选本地数据，与书架同一处理：开箱失败不能让
    // 启动失败，否则一个纯装饰性的集合会拖住短剧页之外的所有功能。
    optional(() async {
      await DiggStore.instance.init();
      // DiggStore 自己把「不可用」当成「没有点赞」处理（见 _openBox）。
    }),
    // 「上滑查看更多视频」的一次性标记同样是可选数据：读不到就当没弹过，
    // 弹一次的语义退化成「本次启动弹一次」也不能拖住启动。
    optional(() async {
      await SwipeGuideStore.instance.init();
      // SwipeGuideStore 自己把「不可用」当成「未显示」处理。
    }),
    // 首页 feed 的冷启动缓存也是可选数据：打不开就当没有缓存，
    // 首页退化为先加载再显示，其余行为不变。
    optional(() async {
      HomeFeedCache.hiveReady = true;
      await HomeFeedCache.instance.warmUp();
      // HomeFeedCache 自己把「不可用」当成「没有缓存」处理。
    }),
    // 榜单缓存同理：开箱失败只是退化为每次现拉。
    optional(() async {
      RankCache.hiveReady = true;
      await RankCache.instance.warmUp();
      // RankCache 自己把「不可用」当成「没有缓存」处理。
    }),
    // 官方播放页开关（PlayerBottomStyleConfig / 清屏反转 / 横屏锁）随同一份
    // 运行时配置读取；读不到就用默认值，不能拖住启动。
    PlayerStyleConfig.load(),
    // 官方播放页字号档（jk3/b 的 SP）同理：读失败回标准档，不拖启动。
    ShortSeriesFontScale.load(),
    // 解码器偏好必须先进内存：`NativePlayer.create` 在起播路径上直接读它，
    // 不能在那里再 await 读盘（见 DecoderPreferenceCache 的说明）。
    optional(DecoderPreferenceCache.load),
    // 播放器独立音量同理：起播与解除静音直接读内存里的档位。
    optional(PlayerPanelPreferences.loadVolumeLevel),
    // 离线缓存的记录箱启动即打开：播放器的离线命中只在 box 就绪时才查
    // （避免运行中途首次 openBox 失败产生游离异步错误）。可选数据，失败
    // 只退化为「本会话不查离线」。
    optional(HiveDramaDownloadStore.instance.warmUp),
    // 听书音频离线记录箱：与短剧箱分开，同样只在就绪时才查离线命中。
    optional(HiveAudioDownloadStore.instance.warmUp),
    // 主题样式与 SharedPreferences 一并并行：两者都是启动链上的必要项，
    // 不该排在并行段之后串行等。prefs 读失败即启动失败(失败页 + 重试);
    // 样式 store 是可选外观偏好,内部吞错,读失败只回落默认外观(#421)。
    spFuture,
    themeStyleFuture,
  ]);
  // 短剧功能开关：异步读，失败退化为默认开启。**不能进上面的 await 段** ——
  // 闸门里的 SharedPreferences 读取在 widget 测试的 fake-async 路径上会让
  // 后续用例的闸门永远不开（comprehensive_data_boundaries 的 6 条就是这么红的）。
  // 代价是关闭短剧时首帧可能先画 4 项、下一帧收成 3 项。
  unawaited(optional(DramaFeaturePreferences.instance.load));
  // 听书后台播放开关：异步读取 SharedPreferences，失败退化为默认开启。
  unawaited(AudioPreferences.instance.load());
  // 短剧「边看边往后缓存」的开关与集数：同一条装配链里读，避免播放页
  // 起来时还没加载完、拿默认值把用户关掉的开关又打开。
  unawaited(DramaCachePreferences.instance.load());
  // 短剧切后台悬浮窗开关（#24）：异步读取，失败退化为默认关闭。
  unawaited(PlayerPreferences.loadFloatingWindow());
  // 桌面端老板键偏好与全局热键监听：可选能力，失败只退化为未启用。
  if (isBossKeyHost) {
    unawaited(
      optional(() async {
        await BossKeyPreferences.instance.load();
        await BossKeyService.instance.initialize();
      }),
    );
  }
  // 离线缓存的网络门（官方 onNetChangeCheck）：断网/只剩计费链路时
  // 自动暂停下载队列，半成品保留。监听失败只退化为「无自动暂停」。
  try {
    Connectivity().onConnectivityChanged.listen((results) {
      final view = foldConnectivity(results);
      DramaDownloader.instance.updateConnectivity(
        online: view.online,
        metered: view.metered,
      );
      AudioDownloader.instance.updateConnectivity(
        online: view.online,
        metered: view.metered,
      );
    });
  } catch (_) {
    // 监听连通性只为自动暂停下载；拿不到不构成启动失败，但值得留一条记录，
    // 否则「断网没自动暂停」会被当成下载器自己的 bug。
    AppLog.w('startup', '连通性监听注册失败，自动暂停下载不可用');
  }
  // 海报缓存的字节预算清扫：超额时删最旧的图。失败不影响任何页面。
  unawaited(PosterCache.instance.enforceBudget());
  // 小米澎湃 OS 公平运行内存：注册 TRIM/KILL 通道回调。必须在启动时构造，
  // 否则广播到达时 Dart 侧还没有处理函数，原生侧只能按“未处理”回。
  FairMemoryService.instance.init();
  final sp = await spFuture;
  // Note: Optional preference schemas cannot block local data startup; see
  // .agents/notes/implemented/bug-fix/2026-09-17-persistent-data-and-web-cancellation.md.
  final savedTheme = sp.get(themeModeKey);
  themeModeNotifier.value = themeModeFromName(
    savedTheme is String ? savedTheme : null,
  );
  // 墨水屏模式与深色模式同为可选偏好：读不到退化为关闭，不拖住启动。
  einkModeNotifier.value = sp.getBool(einkModeKey) ?? false;
  // OLED 纯黑与墨水屏互斥；两个旧值同时为 true 时墨水屏优先。
  oledModeNotifier.value = sp.getBool(oledModeKey) ?? false;
  // 播放页布局（短剧上下分屏/左右分栏）同样是可选偏好：读不到退化为
  // 沉浸式，不阻塞启动。
  PlayerLayoutPreferences.mode.value = PlayerLayoutPreferences.decode(
    sp.getString(PlayerLayoutPreferences.key),
  );
  // 短剧分区上次停在哪个频道（官方 SP `last_tab_type`）：同样只读一次，
  // 页面在 initState 同步取用，首帧不会先闪「推荐」。
  DramaChannelPreferences.load(sp);
}

class FqApp extends StatefulWidget {
  const FqApp({
    super.key,
    this.initializer,
    this.backendStarter,
    this.styleStore,
  });

  /// Test seams for the real production tree. Production leaves them null:
  /// startup uses [_initializeLocalData] and the real backend, and appearance
  /// reads the device-wide [AppThemeStyleStore.instance].
  @visibleForTesting
  final Future<void> Function()? initializer;
  @visibleForTesting
  final Future<void> Function()? backendStarter;
  @visibleForTesting
  final AppThemeStyleStore? styleStore;

  @override
  State<FqApp> createState() => _FqAppState();
}

class _FqAppState extends State<FqApp> {
  AppThemeStyleStore get _styleStore =>
      widget.styleStore ?? AppThemeStyleStore.instance;
  // Official tabbar + 18dp applies on every page. Our bottom chrome is a
  // floating dock: 56 high with an 8dp gap in the classic style, 54 high with
  // a 12dp gap in the archive style (issue #478). 72 keeps the floating audio
  // pill clear of both; the desktop shell has no bottom bar.
  final _audioRoutes = AudioFloatingRoutes(
    defaultBottomInset: isDesktopHost ? 0 : 72,
  );
  final _desktopRoutes = DesktopRouteObserver();
  // Desktop fullscreen reparents the content; keep the playback owner alive.
  final _audioScopeKey = GlobalKey();
  final _navigatorKey = isDesktopHost
      ? DesktopPlatform.navigatorKey
      : GlobalKey<NavigatorState>();
  final _localDataReady = Completer<void>();

  Future<void> _initializeData() async {
    await (widget.initializer ?? _initializeLocalData)();
    if (!_localDataReady.isCompleted) _localDataReady.complete();
  }

  Future<RecentListen?> _loadRecentListenWhenReady() async {
    // Keep the Navigator and playback owner mounted during startup/retries,
    // but read history only after the local stores have opened successfully.
    await _localDataReady.future;
    if (!mounted) return null;
    return loadRecentListen();
  }

  @override
  void dispose() {
    if (!_localDataReady.isCompleted) _localDataReady.complete();
    BackendService.instance.cancelStartupTimeout();
    _audioRoutes.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return ValueListenableBuilder<ThemeMode>(
      valueListenable: themeModeNotifier,
      builder: (context, mode, _) {
        return ValueListenableBuilder<bool>(
          valueListenable: einkModeNotifier,
          builder: (context, eink, _) {
            return ValueListenableBuilder<bool>(
              valueListenable: oledModeNotifier,
              builder: (context, oled, _) {
                // 墨水屏强制浅色纯黑白：深色反白在墨水屏上残影最重。
                final effectiveMode = eink ? ThemeMode.light : mode;
                return ValueListenableBuilder<AppThemeStyle>(
                  valueListenable: _styleStore,
                  builder: (context, style, _) => MaterialApp(
                    navigatorKey: _navigatorKey,
                    navigatorObservers: [
                      _audioRoutes,
                      if (isDesktopHost) _desktopRoutes,
                    ],
                    builder: (context, child) {
                      final palette = HomePalette.of(context);
                      final playback = AudioPlaybackScope(
                        key: _audioScopeKey,
                        navigatorKey: _navigatorKey,
                        recentListen: _loadRecentListenWhenReady,
                        child: child ?? const SizedBox.shrink(),
                      );
                      // One live presentation scope above the root Navigator,
                      // so pushed routes, nested Navigators and every Overlay
                      // entry read the same discrete style. It is installed in
                      // the builder (not in a page) on purpose; see
                      // [AppUiScope].
                      return AppUiScope(
                        store: _styleStore,
                        child: AnnotatedRegion<SystemUiOverlayStyle>(
                          // Routes without an AppBar need a live fallback above
                          // the Navigator; the covered root route cannot paint
                          // its style. Reader/video annotations still override
                          // this default.
                          value:
                              (palette.dark
                                      ? SystemUiOverlayStyle.light
                                      : SystemUiOverlayStyle.dark)
                                  .copyWith(
                                    statusBarColor: palette.canvas,
                                    systemNavigationBarColor: palette.canvas,
                                    systemNavigationBarDividerColor:
                                        palette.canvas,
                                    systemNavigationBarIconBrightness:
                                        palette.dark
                                        ? Brightness.light
                                        : Brightness.dark,
                                  ),
                          child: AudioFloatingRouteScope(
                            routes: _audioRoutes,
                            child: isDesktopHost
                                ? DesktopAppFrame(child: playback)
                                : playback,
                          ),
                        ),
                      );
                    },
                    title: '什锦铺',
                    debugShowCheckedModeBanner: false,
                    // OLED 纯黑只在深色下生效（浅色时 createTheme 直接忽略）。
                    theme: _theme(
                      Brightness.light,
                      eink: eink,
                      oled: oled,
                      style: style,
                    ),
                    darkTheme: _theme(
                      Brightness.dark,
                      eink: eink,
                      oled: oled,
                      style: style,
                    ),
                    themeMode: effectiveMode,
                    // 全 App 文案是中文，系统文本菜单（复制/粘贴/全选）与 Material
                    // 内置文案也必须跟着中文：缺 delegates 时一律回退英文（#79）。
                    locale: const Locale('zh', 'CN'),
                    supportedLocales: const [Locale('zh', 'CN'), Locale('en')],
                    localizationsDelegates:
                        GlobalMaterialLocalizations.delegates,
                    home: AppBootstrap(
                      backendStarter:
                          widget.backendStarter ??
                          BackendService.instance.start,
                      initializer: _initializeData,
                      child: RootShell(backendStarter: widget.backendStarter),
                    ),
                  ),
                );
              },
            );
          },
        );
      },
    );
  }

  ThemeData _theme(
    Brightness brightness, {
    bool eink = false,
    bool oled = false,
    AppThemeStyle style = AppThemeStyle.archive,
  }) => AppTheme.createTheme(
    brightness,
    einkMode: eink,
    oledMode: oled,
    style: style,
  );
}

/// Opens local data before any page can access LibraryStore's boxes. Failed
/// initialization is retryable without clearing or replacing the user's data.
/// See .agents/notes/implemented/bug-fix/2026-09-17-reviewed-runtime-boundaries.md.
///
/// When [backendStarter] is provided, the backend starts concurrently with
/// local-data init instead of waiting for it (the two chains are independent:
/// the backend only needs the asset bundle + app dir, never Hive/SharedPrefs
/// stores). The backend future is deliberately NOT awaited here: RootShell
/// awaits the same shared future (BackendService.start is idempotent) and
/// owns backend-error UI. When null (widget tests), no backend starts here.
class AppBootstrap extends StatefulWidget {
  final Widget child;
  final Future<void> Function()? initializer;
  final Future<void> Function()? backendStarter;

  const AppBootstrap({
    super.key,
    required this.child,
    this.initializer,
    this.backendStarter,
  });

  @override
  State<AppBootstrap> createState() => _AppBootstrapState();
}

class _AppBootstrapState extends State<AppBootstrap> {
  bool _initializing = false;
  bool _ready = false;
  bool _failed = false;
  Future<void>? _backendFuture;

  @override
  void initState() {
    super.initState();
    _initialize();
  }

  Future<void> _initialize() async {
    if (_initializing || _ready) return;
    setState(() {
      _initializing = true;
      _failed = false;
    });
    // Start the backend before awaiting local data (see class doc): the
    // two chains run concurrently; a retry must not start it twice.
    _backendFuture ??= widget.backendStarter?.call();
    // Attach a no-op error handler so a backend failure is never reported
    // as an unhandled async error if RootShell never mounts to await the
    // same future (e.g. local-data init keeps failing). RootShell awaiting
    // the original future still observes the error.
    unawaited(_backendFuture?.then<void>((_) {}, onError: (_) {}));
    try {
      await (widget.initializer ?? _initializeLocalData)();
      if (mounted) setState(() => _ready = true);
    } catch (_) {
      // 这里不写日志：启动失败发生在持久化开启之前，而 AppLog 的写入会排到
      // 那条尚未完成的 I/O 之后（test/app_bootstrap_test.dart 的失败路径用例
      // 因此会挂到超时）。失败本身已经由界面的重试入口与 runZonedGuarded 呈现。
      if (mounted) setState(() => _failed = true);
    } finally {
      _initializing = false;
    }
  }

  @override
  Widget build(BuildContext context) {
    if (_ready) return widget.child;
    if (_failed) {
      return Scaffold(
        body: SafeArea(
          child: Center(
            child: SingleChildScrollView(
              padding: const EdgeInsets.all(24),
              child: Column(
                mainAxisSize: MainAxisSize.min,
                children: [
                  Icon(
                    LucideIcons.triangle_alert,
                    color: Theme.of(context).colorScheme.error,
                  ),
                  const SizedBox(height: 16),
                  const Text('无法读取本地数据'),
                  const SizedBox(height: 8),
                  const Text('请检查设备可用空间后重试。', textAlign: TextAlign.center),
                  const SizedBox(height: 16),
                  OutlinedButton(
                    onPressed: _initialize,
                    child: const Text('重试'),
                  ),
                ],
              ),
            ),
          ),
        ),
      );
    }
    // 成功路径不再整屏「转圈 + 文案」：本地数据就绪前用首页骨架占住版式。
    // 骨架屏的价值正是让真卡片落位时不跳，而一句「正在读取本地数据…」配
    // 转圈只会让人读成应用卡住。提示语留给失败路径——那一屏必须说清
    // 「没读到」并给出重试（#318）。
    return Scaffold(
      body: SafeArea(
        child: Semantics(
          // 骨架是纯形状，读屏用户拿不到任何加载提示：旧实现有一句
          // 「正在读取本地数据…」，这里把它降级成无障碍标签——文案不再占屏，
          // 但状态仍然说得出。
          label: '正在读取本地数据…',
          liveRegion: true,
          child: ExcludeSemantics(
            child: CustomScrollView(
              // 滚动物理跟真实首页一致，否则骨架 → 首页时手感会变一次。
              physics: const BouncingScrollPhysics(
                parent: AlwaysScrollableScrollPhysics(),
              ),
              slivers: [
                SliverToBoxAdapter(
                  // 骨架自带的脉动保留：它在说「还在加载」，而不是界面卡住。
                  //
                  // 代价是「本地数据未就绪」态没有静止的一帧——测试里不能靠
                  // `pumpAndSettle()` 等它停下来（会卡到超时），要用有界推进
                  // 推到目标出现为止（见 test/support/pump_until.dart 的
                  // pumpUntilFound）。
                  child: AppStyleTokens.of(context).isClassic
                      ? const ClassicHomeSkeleton()
                      : const HomeSkeleton(),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}

class RootShell extends StatefulWidget {
  final Future<void> Function()? backendStarter;

  const RootShell({super.key, this.backendStarter});

  @override
  State<RootShell> createState() => _RootShellState();
}

class _RootShellState extends State<RootShell>
    with WidgetsBindingObserver, TickerProviderStateMixin {
  int _index = 0;

  /// 页面滑动过渡动画：dock 点击 / 拖动松手 / 页面回调统一经 [_selectTab]
  /// 驱动。页面用 Stack + Transform.translate 按动画值平移（与 PageView
  /// 的滑动观感一致），但挂载时机完全可控——首次访问的目标页先在静止帧
  /// 挂载完，再启动滑动，页面构建不会冻住滑动中的 dock 高亮。
  late final AnimationController _pageMotion = AnimationController(
    vsync: this,
    duration: const Duration(milliseconds: 260),
  )..value = 1;

  /// 滑动动画的起点页码（可为小数：打断上一次动画时从当前显示位置继续）。
  double _pageFrom = 0;

  /// 首次访问延迟挂载的目标页：静止帧里先挂载（不 Offstage 但 Transform
  /// 放在屏外），挂载帧结束后清除并启动滑动。
  int? _premount;

  /// 预挂载世代令牌：每次实际切换自增，使待执行的预挂载 post-frame 回调
  /// 失效——同帧多次选择时只有最新一次生效，过期回调不得覆盖 _index。
  int _premountGeneration = 0;

  /// 已挂载过的 tab。未访问的页不进 Stack，避免跨多页切换把沿途页面
  /// （短剧视频流等）全部提前挂载。
  final Set<int> _visitedTabs = {0};

  /// 页面 widget 缓存：避免 AnimatedBuilder 每帧重建 widget 对象。
  /// State 由框架保活，缓存的 widget 只是配置描述，不影响主题等
  /// inherited 依赖的正常更新。
  final Map<int, Widget> _tabCache = {};

  /// 首页 feed 的滚动控制器，由壳层持有以便底部栏触发回顶部。
  final ScrollController _homeScroll = ScrollController();

  /// 上一次「重复点击底部首页 tab」的时间，用于 800ms 防抖。
  ///
  /// 官方对重复点击用 `throttleFirst(800L, MILLISECONDS)`
  /// （BookshelfVideoMultiTabFragment.java:101）。
  DateTime? _lastHomeTabRepeatAt;

  /// 底部 tab 被选中。重复点当前 tab 时回到首页顶部。
  ///
  /// 官方把它放在底部栏而不是页内：`onBottomTabRepeatClick()` 转发到当前
  /// fragment，最终是 `scrollToPosition(0)`（BookshelfVideoTabFragment.java:247）。
  /// 首页头部是普通 sliver（不是折叠 AppBar），把 offset 归零即等价，吸顶的
  /// 分类栏会自己重新吸住。
  void _selectTab(int index) {
    // 短剧功能关闭后 dock 上已没有这一项，任何残留入口（空态按钮、
    // 桌面导航、深链）都不该把壳层切过去。
    if (index == 1 && !DramaFeaturePreferences.instance.enabled.value) return;
    if (index != _index) {
      FrameStats.mark('shell tab $index');
      // 先广播可见性：页面据此暂停/恢复播放器与定时器，不靠 TickerMode 翻转
      // 触发整页重建。
      shellVisibleTab.value = index;
      // 任何实际切换都使待执行的预挂载回调失效，防止过期回调覆盖新选择。
      final generation = ++_premountGeneration;
      if (_visitedTabs.contains(index) ||
          einkModeNotifier.value ||
          MediaQuery.disableAnimationsOf(context)) {
        // 已访问过 / eink / 减弱动态效果：目标页已挂载（或不需要动画），
        // 直接切换，不走预挂载帧。
        final from = _currentPage();
        setState(() {
          _index = index;
          _premount = null;
          _visitedTabs.add(index);
        });
        _startPageMotion(from, index);
        return;
      }
      // 首次访问：先在静止帧把目标页挂载完（不 Offstage 但 Transform
      // 放在屏外，页面还停在旧 tab、dock 高亮未动），挂载帧结束后再
      // 同步启动页面滑动与 dock 弹簧。页面构建的开销发生在动画开始前
      // 而不是滑动中段，dock 高亮不会被冻结在中途项上再跳变。
      setState(() {
        _visitedTabs.add(index);
        _premount = index;
      });
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (!mounted || generation != _premountGeneration) return;
        final from = _currentPage();
        setState(() {
          _index = index;
          _premount = null;
        });
        _startPageMotion(from, index);
      });
      return;
    }
    if (index != 0) return; // 只有首页有 feed 需要回顶
    final now = DateTime.now();
    final last = _lastHomeTabRepeatAt;
    if (last != null && now.difference(last).inMilliseconds < 800) return;
    _lastHomeTabRepeatAt = now;
    if (!_homeScroll.hasClients) return;
    // 官方是瞬间跳转（scrollToPosition(0)），没有动画。
    _homeScroll.jumpTo(_homeScroll.position.minScrollExtent);
  }

  /// 启动页面滑动：与 dock 高亮的弹簧滑动同帧开始、同起同终。
  /// [from] 必须在 setState 改变 [_index] 之前捕获（否则起点=终点，
  /// 动画无效）。eink / 系统减弱动态效果不做动画，直接落位。
  void _startPageMotion(double from, int index) {
    if (einkModeNotifier.value || MediaQuery.disableAnimationsOf(context)) {
      _pageMotion.value = 1;
      _pageFrom = index.toDouble();
      return;
    }
    _pageFrom = from;
    _pageMotion.forward(from: 0);
  }

  /// 当前显示的连续页码（动画中为小数，静止时等于 [_index]）。
  double _currentPage() =>
      _pageFrom +
      (_index - _pageFrom) * Curves.easeOutCubic.transform(_pageMotion.value);

  Widget _tabChild(int index) =>
      _tabCache.putIfAbsent(index, () => _buildTabChild(index));

  Widget _buildTabChild(int index) {
    switch (index) {
      case 0:
        return HomePage(
          scrollController: _homeScroll,
          cueLoader: ApiClient.instance.searchCue,
        );
      case 1:
        // iOS 首版没有原生播放器实现：把短剧页换成「暂不支持」占位，
        // 避免进入播放页时触发缺失的 fqapp/native_player 通道。
        return supportsVideoPlayback
            ? const DramaPage()
            : const UnsupportedFeaturePage(
                icon: LucideIcons.clapperboard,
                title: '短剧暂不支持',
                description: '当前平台没有内置视频播放器。搜书、书架和阅读可以正常使用。',
              );
      case 2:
        // 空书架上的「去书城找书」切回首页 tab；收藏空态的「找短剧」
        // 切到短剧 tab。
        return LibraryPage(
          onBrowse: () => _selectTab(0),
          onFindDrama: DramaFeaturePreferences.instance.enabled.value
              ? () => _selectTab(1)
              : null,
        );
      default:
        return const MinePage();
    }
  }

  String? _backendError;

  /// 检查云端是否有更新时置位：回到前台可能连续触发几次，别把弹窗叠起来。
  bool _checkingRemote = false;

  @override
  void initState() {
    super.initState();
    // WebDAV 自动同步的触发点全在壳层：退后台/切走应用静默推一次、回前台
    // 问一句云端有没有新版本。这条观察者一旦漏掉，同步就只剩「手动点」。
    WidgetsBinding.instance.addObserver(this);
    // 短剧频道在推荐（视频流）与浅色页之间切换时，悬浮 dock 和系统导航栏
    // 要跟着换肤，所以停在壳层的 build 里监听。
    dramaLightPageNotifier.addListener(_onDramaChromeChanged);
    // 墨水屏切换后重建壳层:部分子组件据此降级动效。
    einkModeNotifier.addListener(_onEinkModeChanged);
    // 初始可见页：页面据此决定是否暂停播放器/定时器。
    shellVisibleTab.value = _index;
    _pageMotion.addStatusListener(_onPageMotionStatus);
    DramaFeaturePreferences.instance.enabled.addListener(
      _onDramaFeatureChanged,
    );
    _startBackend();
    // 首帧之后再问云端：启动不该等一次网络往返，检查失败也不该挡住首页。
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted) unawaited(_checkRemoteUpdate());
    });
  }

  void _onDramaChromeChanged() {
    if (mounted) setState(() {});
  }

  void _onEinkModeChanged() {
    if (mounted) setState(() {});
  }

  /// 页面滑动动画结束时触发一次 rebuild：让 dock 恢复 BackdropFilter
  /// 实时模糊（动画期间跳过了模糊以避免逐帧全屏高斯开销）。
  void _onPageMotionStatus(AnimationStatus status) {
    if ((status == AnimationStatus.completed ||
            status == AnimationStatus.dismissed) &&
        mounted) {
      FrameStats.mark('motion end');
      setState(() {});
    }
  }

  /// 短剧开关变化：收起/恢复入口，并把停在短剧页的壳层挪回首页。
  ///
  /// 短剧页是一个全屏视频流，关掉开关后不能让它继续留在 Stack 里播：
  /// 先摘掉已挂载标记与 widget 缓存（再进来是全新页面），再在不走滑动
  /// 动画的情况下直接落位首页（目标页已经不存在，动画没有终点）。
  void _onDramaFeatureChanged() {
    if (!mounted) return;
    final enabled = DramaFeaturePreferences.instance.enabled.value;
    if (!enabled && desktopTab.value == 1) desktopTab.value = 0;
    setState(() {
      // 两个方向都要重做缓存：入口的回调是构建时定的闭包。
      _tabCache.remove(1);
      _tabCache.remove(2);
      if (enabled) return;
      _visitedTabs.remove(1);
      if (_index == 1 || _premount == 1) {
        ++_premountGeneration;
        if (_index == 1) _index = 0;
        _premount = null;
        _pageFrom = _index.toDouble();
        _pageMotion.value = 1;
        shellVisibleTab.value = _index;
      }
    });
  }

  Future<void> _startBackend() async {
    setState(() {
      _backendError = null;
    });
    try {
      await (widget.backendStarter ?? BackendService.instance.start)();
      // 成功路径不再有整屏闸门，界面不需要为此重建；只有失败才要换屏。
    } catch (e) {
      if (mounted) {
        setState(() {
          _backendError = '$e';
        });
      }
    }
  }

  Future<void> _resetProxyAndRetry() async {
    setState(() => _backendError = null);
    try {
      await NetworkProxyPreferences.instance.save(const NetworkProxyConfig());
      if (mounted) await _startBackend();
    } catch (_) {
      if (mounted) setState(() => _backendError = '代理配置保存失败，请重试。');
    }
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    dramaLightPageNotifier.removeListener(_onDramaChromeChanged);
    einkModeNotifier.removeListener(_onEinkModeChanged);
    _pageMotion.removeStatusListener(_onPageMotionStatus);
    DramaFeaturePreferences.instance.enabled.removeListener(
      _onDramaFeatureChanged,
    );
    _homeScroll.dispose();
    _pageMotion.dispose();
    super.dispose();
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    switch (state) {
      case AppLifecycleState.resumed:
        unawaited(_checkRemoteUpdate());
      case AppLifecycleState.paused:
      case AppLifecycleState.hidden:
        // 兜底触发点：页面自己的「离开时同步」可能还没跑完，或者根本来不及
        // （用户直接回到桌面）。这里再推一次，`minInterval` 保证不会连成串。
        //
        // Flutter 没有「保证请求在退出前完成」的 API（Android 没有
        // `onTaskRemoved`，iOS 没有 `beginBackgroundTask`），所以真正的保证
        // 不是「退出时传完」，而是**平时就把脏数据推上去**，让退出时几乎没事可做。
        unawaited(WebdavAutoSync.instance.flush());
      case AppLifecycleState.inactive:
        // 移动端 inactive 只是下拉通知栏、来电，太频繁，不当作退出。
        //
        // 桌面端没有 paused：切到别的应用、点 Dock 只到 inactive，窗口最小化
        // 才是 hidden。不在这里兜一手，桌面就只剩「关窗口」一次同步机会
        // （见 beforeClose）。`flush` 自带 30 秒间隔，频繁切窗口不会把请求连成串。
        if (isDesktopHost) unawaited(WebdavAutoSync.instance.flush());
      case AppLifecycleState.detached:
        // 进程即将结束，只做「把待发标记落定」这种同步动作；真正的网络
        // 请求在这里不保证有结果，兜底仍然是上面的 paused/hidden。
        unawaited(WebdavAutoSync.instance.flush());
    }
  }

  /// 云端出现本机没见过的版本时，问一句「同步 / 忽略」。
  ///
  /// 判据是云端那一版的标识（ETag）与本机上次同步时记下的标识是否相同，
  /// 不是「谁的时间更晚」—— 时间比较会被设备时钟偏移搞乱，版本比较不会。
  /// 也不是「本地旧」：谁更新必须下载后逐条合并才知道，那就是同步本身。
  Future<void> _checkRemoteUpdate() async {
    if (_checkingRemote || !mounted) return;
    _checkingRemote = true;
    try {
      final update = await WebdavAutoSync.instance.check();
      if (update == null || !mounted) return;
      final lastSyncedAt = update.lastSyncedAt;
      final answer = await showDialog<bool>(
        context: context,
        builder: (dialogContext) => AlertDialog(
          title: const Text('云端有更新'),
          content: Text(
            '云端备份${update.remoteModified == null ? '' : '在 ${_stamp(update.remoteModified!)} '}'
            '有更新，与本机上次同步时看到的不是同一版'
            '${lastSyncedAt == null ? '（本机还没有同步过）' : '（上次同步：${_stamp(lastSyncedAt)}）'}。\n\n'
            '现在同步吗？',
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.pop(dialogContext, false),
              child: const Text('忽略'),
            ),
            FilledButton(
              onPressed: () => Navigator.pop(dialogContext, true),
              child: const Text('立即同步'),
            ),
          ],
        ),
      );
      if (!mounted) return;
      if (answer == true) {
        await _syncFromPrompt(update);
      } else if (answer == false) {
        // 只有明确点了「忽略」才算「这一版先不管」：同一个云端版本不再追问，
        // 云端再被改过才会重新提示。点遮罩或按返回键是 null —— 那只是
        // 「先不回答」，不该被记成一次回答，否则用户下次打开就再也看不到提示。
        await WebdavAutoSync.instance.dismiss(update);
      }
    } finally {
      _checkingRemote = false;
    }
  }

  Future<void> _syncFromPrompt(WebdavRemoteUpdate update) async {
    final messenger = ScaffoldMessenger.maybeOf(context);
    messenger?.showSnackBar(const SnackBar(content: Text('正在同步，请不要退出…')));
    try {
      final report = await WebdavAutoSync.instance.syncNow(update);
      messenger
        ?..hideCurrentSnackBar()
        ..showSnackBar(
          SnackBar(content: Text(describeSyncReport(report, brief: true))),
        );
    } on WebdavException catch (error) {
      messenger
        ?..hideCurrentSnackBar()
        ..showSnackBar(SnackBar(content: Text(error.message)));
    } catch (_) {
      messenger
        ?..hideCurrentSnackBar()
        ..showSnackBar(const SnackBar(content: Text('同步未完成，请稍后重试')));
    }
  }

  static String _stamp(DateTime at) => at.toLocal().toString().split('.').first;

  @override
  Widget build(BuildContext context) {
    // 后端起不来时保留整屏错误页：原因、重试与服务面板入口都必须在。
    // 本地服务没起来时用户仍要能进离线阅读、查服务面板、或重置代理再试
    // （#318 只动成功路径的等待提示）。
    if (_backendError != null) return _backendFailureView(context);
    // 成功路径不再整屏遮罩：壳层与首页立刻出现，本地服务在后台静默启动，
    // 等待反馈交给首页自己的骨架。核心就绪后数据直接落位，用户无需重试
    // （传输层会把启动期间的请求排队到核心就绪为止）。
    if (isDesktopHost) {
      return ValueListenableBuilder<int>(
        valueListenable: desktopTab,
        builder: (context, index, _) {
          AudioFloatingRouteScope.configure(context, hidden: index == 1);
          return LazyIndexedStack(
            index: index,
            children: [
              HomePage(cueLoader: ApiClient.instance.searchCue),
              // 关掉短剧时不挂短剧页：占位保持 4 项，桌面 tab 下标不必换算。
              if (DramaFeaturePreferences.instance.enabled.value)
                const DramaPage()
              else
                const SizedBox.shrink(),
              LibraryPage(
                onBrowse: () => desktopTab.value = 0,
                onFindDrama: DramaFeaturePreferences.instance.enabled.value
                    ? () => desktopTab.value = 1
                    : null,
              ),
              const MinePage(),
            ],
          );
        },
      );
    }
    AudioFloatingRouteScope.configure(context, hidden: _index == 1);
    final palette = HomePalette.of(context);
    final isDark = Theme.of(context).brightness == Brightness.dark;
    final isDramaTab = _index == 1;
    // 短剧的推荐频道压在全屏视频流上，dock 用深色玻璃；看剧/漫剧/最近/收藏
    // 是浅色页，dock 跟主题走，否则浅色外观下页面是奶白、dock 还是黑的。
    final dramaOnVideo = isDramaTab && !dramaLightPageNotifier.value;
    // 系统导航栏（Android 底部系统自绘的那条）按当前画布取色。Flutter 的
    // light / dark 两套预设都把它写成纯黑底 + 白图标，浅色页面下会在最底部
    // 留一条突兀的黑带；短剧只有视频流（推荐）背后是视频，仍用黑。
    final lightSystemIcons = dramaOnVideo || isDark;
    return Scaffold(
      extendBody: true,
      // 状态栏图标亮度挂在壳层、按选中 tab 切换：短剧页是黑底视频流（官方
      // SeriesMallFragment 的透明顶栏直接压在 feed 上），深色图标在黑底上
      // 整条状态栏都看不见，必须浅色；其余三页浅色底用深色。样式放壳层而不是
      // 各页内部，是因为 IndexedStack 里未选中的页不参与绘制，页内
      // AnnotatedRegion 切走后会残留上一个页的样式。
      body: AnnotatedRegion<SystemUiOverlayStyle>(
        value:
            (lightSystemIcons
                    ? SystemUiOverlayStyle.light
                    : SystemUiOverlayStyle.dark)
                .copyWith(
                  // 状态栏显式铺成画布色：透明状态栏在 Android 10+ 会被系统
                  // 叠一层对比度黑纱，奶白画布会被压成灰带。短剧视频流仍透明。
                  statusBarColor: dramaOnVideo
                      ? Colors.transparent
                      : palette.canvas,
                  systemNavigationBarColor: dramaOnVideo
                      ? Colors.black
                      : palette.canvas,
                  systemNavigationBarDividerColor: dramaOnVideo
                      ? Colors.black
                      : palette.canvas,
                  systemNavigationBarIconBrightness: lightSystemIcons
                      ? Brightness.light
                      : Brightness.dark,
                ),
        child: LayoutBuilder(
          builder: (context, constraints) {
            final width = constraints.maxWidth;
            return AnimatedBuilder(
              animation: _pageMotion,
              builder: (context, _) {
                final page = _currentPage();
                return Stack(
                  key: const ValueKey('root-page-stack'),
                  fit: StackFit.expand,
                  children: [
                    for (var i = 0; i < 4; i++)
                      if (_visitedTabs.contains(i))
                        KeyedSubtree(
                          key: ValueKey('root-tab-$i'),
                          child: Offstage(
                            key: ValueKey('root-tab-offstage-$i'),
                            // 静止时只显示当前页；预挂载帧额外显示目标页
                            // （Transform 放在屏外，完成 layout 但不显示）；
                            // 动画中显示视口范围内的页（旧页滑出 + 新页滑入）。
                            offstage:
                                !(i == _index ||
                                    i == _premount ||
                                    (_pageMotion.isAnimating &&
                                        (i - page).abs() < 1)),
                            child: Transform.translate(
                              offset: Offset((i - page) * width, 0),
                              // RepaintBoundary 把页面内容缓存为独立图层：
                              // 动画期间 Transform 只移动图层（GPU 合成），
                              // 不触发页面内容的逐帧 repaint。
                              child: RepaintBoundary(
                                child: TickerMode(
                                  enabled: i == _index,
                                  child: _tabChild(i),
                                ),
                              ),
                            ),
                          ),
                        ),
                  ],
                );
              },
            );
          },
        ),
      ),
      // 上游 Wenku8 GlassDock：胶囊、拖动预览和液态玻璃选中区；短剧视频流
      // 与 OLED 纯黑下改用同色静态底板，不对每帧变化的画面做实时折射。
      bottomNavigationBar: ShellDock(
        selectedIndex: _index,
        onSelected: _selectTab,
        overVideo: dramaOnVideo,
        staticMaterial: shellDockStaticMaterial(overVideo: dramaOnVideo),
        animating: _pageMotion.isAnimating,
        showDrama: DramaFeaturePreferences.instance.enabled.value,
      ),
    );
  }

  /// 后端启动失败时的整屏错误页。
  ///
  /// 失败路径必须说清原因并留下重试与服务面板入口：本地服务没起来时，用户
  /// 仍要能进离线阅读、查服务面板、或重置代理后再试。成功路径不再显示这层
  /// 整屏提示（#318），所以这里是唯一还会整屏接管的地方。
  Widget _backendFailureView(BuildContext context) {
    return Scaffold(
      body: SafeArea(
        child: Center(
          child: SingleChildScrollView(
            padding: const EdgeInsets.symmetric(vertical: 24),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                Icon(
                  LucideIcons.triangle_alert,
                  color: Theme.of(context).colorScheme.error,
                ),
                const SizedBox(height: 16),
                const Text('启动失败'),
                TextButton.icon(
                  onPressed: () => Navigator.push(
                    context,
                    MaterialPageRoute(builder: (_) => const CachedBooksPage()),
                  ),
                  icon: const Icon(LucideIcons.download),
                  label: const Text('离线阅读'),
                ),
                const SizedBox(height: 8),
                Padding(
                  padding: const EdgeInsets.symmetric(horizontal: 24),
                  child: Text(
                    _backendError ?? '',
                    textAlign: TextAlign.center,
                    style: const TextStyle(fontSize: 12, color: Colors.red),
                  ),
                ),
                const SizedBox(height: 12),
                OutlinedButton(
                  onPressed: _startBackend,
                  child: const Text('重试'),
                ),
                TextButton.icon(
                  onPressed: () => Navigator.push(
                    context,
                    MaterialPageRoute(builder: (_) => const ApiServicePage()),
                  ),
                  icon: const Icon(LucideIcons.settings),
                  label: const Text('服务面板'),
                ),
                if (isDesktopHost)
                  TextButton(
                    onPressed: _resetProxyAndRetry,
                    child: Text(isLinuxDesktop ? '重置代理为默认连接并重试' : '重置代理为直连并重试'),
                  ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}
