import 'dart:async';

import 'package:shared_preferences/shared_preferences.dart';

abstract interface class SearchHistoryRepository {
  Future<List<String>> load();

  Future<List<String>> add(String query);

  Future<List<String>> remove(String query);

  Future<void> clear();
}

class SearchHistoryStore implements SearchHistoryRepository {
  SearchHistoryStore._();

  static final SearchHistoryStore instance = SearchHistoryStore._();

  /// Exposed so the backup layer can name the same preference instead of
  /// repeating the literal.
  static const key = 'search_history_v1';
  static const maxEntries = 20;
  Future<void> _writes = Future<void>.value();
  Zone _writesZone = Zone.current;

  /// Drops a write chain left over from a different zone.
  ///
  /// A [Future] created in one widget-test zone never completes in another
  /// (each testWidgets test runs in its own FakeAsync zone), so awaiting a
  /// chain from an earlier test would hang [load] forever. In the app the
  /// zone never changes, so this is a no-op there and the chain keeps
  /// serializing concurrent writes.
  void _dropStaleWriteChain() {
    if (!identical(Zone.current, _writesZone)) {
      _writes = Future<void>.value();
      _writesZone = Zone.current;
    }
  }

  @override
  Future<List<String>> load() async {
    _dropStaleWriteChain();
    await _writes;
    return _read();
  }

  Future<List<String>> _read() async {
    final preferences = await SharedPreferences.getInstance();
    final raw = preferences.get(key);
    return normalizeSearchHistory(raw is List ? raw.whereType<String>() : []);
  }

  @override
  Future<List<String>> add(String query) => _serialize(() async {
    final items = mergeSearchHistory(await _read(), query);
    final preferences = await SharedPreferences.getInstance();
    await preferences.setStringList(key, items);
    return items;
  });

  @override
  Future<List<String>> remove(String query) => _serialize(() async {
    final normalized = normalizeSearchQuery(query).toLowerCase();
    final items = (await _read())
        .where((item) => item.toLowerCase() != normalized)
        .toList(growable: false);
    final preferences = await SharedPreferences.getInstance();
    await preferences.setStringList(key, items);
    return items;
  });

  @override
  Future<void> clear() => _serialize(() async {
    final preferences = await SharedPreferences.getInstance();
    await preferences.remove(key);
  });

  /// 把另一台设备的搜索历史并进来，返回其中**新出现**的条数。
  ///
  /// 顺序由 [interleaveSearchHistory] 决定（两边轮流取），去重、空白折叠和
  /// 上限也都归它管，所以同一份快照合并两次不会多出东西。
  Future<int> merge(Iterable<String> incoming) => _serialize(() async {
    final current = await _read();
    final merged = interleaveSearchHistory(current, incoming);
    final preferences = await SharedPreferences.getInstance();
    await preferences.setStringList(key, merged);
    final known = current.map((item) => item.toLowerCase()).toSet();
    // 按「真正多出来的词」计数，而不是列表长度的差：两边各有一条不同的词时
    // 长度不变，但内容确实变了，报 0 会让人以为什么都没同步到。
    return merged.where((item) => !known.contains(item.toLowerCase())).length;
  });

  Future<T> _serialize<T>(Future<T> Function() action) {
    _dropStaleWriteChain();
    final operation = _writes.then((_) => action());
    _writes = operation.then<void>((_) {}, onError: (Object _) {});
    return operation;
  }
}

String normalizeSearchQuery(String query) =>
    query.trim().replaceAll(RegExp(r'\s+'), ' ');

List<String> mergeSearchHistory(Iterable<String> current, String query) {
  final normalized = normalizeSearchQuery(query);
  if (normalized.isEmpty) return normalizeSearchHistory(current);
  return normalizeSearchHistory([normalized, ...current]);
}

List<String> normalizeSearchHistory(Iterable<String> values) {
  final output = <String>[];
  final seen = <String>{};
  for (final value in values) {
    final normalized = normalizeSearchQuery(value);
    if (normalized.isEmpty || !seen.add(normalized.toLowerCase())) continue;
    output.add(normalized);
    if (output.length == SearchHistoryStore.maxEntries) break;
  }
  return List.unmodifiable(output);
}

/// 两边各按自己的新旧顺序轮流取一条，凑满 [SearchHistoryStore.maxEntries] 为止。
///
/// 旧做法是「本机在前、云端在后」拼起来再截断：本机一旦满 20 条，云端的新词
/// 就永远挤不进来 —— 在一台很少搜索的设备上，另一台搜过的词一个都同步不到。
///
/// 搜索历史只存顺序、不存时间，没法按「谁更新」裁决，轮流取是唯一不偏袒
/// 任何一边的做法。它也是幂等的：对同一个输入再合并一次，结果不变。
List<String> interleaveSearchHistory(
  Iterable<String> current,
  Iterable<String> incoming,
) {
  final left = current.toList(growable: false);
  final right = incoming.toList(growable: false);
  final output = <String>[];
  final seen = <String>{};
  var index = 0;
  while (output.length < SearchHistoryStore.maxEntries &&
      (index < left.length || index < right.length)) {
    for (final list in [left, right]) {
      if (index >= list.length) continue;
      final normalized = normalizeSearchQuery(list[index]);
      if (normalized.isEmpty || !seen.add(normalized.toLowerCase())) continue;
      output.add(normalized);
      if (output.length == SearchHistoryStore.maxEntries) break;
    }
    index++;
  }
  return List.unmodifiable(output);
}
