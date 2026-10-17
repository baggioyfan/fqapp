import 'dart:math';

import 'package:shared_preferences/shared_preferences.dart';

/// 本机在「阅读时长」里用的稳定标识。
///
/// 阅读时长按设备分桶存（G-Counter）：合并时同设备取大、不同设备各留一行，
/// 展示时求和。没有这个 id，两台设备同一天都读书就只能取大，会静默丢掉
/// 一台的时长 —— 而「通勤用手机、晚上用平板」正是双设备用户的日常。
///
/// 用自己生成的随机串而不是 `androidId`：后者是系统级标识，为一个统计功能
/// 去读它没有必要；而且重装后会变，随机串同样会变，语义上没有区别。
class DeviceIdentity {
  static const _key = 'read_time_device_id_v1';

  static String? _cached;

  /// 首次调用生成并落盘，之后一直复用。初始化前调用会退化成进程内临时 id，
  /// 因此 [ReadTimeStore.init] 必须先跑完再写入任何时长。
  static Future<String> load() async {
    final cached = _cached;
    if (cached != null) return cached;
    final sp = await SharedPreferences.getInstance();
    final saved = sp.getString(_key);
    if (saved != null && saved.isNotEmpty) {
      _cached = saved;
      return saved;
    }
    final generated = _generate();
    await sp.setString(_key, generated);
    _cached = generated;
    return generated;
  }

  /// 同步读缓存值。只给「已经在 init 里 load 过」的路径用。
  static String get currentOrEmpty => _cached ?? '';

  static String _generate() {
    final random = Random.secure();
    final buffer = StringBuffer();
    for (var i = 0; i < 8; i++) {
      buffer.write(random.nextInt(16).toRadixString(16));
    }
    return buffer.toString();
  }

  /// 测试用：清掉缓存，让下一次 [load] 重新读盘。
  static void resetForTesting([String? value]) {
    _cached = value;
  }
}
