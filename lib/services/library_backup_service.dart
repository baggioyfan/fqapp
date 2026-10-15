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
    // Read-time totals and search history are plain data too, so they are read
    // here and cross the isolate boundary with the rest of the snapshot.
    final readTime = library.readTimeBackupSnapshot();
    final searchHistory = await SearchHistoryStore.instance.load();
    return Isolate.run(
      () => LibraryBackup.capture(
        shelf: shelf,
        history: snapshot.history,
        watched: snapshot.watched,
        readTime: readTime,
        searchHistory: searchHistory,
      ),
    );
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
      readTime: backup.readTimeEntries,
    );
    final shelf = await ShelfStore.instance.mergeBackup(backup.shelf);
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
