import 'dart:convert';
import 'dart:typed_data';

import '../services/search_history_store.dart';
import '../services/shelf_store.dart';
import 'media_item.dart';

/// A portable allowlist, never a dump of Hive boxes or device preferences.
// Note: 范围、合并规则与非事务恢复见
// .agents/notes/implemented/feature/2026-10-15-library-backup.md
class LibraryBackup {
  static const maxBytes = 16 * 1024 * 1024;

  static const _maxDaySeconds = 1e9;
  static const _maxSearchTerms = 20;
  static const _maxSearchTermLength = 200;
  static const _maxRecords = 10000;
  static const _maxEpisodes = 100000;
  static const _format = 'fqapp.library-backup';

  /// 2 adds `readTime` and `searchHistory`; 3 adds `shelfRemoved`;
  /// 4 replaces the (book × day) `readTime` cross-tab with `daily` + `books`,
  /// both counted per device.
  /// 5 makes `history` optional. The WebDAV snapshot leaves it out because the
  /// same records already travel in `progress.json` ([ProgressShard]); writing
  /// them twice made the cloud copy ~40 KB bigger for no benefit. A manual
  /// export still writes them, so a backup file stays self-contained.
  /// Older files stay importable: a v1–v3 `readTime` list is folded into the
  /// two new tables on read, so no export ever loses the totals.
  static const _version = 5;
  static const _supportedVersions = {1, 2, 3, 4, 5};
  static const _kinds = {'book', 'audio', 'manga', 'video', 'manju'};
  static final _idPattern = RegExp(r'^[a-zA-Z0-9_-]{1,128}$');
  static final _devicePattern = RegExp(r'^[a-zA-Z0-9_~-]{1,32}$');

  /// 旧文件没有设备维度，读进来时先挂在这个哨兵下；真正合并时
  /// [ReadTimeStore.merge] 会把它换成本机 id，这样同一台设备重复导入
  /// 只会取大，不会把时长翻倍。
  static const legacyDeviceKey = '~local';

  final DateTime createdAt;
  final List<ShelfRecord> shelf;

  /// 书架里被删掉的条目：`{kind}:{id} -> 删除时刻`。
  ///
  /// 没有它，「已从书架移除」和「从来不在书架」在文件里长得一样，并集合并只能
  /// 把删掉的条目搬回来 —— 连删掉它的那台设备自己都会在合并那一步复活它。
  /// key 用 `kind:id`（不带存储前缀），[shelfTombstones] 负责还原成存储键。
  final Map<String, DateTime> shelfRemoved;

  /// IDs here are content IDs. Storage keys are reconstructed by LibraryStore.
  final List<Map<String, dynamic>> history;
  final Map<String, Map<String, int>> watched;

  /// 阅读时长按天表：`{day: {deviceId: seconds}}`。
  ///
  /// 按设备分桶而不是直接存一个总数，是因为合并只能取大（加法不幂等），
  /// 而取大会让「手机读一小时 + 平板读四十分钟」丢掉一台。分设备之后
  /// 合并取大、展示求和，两个设备都不丢，重复导入也不会翻倍。
  final Map<String, Map<String, double>> daily;

  /// 阅读时长按书表：`{id, kind, devices: {deviceId: seconds}}`。
  final List<({String id, String kind, Map<String, double> devices})> books;
  final List<String> searchHistory;
  final int excludedLocalRecords;

  LibraryBackup._({
    required this.createdAt,
    required this.shelf,
    required this.shelfRemoved,
    required this.history,
    required this.watched,
    required this.daily,
    required this.books,
    required this.searchHistory,
    required this.excludedLocalRecords,
  });

  /// 删除记录还原成存储键，交给 `ShelfStore.mergeBackup` 的 `removed`。
  Map<String, DateTime> get shelfTombstones {
    final result = <String, DateTime>{};
    for (final entry in shelfRemoved.entries) {
      final parts = _splitBare(entry.key);
      if (parts == null) continue;
      result[ShelfStore.keyFor(parts.kind, parts.id)] = entry.value;
    }
    return result;
  }

