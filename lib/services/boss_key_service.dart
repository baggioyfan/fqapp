import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:window_manager/window_manager.dart';

import 'app_log.dart';
import 'boss_key_preferences.dart';
import 'desktop_platform.dart';
import 'native_player.dart';

/// Current runtime status of the desktop boss key service.
@immutable
class BossKeyStatus {
  const BossKeyStatus({
    this.globalHotkeySupported = true,
    this.backend = 'unknown',
    this.registered = false,
    this.activeShortcut,
    this.hidden = false,
    this.errorMessage,
  });

  final bool globalHotkeySupported;
  final String backend;
  final bool registered;
  final BossKeyShortcut? activeShortcut;
  final bool hidden;
  final String? errorMessage;

  BossKeyStatus copyWith({
    bool? globalHotkeySupported,
    String? backend,
    bool? registered,
    BossKeyShortcut? activeShortcut,
    bool clearActiveShortcut = false,
    bool? hidden,
    String? errorMessage,
    bool clearErrorMessage = false,
  }) => BossKeyStatus(
    globalHotkeySupported: globalHotkeySupported ?? this.globalHotkeySupported,
    backend: backend ?? this.backend,
    registered: registered ?? this.registered,
    activeShortcut: clearActiveShortcut
        ? null
        : (activeShortcut ?? this.activeShortcut),
    hidden: hidden ?? this.hidden,
    errorMessage: clearErrorMessage
        ? null
        : (errorMessage ?? this.errorMessage),
  );
}

/// Outcome of enabling, disabling, or updating the boss key shortcut.
@immutable
class BossKeyApplyResult {
  const BossKeyApplyResult.success() : ok = true, errorMessage = null;
  const BossKeyApplyResult.failure(this.errorMessage) : ok = false;

  final bool ok;
  final String? errorMessage;
}

/// Native global-hotkey bridge (Windows Win32 `RegisterHotKey`, Linux X11 `XGrabKey`).
abstract class BossKeyNativeBridge {
  Future<({bool globalHotkey, String backend})> capabilities();
  Future<void> register(BossKeyShortcut shortcut);
  Future<void> unregister();
  void setTriggerHandler(Future<void> Function()? onTriggered);
}

/// Desktop window visibility and taskbar control for the boss key.
abstract class BossKeyWindowControl {
  Future<bool> isVisible();
  Future<void> hide();
  Future<void> restore();
}

class _MethodChannelBossKeyBridge implements BossKeyNativeBridge {
  static const _channel = MethodChannel('fqapp/boss_key');

  @override
  Future<({bool globalHotkey, String backend})> capabilities() async {
    final map = await _channel.invokeMapMethod<String, dynamic>('capabilities');
    return (
      globalHotkey: map?['globalHotkey'] == true,
      backend: map?['backend'] is String
          ? map!['backend'] as String
          : 'unknown',
    );
  }

  @override
  Future<void> register(BossKeyShortcut shortcut) async {
    await _channel.invokeMethod<void>('register', shortcut.toPlatformArgs());
  }

  @override
  Future<void> unregister() async {
    await _channel.invokeMethod<void>('unregister');
  }

  @override
  void setTriggerHandler(Future<void> Function()? onTriggered) {
    if (onTriggered == null) {
      _channel.setMethodCallHandler(null);
      return;
    }
    _channel.setMethodCallHandler((call) async {
      if (call.method == 'onTriggered') {
        await onTriggered();
      }
      return null;
    });
  }
}

class _WindowManagerBossKeyControl implements BossKeyWindowControl {
  @override
  Future<bool> isVisible() => windowManager.isVisible();

  @override
  Future<void> hide() async {
    await windowManager.hide();
    await windowManager.setSkipTaskbar(true);
  }

  @override
  Future<void> restore() async {
    await windowManager.setSkipTaskbar(false);
    if (await windowManager.isMinimized()) {
      await windowManager.restore();
    }
    await windowManager.show();
    await windowManager.focus();
  }
}

