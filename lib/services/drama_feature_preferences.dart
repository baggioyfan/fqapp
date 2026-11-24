import 'package:flutter/foundation.dart';
import 'package:shared_preferences/shared_preferences.dart';

/// 短剧功能的开关（设置页「短剧 → 短剧功能」）。
///
/// 关闭后壳层收起短剧入口（手机 dock / 桌面导航栏）、书架收藏空态的
/// 「找短剧」按钮，播放页也不再起播放器实例；偏好本身保留，重新打开
/// 即恢复原状。
class DramaFeaturePreferences {
  DramaFeaturePreferences._();

  static final instance = DramaFeaturePreferences._();
  static const _key = 'drama_feature_enabled';

  /// 默认开启：老用户升级上来不该平白少一个 tab。
  final ValueNotifier<bool> enabled = ValueNotifier(true);
  Future<void>? _loading;

  Future<void> load() => _loading ??= _load();

  Future<void> _load() async {
    try {
      final preferences = await SharedPreferences.getInstance();
      enabled.value = preferences.getBool(_key) ?? true;
    } catch (_) {
      // 读失败允许下次启动重试：否则一次 IO 抖动会把开关永久钉在默认值。
      _loading = null;
      rethrow;
    }
  }

  Future<void> setEnabled(bool value) async {
    await load();
    final preferences = await SharedPreferences.getInstance();
    if (!await preferences.setBool(_key, value)) {
      throw StateError('Could not save short drama preference');
    }
    enabled.value = value;
  }
}
