import 'package:screen_retriever/screen_retriever.dart';
import 'dart:async';
import 'dart:convert';
import 'dart:ffi' hide Size;
import 'dart:io';
import 'dart:math';
import 'dart:typed_data';

import 'package:archive/archive.dart';
import 'package:ffi/ffi.dart';
import 'package:file_selector/file_selector.dart';
import 'package:flutter/foundation.dart';
import 'package:material_ui/material_ui.dart';
import 'package:flutter/services.dart';
import 'package:flutter_tts/flutter_tts.dart';
import 'package:media_kit/media_kit.dart';
import 'package:media_kit_video/media_kit_video.dart';
import 'package:path_provider/path_provider.dart';
import 'package:smtc_windows/smtc_windows.dart';
import 'package:wakelock_plus/wakelock_plus.dart';
import 'package:window_manager/window_manager.dart';

import '../widgets/desktop_login.dart';
import 'desktop_media.dart';
import 'app_log.dart';
import 'platform_channel.dart';
// `linux_platform.dart` 在 fork 里只剩一句 `export ... show isLinuxDesktop`，
// 而本文件现在自己定义 isLinuxDesktop，所以不再 import 它（否则成环）。

bool get isMediaDesktop =>
    !kIsWeb &&
    (defaultTargetPlatform == TargetPlatform.windows ||
        defaultTargetPlatform == TargetPlatform.linux);

bool get isWindowsDesktop =>
    !kIsWeb && defaultTargetPlatform == TargetPlatform.windows;

bool get isMacDesktop =>
    !kIsWeb && defaultTargetPlatform == TargetPlatform.macOS;

bool get isLinuxDesktop =>
    !kIsWeb && defaultTargetPlatform == TargetPlatform.linux;

/// Desktop hosts (Windows / macOS / Linux) share the shell: window bar, two-pane
/// detail workspace, directory sidebar and immersive reader. The platform list
/// lives here rather than in each page so a new desktop port cannot half-apply
/// the shell.
bool get isDesktopHost => isWindowsDesktop || isMacDesktop || isLinuxDesktop;

/// Boss key host: every desktop can hide its own window and each has a global
/// hotkey hook — Win32 `RegisterHotKey`, X11 `XGrabKey`, and Carbon
/// `RegisterEventHotKey` on macOS. So this is just [isDesktopHost]; the alias
/// stays so call sites read as a capability rather than a platform list.
bool get isBossKeyHost => isDesktopHost;

/// Real host operating system, for code that picks a native library or binary.
///
/// Never use [defaultTargetPlatform] for that decision: `flutter test` forces it
/// to [TargetPlatform.android] (via the FLUTTER_TEST env var), so a
/// TargetPlatform check would send a macOS test run down the kernel32 path and
/// fail with "Failed to load dynamic library 'kernel32.dll'".
bool get isMacHost => !kIsWeb && Platform.isMacOS;
bool get isWindowsHost => !kIsWeb && Platform.isWindows;
bool get isLinuxHost => !kIsWeb && Platform.isLinux;

/// iOS 与桌面共用进程内的 media_kit 播放器、Dart 侧文件通路与
/// [DesktopPlatform] 的通道契约。
///
/// 判定放在这里、而不是 `ios_platform.dart`:`ios_platform.dart` 需要 import
/// 本文件里的 [DesktopPlatform],反向再 import 会绕成一对循环依赖。
bool get isIOSPlatform =>
    !kIsWeb && defaultTargetPlatform == TargetPlatform.iOS;

/// 打开文件时的类型筛选。
///
/// `file_selector` 的 iOS 实现只认 `uniformTypeIdentifiers`:只给 `extensions`
/// 的组会直接抛 `ArgumentError`(见 file_selector_ios 的
/// `_allowedUtiListFromTypeGroups`),UIDocumentPicker 不会退回去看扩展名。
/// 于是同一处入口按平台给两种表达,而不是在 iOS 上留一个必崩的路径。
XTypeGroup _openTypeGroup({
  required String label,
  required List<String> extensions,
  required List<String> iosTypes,
}) => isIOSPlatform
    ? XTypeGroup(label: label, uniformTypeIdentifiers: iosTypes)
    : XTypeGroup(label: label, extensions: extensions);

/// On Windows an inactive window is still visible; it simply lacks input focus.
/// Only hidden/paused/detached windows should defer foreground video playback.
bool playbackAppIsActive(AppLifecycleState? state) =>
    !(isLinuxDesktop && DesktopSystemSession.instance.blocked) &&
    (state == null ||
        state == AppLifecycleState.resumed ||
        (isDesktopHost && state == AppLifecycleState.inactive));

/// 桌面窗口只是失焦时，是否仍算「在前台」。
///
/// Flutter 3.13 起桌面端有真正的生命周期：窗口失去焦点报 `inactive`，
/// 最小化报 `hidden` / `paused`。**失焦不是退到后台** —— 窗口还在、渲染还在
/// 跑；把它当后台会让听书跟随停止翻页（鼠标点一下别的窗口，页面就不跟了）。
///
/// 与 [playbackAppIsActive] 是同一件事的两处用法：那个管视频前台播放，这个
/// 管阅读页的跟随与高亮。平台范围比它宽一点，三个桌面平台都成立。
bool desktopInactiveStillVisible(AppLifecycleState state) =>
    !(isLinuxDesktop && DesktopSystemSession.instance.blocked) &&
    (state == AppLifecycleState.resumed ||
        ((!kIsWeb &&
                (defaultTargetPlatform == TargetPlatform.windows ||
                    defaultTargetPlatform == TargetPlatform.macOS ||
                    defaultTargetPlatform == TargetPlatform.linux)) &&
            state == AppLifecycleState.inactive));

/// logind hints are observable, but compositor lock reliability is unverified.
class DesktopSystemSession extends ChangeNotifier {
  static final instance = DesktopSystemSession();
  bool locked = false;
  bool suspended = false;
  bool serviceAvailable = false;
  bool get blocked => locked || suspended;
  void accept(dynamic event) {
    if (event is! Map || event['value'] is! bool) return;
    final value = event['value'] as bool;
    switch (event['type']) {
      case 'locked':
        if (locked == value) return;
        locked = value;
      case 'suspend':
        if (suspended == value) return;
        suspended = value;
      case 'service':
        serviceAvailable = value;
        if (!value) AppLog.w('session', 'logind 不可用，无法保证锁屏/挂起通知');
      default:
        return;
    }
    notifyListeners();
  }

