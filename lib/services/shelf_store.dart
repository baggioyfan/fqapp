import 'package:flutter/foundation.dart';
import 'package:hive_ce/hive.dart';

import '../models/media_item.dart';
import 'encrypted_hive.dart';

/// One 加入书架 record.
class ShelfRecord {
  final MediaItem item;
  final DateTime addedAt;

  const ShelfRecord({required this.item, required this.addedAt});
}

/// The device-local 加入书架 collection.
///
/// The official client keeps this on the account: the shelf's 书架 tab lists
/// the favourites that sync across devices, and short dramas reach it through
/// 追剧. The backend has no favourites endpoint and this app has no login, so the
/// shelf is a Hive box next to the reading history instead. Records carry the
/// same fields the history does, so one set of cards renders both.
///
/// Note: 官方把「加入书架 / 追剧」存在账号上，这里退化为本地集合；理由与被否掉的
/// 方案见 .agents/notes/implemented/feature/2026-09-20-official-bookshelf.md
class ShelfStore {
  ShelfStore._();

  static final ShelfStore instance = ShelfStore._();

  static const boxName = 'shelf';

  /// 删除记录（墓碑）。删掉一条收藏之后，本地只是「没有它了」，同步时看不出
  /// 是「删掉了」还是「本来就没有」，并集合并就会把它原样搬回来 —— 连删掉它的
  /// 那台设备自己都会在合并那一步复活它。所以删除这件事必须单独记下来。
  ///
  /// key 与书架同构（见 [keyFor]），value 是删除时刻的毫秒时间戳。
  static const tombstoneBoxName = 'shelf_tombstones_v1';

  /// 墓碑只用来纠正「离线期间的另一台设备」，留半年足够；再久就丢掉，
  /// 免得文件无限变长（代价：离线超过半年的设备可能带回一条旧记录）。
  static const tombstoneTtl = Duration(days: 180);

  static const _keyPrefix = 'shelf_v1:';

  Box<dynamic>? _box;
  Box<dynamic>? _tombstones;
  final ValueNotifier<int> _revision = ValueNotifier<int>(0);

  /// Bumps on every write; the shelf page rebuilds from it.
  ValueListenable<int> get listenable => _revision;

  bool get isReady => _openBox != null;

  /// The box, but only while it is usable. A closed box (Hive.close() between
  /// test cases, a failed reopen) reads as "no local shelf" instead of throwing
  /// out of every card on the page.
  Box<dynamic>? get _openBox {
    final box = _box;
    return box != null && box.isOpen ? box : null;
  }

  /// 墓碑箱缺失时退化为「没有删除记录」，也就是旧的并集行为：
  /// 数据不会丢，只是删除暂时不传播。
  Box<dynamic>? get _openTombstones {
    final box = _tombstones;
    return box != null && box.isOpen ? box : null;
  }

  /// The stable key of one shelf entry. The series id wins over the item id for
  /// the same reason the detail page prefers it: a short drama can be opened
  /// from a single episode and must still land on the series.
  static String keyFor(String kind, String id) => '$_keyPrefix$kind:$id';

  static String keyOf(MediaItem item) =>
      keyFor(item.kind, item.seriesId ?? item.id);

  /// `shelf_v1:book:123` -> `book:123`。快照里不带存储前缀，只带身份。
  static String bareKey(String key) =>
      key.startsWith(_keyPrefix) ? key.substring(_keyPrefix.length) : key;

  Future<void> init() async {
    if (_openBox != null) return;
    _box = await EncryptedHive.openBox<dynamic>(Hive, boxName);
    // 墓碑是可选数据：开不出来就退回「删除不传播」，不能拖住书架本身。
    try {
      _tombstones = await EncryptedHive.openBox<dynamic>(Hive, tombstoneBoxName);
    } catch (_) {
      _tombstones = null;
    }
    _revision.value++;
  }

  bool contains(String kind, String id) {
    final value = _openBox?.get(keyFor(kind, id));
    return value is Map;
  }

  bool containsItem(MediaItem item) =>
      _openBox?.containsKey(keyOf(item)) ?? false;

  /// Newest first. Callers that need the official ordering (置顶 → 最近阅读)
  /// sort further; this is only the storage order.
  List<ShelfRecord> records() {
    final box = _openBox;
    if (box == null) return const [];
    final records = <ShelfRecord>[];
    for (final key in box.keys) {
      final raw = box.get(key);
      if (raw is! Map) continue;
      final item = _itemFrom(raw);
      if (item == null) continue;
      records.add(
        ShelfRecord(item: item, addedAt: _addedAt(raw) ?? DateTime(1970)),
      );
    }
    records.sort((a, b) => b.addedAt.compareTo(a.addedAt));
    return records;
  }