/// Coordinates desktop global hotkey registration, window hiding/restoration,
/// and pausing active media playback (drama video, audiobook, system TTS).
class BossKeyService {
  BossKeyService._();

  static final BossKeyService instance = BossKeyService._();

  static const _triggerDebounce = Duration(milliseconds: 300);

  /// Registered by `AudioPlaybackScope` so audiobook and system-TTS sessions
  /// pause through their own controllers (updating UI and SMTC/MPRIS cleanly).
  static Future<void> Function()? pauseAudioScope;

  BossKeyNativeBridge _bridge = _MethodChannelBossKeyBridge();
  BossKeyWindowControl _windowControl = _WindowManagerBossKeyControl();
  Future<void> Function()? _pausePlaybackOverride;
  DateTime Function() _clock = DateTime.now;
  bool Function() _platformSupported = () => isMediaDesktop;

  final ValueNotifier<BossKeyStatus> status = ValueNotifier<BossKeyStatus>(
    const BossKeyStatus(),
  );

  bool _initialized = false;
  bool _toggling = false;
  int _recordingDepth = 0;
  DateTime? _lastTriggerAt;
  Future<void>? _opQueue;

  Future<T> _serialize<T>(Future<T> Function() action) {
    final previous = _opQueue;
    final completer = Completer<T>();
    Future<void> run() async {
      try {
        completer.complete(await action());
      } catch (error, stack) {
        completer.completeError(error, stack);
      }
    }

    late final Future<void> tail;
    final next = previous == null ? run() : previous.then((_) => run());
    tail = next.catchError((Object _) {}).whenComplete(() {
      if (identical(_opQueue, tail)) _opQueue = null;
    });
    _opQueue = tail;
    return completer.future;
  }

  /// Queries native capabilities and registers the saved shortcut if enabled.
  ///
  /// Never throws on startup: failures are surfaced through [status] and logs.
  Future<void> initialize() => _serialize(() async {
    if (!_platformSupported()) return;
    await BossKeyPreferences.instance.load();
    _bridge.setTriggerHandler(handleTriggered);
    _initialized = true;

    try {
      final caps = await _bridge.capabilities();
      status.value = status.value.copyWith(
        globalHotkeySupported: caps.globalHotkey,
        backend: caps.backend,
      );
      if (!caps.globalHotkey) {
        if (BossKeyPreferences.instance.enabled.value) {
          status.value = status.value.copyWith(
            registered: false,
            clearActiveShortcut: true,
            errorMessage: _unsupportedMessage(caps.backend),
          );
        }
        return;
      }
    } on MissingPluginException {
      status.value = status.value.copyWith(
        globalHotkeySupported: false,
        backend: 'missing',
        registered: false,
        clearActiveShortcut: true,
        errorMessage: '当前桌面环境未接入全局快捷键通道',
      );
      return;
    } catch (error, stack) {
      AppLog.w('boss-key', '查询老板键能力失败', error: error, stack: stack);
    }

    if (BossKeyPreferences.instance.enabled.value && _recordingDepth == 0) {
      final shortcut = BossKeyPreferences.instance.shortcut.value;
      try {
        await _bridge.register(shortcut);
        status.value = status.value.copyWith(
          registered: true,
          activeShortcut: shortcut,
          clearErrorMessage: true,
        );
      } catch (error, stack) {
        final message = _describeError(error, shortcut);
        AppLog.w(
          'boss-key',
          '启动时注册老板键失败: $message',
          error: error,
          stack: stack,
        );
        status.value = status.value.copyWith(
          registered: false,
          clearActiveShortcut: true,
          errorMessage: message,
        );
      }
    }
  });