  AppLifecycleState get lifecycle => blocked
      ? AppLifecycleState.hidden
      : WidgetsBinding.instance.lifecycleState ?? AppLifecycleState.resumed;
}

class DesktopPlatform with WindowListener {
  DesktopPlatform._();
  static final instance = DesktopPlatform._();
  static final navigatorKey = GlobalKey<NavigatorState>();
  static final readerBrightness = ValueNotifier<double>(1);
  static final fullscreen = ValueNotifier<bool>(false);
  static final maximized = ValueNotifier<bool>(false);
  final _events = <String, StreamController<dynamic>>{};
  final _players = <int, _DesktopPlayer>{};
  final _tts = FlutterTts();
  SMTCWindows? _smtc;
  String? _utterance;
  int _nextId = 1000000;
  bool _closing = false;
  Future<void> Function()? beforeClose;
  Future<void> _awakeQueue = Future.value();
  bool _readerAwake = false;
  bool _playerAwake = false;

  /// macOS 的常亮断言子进程（`caffeinate -di`）。null = 当前没有持断言。
  Process? _caffeinate;
  String? _readerSession;
  Timer? _readerTimer;

  Stream<dynamic> events(String name) =>
      (_events[name] ??= StreamController<dynamic>.broadcast()).stream;
  void _emit(String name, dynamic event) => _events[name]?.add(event);

  Future<void> initialize() async {
    if (!isWindowsDesktop) return;
    MediaKit.ensureInitialized();
    await windowManager.ensureInitialized();
    PlatformChannels.invoke = invoke;
    PlatformChannels.events = events;
    windowManager.addListener(this);
    await windowManager.setPreventClose(true);
    final display = await screenRetriever.getPrimaryDisplay();
    final available = display.visibleSize ?? display.size;
    await windowManager.waitUntilReadyToShow(
      WindowOptions(
        size: Size(min(1280, available.width), min(800, available.height)),
        minimumSize: Size(
          min(800, available.width),
          min(440, available.height),
        ),
        center: true,
        title: '什锦铺',
        titleBarStyle: TitleBarStyle.hidden,
      ),
      () async {
        await windowManager.show();
        await windowManager.focus();
        try {
          maximized.value = await windowManager.isMaximized();
        } catch (_) {}
      },
    );
    initializeSpeech();
    // Optional system media integration must not prevent reading or startup.
    // SMTC 是 Windows 的系统媒体桥；macOS 要用 MPNowPlayingInfoCenter /
    // MPRemoteCommandCenter，本 fork 没有实现那一层（见 build_macos.sh 的
    // 原生侧范围），所以这里只在 Windows 上装配，其它桌面平台媒体键静默。
    if (isWindowsHost) {
      try {
        await SMTCWindows.initialize();
        _smtc = SMTCWindows();
        _smtc!.buttonPressStream.listen((button) {
          final action = switch (button) {
            PressedButton.play => 'playPause',
            PressedButton.pause => 'playPause',
            PressedButton.next => 'next',
            PressedButton.previous => 'prev',
            PressedButton.stop => 'stop',
            _ => null,
          };
          if (action != null) {
            unawaited(
              PlatformChannels.notify(
                'fqapp/native_player',
                'onNotificationAction',
                {'action': action},
              ),
            );
          }
        });
        await _smtc!.disableSmtc();
      } catch (_) {
        _smtc = null;
      }
    }
  }

  Future<void> disposeMedia() async {
    final hosts = _players.values.toList();
    _players.clear();
    for (final host in hosts) {
      await host.dispose();
    }
  }

  /// 装配系统朗读的完成/错误回调。
  ///
  /// 回调把 flutter_tts 的完成/失败翻成 `fqapp/system_tts_events` 的 `done` /
  /// `error`,与 Android 原生实现是同一份契约。
  void initializeSpeech() {
    _tts.setCompletionHandler(() {
      final id = _utterance;
      if (id != null) {
        _utterance = null;
        _emit('fqapp/system_tts_events', {'type': 'done', 'id': id});
      }
    });
    _tts.setErrorHandler((dynamic _) {
      final id = _utterance;
      _utterance = null;
      _emit('fqapp/system_tts_events', {'type': 'error', 'id': id});
    });
  }

  Widget videoSurface(int id, {Key? key}) {
    final host = _players[id];
    return host == null
        ? const SizedBox.expand()
        : Video(
            key: key,
            controller: host.video,
            controls: NoVideoControls,
            fit: BoxFit.fill,
            pauseUponEnteringBackgroundMode: false,
            resumeUponEnteringForegroundMode: false,
          );
  }

  Future<void> setFullscreen(bool value) async {
    try {
      await windowManager.setFullScreen(value);
    } catch (_) {}
    fullscreen.value = value;
    if (!value) {
      try {
        maximized.value = await windowManager.isMaximized();
      } catch (_) {}
    }
  }

  Future<void> minimizeWindow() async {
    if (!isWindowsDesktop) return;
    try {
      await windowManager.minimize();
    } catch (_) {}
  }

  Future<void> toggleMaximizeWindow() async {
    if (!isWindowsDesktop) return;
    try {
      if (await windowManager.isMaximized()) {
        await windowManager.unmaximize();
      } else {
        await windowManager.maximize();
      }
    } catch (_) {}
  }

  Future<void> closeWindow() async {
    if (!isWindowsDesktop) return;
    try {
      await windowManager.close();
    } catch (_) {}
  }

  Future<void> startWindowDragging() async {
    if (!isWindowsDesktop) return;
    try {
      await windowManager.startDragging();
    } catch (_) {}
  }

  @override
  void onWindowMaximize() {
    maximized.value = true;
  }

  @override
  void onWindowUnmaximize() {
    maximized.value = false;
  }

  @override
  void onWindowLeaveFullScreen() {
    fullscreen.value = false;
  }

  @override
  void onWindowEnterFullScreen() {
    fullscreen.value = true;
  }

  @override
  void onWindowClose() async {
    if (_closing) return;
    _closing = true;
    try {
      try {
        await beforeClose?.call();
      } catch (_) {}
      for (final host in _players.values.toList()) {
        await host.dispose();
      }
      _players.clear();
      _utterance = null;
      await _tts.stop();
      await _smtc?.disableSmtc();
      _readerTimer?.cancel();
      _readerAwake = _playerAwake = false;
      _updateAwake();
    } finally {
      await windowManager.destroy();
    }
  }

