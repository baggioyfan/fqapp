import 'package:flutter/services.dart';
import 'package:media_kit/media_kit.dart';

import 'desktop_platform.dart';
import 'platform_channel.dart';
import 'ios_audio_session.dart';

/// iOS 的进程内平台适配层。
///
/// iOS 上没有 Android 那套 `fqapp/native_player` 原生实现,也没有 Windows 的
/// 窗口管理器。这里把同一份通道契约接到 Dart 侧的 media_kit 播放器(与
/// Windows/Linux 共用 [DesktopPlatform]),于是播放页、短剧页、听书页的代码
/// 一行都不用改,只是能力收敛到桌面那一档:能播、能暂停/拖动/倍速/音量,
/// 没有悬浮窗、画中画；锁屏媒体会话交给 [IosAudioSession]。
///
/// 没有原生实现的通道仍然交回真正的 [MethodChannel]:缺失时照常抛
/// `MissingPluginException`,与没装适配层之前完全一致,不会把「没做这件事」
/// 伪装成「已经做好」。
class IosPlatform {
  IosPlatform._();

  static Future<void> install() async {
    // media_kit 的 mpv 接口必须在构造 Player 之前初始化。桌面在
    // `DesktopPlatform.initialize()` 里顺带做,而 iOS 不跑那套窗口初始化。
    MediaKit.ensureInitialized();
    PlatformChannels.events = (name) {
      if (name == 'fqapp/native_player/events' ||
          name == 'fqapp/reader/events') {
        return DesktopPlatform.instance.events(name);
      }
      return EventChannel(name).receiveBroadcastStream();
    };
    PlatformChannels.invoke = (channel, method, arguments) async {
      switch (channel) {
        case 'fqapp/native_player':
          if (method == 'startListenForeground') {
            final args = (arguments as Map?) ?? const {};
            final owner = args['owner'] as String?;
            if (owner == null) return null;
            await IosAudioSession.update(
              owner: owner,
              title: args['title'] as String? ?? '',
              episode: args['episode'] as String? ?? '',
              cover: args['coverUrl'] as String? ?? '',
              playing: args['playing'] == true,
              positionMs: (args['positionMs'] as num?)?.toInt() ?? 0,
              durationMs: (args['durationMs'] as num?)?.toInt() ?? 0,
              rate: (args['speed'] as num?)?.toDouble() ?? 1,
              hasPrev: args['hasPrev'] == true,
              hasNext: args['hasNext'] == true,
            );
            return null;
          }
          if (method == 'stopListenForeground') {
            final owner = (arguments as Map?)?['owner'] as String?;
            if (owner != null) await IosAudioSession.stop(owner: owner);
            return null;
          }
          // 亮屏锁与其他播放器指令都落到 DesktopPlatform:它的
          // reader/player 双投票是唯一的所有权来源,谁都不许单方面关掉对方
          // 要的常亮(见 _setAwake)。
          return DesktopPlatform.instance.invoke(channel, method, arguments);
        // 文件通路(备份、本地书籍、TXT/日志导出、番茄分卷)与阅读器设备
        // 状态复用桌面实现:`_save` 在 iOS 上换成系统分享面板,pickBook 与
        // openBackup 换成语义等价的 UTI(见 desktop_platform.dart)。
        case 'fqapp/library_backup':
        case 'fqapp/local_books':
        case 'fqapp/downloads':
        case 'fqapp/reader':
          return DesktopPlatform.instance.invoke(channel, method, arguments);
        case 'fqapp/system_tts':
          final iosSession = IosAudioSession.generation;
          final result = await MethodChannel(
            channel,
          ).invokeMethod<dynamic>(method, arguments);
          if (const {'pause', 'stop', 'shutdown'}.contains(method)) {
            await IosAudioSession.releaseIfIdle(session: iosSession);
          }
          return result;
      }
      // iOS 自己的原生通道(Keychain 等)与插件通道照旧。
      return MethodChannel(channel).invokeMethod<dynamic>(method, arguments);
    };
  }
}