  /// Adds the item, or removes it when it is already on the shelf.
  /// Returns true when the item is on the shelf afterwards.
  Future<bool> toggle(MediaItem item) async {
    final box = _openBox;
    if (box == null) return false;
    final key = keyOf(item);
    if (box.containsKey(key)) {
      await box.delete(key);
      await _recordRemovals([key]);
      _revision.value++;
      return false;
    }
    await box.put(key, _recordOf(item, DateTime.now()));
    _revision.value++;
    return true;
  }

  Future<void> add(MediaItem item) async {
    final box = _openBox;
    if (box == null) return;
    await box.put(keyOf(item), _recordOf(item, DateTime.now()));
    _revision.value++;
  }

  Future<void> removeKeys(Iterable<String> keys) async {
    final box = _openBox;
    if (box == null) return;
    final known = keys.toSet();
    if (known.isEmpty) return;
    final removed = known.where(box.containsKey).toList();
    await box.deleteAll(removed);
    await _recordRemovals(removed);
    _revision.value++;
  }

  /// 撤销「移出书架」：把记录按**原 addedAt** 写回（`_recordOf` 含 addedAt
  /// 字段，schema 不变）。页面在移出前把选中的 [ShelfRecord] 暂存在内存
  /// 闭包里，SnackBar 撤销时调这里恢复。
  ///
  /// 仅内存级：进程死亡即失效，诚实不做伪恢复。
  Future<void> restoreAll(Iterable<ShelfRecord> records) async {
    final box = _openBox;
    if (box == null) return;
    var wrote = false;
    for (final record in records) {
      await box.put(keyOf(record.item), _recordOf(record.item, record.addedAt));
      wrote = true;
    }
    // 撤销的语义是「刚才没删过」，所以必须把墓碑一起撤掉，否则下一次同步
    // 会把刚恢复的条目再删一遍。
    final tombstones = _openTombstones;
    if (tombstones != null) {
      final keys = [for (final record in records) keyOf(record.item)];
      await tombstones.deleteAll(keys.where(tombstones.containsKey));
    }
    if (wrote) _revision.value++;
  }

  Future<void> clear() async {
    final box = _openBox;
    if (box == null) return;
    // 清空也是一次删除：不记墓碑的话，下次同步会把整架收藏搬回来。
    final everything = box.keys.toList();
    await box.clear();
    await _recordRemovals(everything);
    _revision.value++;
  }

  /// 本机记录的删除：`key -> 删除时刻`。快照会把它一起上传，另一台设备靠它
  /// 知道「这条是被删了」而不是「本来就没有」。
  Map<String, DateTime> tombstones() {
    final box = _openTombstones;
    if (box == null) return const {};
    final result = <String, DateTime>{};
    for (final key in box.keys) {
      final value = box.get(key);
      if (value is num && value > 0) {
        result[key.toString()] = DateTime.fromMillisecondsSinceEpoch(
          value.toInt(),
        );
      }
    }
    return result;
  }

  /// 写墓碑并顺手丢掉过期的，避免文件只增不减。
  Future<void> _recordRemovals(Iterable<String> keys) async {
    final box = _openTombstones;
    if (box == null) return;
    final now = DateTime.now().millisecondsSinceEpoch;
    final stamps = {for (final key in keys) key: now};
    if (stamps.isNotEmpty) await box.putAll(stamps);
    await _pruneTombstones(box);
  }

  Future<void> _pruneTombstones(Box<dynamic> box) async {
    final cutoff = DateTime.now()
        .subtract(tombstoneTtl)
        .millisecondsSinceEpoch;
    final stale = [
      for (final key in box.keys)
        if ((box.get(key) as num? ?? 0) < cutoff) key,
    ];
    if (stale.isNotEmpty) await box.deleteAll(stale);
  }