  Future<dynamic> invoke(
    String channel,
    String method,
    dynamic arguments,
  ) async {
    final args = arguments is Map ? arguments : const <dynamic, dynamic>{};
    switch (channel) {
      case 'fqapp/native_player':
        if (method == 'create') {
          MediaKit.ensureInitialized();
          final id = _nextId++;
          final host = _DesktopPlayer(
            id,
            (event) => _emit('fqapp/native_player/events', event),
          );
          _players[id] = host;
          unawaited(
            host.open(
              args['cdnUrl'] as String,
              args['keyHex'] as String,
              startPositionMs: args['startPositionMs'],
            ),
          );
          return {'playerId': id};
        }
        if (method == 'reopen') {
          // 后台切章不能新建 mpv（音频输出初始化会挂住），改为复用同一个
          // 播放器原地换源；完成时发 `reopened` 事件，由 Dart 侧等待。
          final rawId = args['id'];
          final host = rawId is num ? _players[rawId.toInt()] : null;
          if (host == null) {
            throw StateError('Player is unavailable for reopen');
          }
          unawaited(
            host.reopen(
              args['cdnUrl'] as String,
              args['keyHex'] as String,
              args['requestId'] as int,
            ),
          );
          return null;
        }
        if (method == 'setKeepScreenOn') {
          await _setAwake(player: args['on'] == true);
          return null;
        }
        if (method == 'startListenForeground') {
          final smtc = _smtc;
          if (smtc == null) return null;
          await smtc.updateMetadata(
            MusicMetadata(
              title: args['title'] as String?,
              artist: args['episode'] as String?,
              // Windows 的「正在播放」卡片同样用作品封面（issue #123）；
              // SMTC 自己按 URL 拉图，取不到就保留应用图标。
              thumbnail: switch (args['coverUrl']) {
                final String url when url.isNotEmpty => url,
                _ => null,
              },
            ),
          );
          await smtc.setIsPrevEnabled(args['hasPrev'] == true);
          await smtc.setIsNextEnabled(args['hasNext'] == true);
          await smtc.updateTimeline(
            PlaybackTimeline(
              startTimeMs: 0,
              endTimeMs: (args['durationMs'] as num?)?.toInt() ?? 0,
              positionMs: (args['positionMs'] as num?)?.toInt() ?? 0,
              minSeekTimeMs: 0,
              maxSeekTimeMs: (args['durationMs'] as num?)?.toInt() ?? 0,
            ),
          );
          await smtc.setPlaybackStatus(
            args['playing'] == true
                ? PlaybackStatus.playing
                : PlaybackStatus.paused,
          );
          await smtc.enableSmtc();
          return null;
        }
        if (method == 'stopListenForeground') {
          await _smtc?.disableSmtc();
          return null;
        }
        if (isLinuxDesktop &&
            !const {
              'dispose',
              'play',
              'pause',
              'seek',
              'setRate',
              'setVolume',
              'getPlaybackSettings',
            }.contains(method)) {
          throw PlatformException(
            code: 'unsupported_platform',
            message: method,
          );
        }
        final id = (args['id'] as num?)?.toInt();
        final host = _players[id];
        if (method == 'dispose') {
          _players.remove(id);
          await host?.dispose();
          return null;
        }
        if (host == null) {
          throw PlatformException(code: 'player_closed', message: '播放器已关闭');
        }
        if (method == 'getPlaybackSettings') {
          return {
            'volume': host.player.state.volume / 100,
            'rate': host.player.state.rate,
          };
        }
        await host.command(method, args);
        return null;
      case 'fqapp/library_backup':
        return _backup(method, args);
      case 'fqapp/local_books':
        if (method == 'pickBookFile') return pickBook();
      case 'fqapp/downloads':
        if (method == 'saveText') {
          final path = await _save(
            args['fileName'] as String,
            Uint8List.fromList(utf8.encode(args['text'] as String)),
            ['txt'],
          );
          if (path == null) {
            throw PlatformException(code: 'cancelled', message: '已取消保存');
          }
          // iOS 的分享面板写的是应用私有临时目录,不能报成「下载目录」。
          return {'path': path, 'public': !isIOSPlatform};
        }
      case 'fqapp/reader':
        return _reader(method, args);
      case 'fqapp/system_tts':
        return _speech(method, args);
      case 'fqapp/fanqie_account':
        if (method == 'login') {
          final context = navigatorKey.currentContext;
          if (context == null) {
            throw PlatformException(code: 'not_ready', message: '窗口尚未就绪');
          }
          return DesktopLogin.open(context);
        }
        if (method == 'cancelLogin') {
          DesktopLogin.cancel();
          return null;
        }
        if (method == 'clearSession') {
          await DesktopLogin.clearSession();
          return null;
        }
      case 'fqapp/eink-refresh':
        return false;
      case 'fqapp/volume-key':
        return null;
      case 'fqapp/fair_memory':
        return null;
    }
    throw MissingPluginException('$channel/$method');
  }

  Future<dynamic> _speech(String method, Map args) async {
    try {
      return await _speechInner(method, args);
    } on PlatformException catch (e) {
      if (e.code != 'tts_unavailable' && e.code != 'tts_failed') rethrow;
      throw PlatformException(
        code: e.code,
        message: isMacHost
            ? 'macOS 语音不可用，请在系统设置中启用语音'
            : 'Windows 语音不可用，请安装中文语音',
      );
    }
  }

