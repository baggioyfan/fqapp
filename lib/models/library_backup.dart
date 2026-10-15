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

  /// Past this the exporter retries with a shorter read-time window instead of
  /// failing outright: day buckets dominate the payload, and an install that
  /// has been tracking for years can approach the hard limit on its own.
  static const _trimAboveBytes = 8 * 1024 * 1024;
  static const _trimmedReadTimeDays = 365;
  static const _maxDaySeconds = 1e9;
  static const _maxSearchTerms = 20;
  static const _maxSearchTermLength = 200;
  static const _maxRecords = 10000;
  static const _maxEpisodes = 100000;
  static const _format = 'fqapp.library-backup';

  /// 2 adds `readTime` and `searchHistory`; 1 files stay importable, their
  /// missing lists simply read as empty.
  static const _version = 2;
  static const _supportedVersions = {1, 2};
  static const _kinds = {'book', 'audio', 'manga', 'video', 'manju'};
  static final _idPattern = RegExp(r'^[a-zA-Z0-9_-]{1,128}$');

  final DateTime createdAt;
  final List<ShelfRecord> shelf;

  /// IDs here are content IDs. Storage keys are reconstructed by LibraryStore.
  final List<Map<String, dynamic>> history;
  final Map<String, Map<String, int>> watched;

  /// `{id, kind, days: {day: seconds}}` — the user-visible read-time totals,
  /// never the internal allocation/migration keys those totals are derived from.
  final List<Map<String, dynamic>> readTime;
  final List<String> searchHistory;
  final int excludedLocalRecords;

  LibraryBackup._({
    required this.createdAt,
    required this.shelf,
    required this.history,
    required this.watched,
    required this.readTime,
    required this.searchHistory,
    required this.excludedLocalRecords,
  });

  int get episodeCount =>
      watched.values.fold(0, (total, episodes) => total + episodes.length);

  /// The read-time entries in the typed shape the store's merge consumes:
  /// `id` is a content ID and `kind` scopes the storage key, as with history.
  List<({String id, String kind, Map<String, double> days})>
  get readTimeEntries => [
    for (final entry in readTime)
      (
        id: entry['id'] as String,
        kind: entry['kind'] as String,
        days: {
          for (final day in (entry['days'] as Map).entries)
            day.key as String: (day.value as num).toDouble(),
        },
      ),
  ];

  factory LibraryBackup.capture({
    required List<ShelfRecord> shelf,
    required List<Map<String, dynamic>> history,
    required Map<String, Map<String, int>> watched,
    required List<({String id, String kind, Map<String, double> days})>
    readTime,
    required Iterable<String> searchHistory,
  }) {
    var excluded = 0;
    bool include(String id) {
      if (!_bareId(id).startsWith('local_')) return true;
      excluded++;
      return false;
    }

    // The same validation is used before export and before any restore writes.
    return LibraryBackup._fromJson({
      'format': _format,
      'version': _version,
      'createdAt': DateTime.now().millisecondsSinceEpoch,
      'shelf': [
        for (final record in shelf)
          if (include(record.item.seriesId ?? record.item.id))
            {..._shelfJson(record), 'cover': _portableCover(record.item.cover)},
      ],
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
      'readTime': [
        for (final entry in readTime)
          if (include(entry.id) && entry.days.isNotEmpty)
            {
              // Stored by content ID, like history: the store rebuilds the
              // `kind:id` key for scoped media on restore.
              'id': _bareId(entry.id),
              'kind': entry.kind,
              'days': {
                for (final day in entry.days.entries)
                  if (_parseDayKey(day.key) != null) day.key: day.value,
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
      throw const FormatException('不是受支持的 FQApp 备份，请使用兼容版本导出的文件');
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
    final history = <Map<String, dynamic>>[];
    final historyKeys = <String>{};
    for (final value in _list(raw['history'])) {
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
      for (final key in ['autoAdvance', 'completed']) {
        if (record[key] == null) continue;
        if (record[key] is! bool) throw FormatException('备份字段 $key 无效');
        clean[key] = record[key];
      }
      history.add(Map.unmodifiable(clean));
    }
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
    final readTime = <Map<String, dynamic>>[];
    final readTimeIds = <String>{};
    for (final value in _list(raw['readTime'] ?? const <dynamic>[])) {
      final record = _map(value);
      final id = _id(record['id']);
      if (!_kinds.contains(record['kind'])) {
        throw const FormatException('阅读时长含未知作品类型');
      }
      if (!readTimeIds.add(id)) throw const FormatException('备份中有重复的阅读时长');
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
        days[day.key] = seconds.toDouble();
      }
      if (days.isEmpty) continue;
      readTime.add(
        Map.unmodifiable({
          'id': id,
          'kind': record['kind'],
          'days': Map.unmodifiable(days),
        }),
      );
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
      shelf: List.unmodifiable(shelf),
      history: List.unmodifiable(history),
      watched: Map.unmodifiable(watched),
      readTime: List.unmodifiable(readTime),
      searchHistory: List.unmodifiable(searchHistory),
      excludedLocalRecords: _integer(
        raw['excludedLocalRecords'] ?? 0,
        '排除条数',
        2147483647,
      ),
    );
  }

  Uint8List encode() {
    var bytes = _encodeBytes();
    if (bytes.length > _trimAboveBytes) {
      // Retry once with the read-time window shortened; the rest of the payload
      // is bounded by record counts and cannot be trimmed meaningfully.
      bytes = _encodeBytes(readTimeDays: _trimmedReadTimeDays);
    }
    if (bytes.length > maxBytes) throw const FormatException('备份数据超过 16 MB');
    return bytes;
  }

  Uint8List _encodeBytes({int? readTimeDays}) => Uint8List.fromList(
    utf8.encode(
      jsonEncode({
        'format': _format,
        'version': _version,
        'createdAt': createdAt.millisecondsSinceEpoch,
        'shelf': shelf.map(_shelfJson).toList(),
        'history': history,
        'watched': [
          for (final entry in watched.entries)
            {'id': entry.key, 'episodes': entry.value},
        ],
        'readTime': [
          for (final entry in readTime)
            if (readTimeDays == null)
              entry
            else
              {...entry, 'days': _recentDays(entry['days'], readTimeDays)},
        ],
        'searchHistory': searchHistory,
        'excludedLocalRecords': excludedLocalRecords,
      }),
    ),
  );

  /// Drops day buckets older than the newest [keep] days. Only used by the
  /// size fallback, so a normal export keeps the full stored window.
  static Map<String, dynamic> _recentDays(Object? days, int keep) {
    if (days is! Map) return const {};
    final dated = <String, DateTime>{};
    for (final entry in days.entries) {
      final key = entry.key.toString();
      final date = _parseDayKey(key);
      if (date != null) dated[key] = date;
    }
    if (dated.length <= keep) {
      return {
        for (final entry in days.entries) entry.key.toString(): entry.value,
      };
    }
    final keys = dated.keys.toList()
      ..sort((a, b) => dated[a]!.compareTo(dated[b]!));
    return {for (final key in keys.sublist(keys.length - keep)) key: days[key]};
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
