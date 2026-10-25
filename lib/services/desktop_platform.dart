import 'package:screen_retriever/screen_retriever.dart';
import 'dart:async';
import 'dart:convert';
import 'dart:ffi' hide Size;
import 'dart:io';
import 'dart:math';

import 'package:archive/archive.dart';
import 'package:ffi/ffi.dart';
import 'package:file_selector/file_selector.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_tts/flutter_tts.dart';
import 'package:media_kit/media_kit.dart';
import 'package:media_kit_video/media_kit_video.dart';
import 'package:path_provider/path_provider.dart';
import 'package:smtc_windows/smtc_windows.dart';
import 'package:window_manager/window_manager.dart';

import '../widgets/desktop_login.dart';
import 'desktop_media.dart';
import 'app_log.dart';
import 'platform_channel.dart';

bool get isWindowsDesktop =>
    !kIsWeb && defaultTargetPlatform == TargetPlatform.windows;

bool get isMacDesktop =>
    !kIsWeb && defaultTargetPlatform == TargetPlatform.macOS;

/// Desktop hosts (Windows / macOS) share every path in this file except the
/// handful of OS-specific primitives below (`_updateAwake`, `decodeDesktopText`,
/// SMTC media keys, the TTS settings deep link).
bool get isDesktopHost => isWindowsDesktop || isMacDesktop;

/// Real host operating system, for code that picks a native library or binary.
///
/// Never use [defaultTargetPlatform] for that decision: `flutter test` forces it
/// to [TargetPlatform.android] (via the FLUTTER_TEST env var), so a
/// TargetPlatform check would send a macOS test run down the kernel32 path and
/// fail with "Failed to load dynamic library 'kernel32.dll'".
bool get isMacHost => !kIsWeb && Platform.isMacOS;
bool get isWindowsHost => !kIsWeb && Platform.isWindows;

/// On Windows/macOS an inactive window is still visible; it simply lacks input
/// focus. Only hidden/paused/detached windows should defer foreground video
/// playback.
bool playbackAppIsActive(AppLifecycleState? state) =>
    state == null ||
    state == AppLifecycleState.resumed ||
    (isDesktopHost && state == AppLifecycleState.inactive);

class DesktopPlatform with WindowListener {
  DesktopPlatform._();
  static final instance = DesktopPlatform._();
  static final navigatorKey = GlobalKey<NavigatorState>();
  static final readerBrightness = ValueNotifier<double>(1);
  static final fullscreen = ValueNotifier<bool>(false);
  final _events = <String, StreamController<dynamic>>{};
  final _players = <int, _DesktopPlayer>{};
  final _tts = FlutterTts();
  SMTCWindows? _smtc;
  String? _utterance;
  int _nextId = 1000000;
  bool _closing = false;
  Future<void> Function()? beforeClose;
  bool _readerAwake = false;
  bool _playerAwake = false;
  Process? _caffeinate;
  String? _readerSession;
  Timer? _readerTimer;

  Stream<dynamic> events(String name) =>
      (_events[name] ??= StreamController<dynamic>.broadcast()).stream;
  void _emit(String name, dynamic event) => _events[name]?.add(event);