  Future<dynamic> _speechInner(String method, Map args) async {
    // macOS 与 Windows 共用 flutter_tts，但引擎标识与「打开语音设置」的
    // 落点不同：把这两处按宿主系统分开，其余逻辑一并共用。
    final engineKey = isMacHost ? 'macos' : 'windows';
    final engineLabel = isMacHost ? 'macOS 系统语音' : 'Windows 默认语音';
    switch (method) {
      case 'engines':
        final voices = await _tts.getVoices;
        // 默认项不是真实音色:选中它时 initialize 退回 setLanguage('zh-CN'),
        // 由系统挑一个默认中文语音。
        return {
          'defaultEngine': engineKey,
          'engines': [
            {'package': engineKey, 'label': engineLabel},
            if (voices is List)
              for (final voice in voices)
                if (voice is Map && voice['name'] is String)
                  {
                    'package': jsonEncode({
                      'name': voice['name'],
                      'locale': voice['locale'],
                    }),
                    'label': '${voice['name']} (${voice['locale']})',
                  },
          ],
        };
      case 'initialize':
        await _tts.stop();
        _utterance = null;
        final engine = args['engine'];
        if (engine is String && engine.startsWith('{')) {
          final voice = (jsonDecode(engine) as Map).cast<String, String>();
          await _tts.setVoice(voice);
        } else {
          await _tts.setLanguage('zh-CN');
        }
        // Windows flutter_tts adds the SAPI 0.5 baseline internally.
        final rate = (args['rate'] as num?)?.toDouble() ?? 1;
        await _tts.setSpeechRate(rate - .5);
        return 300;
      case 'speak':
        _utterance = args['id'] as String;
        final result = await _tts.speak(args['text'] as String);
        if (result == 0) {
          throw PlatformException(
            code: 'tts_failed',
            message: isMacHost
                ? 'macOS 语音不可用，请在系统设置中启用语音'
                : 'Windows 语音不可用，请安装中文语音',
          );
        }
        return null;
      case 'setVolume':
        // flutter_tts expects 0.0-1.0; the media slider already sends 0..1.
        await _tts.setVolume(
          ((args['volume'] as num?)?.toDouble() ?? 1)
              .clamp(0.0, 1.0)
              .toDouble(),
        );
        return null;
      case 'pause':
        // Android's native pause stops the engine but keeps audio focus. The
        // shared flutter_tts path has no separate pause, so stopping the
        // current utterance and clearing it is equivalent; the session/focus
        // stays put until stopListenForeground releases it (AudioSessionBridge).
        _utterance = null;
        await _tts.stop();
        return null;
      case 'stop':
      case 'shutdown':
        _utterance = null;
        await _tts.stop();
        return null;
      case 'settings':
        if (isMacHost) {
          // 系统设置里「朗读内容」的深链：macOS 没有 ms-settings，只能走
          // x-apple.systempreferences。
          await Process.run('open', const [
            'x-apple.systempreferences:'
                'com.apple.preference.universalaccess?TextToSpeech',
          ]);
        } else {
          await Process.run('explorer.exe', ['ms-settings:speech']);
        }
        return null;
    }
    throw MissingPluginException(method);
  }

  Future<dynamic> _reader(String method, Map args) async {
    if (isLinuxDesktop &&
        (method == 'setImmersive' || method == 'setBrightness')) {
      throw PlatformException(
        code: 'unsupported_platform',
        message: 'Linux does not provide this Android device control',
      );
    }
    switch (method) {
      case 'start':
        _readerSession = args['session'] as String?;
        _readerTimer?.cancel();
        _readerTimer = Timer.periodic(
          const Duration(minutes: 1),
          (_) => _emit('fqapp/reader/events', _readerStatus()),
        );
        if (!isLinuxDesktop) _setBrightness(args['brightness']);
        return _readerStatus();
      case 'setBrightness':
        _setBrightness(args['brightness']);
        return true;
      case 'keepScreenOn':
        await _setAwake(reader: args['on'] == true);
        return null;
      case 'stop':
      case 'suspend':
        _readerTimer?.cancel();
        readerBrightness.value = 1;
        await _setAwake(reader: false);
        return null;
      case 'setImmersive':
        return null;
      case 'pickFont':
        final file = await openFile(
          acceptedTypeGroups: [
            _openTypeGroup(
              label: '字体',
              extensions: ['ttf', 'otf', 'ttc'],
              iosTypes: ['public.font'],
            ),
          ],
        );
        if (file == null) return null;
        if (await file.length() > 32 * 1024 * 1024) {
          throw PlatformException(code: 'file_size', message: '字体不能超过 32 MB');
        }
        final root = await getApplicationSupportDirectory();
        final fonts = await Directory(
          '${root.path}/fonts',
        ).create(recursive: true);
        final target = File(
          '${fonts.path}/${DateTime.now().microsecondsSinceEpoch}-${_safeName(file.name)}',
        );
        await File(file.path).copy(target.path);
        return {'path': target.path, 'name': file.name};
    }
    if (isLinuxDesktop) {
      throw PlatformException(code: 'unsupported_platform', message: method);
    }
    return null;
  }

  void _setBrightness(dynamic raw) {
    final value = raw is num ? raw.toDouble() : -1.0;
    readerBrightness.value = value < 0 ? 1 : value.clamp(.05, 1);
  }

  Map<String, dynamic> _readerStatus() => {
    'session': _readerSession,
    'timestamp': DateTime.now().millisecondsSinceEpoch,
    if (!isLinuxDesktop) 'systemBrightness': 1.0,
  };
  Future<void> _setAwake({bool? reader, bool? player}) {
    final request = _awakeQueue.then((_) async {
      final oldReader = _readerAwake, oldPlayer = _playerAwake;
      _readerAwake = reader ?? oldReader;
      _playerAwake = player ?? oldPlayer;
      try {
        await _updateAwake();
      } catch (_) {
        _readerAwake = oldReader;
        _playerAwake = oldPlayer;
        rethrow;
      }
    });
    _awakeQueue = request.catchError((Object _) {});
    return request;
  }

  Future<void> _updateAwake() async {
    if (isMacHost) {
      // macOS 没有 SetThreadExecutionState，也没有我们的原生桥：用系统自带的
      // `caffeinate -di` 子进程顶住「系统空闲 / 显示器睡眠」，进程退出即释放。
      _syncCaffeinate(_readerAwake || _playerAwake);
      return;
    }
    if (isLinuxDesktop) {
      await const MethodChannel('fqapp/desktop_session').invokeMethod<void>(
        'setKeepScreenOn',
        {'on': _readerAwake || _playerAwake},
      );
      return;
    }
    if (isIOSPlatform) {
      // iOS 只有一个进程级亮屏开关,reader/player 两份投票已经在 _setAwake
      // 里合成为一个值:某一方撤回自己的票,不能让另一方的常亮跟着一起没。
      if (_readerAwake || _playerAwake) {
        await WakelockPlus.enable();
      } else {
        await WakelockPlus.disable();
      }
      return;
    }
    final call = DynamicLibrary.open('kernel32.dll')
        .lookupFunction<Uint32 Function(Uint32), int Function(int)>(
          'SetThreadExecutionState',
        );
    call(0x80000000 | (_readerAwake || _playerAwake ? 3 : 0));
  }

  /// macOS 侧对应 SetThreadExecutionState：阅读或播放要求常亮时持一个
  /// `caffeinate -di` 子进程（等价 ES_DISPLAY_REQUIRED | ES_SYSTEM_REQUIRED），
  /// 撤回要求时把它杀掉释放断言。
  void _syncCaffeinate(bool want) {
    if (want == (_caffeinate != null)) return;
    if (!want) {
      _caffeinate?.kill();
      _caffeinate = null;
      return;
    }
    unawaited(() async {
      try {
        final process = await Process.start('caffeinate', const ['-d', '-i']);
        // 子进程启动期间要求可能已经被撤回，那就立刻收掉，别留一个孤儿断言。
        if (_readerAwake || _playerAwake) {
          _caffeinate = process;
        } else {
          process.kill();
        }
      } catch (_) {
        // caffeinate 是 macOS 自带命令；这里失败只意味着屏幕可能照常睡，
        // 绝不会影响阅读或播放本身。
      }
    }());
  }