  int get episodeCount =>
      watched.values.fold(0, (total, episodes) => total + episodes.length);

  factory LibraryBackup.capture({
    required List<ShelfRecord> shelf,
    required Map<String, DateTime> shelfRemoved,
    required List<Map<String, dynamic>> history,
    required Map<String, Map<String, int>> watched,
    required Map<String, Map<String, double>> daily,
    required List<({String id, String kind, Map<String, double> devices})>
    books,
    required Iterable<String> searchHistory,
  }) {
    var excluded = 0;
    bool include(String id) {
      if (!_bareId(id).startsWith('local_')) return true;
      excluded++;
      return false;
    }

    // The same validation is used before export and before any restore writes.
    final removedJson = <Map<String, dynamic>>[];
    for (final entry in shelfRemoved.entries) {
      final parts = _splitBare(ShelfStore.bareKey(entry.key));
      if (parts == null || !include(parts.id)) continue;
      removedJson.add({
        'kind': parts.kind,
        'id': parts.id,
        'removedAt': entry.value.millisecondsSinceEpoch,
      });
    }
    return LibraryBackup._fromJson({
      'format': _format,
      'version': _version,
      'createdAt': DateTime.now().millisecondsSinceEpoch,
      'shelf': [
        for (final record in shelf)
          if (include(record.item.seriesId ?? record.item.id))
            {..._shelfJson(record), 'cover': _portableCover(record.item.cover)},
      ],
      'shelfRemoved': removedJson,
      'history': [
        for (final record in history)
          if (include((record['contentId'] ?? record['id']).toString()))
            {
              ...record,
              'id': record['contentId'] ?? record['id'],
              'kind': record['kind'] ?? 'book',
              'cover': _portableCover(record['cover']?.toString() ?? ''),
            },
      ],
      'watched': [
        for (final entry in watched.entries)
          if (include(entry.key)) {'id': entry.key, 'episodes': entry.value},
      ],
      'daily': {
        for (final day in daily.entries)
          if (_parseDayKey(day.key) != null && day.value.isNotEmpty)
            day.key: {
              for (final device in day.value.entries)
                if (device.value.isFinite && device.value > 0)
                  device.key: device.value,
            },
      },
      'books': [
        for (final book in books)
          if (include(book.id) && book.devices.isNotEmpty)
            {
              // Stored by content ID, like history: the store rebuilds the
              // `kind:id` key for scoped media on restore.
              'id': _bareId(book.id),
              'kind': book.kind,
              'devs': {
                for (final device in book.devices.entries)
                  if (device.value.isFinite && device.value > 0)
                    device.key: device.value,
              },
            },
      ],
      'searchHistory': normalizeSearchHistory(searchHistory).toList(),
      'excludedLocalRecords': excluded,
    });
  }

  factory LibraryBackup.decode(Uint8List bytes) {
    if (bytes.length > maxBytes) {
      throw const FormatException('备份文件超过 16 MB');
    }
    dynamic raw;
    try {
      var text = utf8.decode(bytes);
      if (text.startsWith('\uFEFF')) text = text.substring(1);
      raw = jsonDecode(text);
    } on FormatException {
      throw const FormatException('文件不是有效的 UTF-8 JSON 备份');
    }
    return LibraryBackup._fromJson(_map(raw));
  }

