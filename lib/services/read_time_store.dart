import 'package:flutter/foundation.dart';
import 'package:hive_ce_flutter/hive_flutter.dart';

import '../models/library_backup.dart';
import 'device_identity.dart';
import 'encrypted_hive.dart';

/// `day -> {deviceId: seconds}`。按设备分桶是合并正确性的前提：
/// 同一天两台设备都读，取大会丢掉一台，求和会重复计数。
typedef DailyTable = Map<String, Map<String, double>>;

/// 一本书的总时长，同样按设备分桶。
typedef BookTime = ({String id, String kind, Map<String, double> devices});

/// 阅读时长：按天一张表 + 按书一张表，都按设备计数（G-Counter）。
///
/// 为什么不是「书 × 天」交叉表：四个消费点没有一个需要「某书某天」——
/// 日历要按天、排行要按书、今日阅读要按天。交叉表多出来的那一维
/// 只是同步负担（最坏 5000 × 730 = 365 万条，改成 365 + 5000）。
///
/// 合并规则只有一条：**同设备取大**。它是幂等的，所以同一份快照合并两次
/// 不会翻倍，两台设备也不会互相覆盖。
class ReadTimeStore {
  ReadTimeStore._();
  static final ReadTimeStore instance = ReadTimeStore._();

  static const dailyBoxName = 'read_time_daily_v2';
  static const booksBoxName = 'read_time_books_v2';

  static const _kindKey = 'kind';
  static const _touchedKey = 'touched';
  static const _devicesKey = 'devs';

  /// 统计页的日期选择器只覆盖最近 365 天，存更久只是同步负担。
  @visibleForTesting
  int retentionDays = 365;

  /// 按书记录的上限，超出后先淘汰最久没碰过的。
  @visibleForTesting
  int maxBooks = 5000;

  Box<dynamic>? _dailyBox;
  Box<dynamic>? _booksBox;
  String _deviceId = '';
  Listenable? _changes;

  bool get isReady => _dailyBox != null && _booksBox != null;

  /// 两台设备都读同一天时，日表变了书表也一定变；但合并云端数据可能只
  /// 动其中一张，所以两个盒子一起监听。未初始化时给一个永不通知的占位，
  /// 免得页面在 init 之前取监听就崩。
  Listenable get listenable => _changes ??= Listenable.merge([
    if (_dailyBox != null) _dailyBox!.listenable(),
    if (_booksBox != null) _booksBox!.listenable(),
  ]);

  String get deviceId => _deviceId;

  Future<void> init() async {
    _dailyBox = await EncryptedHive.openBox(Hive, dailyBoxName);
    _booksBox = await EncryptedHive.openBox(Hive, booksBoxName);
    _deviceId = await DeviceIdentity.load();
    _changes = null;
    await _sweep();
  }

  /// 按天总时长（秒），已跨设备求和。
  Map<String, double> dailyTotals() {
    final box = _dailyBox;
    if (box == null) return const {};
    final out = <String, double>{};
    for (final key in box.keys) {
      final day = key.toString();
      if (_parseDayKey(day) == null) continue;
      final total = _sumDevices(_devicesOf(box.get(key)));
      if (total > 0) out[day] = total;
    }
    return out;
  }

  /// 每本书的总时长（秒），已跨设备求和。
  Map<String, double> bookTotals() {
    final box = _booksBox;
    if (box == null) return const {};
    final out = <String, double>{};
    for (final key in box.keys) {
      final total = _sumDevices(_recordDevices(box.get(key)));
      if (total > 0) out[key.toString()] = total;
    }
    return out;
  }

  /// 每本书的类型，用来给「只有时长、没有历史记录」的行补标题和图标。
  Map<String, String> kinds() {
    final box = _booksBox;
    if (box == null) return const {};
    final out = <String, String>{};
    for (final key in box.keys) {
      final raw = box.get(key);
      final kind = raw is Map ? raw[_kindKey] : null;
      if (kind is String && kind.trim().isNotEmpty) {
        out[key.toString()] = kind.trim();
      }
    }
    return out;
  }

  /// 备份里的形状：日表按设备分桶，书表带类型。
  ({DailyTable daily, List<BookTime> books}) export() {
    final daily = <String, Map<String, double>>{};
    final dayBox = _dailyBox;
    if (dayBox != null) {
      for (final key in dayBox.keys) {
        final day = key.toString();
        if (_parseDayKey(day) == null) continue;
        final devices = _devicesOf(dayBox.get(key));
        if (devices.isEmpty) continue;
        daily[day] = Map<String, double>.unmodifiable(devices);
      }
    }
    final books = <BookTime>[];
    final bookBox = _booksBox;
    if (bookBox != null) {
      for (final key in bookBox.keys) {
        final devices = _recordDevices(bookBox.get(key));
        if (devices.isEmpty) continue;
        books.add((
          id: key.toString(),
          kind: _kindOf(bookBox.get(key)) ?? 'book',
          devices: Map<String, double>.unmodifiable(devices),
        ));
      }
    }
    return (daily: daily, books: books);
  }