  String _safeName(String name) =>
      name.replaceAll(RegExp(r'[<>:"/\\|?*\x00-\x1f]'), '_');
  Future<String?> _save(
    String name,
    Uint8List bytes,
    List<String> extensions,
  ) async {
    // iOS 没有「另存为」面板(file_selector_ios 没实现 getSaveLocation),
    // 改成写临时文件再弹系统分享面板,由用户决定存到「文件」、发出去还是
    // 取消。返回的是分享文件在**应用私有临时目录**里的路径,调用方不能把
    // 它当成「下载目录」。
    if (isIOSPlatform) {
      return const MethodChannel('fqapp/ios_files').invokeMethod<String>(
        'saveFile',
        {'name': _safeName(name), 'bytes': bytes},
      );
    }
    final location = await getSaveLocation(
      suggestedName: _safeName(name),
      acceptedTypeGroups: [XTypeGroup(label: '文件', extensions: extensions)],
    );
    if (location == null) return null;
    if (isLinuxDesktop) {
      if (!await _saveLinux(location.path, bytes)) return null;
    } else {
      await XFile.fromData(bytes, name: name).saveTo(location.path);
    }
    return location.path;
  }

  Future<bool> _saveLinux(String path, Uint8List bytes) async {
    final libc = DynamicLibrary.process();
    final open = libc
        .lookupFunction<
          Int32 Function(Pointer<Utf8>, Int32, Uint32),
          int Function(Pointer<Utf8>, int, int)
        >('open');
    final close = libc.lookupFunction<Int32 Function(Int32), int Function(int)>(
      'close',
    );
    final errno = libc
        .lookupFunction<Pointer<Int32> Function(), Pointer<Int32> Function()>(
          '__errno_location',
        );
    // Linux open flags: write-only, no symlink following, nonblocking, close-on-exec.
    const flags = 0x1 | 0x20000 | 0x800 | 0x80000;
    final nativePath = path.toNativeUtf8();
    int fd;
    var existing = false;
    try {
      fd = open(
        nativePath,
        flags | 0x40 | 0x80,
        0x1b6,
      ); // O_CREAT | O_EXCL, 0666
      if (fd < 0 && errno().value == 17) {
        // EEXIST
        existing = true;
        fd = open(nativePath, flags, 0);
      }
      if (fd < 0) {
        throw FileSystemException('无法打开保存文件', path, OSError('', errno().value));
      }
    } finally {
      malloc.free(nativePath);
    }
    try {
      // Pin the opened inode: a replaced path must never redirect this write.
      final file = File('/proc/self/fd/$fd');
      final before = await file.stat();
      if (before.type != FileSystemEntityType.file) {
        throw FileSystemException('只能保存到普通文件', path);
      }
      if (existing) {
        final context = navigatorKey.currentContext;
        if (context == null || !context.mounted) {
          throw PlatformException(code: 'not_ready', message: '窗口尚未就绪');
        }
        final confirmed = await showDialog<bool>(
          context: context,
          builder: (context) => AlertDialog(
            title: const Text('覆盖已有文件？'),
            content: Text('文件已存在，覆盖后无法撤销：\n$path'),
            actions: [
              TextButton(
                onPressed: () => Navigator.pop(context, false),
                child: const Text('取消'),
              ),
              FilledButton(
                onPressed: () => Navigator.pop(context, true),
                child: const Text('覆盖'),
              ),
            ],
          ),
        );
        if (confirmed != true) return false;
      }
      final after = await file.stat();
      if (await FileSystemEntity.type(path, followLinks: false) !=
              FileSystemEntityType.file ||
          await Link(file.path).target() !=
              await File(path).resolveSymbolicLinks() ||
          before.size != after.size ||
          before.modified != after.modified ||
          before.changed != after.changed ||
          before.mode != after.mode) {
        throw PlatformException(
          code: 'file_changed',
          message: '目标文件已变化，请重新选择保存位置',
        );
      }
      await file.writeAsBytes(bytes, flush: true);
      if (await Link(file.path).target() !=
          await File(path).resolveSymbolicLinks()) {
        throw PlatformException(code: 'file_changed', message: '保存期间目标文件已被替换');
      }
      return true;
    } finally {
      close(fd);
    }
  }

  Future<Directory> _captureDirectory() async {
    final root = await getApplicationSupportDirectory();
    return Directory('${root.path}/fanqie_capture').create(recursive: true);
  }

  bool _validPart(String name) =>
      RegExp(r'^part-[0-9]+-[a-fA-F0-9-]+\.json$').hasMatch(name);
  Future<dynamic> _backup(String method, Map args) async {
    switch (method) {
      case 'saveBackup':
        return await _save(args['name'] as String, args['bytes'] as Uint8List, [
              'json',
            ]) !=
            null;
      case 'openBackup':
        final selected = await openFile(
          acceptedTypeGroups: [
            _openTypeGroup(
              label: '备份文件',
              extensions: ['json'],
              iosTypes: ['public.json'],
            ),
          ],
        );
        if (selected == null) return null;
        if (await selected.length() > 128 * 1024 * 1024) {
          throw PlatformException(code: 'file_size', message: '备份文件过大');
        }
        return selected.readAsBytes();
      case 'storeFanqieCapture':
        final root = await _captureDirectory();
        final temp = File('${root.path}/latest.tmp');
        await temp.writeAsBytes(args['bytes'] as Uint8List, flush: true);
        await temp.rename('${root.path}/latest.json');
        return true;
      case 'latestFanqieCapture':
        final root = await _captureDirectory();
        final file = File('${root.path}/latest.json');
        return await file.exists() ? file.readAsBytes() : null;
      case 'storeFanqieCapturePart':
        final root = await _captureDirectory();
        final random = Random.secure();
        final suffix = List.generate(
          12,
          (_) => random.nextInt(16).toRadixString(16),
        ).join();
        final name =
            'part-${DateTime.now().microsecondsSinceEpoch}-$suffix.json';
        await File(
          '${root.path}/$name',
        ).writeAsBytes(args['bytes'] as Uint8List, flush: true);
        return name;
      case 'readFanqieCapturePart':
        final name = args['name'] as String;
        if (!_validPart(name)) {
          throw PlatformException(code: 'invalid_part', message: '分卷名称无效');
        }
        final root = await _captureDirectory();
        final file = File('${root.path}/$name');
        return await file.exists() ? file.readAsBytes() : null;
      case 'exportFanqieCapture':
        final root = await _captureDirectory();
        final archive = Archive();
        final bytes = args['bytes'] as Uint8List;
        archive.addFile(ArchiveFile('capture.json', bytes.length, bytes));
        for (final name in (args['parts'] as List).cast<String>().toSet()) {
          if (!_validPart(name)) throw PlatformException(code: 'invalid_part');
          final bytes = await File('${root.path}/$name').readAsBytes();
          archive.addFile(ArchiveFile(name, bytes.length, bytes));
        }
        return await _save(
              args['name'] as String,
              Uint8List.fromList(ZipEncoder().encode(archive)),
              ['zip'],
            ) !=
            null;
    }
    throw MissingPluginException(method);
  }