  factory LibraryBackup._fromJson(Map<String, dynamic> raw) {
    final version = raw['version'];
    if (raw['format'] != _format ||
        version is! int ||
        !_supportedVersions.contains(version)) {
      throw const FormatException('不是受支持的番茄小铺备份，请使用兼容版本导出的文件');
    }
    final createdAt = _integer(raw['createdAt'], '备份时间', 8640000000000000);
    final shelf = <ShelfRecord>[];
    final shelfKeys = <String>{};
    for (final value in _list(raw['shelf'])) {
      final record = _map(value);
      final common = _common(record);
      final item = MediaItem(
        id: common['id'] as String,
        kind: common['kind'] as String,
        title: common['title'] as String,
        cover: common['cover'] as String,
        author: common['author'] as String,
        badge: common['badge'] as String,
        ep: common['ep'] as String,
        seriesId: common['seriesId'] as String?,
        episodeId: common['episodeId'] as String?,
      );
      if (!shelfKeys.add(ShelfStore.keyOf(item))) {
        throw const FormatException('备份中有重复的收藏');
      }
      shelf.add(
        ShelfRecord(
          item: item,
          addedAt: DateTime.fromMillisecondsSinceEpoch(
            _integer(record['addedAt'], '收藏时间', 8640000000000000),
          ),
        ),
      );
    }
    // 删除记录。同一作品可能被删过多次，取最晚的一次。
    final shelfRemoved = <String, DateTime>{};
    for (final value in _list(raw['shelfRemoved'] ?? const <dynamic>[])) {
      final record = _map(value);
      if (!_kinds.contains(record['kind'])) {
        throw const FormatException('备份含未知作品类型');
      }
      final at = DateTime.fromMillisecondsSinceEpoch(
        _integer(record['removedAt'], '删除时间', 8640000000000000),
      );
      final key = '${record['kind']}:${_id(record['id'])}';
      final existing = shelfRemoved[key];
      if (existing == null || at.isAfter(existing)) shelfRemoved[key] = at;
    }
    // 顺手把文件里自相矛盾的部分消掉：收藏和删除只留较晚的那一个。
    final keptShelf = <ShelfRecord>[];
    for (final record in shelf) {
      final key = ShelfStore.bareKey(ShelfStore.keyOf(record.item));
      final removedAt = shelfRemoved[key];
      if (removedAt == null) {
        keptShelf.add(record);
      } else if (record.addedAt.isAfter(removedAt)) {
        // 删掉之后又加了回来，以「加回来」为准。
        shelfRemoved.remove(key);
        keptShelf.add(record);
      }
      // 其余情况：删除更晚，这条收藏不该存在。
    }
    // v5 起整包可以不带 `history`（那些记录由 `progress.json` 单独承载）。
    // 缺失按空表处理：合并空表不会改动本机进度，所以「整包瘦身后的云端
    // 文件」对合并是透明的。
    final history = sanitizeHistory(_list(raw['history'] ?? const <dynamic>[]));
    final watched = <String, Map<String, int>>{};
    var count = 0;
    for (final value in _list(raw['watched'])) {
      final record = _map(value);
      final id = _id(record['id']);
      if (watched.containsKey(id)) throw const FormatException('备份中有重复的已看记录');
      final episodes = _map(record['episodes']);
      count += episodes.length;
      if (count > _maxEpisodes) throw const FormatException('已看剧集超过 100000 条');
      watched[id] = Map.unmodifiable({
        for (final entry in episodes.entries)
          _id(entry.key): _integer(entry.value, '已看时间', 8640000000000000),
      });
    }
    // 阅读时长：v4 起是「按天表 + 按书表」，两张都按设备分桶。
    final daily = <String, Map<String, double>>{};
    final books = <String, ({String id, String kind, Map<String, double> devices})>{};
    final dailyJson = raw['daily'];
    final booksJson = raw['books'];
    if (dailyJson != null) {
      for (final entry in _map(dailyJson).entries) {
        if (_parseDayKey(entry.key) == null) {
          throw const FormatException('备份中的阅读时长日期无效');
        }
        final devices = _deviceSeconds(entry.value);
        if (devices.isNotEmpty) daily[entry.key] = Map.unmodifiable(devices);
      }
    }
    if (booksJson != null) {
      for (final value in _list(booksJson)) {
        final record = _map(value);
        final id = _id(record['id']);
        if (!_kinds.contains(record['kind'])) {
          throw const FormatException('阅读时长含未知作品类型');
        }
        if (books.containsKey(id)) {
          throw const FormatException('备份中有重复的阅读时长');
        }
        final devices = _deviceSeconds(record['devs']);
        if (devices.isEmpty) continue;
        books[id] = (
          id: id,
          kind: record['kind'] as String,
          devices: Map.unmodifiable(devices),
        );
      }
    }
    // v1–v3 的 (书 × 天) 交叉表：在内存里折叠一次，不写回。旧文件没有设备
    // 维度，先挂在哨兵下，合并时再换成本机 id —— 这样重复导入只取大，不翻倍。
    if (dailyJson == null && booksJson == null) {
      for (final value in _list(raw['readTime'] ?? const <dynamic>[])) {
        final record = _map(value);
        final id = _id(record['id']);
        if (!_kinds.contains(record['kind'])) {
          throw const FormatException('阅读时长含未知作品类型');
        }
        final days = <String, double>{};
        for (final day in _map(record['days']).entries) {
          final seconds = day.value;
          if (_parseDayKey(day.key) == null ||
              seconds is! num ||
              !seconds.isFinite ||
              seconds < 0 ||
              seconds > _maxDaySeconds) {
            throw const FormatException('备份中的阅读时长无效');
          }
          if (seconds <= 0) continue;
          days[day.key] = seconds.toDouble();
        }
        if (days.isEmpty) continue;
        var total = 0.0;
        for (final day in days.entries) {
          final current = daily[day.key] ?? const <String, double>{};
          daily[day.key] = Map.unmodifiable({
            ...current,
            legacyDeviceKey: (current[legacyDeviceKey] ?? 0) + day.value,
          });
          total += day.value;
        }
        books[id] = (
          id: id,
          kind: record['kind'] as String,
          devices: Map.unmodifiable({legacyDeviceKey: total}),
        );
      }
    }
    final searchHistory = <String>[];
    final searchSeen = <String>{};
    for (final value in _list(raw['searchHistory'] ?? const <dynamic>[])) {
      if (value is! String) throw const FormatException('搜索历史记录无效');
      final term = normalizeSearchQuery(value);
      if (term.isEmpty) continue;
      if (term.length > _maxSearchTermLength) {
        throw const FormatException('搜索历史记录过长');
      }
      if (!searchSeen.add(term.toLowerCase())) continue;
      if (searchHistory.length == _maxSearchTerms) break;
      searchHistory.add(term);
    }
    return LibraryBackup._(
      createdAt: DateTime.fromMillisecondsSinceEpoch(createdAt),
      shelf: List.unmodifiable(keptShelf),
      shelfRemoved: Map.unmodifiable(shelfRemoved),
      history: List.unmodifiable(history),
      watched: Map.unmodifiable(watched),
      daily: Map.unmodifiable(daily),
      books: List.unmodifiable(books.values),
      searchHistory: List.unmodifiable(searchHistory),
      excludedLocalRecords: _integer(
        raw['excludedLocalRecords'] ?? 0,
        '排除条数',
        2147483647,
      ),
    );
  }

