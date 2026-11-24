import 'dart:async';

import 'package:flutter/services.dart';

import 'app_log.dart';
import 'desktop_platform.dart' show isIOSPlatform;

/// 锁屏 / 控制中心 / 耳机键的播放能力。
///
/// 安卓侧由 `ListenKeepAliveService` 的前台服务 + MediaSession 提供，iOS 没有
/// 等价物，因此由 `ios/Runner/AppDelegate.swift` 里的 `AudioSessionBridge`
/// 直接驱动 `AVAudioSession` / `MPNowPlayingInfoCenter` / `MPRemoteCommandCenter`。
///
/// Dart 只在播放状态变化时推一次元数据（[update]），收到的按钮事件原样转给
/// 播放控制器的 `_handleRemoteAction`，两端行为因此保持一致。
class IosAudioSession {
  IosAudioSession._();

  static const MethodChannel _channel = MethodChannel('fqapp/audio_session');
  static const EventChannel _events = EventChannel(
    'fqapp/audio_session/events',
  );

  static String? _owner;
  static int _generation = 0;
  static int _intent = 0;
  static int? _interruptedSession;
  static void Function(String action, int? positionMs)? _onAction;

  static int get generation => _generation;

  static bool get hasOwner => _owner != null;

  static bool owns(String owner) => isIOSPlatform && owner == _owner;

  /// 每次重新接管生成新会话，丢弃旧页面及旧中断排队中的事件。
  static void claim({
    required String owner,
    required void Function(String, int?) onAction,
  }) {
    if (!isIOSPlatform) return;
    install();
    _onAction = onAction;
    if (_owner == owner) return;
    _owner = owner;
    _intent = 0;
    _interruptedSession = null;
    ++_generation;
    unawaited(_invoke('claim', _identity));
  }

  static Map<String, dynamic> get _identity => {
    'owner': _owner,
    'session': _generation,
    'intent': _intent,
  };

  /// 用户操作与会话切换撤销自动恢复；中断造成的暂停不调用此方法。
  static void cancelInterruption(String owner) {
    if (!owns(owner)) return;
    _interruptedSession = null;
    ++_intent;
    unawaited(_invoke('cancelInterruption', _identity));
  }

  static Future<void> _invoke(
    String method,
    Map<String, dynamic> arguments,
  ) async {
    try {
      await _channel.invokeMethod<void>(method, arguments);
    } catch (error) {
      AppLog.w('audio-session', 'iOS 媒体会话 $method 失败: $error');
    }
  }

  static bool _installed = false;

  /// 订阅事件通道。重复调用是安全的，非 iOS 平台直接返回。
  static void install() {
    if (!isIOSPlatform || _installed) return;
    _installed = true;
    _events.receiveBroadcastStream().listen(
      (dynamic event) {
        if (event is! Map ||
            _owner == null ||
            event['owner'] != _owner ||
            event['session'] != _generation) {
          return;
        }
        final action = event['action']?.toString() ?? '';
        if (action.isEmpty) return;
        if ((action == 'interruptionPause' || action == 'interruptionResume') &&
            event['intent'] != _intent) {
          return;
        }
        if (action == 'interruptionPause') {
          _interruptedSession = _generation;
        } else if (action == 'interruptionResume') {
          if (_interruptedSession != _generation) return;
          _interruptedSession = null;
        }
        final raw = event['positionMs'];
        _onAction?.call(action, raw is int ? raw : null);
      },
      onError: (Object error) {
        AppLog.w('audio-session', 'iOS 媒体事件通道异常: $error');
      },
    );
  }

  /// 解码器/语音引擎出声前配置并激活同一桥，不在冷启动激活。
  static Future<bool> prepare({
    required String owner,
    required String mode,
  }) async {
    if (!isIOSPlatform) return true;
    if (!owns(owner)) return false;
    final identity = _identity;
    await _invoke('prepare', {...identity, 'mode': mode});
    return identity['session'] == _generation && owner == _owner;
  }

  static Future<int?> beginBackgroundWindow({required String owner}) async {
    if (!owns(owner)) return null;
    try {
      return await _channel.invokeMethod<int>(
        'beginBackgroundWindow',
        _identity,
      );
    } catch (error) {
      AppLog.w('audio-session', 'iOS 后台换章额度申请失败: $error');
      return null;
    }
  }

  static Future<void> endBackgroundWindow(int? token) async {
    if (!isIOSPlatform || token == null) return;
    await _invoke('endBackgroundWindow', {'token': token});
  }

  /// 内联播放器没有媒体卡片，但中断观察仍需真实的播放意图。
  static Future<void> setPlaying({
    required String owner,
    required bool playing,
  }) async {
    if (!owns(owner)) return;
    await _invoke('setPlaying', {..._identity, 'playing': playing});
  }

  /// 解码器停下后重试释放，避免先清卡片时 AVAudioSession 仍处于 busy。
  static Future<void> releaseIfIdle({required int session}) async {
    if (!isIOSPlatform || _owner != null || session != _generation) return;
    await _invoke('releaseIfIdle', _identity);
  }

  /// 推送当前的媒体元数据。锁屏卡片、控制中心、CarPlay 与蓝牙都会读这里。
  static Future<void> update({
    required String owner,
    required String title,
    required String episode,
    String cover = '',
    required bool playing,
    required int positionMs,
    required int durationMs,
    required double rate,
    required bool hasPrev,
    required bool hasNext,

    /// `audio`（听书，长语音）或 `video`（影视）。原生侧据此切换
    /// AVAudioSession 的 mode：影视走 `.moviePlayback`，避免语音优化压音轨。
    String mode = 'audio',
  }) async {
    if (!owns(owner)) return;
    try {
      await _channel.invokeMethod<void>('update', <String, dynamic>{
        ..._identity,
        'title': title,
        'episode': episode,
        'cover': cover,
        'playing': playing,
        'positionMs': positionMs,
        'durationMs': durationMs,
        'rate': rate,
        'hasPrev': hasPrev,
        'hasNext': hasNext,
        'mode': mode,
      });
    } on PlatformException catch (error) {
      // 媒体卡片是增强项：失败只记日志，不该影响播放本身。
      AppLog.w('audio-session', '更新媒体卡片失败: ${error.message ?? error.code}');
    } on MissingPluginException {
      // 旧版本包或未链接桥接时静默降级。
    }
  }

  /// 停止播放后清掉卡片。
  static Future<void> stop({required String owner}) async {
    if (!owns(owner)) return;
    final identity = _identity;
    _owner = null;
    _onAction = null;
    _interruptedSession = null;
    try {
      await _channel.invokeMethod<void>('stop', identity);
    } on PlatformException catch (error) {
      AppLog.w('audio-session', '清理媒体卡片失败: ${error.message ?? error.code}');
    } on MissingPluginException {
      // 同上。
    }
  }
}