  Future<Map<String, dynamic>?> pickBook() async {
    final file = await openFile(
      acceptedTypeGroups: [
        _openTypeGroup(
          label: '本地书籍',
          extensions: ['txt', 'epub'],
          iosTypes: ['public.plain-text', 'org.idpf.epub-container'],
        ),
      ],
    );
    if (file == null) return null;
    if (await file.length() > 32 * 1024 * 1024) {
      throw PlatformException(code: 'file_size', message: '书籍不能超过 32 MB');
    }
    final bytes = await file.readAsBytes();
    final text = Platform.isLinux && file.name.toLowerCase().endsWith('.txt')
        ? await decodeLinuxText(bytes)
        : null;
    return {
      'name': file.name,
      'bytes': bytes,
      'byteLength': bytes.length,
      if (file.name.toLowerCase().endsWith('.txt'))
        'text': text ?? decodeDesktopText(bytes),
    };
  }
}

/// Decode the already size-checked bytes; never re-read a mutable picked file.
Future<String> decodeLinuxText(Uint8List bytes) async {
  if (bytes.length >= 2 &&
      ((bytes[0] == 255 && bytes[1] == 254) ||
          (bytes[0] == 254 && bytes[1] == 255))) {
    return decodeDesktopText(bytes);
  }
  try {
    return utf8.decode(bytes).replaceFirst(RegExp('^\uFEFF'), '');
  } on FormatException {
    final process = await Process.start('iconv', [
      '-f',
      'GB18030',
      '-t',
      'UTF-8',
    ]);
    final output = process.stdout.transform(utf8.decoder).join();
    final errors = process.stderr.drain<void>();
    process.stdin.add(bytes);
    await process.stdin.close();
    final text = await output;
    await errors;
    if (await process.exitCode != 0) throw const FormatException('无法解码本地书籍');
    return text;
  }
}

String decodeDesktopText(Uint8List bytes) {
  if (bytes.length >= 2 &&
      ((bytes[0] == 255 && bytes[1] == 254) ||
          (bytes[0] == 254 && bytes[1] == 255))) {
    final little = bytes[0] == 255;
    return String.fromCharCodes([
      for (var i = 2; i + 1 < bytes.length; i += 2)
        little ? bytes[i] | bytes[i + 1] << 8 : bytes[i] << 8 | bytes[i + 1],
    ]);
  }
  try {
    return utf8.decode(bytes).replaceFirst(RegExp('^\uFEFF'), '');
  } on FormatException {
    // 中文 TXT 大量是 GBK/GB18030。Windows 上有系统转换 API,其余平台只能
    // 走系统 libiconv —— 早先这里无条件 `DynamicLibrary.open('kernel32.dll')`,
    // 在 iOS/macOS 上必然打不开,导入 GB18030 的 TXT 只剩一句失败的提示。
    return Platform.isWindows
        ? _decodeGb18030Windows(bytes)
        : _decodeGb18030Iconv(bytes);
  }
}

/// GB18030 → UTF-16,走 Windows 的 `MultiByteToWideChar`(代码页 54936)。
///
/// flags=0 表示宽松转换:遇到非法字节用 U+FFFD 顶替,而不是整段失败。
String _decodeGb18030Windows(Uint8List bytes) {
  final convert = DynamicLibrary.open('kernel32.dll')
      .lookupFunction<
        Int32 Function(
          Uint32,
          Uint32,
          Pointer<Uint8>,
          Int32,
          Pointer<Uint16>,
          Int32,
        ),
        int Function(int, int, Pointer<Uint8>, int, Pointer<Uint16>, int)
      >('MultiByteToWideChar');
  final input = calloc<Uint8>(bytes.length);
  input.asTypedList(bytes.length).setAll(0, bytes);
  Pointer<Uint16> output = nullptr;
  try {
    final length = convert(54936, 0, input, bytes.length, nullptr, 0);
    if (length == 0) throw const FormatException('无法识别 TXT 编码');
    output = calloc<Uint16>(length);
    if (convert(54936, 0, input, bytes.length, output, length) == 0) {
      throw const FormatException('无法读取 TXT');
    }
    return String.fromCharCodes(output.asTypedList(length));
  } finally {
    calloc.free(input);
    if (output != nullptr) calloc.free(output);
  }
}

typedef _IconvOpenNative = Pointer<Void> Function(Pointer<Utf8>, Pointer<Utf8>);
typedef _IconvOpenDart = Pointer<Void> Function(Pointer<Utf8>, Pointer<Utf8>);
typedef _IconvNative =
    IntPtr Function(
      Pointer<Void>,
      Pointer<Pointer<Uint8>>,
      Pointer<IntPtr>,
      Pointer<Pointer<Uint8>>,
      Pointer<IntPtr>,
    );
typedef _IconvDart =
    int Function(
      Pointer<Void>,
      Pointer<Pointer<Uint8>>,
      Pointer<IntPtr>,
      Pointer<Pointer<Uint8>>,
      Pointer<IntPtr>,
    );
typedef _IconvCloseNative = Int32 Function(Pointer<Void>);
typedef _IconvCloseDart = int Function(Pointer<Void>);
typedef _ErrnoNative = Pointer<Int32> Function();
typedef _ErrnoDart = Pointer<Int32> Function();

/// `iconv_open` 失败时返回 `(iconv_t)-1`,也就是整字全是 1 的指针。
///
/// Dart 把这个字读成有符号整数,所以哨兵只等于 -1:拿 `>= 0` 之类的判断会
/// 把失败当成成功,然后把这个假描述符交给 `iconv`。
const _iconvInvalid = -1;