  /// Enables or disables the global boss key.
  ///
  /// Enabling registers the native hotkey first so a conflicting or unsupported
  /// session never leaves the switch enabled without a working recovery key.
  Future<BossKeyApplyResult> setEnabled(bool enabled) => _serialize(() async {
    if (!_platformSupported()) {
      return const BossKeyApplyResult.failure('当前平台不支持老板键');
    }
    if (!_initialized) {
      await _ensureInitializedInsideQueue();
    }
    final prefs = BossKeyPreferences.instance;
    final shortcut = prefs.shortcut.value;

    if (!enabled) {
      try {
        await _bridge.unregister();
      } catch (error, stack) {
        AppLog.w('boss-key', '注销老板键失败', error: error, stack: stack);
      }
      final saved = await prefs.setEnabled(false);
      status.value = status.value.copyWith(
        registered: false,
        clearActiveShortcut: true,
        clearErrorMessage: true,
      );
      if (!saved) {
        return const BossKeyApplyResult.failure('老板键已关闭，但未能保存设置');
      }
      return const BossKeyApplyResult.success();
    }

    if (!status.value.globalHotkeySupported) {
      final message = _unsupportedMessage(status.value.backend);
      status.value = status.value.copyWith(
        registered: false,
        clearActiveShortcut: true,
        errorMessage: message,
      );
      return BossKeyApplyResult.failure(message);
    }

    final validation = shortcut.validationError;
    if (validation != null) {
      status.value = status.value.copyWith(errorMessage: validation);
      return BossKeyApplyResult.failure(validation);
    }

    try {
      await _bridge.register(shortcut);
    } catch (error, stack) {
      final message = _describeError(error, shortcut);
      AppLog.w('boss-key', '启用老板键失败: $message', error: error, stack: stack);
      final isUnsupported =
          error is PlatformException && error.code == 'UNSUPPORTED_DISPLAY';
      status.value = status.value.copyWith(
        globalHotkeySupported: isUnsupported
            ? false
            : status.value.globalHotkeySupported,
        registered: false,
        clearActiveShortcut: true,
        errorMessage: message,
      );
      return BossKeyApplyResult.failure(message);
    }

    final saved = await prefs.setEnabled(true);
    if (!saved) {
      try {
        await _bridge.unregister();
      } catch (_) {}
      status.value = status.value.copyWith(
        registered: false,
        clearActiveShortcut: true,
        errorMessage: '未能保存老板键开关状态',
      );
      return const BossKeyApplyResult.failure('未能保存老板键开关状态');
    }

    status.value = status.value.copyWith(
      registered: true,
      activeShortcut: shortcut,
      clearErrorMessage: true,
    );
    return const BossKeyApplyResult.success();
  });

  /// Updates the configured shortcut.
  ///
  /// When the boss key is enabled and not currently suspended for recording,
  /// attempts to register [shortcut] before persisting so a conflicting key
  /// leaves the previous working binding untouched.
  Future<BossKeyApplyResult> updateShortcut(BossKeyShortcut shortcut) =>
      _serialize(() async {
        final validation = shortcut.validationError;
        if (validation != null) {
          return BossKeyApplyResult.failure(validation);
        }
        final prefs = BossKeyPreferences.instance;
        final previous = prefs.shortcut.value;
        final enabled = prefs.enabled.value;

        if (enabled && _platformSupported()) {
          if (!_initialized) {
            await _ensureInitializedInsideQueue();
          }
          if (!status.value.globalHotkeySupported) {
            return BossKeyApplyResult.failure(
              _unsupportedMessage(status.value.backend),
            );
          }
          try {
            await _bridge.register(shortcut);
          } catch (error, stack) {
            final message = _describeError(error, shortcut);
            AppLog.w(
              'boss-key',
              '更换老板键失败: $message',
              error: error,
              stack: stack,
            );
            return BossKeyApplyResult.failure(message);
          }
        }

        final saved = await prefs.setShortcut(shortcut);
        if (!saved) {
          if (enabled && _platformSupported()) {
            if (_recordingDepth == 0) {
              try {
                await _bridge.register(previous);
              } catch (_) {}
            } else {
              try {
                await _bridge.unregister();
              } catch (_) {}
            }
          }
          return const BossKeyApplyResult.failure('未能保存新的快捷键设置');
        }

        if (enabled && _platformSupported()) {
          status.value = status.value.copyWith(
            registered: true,
            activeShortcut: shortcut,
            clearErrorMessage: true,
          );
        }
        return const BossKeyApplyResult.success();
      });