  /// 合并一次备份里的书架。
  ///
  /// [removed] 是对方（云端）带来的墓碑，key 与本机相同。逐条按时间取较晚的
  /// 那次操作：墓碑比收藏时间新 ⇒ 删掉；收藏时间比墓碑新 ⇒ 保留（说明删掉之后
  /// 又加回来了）。合并后的墓碑留在本机，随下一次 [records]/[tombstones] 一起
  /// 上传，对方才会跟着删。
  ///
  /// The check and putAll are synchronous up to the first await, so another
  /// shelf action cannot slip between the check and Hive's in-memory update.
  Future<int> mergeBackup(
    Iterable<ShelfRecord> records, {
    Map<String, DateTime> removed = const {},
  }) async {
    final box = _openBox;
    if (box == null) throw StateError('书架尚未初始化');
    final tombstones = _openTombstones;
    final missing = <String, Map<String, dynamic>>{};
    try {
      if (tombstones != null) {
        // 1. 先合墓碑：同一条被删过两次，取较晚的那次。
        final stamps = <String, int>{};
        for (final entry in removed.entries) {
          final incoming = entry.value.millisecondsSinceEpoch;
          final current = tombstones.get(entry.key);
          final existing = current is num ? current.toInt() : 0;
          if (incoming > existing) stamps[entry.key] = incoming;
        }
        if (stamps.isNotEmpty) await tombstones.putAll(stamps);
        await _pruneTombstones(tombstones);

        // 2. 墓碑已经输给本机更晚的收藏（删了又加回来）⇒ 丢掉这条墓碑，
        //    否则会一直被上传，对方那台的旧记录也会被误删。
        final beaten = <String>[];
        for (final key in tombstones.keys) {
          final addedAt = _addedAtMs(box.get(key));
          final removedAt = _tombstoneMs(tombstones, key);
          if (addedAt != null && removedAt != null && addedAt > removedAt) {
            beaten.add(key);
          }
        }
        if (beaten.isNotEmpty) await tombstones.deleteAll(beaten);

        // 3. 墓碑赢了的本机收藏：删掉。记录坏到读不出收藏时间时也按删除处理，
        //    否则这条会永远卡在本地。
        final killed = <String>[];
        for (final key in box.keys) {
          final removedAt = _tombstoneMs(tombstones, key);
          if (removedAt == null) continue;
          final addedAt = _addedAtMs(box.get(key));
          if (addedAt == null || removedAt >= addedAt) killed.add(key);
        }
        if (killed.isNotEmpty) await box.deleteAll(killed);
      }

      // 4. 对方的收藏：只补本机没有的，且不能是已经被删掉的。
      for (final record in records) {
        final key = keyOf(record.item);
        final removedAt = _tombstoneMs(tombstones, key);
        if (removedAt != null &&
            removedAt >= record.addedAt.millisecondsSinceEpoch) {
          continue;
        }
        if (box.containsKey(key)) continue;
        missing[key] = _recordOf(record.item, record.addedAt);
      }
      if (missing.isNotEmpty) await box.putAll(missing);
      // A retry after a failed flush must still retry durable persistence.
      await box.flush();
    } finally {
      // A failed disk write can still have changed part of the visible box.
      _revision.value++;
    }
    return missing.length;
  }

  static int? _addedAtMs(Object? raw) =>
      raw is Map ? _addedAt(raw)?.millisecondsSinceEpoch : null;

  static int? _tombstoneMs(Box<dynamic>? box, String key) {
    if (box == null) return null;
    final value = box.get(key);
    return value is num && value > 0 ? value.toInt() : null;
  }

  static Map<String, dynamic> _recordOf(MediaItem item, DateTime addedAt) => {
    'id': item.id,
    'kind': item.kind,
    'title': item.title,
    'cover': item.cover,
    'author': item.author,
    'badge': item.badge,
    'ep': item.ep,
    'seriesId': item.seriesId,
    'episodeId': item.episodeId,
    'addedAt': addedAt.millisecondsSinceEpoch,
  };

  static DateTime? _addedAt(Map<dynamic, dynamic> raw) {
    final value = raw['addedAt'];
    return value is num && value > 0
        ? DateTime.fromMillisecondsSinceEpoch(value.toInt())
        : null;
  }

  /// A broken record must not take the whole shelf down with it: unknown shapes
  /// are skipped, which is the same rule the history list follows.
  static MediaItem? _itemFrom(Map<dynamic, dynamic> raw) {
    final id = raw['id']?.toString() ?? '';
    final title = raw['title']?.toString() ?? '';
    if (id.isEmpty && title.isEmpty) return null;
    return MediaItem(
      id: id,
      title: title.isEmpty ? '未知作品' : title,
      cover: raw['cover']?.toString() ?? '',
      author: raw['author']?.toString() ?? '',
      badge: raw['badge']?.toString() ?? '',
      ep: raw['ep']?.toString() ?? '',
      kind: raw['kind']?.toString() ?? 'book',
      seriesId: raw['seriesId']?.toString(),
      episodeId: raw['episodeId']?.toString(),
    );
  }
}
