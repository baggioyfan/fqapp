import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'player_style_config.dart';

/// 更多面板里「需要落盘」的那几项的官方存储语义。
///
/// 官方有两套完全不同的做法，这里逐项照搬（`ShortSeriesMorePanelDialogV2`
/// 的 `ActionItemSingleChoiceHolder.onBind` / `onClick`）：
/// - **画面撑满**：SP `is_fill_screen`，键 `is_fill_screen`，
///   默认值 `!short_video_setting_opt_v679.default_video_size_aspect_fit`，
///   并且**只在竖屏**（`sb4.e.q()`）时该默认值生效，其余情况缺省 false
///   （`FillScreenDataManager.java:27-37`）
/// - **默认静音**：官方**不落盘**，只有 `tm3.b` 的静态字段
///   （`tm3/b.java:17-21`：`b/c/d/e/f` 均无初始化器，JVM 缺省全 false；
///   `m()` 开静音、`a()` 关静音、`g()` 启动时设置检查），
///   跨进程靠本地广播 `action_on_default_mute_play_status_changed` + extra
///   `key_default_mute_play`（`jq3/d0.java:390` 读 extra 缺省 false）。
///   **出厂 = 有声**；此前注释「e = true」是误读，已更正。
///
/// 弹幕开关的落盘在 `DanmakuPreference`（另一个文件，另一套键）。
class PlayerPanelPreferences {
  const PlayerPanelPreferences._();

  /// 官方 SP 名与键同名（`d.a.b(ctx, "is_fill_screen")`）。
  static const fillScreenStore = 'is_fill_screen';
  static const fillScreenKey = 'is_fill_screen';

  /// 默认静音的官方初始值：`tm3/b.java` 的 `e` 静态缺省 **false（有声）**。
  ///
  /// 官方**不落盘**，所以这里也只在进程内保存，重启回到 false——
  /// 这不是偷懒，是与官方一致的行为（官方全屏进页音量取 `e()`，
  /// `fullscreen/a.java` 持有者经广播同步）。
  static bool _defaultMute = false;

  static bool get defaultMute => _defaultMute;

  static void setDefaultMute(bool enabled) => _defaultMute = enabled;

  /// 播放器自己的音量档位（0..1），与静音分开记。
  ///
  /// 播放器音量是叠在系统音量之上的比例：1.0 就是「跟系统音量一样大」。
  /// 以前解除静音、换集、新建播放器一律回到 1.0，开了默认静音的用户一点
  /// 音量就先被拉到系统音量满档，再降到自己选的档位，耳朵受不了。现在
  /// 用户选过的档位单独记住并落盘：解除静音和新播放器都回到这个档位。
  /// 没选过时，有声起播仍是 1.0，不改变从未调过音量的用户的行为；但从静音
  /// 解除时用 [firstUnmuteLevel]，不让第一次解除静音就是系统满音量。
  static const volumeLevelKey = 'player_volume_level';

  /// 从未选过档位时，解除静音落到的音量。
  static const firstUnmuteLevel = .5;

  /// 低于它的档位不当作「要记住的音量」：拖到 0 的途中会经过极小值，
  /// 记住它会让下次解除静音几乎没声音。
  static const _minRememberedLevel = .05;

  static double _volumeLevel = 1;
  static bool _levelChosen = false;
  static Timer? _saveVolumeTimer;

  /// 解除静音时应恢复的音量（不含静音态）。
  static double get volumeLevel => _volumeLevel;

  /// 新播放器或换集时应下发的音量：静音为 0，否则是记住的档位。
  static double get playbackVolume => _defaultMute ? 0 : _volumeLevel;

  /// 启动时读入内存：起播路径直接读 [volumeLevel]，不在那里 await 读盘。
  static Future<void> loadVolumeLevel() async {
    try {
      final preferences = await SharedPreferences.getInstance();
      final saved = preferences.getDouble(volumeLevelKey);
      if (saved != null && saved.isFinite && saved >= _minRememberedLevel) {
        _volumeLevel = saved.clamp(_minRememberedLevel, 1.0).toDouble();
        _levelChosen = true;
      }
    } catch (_) {
      // 读不到就保持 1.0：音量只是表现层，不能拖住启动。
    }
  }

  /// 用户在音量条/快捷键上选了 [value]：0 表示静音（保留原档位，方便恢复），
  /// 其余值解除静音并记成新档位。拖动时会连续调用，落盘做了合并。
  static void selectVolume(double value) {
    final level = value.isFinite ? value.clamp(0.0, 1.0).toDouble() : 0.0;
    if (level == 0) {
      _defaultMute = true;
      return;
    }
    _defaultMute = false;
    if (level < _minRememberedLevel) return;
    _remember(level);
  }

  /// 解除静音（喇叭图标、静音药丸、关闭「默认静音」）时应恢复的音量。
  ///
  /// 选过档位就回到那一档；从未选过时用 [firstUnmuteLevel] 并把它记成
  /// 当前档位，之后换集、新播放器都沿用它，不会又回到系统满音量。
  static double takeUnmuteLevel() {
    if (!_levelChosen) _remember(firstUnmuteLevel);
    return _volumeLevel;
  }

  static void _remember(double level) {
    _volumeLevel = level;
    _levelChosen = true;
    _saveVolumeTimer?.cancel();
    _saveVolumeTimer = Timer(const Duration(milliseconds: 400), () async {
      _saveVolumeTimer = null;
      try {
        final preferences = await SharedPreferences.getInstance();
        await preferences.setDouble(volumeLevelKey, _volumeLevel);
      } catch (_) {
        // 落盘失败只影响下次启动，本次会话内存值照常生效。
      }
    });
  }

  @visibleForTesting
  static void resetVolumeForTesting() {
    _saveVolumeTimer?.cancel();
    _saveVolumeTimer = null;
    _volumeLevel = 1;
    _levelChosen = false;
  }

  /// 官方读取（`FillScreenDataManager.a()`）：
  ///
  /// 有 SP 值就用 SP 值；没有 SP 值时**竖屏直接 false**，
  /// 其余情况才用 `!default_video_size_aspect_fit`——
  /// 这个分支是官方源码里显式的：
  /// `if (e.q() && !sp.contains(KEY)) return false;`
  /// `return sp.getBoolean(KEY, !config.defaultVideoSizeAspectFit);`
  static Future<bool> loadFillScreen({bool portrait = true}) async {
    final preferences = await SharedPreferences.getInstance();
    final saved = preferences.getBool(fillScreenKey);
    if (saved != null) return saved;
    if (portrait) return false;
    return !PlayerStyleConfig.instance.defaultVideoSizeAspectFit;
  }

  static Future<void> saveFillScreen(bool enabled) async {
    final preferences = await SharedPreferences.getInstance();
    await preferences.setBool(fillScreenKey, enabled);
  }
}