  /// 只校验进度列表：整包备份与 `progress.json` 分片共用同一套规则，
  /// 免得两处对同一条记录给出不同的判断。
  static List<Map<String, dynamic>> sanitizeHistory(
    List<dynamic> records,
  ) {
    final history = <Map<String, dynamic>>[];
    final historyKeys = <String>{};
    for (final value in records) {
      final record = _map(value);
      final clean = _common(record);
      if (!historyKeys.add('${clean['kind']}:${clean['id']}')) {
        throw const FormatException('备份中有重复的进度');
      }
      for (final key in ['bookId', 'chapterId', 'toneId']) {
        if (record[key] != null && record[key] != '') {
          clean[key] = _id(record[key]);
        }
      }
      for (final key in ['time', 'episode', 'positionVersion', 'textOffset']) {
        if (record[key] != null) {
          clean[key] = _integer(
            record[key],
            key,
            key == 'time' ? 8640000000000000 : 2147483647,
          );
        }
      }
      for (final key in [
        'position',
        'maxScroll',
        'progress',
        'duration',
        'rate',
      ]) {
        if (record[key] == null) continue;
        final value = record[key];
        final max = key == 'progress'
            ? 1
            : key == 'rate'
            ? 10
            : 1e12;
        if (value is! num || !value.isFinite || value < 0 || value > max) {
          throw FormatException('备份字段 $key 无效');
        }
        clean[key] = value.toDouble();
      }
      if (record['positionUnit'] != null) {
        if (record['positionUnit'] != 'comic-page' ||
            clean['kind'] != 'manga') {
          throw const FormatException('不支持的漫画进度单位');
        }
        clean['positionUnit'] = 'comic-page';
      }
      for (final key in ['autoAdvance', 'completed', 'fanqieImported']) {
        if (record[key] == null) continue;
        if (record[key] is! bool) throw FormatException('备份字段 $key 无效');
        clean[key] = record[key];
      }
      history.add(Map.unmodifiable(clean));
    }
    return List.unmodifiable(history);
  }

