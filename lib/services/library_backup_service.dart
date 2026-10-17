import 'dart:isolate';

import 'package:flutter/services.dart';

import '../models/library_backup.dart';
import 'library_store.dart';
import 'search_history_store.dart';
import 'shelf_store.dart';

class LibraryBackupService {
  static const _channel = MethodChannel('fqapp/library_backup');

  Future<LibraryBackup> capture() async {
    final library = LibraryStore.instance;
    final shelfStore = ShelfStore.instance;
    if (!library.isInitialized || !shelfStore.isReady) {
      throw StateError('本机数据尚未初始化');
    }
    final snapshot = await library.backupSnapshot();
    final shelf = shelfStore.records();
    // 删除记录必须一起带走，否则另一台设备的并集合并会把删掉的条目搬回来。
    final shelfRemoved = shelfStore.tombstones();
    // Read-time totals and search history are plain data too, so they are read
    // here and cross the isolate boundary with the rest of the snapshot.
    final readTime = library.readTimeBackupSnapshot();
    final searchHistory = await SearchHistoryStore.instance.load();
    return Isolate.run(
      () => LibraryBackup.capture(
        shelf: shelf,
        shelfRemoved: shelfRemoved,
        history: snapshot.history,
        watched: snapshot.watched,
        daily: readTime.daily,
        books: readTime.books,
        searchHistory: searchHistory,
      ),
    );
  }

  /// 只取进度那一段，给热路径分片用。
  ///
  /// 整包的 `history` 字段仍然保留（降级保护：旧版本只认整包），所以这里
  /// 不是「搬走」，而是「同一份数据再导出一份更小的」。
  Future<List<Map<String, dynamic>>> captureProgress() async {
    final library = LibraryStore.instance;
    if (!library.isInitialized) throw StateError('本机数据尚未初始化');
    return (await library.backupSnapshot()).history;
  }

  /// 把云端进度分片合并进本机。返回真正写入的条数。
  ///
  /// 复用 [LibraryStore.mergeBackup] 的双闸门（`time` 更新且位置更靠后），
  /// 所以分片不引入第二套冲突规则。
  Future<int> restoreHistory(List<Map<String, dynamic>> history) async {
    if (!LibraryStore.instance.isInitialized) {
      throw StateError('本机数据尚未初始化');
    }
    if (history.isEmpty) return 0;
    final result = await LibraryStore.instance.mergeBackup(
      history: history,
      watched: const {},
      daily: const {},
      books: const [],
    );
    return result.history;
  }

  Future<bool> export(LibraryBackup backup) async {
    final bytes = await Isolate.run(backup.encode);
    final stamp = backup.createdAt
        .toLocal()
        .toIso8601String()
        .replaceAll(':', '-')
        .split('.')
        .first;
    return await _channel.invokeMethod<bool>('saveBackup', {
          'name': 'fqapp-backup-$stamp.json',
          'bytes': bytes,
        }) ??
        false;
  }

  Future<LibraryBackup?> pick() async {
    final bytes = await _channel.invokeMethod<Uint8List>('openBackup');
    return bytes == null
        ? null
        : Isolate.run(() => LibraryBackup.decode(bytes));
  }

  /// Reports how many records each store took. `history` counts writes (new and
  /// replaced), because a record that is both newer and further along replaces
  /// the local one instead of being skipped.
  Future<
    ({int shelf, int history, int episodes, int readTime, int searchHistory})
  >
  restore(LibraryBackup backup) async {
    if (!LibraryStore.instance.isInitialized || !ShelfStore.instance.isReady) {
      throw StateError('本机数据尚未初始化');
    }
    // Every record was validated by LibraryBackup before any write. Boxes do
    // not share a transaction; retries re-apply the merged result, which is
    // idempotent for every store involved.
    final library = await LibraryStore.instance.mergeBackup(
      history: backup.history,
      watched: backup.watched,
      daily: backup.daily,
      books: backup.bookEntries,
    );
    final shelf = await ShelfStore.instance.mergeBackup(
      backup.shelf,
      removed: backup.shelfTombstones,
    );
    final searchHistory = await SearchHistoryStore.instance.merge(
      backup.searchHistory,
    );
    return (
      shelf: shelf,
      history: library.history,
      episodes: library.episodes,
      readTime: library.readTime,
      searchHistory: searchHistory,
    );
  }
}
