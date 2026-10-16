import 'dart:isolate';
import 'dart:typed_data';

import '../models/library_backup.dart';
import 'library_backup_service.dart';
import 'webdav_client.dart';
import 'webdav_config.dart';

/// What one sync did, in the shape the settings page reports.
typedef WebdavSyncReport = ({
  bool remoteExisted,
  DateTime? remoteModified,
  int uploadedBytes,
  int shelf,
  int history,
  int episodes,
  int readTime,
  int searchHistory,
});

/// Builds the transport for one sync, so tests can substitute an in-memory
/// server for a real one.
typedef WebdavTransportFactory = WebdavTransport Function(
  WebdavConfig config,
  String password,
);

/// Two-way sync of one snapshot file: pull, merge, push.
///
/// The merge rules live in `LibraryBackupService.restore`, so this only has to
/// order the steps: read the remote file, merge it into this device's data, and
/// write the merged snapshot back. Writing back unconditionally is what makes
/// a second device converge - the remote ends up holding the union of both
/// devices instead of whichever one synced last.
///
/// The merged snapshot never overwrites a remote file that could not be read:
/// a truncated or foreign file aborts the sync before the upload, so a bad
/// upload on one device cannot propagate to the other.
class WebdavSyncService {
  WebdavSyncService({
    LibraryBackupService? backups,
    WebdavTransportFactory? transport,
  }) : _backups = backups ?? LibraryBackupService(),
       _transport = transport ?? _webdavTransport;

  static WebdavTransport _webdavTransport(
    WebdavConfig config,
    String password,
  ) => WebdavClient(config: config, password: password);

  final LibraryBackupService _backups;
  final WebdavTransportFactory _transport;

  /// [password] may be empty: a server that allows anonymous access needs no
  /// credentials, and an empty account is still sent as HTTP Basic.
  Future<WebdavSyncReport> sync(
    WebdavConfig config, {
    required String password,
  }) async {
    final transport = _transport(config, password);
    try {
      await transport.ensureCollection();
      final remote = await transport.download();
      var merged = (
        shelf: 0,
        history: 0,
        episodes: 0,
        readTime: 0,
        searchHistory: 0,
      );
      if (remote != null) {
        merged = await _backups.restore(await _decode(remote.bytes));
      }
      final snapshot = await _backups.capture();
      final bytes = await Isolate.run(snapshot.encode);
      await transport.upload(bytes);
      return (
        remoteExisted: remote != null,
        remoteModified: remote?.modified,
        uploadedBytes: bytes.length,
        shelf: merged.shelf,
        history: merged.history,
        episodes: merged.episodes,
        readTime: merged.readTime,
        searchHistory: merged.searchHistory,
      );
    } finally {
      transport.close();
    }
  }

  /// Decoding runs off the main isolate because a large snapshot is a lot of
  /// JSON; a file this device cannot read stops the sync instead of being
  /// replaced by local data.
  Future<LibraryBackup> _decode(Uint8List bytes) async {
    try {
      return await Isolate.run(() => LibraryBackup.decode(bytes));
    } on FormatException catch (error) {
      throw WebdavException(
        '云端的备份文件无法识别（${error.message}），已停止同步，云端文件未被改动',
      );
    }
  }
}