  /// 不再有「超 8 MB 就悄悄把阅读时长裁到一年」的降级：两张表分别由
  /// 天数（365）和书数（5000）封顶，最坏也就几百 KB，够不到上限。
  /// 这一条很关键 —— 旧逻辑裁掉明细后，新设备恢复出来的累计总时长会静默变少。
  ///
  /// [includeHistory] 默认 `true`：手动导出的备份文件必须自包含（进度也在里
  /// 面），否则拿它去换机就会丢掉全部阅读/播放进度。只有 WebDAV 整包传
  /// `false` —— 那些记录已经由 `progress.json` 单独承载，再写一遍等于云端
  /// 存两份（实测 80 KB 的整包里有约 40 KB 是这份重复）。
  Uint8List encode({bool includeHistory = true}) {
    final bytes = Uint8List.fromList(
      utf8.encode(jsonEncode(_toJson(includeHistory: includeHistory))),
    );
    if (bytes.length > maxBytes) {
      throw const FormatException('备份数据超过 16 MB');
    }
    return bytes;
  }

  Map<String, dynamic> _toJson({required bool includeHistory}) => {
    'format': _format,
    'version': _version,
    'createdAt': createdAt.millisecondsSinceEpoch,
    'shelf': shelf.map(_shelfJson).toList(),
    'shelfRemoved': _shelfRemovedJson(),
    if (includeHistory) 'history': history,
    'watched': [
      for (final entry in watched.entries)
        {'id': entry.key, 'episodes': entry.value},
    ],
    'daily': {
      for (final entry in daily.entries) entry.key: entry.value,
    },
    'books': [
      for (final book in books)
        {'id': book.id, 'kind': book.kind, 'devs': book.devices},
    ],
    'searchHistory': searchHistory,
    'excludedLocalRecords': excludedLocalRecords,
  };

  /// 恢复时用的书表：把内容 id 还原成存储键（音频/漫画带 `kind:` 前缀），
  /// 和历史的键规则保持一致。
  List<({String id, String kind, Map<String, double> devices})>
  get bookEntries => [
    for (final book in books)
      (
        id: book.kind == 'audio' || book.kind == 'manga'
            ? '${book.kind}:${book.id}'
            : book.id,
        kind: book.kind,
        devices: book.devices,
      ),
  ];

  /// `{deviceId: seconds}`，逐项校验；秒数 <= 0 的条目直接丢掉。
  static Map<String, double> _deviceSeconds(dynamic raw) {
    if (raw is! Map) throw const FormatException('备份中的阅读时长无效');
    final out = <String, double>{};
    for (final entry in raw.entries) {
      final device = entry.key.toString();
      if (!_devicePattern.hasMatch(device)) {
        throw const FormatException('备份中的设备标识无效');
      }
      final seconds = entry.value;
      if (seconds is! num ||
          !seconds.isFinite ||
          seconds < 0 ||
          seconds > _maxDaySeconds) {
        throw const FormatException('备份中的阅读时长无效');
      }
      if (seconds <= 0) continue;
      out[device] = seconds.toDouble();
    }
    return out;
  }

