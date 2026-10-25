import 'package:flutter/foundation.dart';

import 'platform_channel.dart';

/// 全屏播放竖滑手势要用的屏幕亮度（左半屏）。
///
/// 只有 Android 实现了这条通道（`PlayerDisplayPlugin`：改的是当前 Activity 的
/// 窗口亮度，不动系统设置、不需要权限）。其它平台、以及通道不可用时的测试环境
/// 一律静默降级：[begin] 返回 null 表示「这个宿主没有亮度手势」，[setBrightness]
/// 与 [end] 变成空操作，绝不会把异常冒泡到播放链路上。
class PlayerDisplay {
  const PlayerDisplay._();

  static const _channel = AppMethodChannel('fqapp/player/display');

  /// 与原生侧的会话名对上：窗口亮度是 Activity 级资源，谁开的谁关。
  static const _session = 'player';

  /// 亮度下限与原生侧一致：再低整块画面看不见，等于关了屏幕。
  static const _minBrightness = 0.02;

  static bool get _supported =>
      !kIsWeb && defaultTargetPlatform == TargetPlatform.android;

  /// 进入全屏时调用一次，返回系统当前亮度（0..1）。
  ///
  /// 返回 null 有两种情况：这个宿主不支持（桌面/测试），或者原生侧还没准备好。
  /// 手势据此决定左半屏是否需要响应。
  static Future<double?> begin() async {
    if (!_supported) return null;
    try {
      final value = await _channel.invokeMethod<double>('begin', {
        'session': _session,
      });
      if (value == null || !value.isFinite) return null;
      return value.clamp(_minBrightness, 1.0).toDouble();
    } catch (_) {
      return null;
    }
  }

  static Future<void> setBrightness(double value) async {
    if (!_supported) return;
    try {
      await _channel.invokeMethod<bool>('setBrightness', {
        'session': _session,
        'brightness': value.clamp(_minBrightness, 1.0).toDouble(),
      });
    } catch (_) {
      // 调不动亮度不该影响播放：和音量设置失败同一条约定。
    }
  }

  /// 退出全屏或离开播放页：把窗口亮度还原成进入前的值。
  static Future<void> end() async {
    if (!_supported) return;
    try {
      await _channel.invokeMethod<void>('end', {'session': _session});
    } catch (_) {}
  }
}