  /// 记一段时长。写入永远落在**本机**这一行上，所以是加法而不是取大。
  Future<void> accumulate(
    String identity,
    String kind,
    double seconds, {
    DateTime? at,
  }) async {
    if (identity.isEmpty || !seconds.isFinite || seconds <= 0) return;
    if (!isReady || _deviceId.isEmpty) return;
    final when = at ?? DateTime.now();
    final day = dayKey(when);
    final dailyBox = _dailyBox!;
    final booksBox = _booksBox!;

    final dayDevices = _devicesOf(dailyBox.get(day));
    dayDevices[_deviceId] = (dayDevices[_deviceId] ?? 0) + seconds;
    await dailyBox.put(day, dayDevices);

    final raw = booksBox.get(identity);
    final devices = _recordDevices(raw);
    devices[_deviceId] = (devices[_deviceId] ?? 0) + seconds;
    final label = kind.trim();
    await booksBox.put(identity, <String, dynamic>{
      _kindKey: label.isEmpty ? (_kindOf(raw) ?? 'book') : label,
      _touchedKey: when.millisecondsSinceEpoch,
      _devicesKey: devices,
    });

    await _sweep();
  }

  /// 合并云端快照。每个 (key, 设备) 取大，其余保留 —— 这就是 G-Counter 的
  /// join，幂等且不会把另一台设备的时长覆盖掉。
  Future<int> merge(DailyTable daily, List<BookTime> books) async {
    if (!isReady) return 0;
    var merged = 0;
    final dailyBox = _dailyBox!;
    final booksBox = _booksBox!;

    for (final entry in daily.entries) {
      if (_parseDayKey(entry.key) == null || entry.value.isEmpty) continue;
      final current = _devicesOf(dailyBox.get(entry.key));
      var changed = false;
      for (final device in entry.value.entries) {
        final incoming = device.value;
        if (!incoming.isFinite || incoming <= 0) continue;
        // 旧文件没有设备维度，合并时才认领成本机，这样重复导入只取大。
        final key = device.key == LibraryBackup.legacyDeviceKey
            ? _deviceId
            : device.key;
        if (incoming > (current[key] ?? 0)) {
          current[key] = incoming;
          changed = true;
        }
      }
      if (!changed) continue;
      await dailyBox.put(entry.key, current);
      merged++;
    }

    for (final book in books) {
      if (book.id.isEmpty || book.devices.isEmpty) continue;
      final raw = booksBox.get(book.id);
      final current = _recordDevices(raw);
      var changed = false;
      for (final device in book.devices.entries) {
        final incoming = device.value;
        if (!incoming.isFinite || incoming <= 0) continue;
        final key = device.key == LibraryBackup.legacyDeviceKey
            ? _deviceId
            : device.key;
        if (incoming > (current[key] ?? 0)) {
          current[key] = incoming;
          changed = true;
        }
      }
      if (!changed) continue;
      final label = book.kind.trim();
      await booksBox.put(book.id, <String, dynamic>{
        _kindKey: label.isEmpty ? (_kindOf(raw) ?? 'book') : label,
        // 合并进来的记录不该看起来像「最久没碰过」而被上限淘汰。
        _touchedKey: DateTime.now().millisecondsSinceEpoch,
        _devicesKey: current,
      });
      merged++;
    }

    if (merged > 0) await _sweep();
    return merged;
  }