/// 输出缓冲单轮大小。写满时 `iconv` 报 E2BIG,续下一轮。
const _iconvChunk = 1 << 16;

/// libc 里 errno 的访问器各平台不同名:Apple 是 `__error`,glibc/musl 是
/// `__errno_location`,bionic 是 `__errno`。
Pointer<Int32> Function() _errnoAccessor(DynamicLibrary libc) {
  for (final name in const ['__error', '__errno_location', '__errno']) {
    try {
      return libc.lookupFunction<_ErrnoNative, _ErrnoDart>(name);
    } on ArgumentError {
      continue;
    }
  }
  throw const FormatException('无法识别 TXT 编码');
}

/// GB18030 → UTF-8,走系统 libiconv。
///
/// iOS/macOS 的 libiconv 在 libSystem 里、随进程一起加载,所以能从
/// `DynamicLibrary.process()` 的全局符号里查到(iOS 不允许像桌面那样
/// dlopen 系统库;`-liconv` 只负责让链接器认这个库)。
///
/// macOS 桌面版是例外：进程符号表里没有 `iconv_open`（libiconv 是独立的
/// dylib），必须按路径 dlopen `/usr/lib/libiconv.2.dylib`；只有 iOS 才走
/// `DynamicLibrary.process()`。
String _decodeGb18030Iconv(Uint8List bytes) {
  final libc = Platform.isMacOS
      ? DynamicLibrary.open('/usr/lib/libiconv.2.dylib')
      : DynamicLibrary.process();
  final open = libc.lookupFunction<_IconvOpenNative, _IconvOpenDart>(
    'iconv_open',
  );
  final convert = libc.lookupFunction<_IconvNative, _IconvDart>('iconv');
  final close = libc.lookupFunction<_IconvCloseNative, _IconvCloseDart>(
    'iconv_close',
  );
  final errno = _errnoAccessor(libc);
  // E2BIG:输出缓冲不够。POSIX 里各平台一致是 7。
  const e2big = 7;
  final target = 'UTF-8'.toNativeUtf8();
  Pointer<Void> descriptor = nullptr;
  try {
    // 各平台库里的编码名不完全一致:GB18030 覆盖 GBK/CP936,缺了再退一级。
    for (final name in const ['GB18030', 'GBK', 'CP936']) {
      final source = name.toNativeUtf8();
      try {
        descriptor = open(target, source);
      } finally {
        // iconv_open 自己复制编码名,这里可以立刻释放。
        calloc.free(source);
      }
      if (descriptor != nullptr && descriptor.address != _iconvInvalid) break;
    }
  } finally {
    calloc.free(target);
  }
  if (descriptor == nullptr || descriptor.address == _iconvInvalid) {
    throw const FormatException('无法识别 TXT 编码');
  }
  final input = calloc<Uint8>(bytes.length);
  input.asTypedList(bytes.length).setAll(0, bytes);
  final inPtr = calloc<Pointer<Uint8>>()..value = input;
  final inLeft = calloc<IntPtr>()..value = bytes.length;
  final outBuf = calloc<Uint8>(_iconvChunk);
  final outPtr = calloc<Pointer<Uint8>>();
  final outLeft = calloc<IntPtr>();
  // 输出缓冲每轮复用,而 [BytesBuilder] 默认会复制 add 进来的那一段,所以
  // 下一轮覆盖 outBuf 不会动到已经收下的字节。
  final builder = BytesBuilder();
  try {
    while (inLeft.value > 0) {
      outPtr.value = outBuf;
      outLeft.value = _iconvChunk;
      final result = convert(descriptor, inPtr, inLeft, outPtr, outLeft);
      final produced = _iconvChunk - outLeft.value;
      if (produced > 0) builder.add(outBuf.asTypedList(produced));
      // 成功:iconv 只有在吃完所有输入时才不返回 -1。
      if (result != -1) break;
      // 失败必须看 errno:只有 E2BIG(输出写满)才续下一轮。EILSEQ/EINVAL
      // 说明这段字节不是 GB18030,已经产出的半截文本不能当成导入成功。
      if (errno().value == e2big && produced > 0) continue;
      throw const FormatException('无法识别 TXT 编码');
    }
  } finally {
    close(descriptor);
    calloc.free(input);
    calloc.free(inPtr);
    calloc.free(inLeft);
    calloc.free(outBuf);
    calloc.free(outPtr);
    calloc.free(outLeft);
  }
  return utf8.decode(builder.takeBytes());
}

/// `create` 下发的续播起点（`startPositionMs`，> 0 才有）落到 media_kit 的
/// [Media.start] 上。
///
/// media_kit 在 mpv 的 on_load 钩子里把它设成 `start` 属性，即 prepare 前生效，
/// 与 Android 端约定一致；Dart 侧 `NativePlayer` 也已按起点显示进度和弹幕锚点。
/// 加密流走本地 CENC 代理，起点处的读取是普通的 `Range: bytes=N-` 请求，
/// 与拖动进度条走同一条路。
@visibleForTesting
Media desktopPlaybackMedia(String uri, Object? startPositionMs) {
  final startMs = startPositionMs is num ? startPositionMs.toInt() : 0;
  return Media(
    uri,
    start: startMs > 0 ? Duration(milliseconds: startMs) : null,
  );
}

/// 为刚建好的 media_kit [VideoController] 请求一帧。
///
/// `VideoController` 构造时用 `addPostFrameCallback` 推迟纹理创建，
/// `Player.open` 又会等 `VideoController` 初始化完成；而 `addPostFrameCallback`
/// 本身不请求帧。窗口静止时（例如 Windows 短剧 feed 起播第一集，画面上只有
/// 一张静态封面），没有任何东西请求新帧，`open` 就一直挂着，直到鼠标划过
/// 窗口触发重绘，或 Dart 侧 25 秒的创建超时报「播放失败」。后续集数不受影响，
/// 因为正在播的视频会持续驱动帧。Windows 与 Linux 都会遇到。
@visibleForTesting
void requestVideoControllerFrame() => WidgetsBinding.instance.scheduleFrame();

/// 诊断构建开关：`--dart-define=FQAPP_PLAYER_DIAGNOSTICS=true` 时把 mpv 日志
/// 放宽到 info 级写进应用日志，用来排查「某些剧集播不了」。产品构建不开。
const desktopPlayerDiagnostics = bool.fromEnvironment(
  'FQAPP_PLAYER_DIAGNOSTICS',
);