  /// `book:123` -> `(kind: 'book', id: '123')`。作品标识里不会有冒号
  /// （见 `_idPattern`），所以按第一个冒号切开就够。
  static ({String kind, String id})? _splitBare(String bare) {
    final separator = bare.indexOf(':');
    if (separator <= 0 || separator == bare.length - 1) return null;
    return (
      kind: bare.substring(0, separator),
      id: bare.substring(separator + 1),
    );
  }

  /// `audio:123` -> `123`. Scoped-media storage keys never travel: a backup
  /// stores the content ID, and the store rebuilds the key from `kind`. It also
  /// keeps a scoped ID that points at a local book recognizable as local data.
  static String _bareId(String id) {
    final separator = id.indexOf(':');
    if (separator < 0) return id;
    final scope = id.substring(0, separator);
    return scope == 'audio' || scope == 'manga'
        ? id.substring(separator + 1)
        : id;
  }

  /// Mirrors `LibraryStore._dayKey`, which does not zero-pad its parts.
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

  /// 删除记录的 JSON 形态。身份解析不出来的（理论上不会有）直接跳过。
  List<Map<String, dynamic>> _shelfRemovedJson() {
    final result = <Map<String, dynamic>>[];
    for (final entry in shelfRemoved.entries) {
      final parts = _splitBare(entry.key);
      if (parts == null) continue;
      result.add({
        'kind': parts.kind,
        'id': parts.id,
        'removedAt': entry.value.millisecondsSinceEpoch,
      });
    }
    return result;
  }

  static Map<String, dynamic> _shelfJson(ShelfRecord record) => {
    'id': record.item.id,
    'kind': record.item.kind,
    'title': record.item.title,
    'cover': record.item.cover,
    'author': record.item.author,
    'badge': record.item.badge,
    'ep': record.item.ep,
    if (record.item.seriesId != null) 'seriesId': record.item.seriesId,
    if (record.item.episodeId != null) 'episodeId': record.item.episodeId,
    'addedAt': record.addedAt.millisecondsSinceEpoch,
  };

  static Map<String, dynamic> _common(Map<String, dynamic> raw) {
    if (!_kinds.contains(raw['kind'])) throw const FormatException('备份含未知作品类型');
    final clean = <String, dynamic>{'id': _id(raw['id']), 'kind': raw['kind']};
    for (final key in ['title', 'cover', 'author', 'badge', 'ep']) {
      final value = raw[key] ?? '';
      if (value is! String || value.length > 8192) {
        throw FormatException('备份字段 $key 无效或过长');
      }
      clean[key] = key == 'cover' ? _portableCover(value) : value;
    }
    for (final key in ['seriesId', 'episodeId']) {
      if (raw[key] != null && raw[key] != '') clean[key] = _id(raw[key]);
    }
    return clean;
  }

  static String _portableCover(String value) {
    final uri = Uri.tryParse(value);
    return uri != null &&
            (uri.scheme == 'https' || uri.scheme == 'http') &&
            uri.host.isNotEmpty &&
            uri.userInfo.isEmpty
        ? value
        : '';
  }

  static String _id(dynamic value) {
    if (value is! String ||
        !_idPattern.hasMatch(value) ||
        value.startsWith('local_')) {
      throw const FormatException('备份含无效作品标识或本地书籍记录');
    }
    return value;
  }

  static int _integer(dynamic value, String label, int max) {
    if (value is! int || value < 0 || value > max) {
      throw FormatException('备份字段 $label 无效');
    }
    return value;
  }

  static Map<String, dynamic> _map(dynamic value) {
    if (value is! Map<String, dynamic>) throw const FormatException('备份记录格式无效');
    return value;
  }

  static List<dynamic> _list(dynamic value) {
    if (value is! List || value.length > _maxRecords) {
      throw const FormatException('备份列表无效或超过 10000 条');
    }
    return value;
  }
}