  Future<void> initialize() async {
    if (!isDesktopHost) return;
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
      ),
      () async {
        await windowManager.show();
        await windowManager.focus();
      },
    );
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
    // Optional system media integration must not prevent reading or startup.
    // SMTC is the Windows system-media (SMTC) bridge; macOS would need
    // MPNowPlayingInfoCenter/MPRemoteCommandCenter in the runner and is
    // deliberately left out of this port (media keys simply do nothing).
    if (isWindowsDesktop) {
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
    await windowManager.setFullScreen(value);
    fullscreen.value = value;
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
          final id = _nextId++;
          final host = _DesktopPlayer(
            id,
            (event) => _emit('fqapp/native_player/events', event),
          );
          _players[id] = host;
          unawaited(
            host.open(args['cdnUrl'] as String, args['keyHex'] as String),
          );
          return {'playerId': id};
        }
        if (method == 'setKeepScreenOn') {
          _playerAwake = args['on'] == true;
          _updateAwake();
          return null;
        }
        if (method == 'startListenForeground') {
          final smtc = _smtc;
          if (smtc == null) return null;
          await smtc.updateMetadata(
            MusicMetadata(
              title: args['title'] as String?,
              artist: args['episode'] as String?,
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
        await host.command(method, args);
        return null;
      case 'fqapp/library_backup':
        return _backup(method, args);
      case 'fqapp/local_books':
        if (method == 'pickBookFile') return _pickBook();
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
          return {'path': path, 'public': true};
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
    final engineKey = isMacHost ? 'macos' : 'windows';
    final engineLabel = isMacHost ? 'macOS 系统语音' : 'Windows 默认语音';
    switch (method) {
      case 'engines':
        final voices = await _tts.getVoices;
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
        await _tts.setSpeechRate(
          ((args['rate'] as num?)?.toDouble() ?? 1) * .5,
        );
        return 300;
      case 'speak':
        _utterance = args['id'] as String;
        final result = await _tts.speak(args['text'] as String);
        if (result == 0) {
          throw PlatformException(
            code: 'tts_failed',
            message: isMacHost ? 'macOS 语音不可用，请在系统设置中启用语音' : 'Windows 语音不可用，请安装中文语音',
          );
        }
        return null;
      case 'stop':
      case 'shutdown':
        _utterance = null;
        await _tts.stop();
        return null;
      case 'settings':
        if (isMacHost) {
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
    switch (method) {
      case 'start':
        _readerSession = args['session'] as String?;
        _readerTimer?.cancel();
        _readerTimer = Timer.periodic(
          const Duration(minutes: 1),
          (_) => _emit('fqapp/reader/events', _readerStatus()),
        );
        _setBrightness(args['brightness']);
        return _readerStatus();
      case 'setBrightness':
        _setBrightness(args['brightness']);
        return true;
      case 'keepScreenOn':
        _readerAwake = args['on'] == true;
        _updateAwake();
        return null;
      case 'stop':
      case 'suspend':
        _readerTimer?.cancel();
        readerBrightness.value = 1;
        _readerAwake = false;
        _updateAwake();
        return null;
      case 'setImmersive':
        return null;
      case 'pickFont':
        final file = await openFile(
          acceptedTypeGroups: [
            const XTypeGroup(label: '字体', extensions: ['ttf', 'otf', 'ttc']),
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
    return null;
  }

  void _setBrightness(dynamic raw) {
    final value = raw is num ? raw.toDouble() : -1.0;
    readerBrightness.value = value < 0 ? 1 : value.clamp(.05, 1);
  }

  Map<String, dynamic> _readerStatus() => {
    'session': _readerSession,
    'timestamp': DateTime.now().millisecondsSinceEpoch,
    'systemBrightness': 1.0,
  };
  void _updateAwake() {
    final want = _readerAwake || _playerAwake;
    if (isMacHost) {
      _syncCaffeinate(want);
      return;
    }
    if (!isWindowsHost) return;
    final call = DynamicLibrary.open('kernel32.dll')
        .lookupFunction<Uint32 Function(Uint32), int Function(int)>(
          'SetThreadExecutionState',
        );
    call(0x80000000 | (want ? 3 : 0));
  }

  /// macOS counterpart of SetThreadExecutionState: hold a `caffeinate -di`
  /// child while the reader or player must stay awake, kill it to release the
  /// assertion (ES_DISPLAY_REQUIRED | ES_SYSTEM_REQUIRED equivalent).
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
        // The UI may have released the assertion while the child was starting.
        if (_readerAwake || _playerAwake) {
          _caffeinate = process;
        } else {
          process.kill();
        }
      } catch (_) {
        // caffeinate is part of every macOS install; a failure here only means
        // the display may sleep, never that reading or playback breaks.
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
    final location = await getSaveLocation(
      suggestedName: _safeName(name),
      acceptedTypeGroups: [XTypeGroup(label: '文件', extensions: extensions)],
    );
    if (location == null) return null;
    await XFile.fromData(bytes, name: name).saveTo(location.path);
    return location.path;
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
            const XTypeGroup(label: '备份文件', extensions: ['json']),
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

  Future<Map<String, dynamic>?> _pickBook() async {
    final file = await openFile(
      acceptedTypeGroups: [
        const XTypeGroup(label: '本地书籍', extensions: ['txt', 'epub']),
      ],
    );
    if (file == null) return null;
    if (await file.length() > 32 * 1024 * 1024) {
      throw PlatformException(code: 'file_size', message: '书籍不能超过 32 MB');
    }
    final bytes = await file.readAsBytes();
    return {
      'name': file.name,
      'bytes': bytes,
      'byteLength': bytes.length,
      if (file.name.toLowerCase().endsWith('.txt'))
        'text': decodeDesktopText(bytes),
    };
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
    if (isMacHost) return decodeGb18030(bytes);
    if (!isWindowsHost) throw const FormatException('无法识别 TXT 编码');
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
}

/// macOS counterpart of the Windows `MultiByteToWideChar(54936, ...)` path:
/// decode GBK/GB18030 TXT bytes through libiconv (part of the OS, no extra
/// dependency) and hand back the UTF-8 string.
String decodeGb18030(Uint8List bytes) {
  final libiconv = DynamicLibrary.open('/usr/lib/libiconv.2.dylib');
  final openIconv = libiconv.lookupFunction<
    Pointer<Void> Function(Pointer<Utf8>, Pointer<Utf8>),
    Pointer<Void> Function(Pointer<Utf8>, Pointer<Utf8>)
  >('iconv_open');
  // size_t 在这里按有符号 64 位声明：iconv 用 (size_t)-1 表示出错，用 Int64
  // 声明可以直接拿到 -1，不受无符号回绕影响（ABI 上两者一致）。
  final convertIconv = libiconv.lookupFunction<
    Int64 Function(
      Pointer<Void>,
      Pointer<Pointer<Uint8>>,
      Pointer<Uint64>,
      Pointer<Pointer<Uint8>>,
      Pointer<Uint64>,
    ),
    int Function(
      Pointer<Void>,
      Pointer<Pointer<Uint8>>,
      Pointer<Uint64>,
      Pointer<Pointer<Uint8>>,
      Pointer<Uint64>,
    )
  >('iconv');
  final closeIconv = libiconv.lookupFunction<
    Int32 Function(Pointer<Void>),
    int Function(Pointer<Void>)
  >('iconv_close');

  final target = 'UTF-8'.toNativeUtf8();
  final source = 'GB18030'.toNativeUtf8();
  final handle = openIconv(target, source);
  calloc.free(target);
  calloc.free(source);
  if (handle.address == -1) throw const FormatException('无法识别 TXT 编码');

  final input = calloc<Uint8>(bytes.length);
  input.asTypedList(bytes.length).setAll(0, bytes);
  // GB18030 is at most 4 bytes per character, so 4x the input is a hard bound.
  final capacity = bytes.length * 4 + 16;
  final output = calloc<Uint8>(capacity);
  final inPointer = calloc<Pointer<Uint8>>();
  final outPointer = calloc<Pointer<Uint8>>();
  final inLeft = calloc<Uint64>();
  final outLeft = calloc<Uint64>();
  try {
    inPointer.value = input;
    outPointer.value = output;
    inLeft.value = bytes.length;
    outLeft.value = capacity;
    // iconv returns (size_t)-1 on an unconvertible sequence, otherwise the
    // (normally zero) count of irreversible conversions.
    if (convertIconv(handle, inPointer, inLeft, outPointer, outLeft) < 0) {
      throw const FormatException('无法识别 TXT 编码');
    }
    return utf8.decode(output.asTypedList(capacity - outLeft.value));
  } finally {
    calloc.free(inPointer);
    calloc.free(outPointer);
    calloc.free(inLeft);
    calloc.free(outLeft);
    calloc.free(input);
    calloc.free(output);
    closeIconv(handle);
  }
}

/// 从 Rust 探针的中文错误里抠出 HTTP 状态码（`取流失败 status=403`）。
int? _probeStatus(String detail) {
  final match = RegExp(r'status=(\d{3})').firstMatch(detail);
  final group = match?.group(1);
  return group == null ? null : int.tryParse(group);
}

class _DesktopPlayer {
  _DesktopPlayer(this.id, this.emit) {
    video = VideoController(player);
    void event(String type, dynamic value) {
      if (!disposed) emit({'playerId': id, 'type': type, 'value': value});
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
      player.stream.error.listen(
        (_) => event('error', {
          'message': '媒体播放失败，请重试或切换清晰度',
          // 3 = 播放器在起播/解码阶段报错（创建已成功）。
          'errorCode': 3,
        }),
      ),
    ]);
    unawaited(
      video.waitUntilFirstFrameRendered.then((_) => event('firstFrame', true)),
    );
  }
  final int id;
  final void Function(Map<String, dynamic>) emit;
  final player = Player();
  late final VideoController video;
  final subscriptions = <StreamSubscription<dynamic>>[];
  final ready = Completer<void>();
  DesktopMedia? media;
  bool disposed = false;
  Future<void> open(String url, String key) async {
    ready.future.ignore();
    // 两段失败原因完全不同，分开记：探针阶段的消息来自 Rust 的固定字面量
    // （连不上 / 不是 206 / 长度无效 / 密钥解不开），可以原样落盘；播放器
    // 阶段抛的异常可能带着签名后的播放地址，只记类型。
    var stage = 'probe';
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
      stage = 'player';
      await player.open(Media(playbackUrl), play: false);
      AppLog.d('desktop-player', 'id=$id opened paused');
      if (disposed) return;
      ready.complete();
      emit({'playerId': id, 'type': 'created', 'value': id});
      _size();
    } catch (error) {
      // 探针阶段的文案是 Rust 里的固定字面量，原样落盘正好区分「连不上」与
      // 「不是 206」「密钥/首块解不开」；播放器阶段的异常只留类型。
      final detail = stage == 'probe' && error is StateError
          ? error.message
          : '${error.runtimeType}';
      // 只记 CDN 主机名，不落带签名的完整地址。
      final host = Uri.tryParse(url)?.host ?? '';
      AppLog.d('desktop-open', 'step=$stage host=$host error=$detail');
      final status = stage == 'probe' ? _probeStatus(detail) : null;
      if (!ready.isCompleted) ready.completeError(StateError('无法打开媒体'));
      if (!disposed) {
        emit({
          'playerId': id,
          'type': 'error',
          'value': {
            'message': '媒体加载失败，请检查网络或重试',
            // 1 = 取流/解密失败（桌面端探针），2 = 播放器打不开媒体。
            'errorCode': stage == 'probe' ? 1 : 2,
            'httpStatusCode': ?status,
          },
        });
      }
      media?.close();
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
    for (final subscription in subscriptions) {
      await subscription.cancel();
    }
    await player.dispose();
    media?.close();
  }
}