  /// Suspends the active global hotkey while the user records a new shortcut.
  Future<void> beginRecording() => _serialize(() async {
    _recordingDepth++;
    if (_recordingDepth == 1 &&
        status.value.registered &&
        _platformSupported()) {
      try {
        await _bridge.unregister();
      } catch (error, stack) {
        AppLog.w('boss-key', '录制前暂停老板键失败', error: error, stack: stack);
      }
      status.value = status.value.copyWith(
        registered: false,
        clearActiveShortcut: true,
      );
    }
  });

  /// Resumes the global hotkey after shortcut recording finishes.
  Future<BossKeyApplyResult> endRecording() => _serialize(() async {
    if (_recordingDepth == 0) return const BossKeyApplyResult.success();
    _recordingDepth--;
    if (_recordingDepth > 0) return const BossKeyApplyResult.success();

    if (!_platformSupported() || !BossKeyPreferences.instance.enabled.value) {
      return const BossKeyApplyResult.success();
    }
    if (!status.value.globalHotkeySupported) {
      return BossKeyApplyResult.failure(
        _unsupportedMessage(status.value.backend),
      );
    }

    final shortcut = BossKeyPreferences.instance.shortcut.value;
    if (status.value.registered && status.value.activeShortcut == shortcut) {
      return const BossKeyApplyResult.success();
    }
    try {
      await _bridge.register(shortcut);
      status.value = status.value.copyWith(
        registered: true,
        activeShortcut: shortcut,
        clearErrorMessage: true,
      );
      return const BossKeyApplyResult.success();
    } catch (error, stack) {
      final message = _describeError(error, shortcut);
      AppLog.w('boss-key', '恢复老板键注册失败: $message', error: error, stack: stack);
      status.value = status.value.copyWith(
        registered: false,
        clearActiveShortcut: true,
        errorMessage: message,
      );
      return BossKeyApplyResult.failure(message);
    }
  });

  /// Handles a native global hotkey trigger.
  ///
  /// When the window is visible, pauses all active playback (drama video,
  /// audiobook, system TTS) and hides the window including its taskbar entry.
  /// Pressing the boss key again restores and focuses the window while keeping
  /// playback paused.
  Future<void> handleTriggered() async {
    if (!_platformSupported()) return;
    if (_recordingDepth > 0 || _toggling) return;
    if (!BossKeyPreferences.instance.enabled.value && !status.value.hidden) {
      return;
    }

    final now = _clock();
    final last = _lastTriggerAt;
    if (last != null && now.difference(last) < _triggerDebounce) {
      return;
    }
    _lastTriggerAt = now;
    _toggling = true;
    try {
      final currentlyHidden = status.value.hidden;
      var visible = !currentlyHidden;
      if (!currentlyHidden) {
        try {
          visible = await _windowControl.isVisible();
        } catch (error, stack) {
          AppLog.w('boss-key', '检查窗口可见性失败', error: error, stack: stack);
          visible = true;
        }
      }

      if (visible && !currentlyHidden) {
        await _pauseAllPlayback();
        await _windowControl.hide();
        status.value = status.value.copyWith(hidden: true);
      } else {
        await _windowControl.restore();
        status.value = status.value.copyWith(hidden: false);
      }
    } catch (error, stack) {
      AppLog.w('boss-key', '老板键切换窗口状态失败', error: error, stack: stack);
    } finally {
      _toggling = false;
    }
  }