class _DesktopPlayer {
  _DesktopPlayer(this.id, this.emit) {
    video = VideoController(player);
    requestVideoControllerFrame();
    void event(String type, dynamic value) {
      if (!disposed && !_reopening) {
        emit({'playerId': id, 'type': type, 'value': value});
      }
    }

    subscriptions.addAll([
      player.stream.position.listen((v) => event('position', v.inMilliseconds)),
      player.stream.duration.listen((v) => event('duration', v.inMilliseconds)),
      player.stream.playing.listen((v) {
        AppLog.d('desktop-player', 'id=$id playing=$v');
        event('playing', v);
      }),
      player.stream.buffering.listen((v) => event('buffering', v)),
      player.stream.completed.listen((v) => event('completed', v)),
      player.stream.width.listen((_) => _size()),
      player.stream.height.listen((_) => _size()),
      player.stream.error.listen((message) {
        // 界面只给通用提示；原始错误（解码器、HTTP 状态、解密）留在日志里排查。
        AppLog.w('desktop-player', 'id=$id mpv error: $message');
        event('error', {'message': '媒体播放失败，请重试或切换清晰度'});
      }),
      // 默认只有 error 级会到这里；诊断构建放宽到 info，能看到开流、
      // 选轨、编码格式、硬解是否生效等起播过程。
      player.stream.log.listen(
        (log) => AppLog.d(
          'mpv',
          'id=$id [${log.prefix}] ${log.level}: ${log.text.trimRight()}',
        ),
      ),
    ]);
    unawaited(
      video.waitUntilFirstFrameRendered.then((_) => event('firstFrame', true)),
    );
  }
  final int id;
  final void Function(Map<String, dynamic>) emit;
  final player = Player(
    configuration: const PlayerConfiguration(
      logLevel: desktopPlayerDiagnostics ? MPVLogLevel.info : MPVLogLevel.error,
    ),
  );
  late final VideoController video;
  final subscriptions = <StreamSubscription<dynamic>>[];
  final ready = Completer<void>();
  DesktopMedia? media;
  bool disposed = false;
  bool _reopening = false;
  Future<void> _reopenQueue = Future<void>.value();
  Future<void> open(String url, String key, {Object? startPositionMs}) async {
    ready.future.ignore();
    try {
      var playbackUrl = url;
      if (key.isNotEmpty) {
        final session = await DesktopMedia.open(url, key);
        if (disposed) {
          session.close();
          return;
        }
        media = session;
        playbackUrl = session.url;
      }
      // Plain audio/video follows the original URI player contract. Some
      // public audio origins return 200 only and must not require CENC Range I/O.
      if (disposed) return;
      await player.open(
        desktopPlaybackMedia(playbackUrl, startPositionMs),
        play: false,
      );
      AppLog.d('desktop-player', 'id=$id opened paused');
      if (disposed) return;
      ready.complete();
      emit({'playerId': id, 'type': 'created', 'value': id});
      _size();
    } catch (error) {
      if (!ready.isCompleted) ready.completeError(StateError('无法打开媒体'));
      final value = desktopOpenFailure(id, error);
      if (!disposed) {
        emit({'playerId': id, 'type': 'error', 'value': value});
      }
      media?.close();
    }
  }

  /// 复用当前 mpv 实例换源，新源打开后才释放旧代理会话。
  ///
  /// 这条路径专门给 iOS 后台用：后台新建 `Player()` 会卡在音频输出初始化
  /// （实测 25 秒超时都回不来），而同一个实例 `open()` 新地址是可行的。
  Future<void> reopen(String url, String key, int request) {
    final operation = _reopenQueue.then((_) => _reopen(url, key, request));
    _reopenQueue = operation.catchError((Object _) {});
    return operation;
  }

  Future<void> _reopen(String url, String key, int request) async {
    if (disposed) return;
    DesktopMedia? nextMedia;
    final previousMedia = media;
    _reopening = true;
    try {
      var playbackUrl = url;
      if (key.isNotEmpty) {
        final session = await DesktopMedia.open(url, key);
        nextMedia = session;
        if (disposed) {
          session.close();
          return;
        }
        playbackUrl = session.url;
      }
      if (disposed) return;
      await player.open(desktopPlaybackMedia(playbackUrl, null), play: false);
      AppLog.d('desktop-player', 'id=$id reopened paused');
      if (disposed) return;
      media = nextMedia;
      previousMedia?.close();
      _reopening = false;
      for (final entry in {
        'position': player.state.position.inMilliseconds,
        'duration': player.state.duration.inMilliseconds,
        'playing': false,
        'playWhenReady': false,
        'completed': false,
      }.entries) {
        emit({'playerId': id, 'type': entry.key, 'value': entry.value});
      }
      emit({
        'playerId': id,
        'type': 'reopened',
        'value': id,
        'requestId': request,
      });
      _size();
    } catch (error) {
      nextMedia?.close();
      final value = desktopOpenFailure(id, error);
      if (!disposed) {
        emit({
          'playerId': id,
          'type': 'error',
          'value': value,
          'requestId': request,
        });
      }
    } finally {
      _reopening = false;
      if (disposed) nextMedia?.close();
    }
  }

  void _size() {
    if (!disposed) {
      emit({
        'playerId': id,
        'type': 'videoSize',
        'width': player.state.width ?? 0,
        'height': player.state.height ?? 0,
        'rotationCorrection': 0,
      });
    }
  }

  Future<void> command(String method, Map args) async {
    await ready.future;
    if (disposed) return;
    AppLog.d('desktop-player', 'id=$id command=$method');
    switch (method) {
      case 'play':
        await player.play();
        emit({'playerId': id, 'type': 'playWhenReady', 'value': true});
      case 'pause':
        await player.pause();
        emit({'playerId': id, 'type': 'playWhenReady', 'value': false});
      case 'seek':
        await player.seek(
          Duration(milliseconds: (args['positionMs'] as num).toInt()),
        );
      case 'setRate':
        await player.setRate((args['rate'] as num).toDouble());
      case 'setVolume':
        await player.setVolume(
          (args['volume'] as num).toDouble().clamp(0, 1) * 100,
        );
      default:
        throw MissingPluginException(method);
    }
  }

  Future<void> dispose() async {
    if (disposed) return;
    disposed = true;
    if (!ready.isCompleted) ready.complete();
    for (final subscription in subscriptions) {
      await subscription.cancel();
    }
    try {
      await player.dispose();
    } finally {
      media?.close();
    }
  }
}
