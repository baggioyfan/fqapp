import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:fqapp/services/webdav_auto_sync.dart';
import 'package:fqapp/services/webdav_client.dart';
import 'package:fqapp/services/webdav_config.dart';

/// 「打开时检查」的判断：云端比本机上次同步更新才提示。
///
/// 判据照 legado 的闸门一：云端 `Last-Modified` 与本机 `lastSyncedAt` 比较。
class _Probe implements WebdavTransport {
  _Probe(this.modified);

  DateTime? modified;
  bool? fail;
  int probes = 0;

  @override
  Future<void> ensureCollection() async {}

  @override
  Future<({Uint8List bytes, DateTime? modified})?> download() async => null;

  @override
  Future<DateTime?> remoteModified() async {
    probes++;
    if (fail == true) throw const WebdavException('无法连接服务器');
    return modified;
  }

  @override
  Future<void> upload(Uint8List bytes) async {}

  @override
  void close() {}
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  final remote = DateTime.utc(2026, 1, 10, 12);
  late _Probe probe;
  late WebdavAutoSync auto;

  setUp(() {
    probe = _Probe(remote);
    auto = WebdavAutoSync(transport: (config, password) => probe);
  });

  Future<void> prefs({
    String? url = 'https://dav.example.com/dav/',
    DateTime? lastSyncedAt,
    DateTime? dismissed,
  }) async {
    SharedPreferences.setMockInitialValues({
      if (url != null) WebdavConfigStore.urlKey: url,
      WebdavConfigStore.userKey: 'reader',
      if (lastSyncedAt != null)
        WebdavConfigStore.lastSyncKey: lastSyncedAt.millisecondsSinceEpoch,
      if (dismissed != null)
        WebdavConfigStore.dismissedKey: dismissed.millisecondsSinceEpoch,
    });
  }

  test('offers a sync when the cloud is newer than the last sync', () async {
    await prefs(lastSyncedAt: remote.subtract(const Duration(hours: 1)));

    final update = await auto.check();

    expect(update, isNotNull);
    expect(update!.remoteModified, remote);
    expect(probe.probes, 1);
  });

  test('stays quiet right after this device synced', () async {
    // 上传那一刻云端时间戳与本机 lastSyncedAt 几乎相同，容差内不算更新。
    await prefs(lastSyncedAt: remote.subtract(const Duration(seconds: 5)));

    expect(await auto.check(), isNull);
  });

  test('stays quiet when the cloud is older', () async {
    await prefs(lastSyncedAt: remote.add(const Duration(hours: 1)));

    expect(await auto.check(), isNull);
  });

  test('asks when this device never synced', () async {
    await prefs();

    expect(await auto.check(), isNotNull);
  });

  test('a dismissed version is not asked about again', () async {
    await prefs(lastSyncedAt: remote.subtract(const Duration(days: 1)));
    await WebdavConfigStore.instance.markDismissed(remote);

    expect(await auto.check(), isNull);

    // 云端再被改过（更晚的时间戳）就重新提示。
    probe.modified = remote.add(const Duration(minutes: 5));
    expect(await auto.check(), isNotNull);
  });

  test('no configuration means nothing to check', () async {
    await prefs(url: null);

    expect(await auto.check(), isNull);
    expect(probe.probes, 0);
  });

  test('a cloud without the snapshot file is not an update', () async {
    await prefs(lastSyncedAt: remote.subtract(const Duration(days: 1)));
    probe.modified = null;

    expect(await auto.check(), isNull);
  });

  test('a failing probe is silent', () async {
    await prefs(lastSyncedAt: remote.subtract(const Duration(days: 1)));
    probe.fail = true;

    expect(await auto.check(), isNull);
  });
}