  /// Releases the global hotkey before desktop app shutdown.
  Future<void> shutdown() => _serialize(() async {
    if (!_platformSupported()) return;
    _bridge.setTriggerHandler(null);
    if (status.value.registered || _initialized) {
      try {
        await _bridge.unregister();
      } catch (error, stack) {
        AppLog.w('boss-key', '退出前注销老板键失败', error: error, stack: stack);
      }
    }
    _initialized = false;
    _recordingDepth = 0;
    status.value = status.value.copyWith(
      registered: false,
      clearActiveShortcut: true,
      hidden: false,
    );
  });

  Future<void> _ensureInitializedInsideQueue() async {
    await BossKeyPreferences.instance.load();
    _bridge.setTriggerHandler(handleTriggered);
    _initialized = true;
    try {
      final caps = await _bridge.capabilities();
      status.value = status.value.copyWith(
        globalHotkeySupported: caps.globalHotkey,
        backend: caps.backend,
      );
    } on MissingPluginException {
      status.value = status.value.copyWith(
        globalHotkeySupported: false,
        backend: 'missing',
      );
    } catch (_) {
      // Keep optimistic default; register() will surface any concrete error.
    }
  }

  Future<void> _pauseAllPlayback() async {
    final override = _pausePlaybackOverride;
    if (override != null) {
      try {
        await override();
      } catch (error, stack) {
        AppLog.w('boss-key', '老板键暂停播放回调失败', error: error, stack: stack);
      }
      return;
    }
    try {
      await pauseAudioScope?.call();
    } catch (error, stack) {
      AppLog.w('boss-key', '老板键暂停听书/朗读失败', error: error, stack: stack);
    }
    try {
      await NativePlayer.pauseOthers();
    } catch (error, stack) {
      AppLog.w('boss-key', '老板键暂停视频/音频播放器失败', error: error, stack: stack);
    }
  }

  String _unsupportedMessage(String backend) {
    if (backend == 'wayland') {
      return '当前为 Wayland 会话，暂不支持隐藏后的全局老板键；请切换到 X11 会话或设置 GDK_BACKEND=x11';
    }
    return '当前桌面会话不支持全局快捷键';
  }

  String _describeError(Object error, BossKeyShortcut shortcut) {
    if (error is MissingPluginException) {
      return '当前桌面环境未接入全局快捷键通道';
    }
    if (error is PlatformException) {
      switch (error.code) {
        case 'HOTKEY_CONFLICT':
          return '快捷键 ${shortcut.formatLabel()} 已被其他应用占用，请更换其他组合键';
        case 'UNSUPPORTED_DISPLAY':
          return error.message?.isNotEmpty == true
              ? error.message!
              : _unsupportedMessage('wayland');
        case 'INVALID_ARGUMENT':
          return error.message?.isNotEmpty == true
              ? error.message!
              : '当前键盘布局不支持 ${shortcut.formatLabel()}';
        default:
          return error.message?.isNotEmpty == true
              ? error.message!
              : '注册全局快捷键 ${shortcut.formatLabel()} 失败';
      }
    }
    return '注册全局快捷键 ${shortcut.formatLabel()} 失败';
  }

  @visibleForTesting
  void resetForTest({
    BossKeyNativeBridge? bridge,
    BossKeyWindowControl? windowControl,
    Future<void> Function()? pausePlayback,
    DateTime Function()? clock,
    bool Function()? platformSupported,
  }) {
    _bridge.setTriggerHandler(null);
    _bridge = bridge ?? _MethodChannelBossKeyBridge();
    _windowControl = windowControl ?? _WindowManagerBossKeyControl();
    _pausePlaybackOverride = pausePlayback;
    _clock = clock ?? DateTime.now;
    _platformSupported = platformSupported ?? (() => isMediaDesktop);
    _initialized = false;
    _toggling = false;
    _recordingDepth = 0;
    _lastTriggerAt = null;
    _opQueue = null;
    status.value = const BossKeyStatus();
  }
}