  /// 老版本「书 × 天」交叉表的一次性折叠。`snapshot` 是 `identity -> day -> 秒`。
  ///
  /// 折叠后丢掉逐日明细，不可逆；但既然没有任何功能需要「某书某天」，
  /// 损失为零。旧数据没有设备维度，整份都算本机的。
  Future<void> migrateFromLegacy(Map<String, Map<String, double>> snapshot) async {
    if (!isReady || _deviceId.isEmpty || snapshot.isEmpty) return;
    final dailyBox = _dailyBox!;
    final booksBox = _booksBox!;
    final daily = <String, double>{};
    for (final entry in snapshot.entries) {
      if (entry.key.isEmpty) continue;
      var bookTotal = 0.0;
      for (final day in entry.value.entries) {
        if (_parseDayKey(day.key) == null) continue;
        if (!day.value.isFinite || day.value <= 0) continue;
        daily[day.key] = (daily[day.key] ?? 0) + day.value;
        bookTotal += day.value;
      }
      if (bookTotal <= 0) continue;
      final raw = booksBox.get(entry.key);
      final devices = _recordDevices(raw);
      devices[_deviceId] = (devices[_deviceId] ?? 0) + bookTotal;
      await booksBox.put(entry.key, <String, dynamic>{
        _kindKey: _kindOf(raw) ?? 'book',
        _touchedKey: DateTime.now().millisecondsSinceEpoch,
        _devicesKey: devices,
      });
    }
    for (final entry in daily.entries) {
      final devices = _devicesOf(dailyBox.get(entry.key));
      devices[_deviceId] = (devices[_deviceId] ?? 0) + entry.value;
      await dailyBox.put(entry.key, devices);
    }
    await _sweep();
  }

  Future<void> clear() async {
    if (!isReady) return;
    await _dailyBox!.clear();
    await _booksBox!.clear();
  }

  Future<void> flush() async {
    await _dailyBox?.flush();
    await _booksBox?.flush();
  }

  /// 日表按日期截断、书表按「最久没碰过」淘汰。两者独立，所以淘汰一本书
  /// 不会让累计总时长跟着变小 —— 这正是交叉表模型做不到的。
  ///
  /// 用 `length` 先做 O(1) 判断再决定要不要遍历：这个方法在播放时会每两秒
  /// 被调用一次，不能每次都扫一遍全表。
  Future<void> _sweep() async {
    if (!isReady) return;
    final dailyBox = _dailyBox!;
    if (dailyBox.length > retentionDays) {
      final dated = <String, DateTime>{};
      for (final key in dailyBox.keys) {
        final day = key.toString();
        final parsed = _parseDayKey(day);
        if (parsed == null) {
          await dailyBox.delete(key);
          continue;
        }
        dated[day] = parsed;
      }
      if (dated.length > retentionDays) {
        final keys = dated.keys.toList()
          ..sort((a, b) => dated[a]!.compareTo(dated[b]!));
        await dailyBox.deleteAll(
          keys.take(keys.length - retentionDays).toList(),
        );
      }
    }

    final booksBox = _booksBox!;
    if (booksBox.length <= maxBooks) return;
    final entries = <({dynamic key, int touched})>[];
    for (final key in booksBox.keys) {
      final raw = booksBox.get(key);
      final touched = raw is Map ? raw[_touchedKey] : null;
      entries.add((
        key: key,
        touched: touched is num && touched.isFinite ? touched.toInt() : 0,
      ));
    }
    entries.sort((a, b) => a.touched.compareTo(b.touched));
    final remove = entries.length - maxBooks;
    if (remove <= 0) return;
    await booksBox.deleteAll(entries.take(remove).map((e) => e.key).toList());
  }

  static Map<String, double> _devicesOf(dynamic raw) {
    if (raw is! Map) return <String, double>{};
    final out = <String, double>{};
    for (final entry in raw.entries) {
      final seconds = _seconds(entry.value);
      if (seconds != null && seconds > 0) {
        out[entry.key.toString()] = seconds;
      }
    }
    return out;
  }

  static Map<String, double> _recordDevices(dynamic raw) {
    if (raw is! Map) return <String, double>{};
    return _devicesOf(raw[_devicesKey]);
  }

  static String? _kindOf(dynamic raw) {
    if (raw is! Map) return null;
    final kind = raw[_kindKey];
    return kind is String && kind.trim().isNotEmpty ? kind.trim() : null;
  }

  static double _sumDevices(Map<String, double> devices) =>
      devices.values.fold<double>(0, (a, b) => a + b);

  static double? _seconds(dynamic value) {
    final number = value is num
        ? value
        : value is String
        ? num.tryParse(value)
        : null;
    if (number == null || !number.isFinite || number < 0) return null;
    return number.toDouble();
  }

  /// 与 `LibraryStore` 的历史键格式一致：`bookId`，或 `kind:id`。
  static String dayKey(DateTime d) => '${d.year}-${d.month}-${d.day}';

  static DateTime? _parseDayKey(String key) {
    final parts = key.split('-');
    if (parts.length != 3) return null;
    final year = int.tryParse(parts[0]);
    final month = int.tryParse(parts[1]);
    final day = int.tryParse(parts[2]);
    if (year == null || month == null || day == null) return null;
    if (year < 1 || year > 9999) return null;
    if (month < 1 || month > 12 || day < 1 || day > 31) return null;
    return DateTime(year, month, day);
  }
}
