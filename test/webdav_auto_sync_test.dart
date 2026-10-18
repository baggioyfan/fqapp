import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:fqapp/services/webdav_auto_sync.dart';
import 'package:fqapp/services/webdav_client.dart';
import 'package:fqapp/services/webdav_config.dart';

/// 「打开时检查」的判断：云端那一版和本机记下的那一版是不是同一个。
///
/// 判据是**版本标识**，不是时间。时间比较会在任何一方时钟不准时静默失效，
/// 下面两个带时钟偏移的用例就是钉这一点。
class _Probe implements WebdavTransport {
  _Probe({this.modified});

  /// 服务端给的版本标识；null 表示不给 ETag（只剩时间可比，用来验降级路径）。
  String? etag = 'v1';

  DateTime? modified;

  /// false 表示云端没有这个文件。
  bool exists = true;

  bool? fail;
  int probes = 0;

  @override
  Future<void> ensureCollection() async {}

  @override
  Future<({Uint8List bytes, DateTime? modified, String? versionKey})?>
  download({String? name}) async => null;

  @override
  Future<RemoteFile?> remoteFile({String? name}) async {
    probes++;
    if (fail == true) throw const WebdavException('无法连接服务器');
    if (!exists) return null;
    return RemoteFile(etag: etag, modified: modified);
  }

  @override
  Future<String?> upload(
    Uint8List bytes, {
    String? name,
    String? ifMatch,
  }) async => null;

  @override
  void close() {}
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  final remote = DateTime.utc(2026, 1, 10, 12);
  late _Probe probe;
  late WebdavAutoSync auto;

  setUp(() {
    probe = _Probe(modified: remote);
    auto = WebdavAutoSync(transport: (config, password) => probe);
  });

  Future<void> prefs({
    String? url = 'https://dav.example.com/dav/',
    DateTime? lastSyncedAt,
    String? knownVersion,
    String? dismissedVersion,
  }) async {
    final values = <String, Object>{WebdavConfigStore.userKey: 'reader'};
    if (url != null) values[WebdavConfigStore.urlKey] = url;
    if (lastSyncedAt != null) {
      values[WebdavConfigStore.lastSyncKey] =
          lastSyncedAt.millisecondsSinceEpoch;
    }
    if (knownVersion != null) {
      values[WebdavConfigStore.fullVersionKey] = knownVersion;
    }
    if (dismissedVersion != null) {
      values[WebdavConfigStore.dismissedVersionKey] = dismissedVersion;
    }
    SharedPreferences.setMockInitialValues(values);
  }

  test('offers a sync when the cloud is a version never seen here', () async {
    await prefs(knownVersion: 'v0');

    final update = await auto.check();

    expect(update, isNotNull);
    expect(update!.versionKey, 'v1');
    expect(update.remoteModified, remote);
    expect(probe.probes, 1);
  });

  test('stays quiet when the cloud is the version this device synced', () async {
    await prefs(knownVersion: 'v1');

    expect(await auto.check(), isNull);
  });

  test('asks when this device never synced', () async {
    await prefs();

    expect(await auto.check(), isNotNull);
  });

  test('a dismissed version is not asked about again', () async {
    await prefs(knownVersion: 'v0', dismissedVersion: 'v1');

    expect(await auto.check(), isNull);

    // 云端再被改过（换了版本）就重新提示。
    probe.etag = 'v2';
    expect(await auto.check(), isNotNull);
  });

  test('no configuration means nothing to check', () async {
    await prefs(url: null);

    expect(await auto.check(), isNull);
    expect(probe.probes, 0);
  });

  test('a cloud without the snapshot file is not an update', () async {
    await prefs(knownVersion: 'v0');
    probe.exists = false;

    expect(await auto.check(), isNull);
  });

  test('a failing probe is silent', () async {
    await prefs(knownVersion: 'v0');
    probe.fail = true;

    expect(await auto.check(), isNull);
  });

  test('a local clock far behind does not fake a remote update', () async {
    // 本机时钟停在 2010 年：按时间比较，云端永远是「更新的」，
    // 于是每次回前台都弹窗。判据换成版本之后，云端没换版就不该开口。
    await prefs(
      lastSyncedAt: DateTime.utc(2010, 1, 1),
      knownVersion: 'v1',
    );

    expect(await auto.check(), isNull);
  });

  test('a local clock far ahead does not hide a real remote change', () async {
    // 反过来更危险：本机时钟跑到 2035 年，按时间比较会认为云端是旧的，
    // 于是另一台设备的更新永远不提示 —— 这正是「静默丢更新」的入口。
    await prefs(
      lastSyncedAt: DateTime.utc(2035, 1, 1),
      knownVersion: 'v0',
    );
    probe.etag = 'v1';

    expect(await auto.check(), isNotNull);
  });

  test('a server without any version marker falls back to time', () async {
    // 连 ETag 都不给的服务端：没有可比的版本，只能退回时间戳。
    // 这里云端比本机上次同步更旧，所以不提示 —— 也就是旧行为。
    await prefs(lastSyncedAt: remote.add(const Duration(hours: 1)));
    probe.etag = null;
    probe.modified = remote;

    expect(await auto.check(), isNull);
  });

  test('a version marker wins over a misleading timestamp', () async {
    // 同一个降级点上更关键的一条：服务端给了 ETag 时，绝不能让时间参与判断。
    // 云端时间戳看起来「很旧」，但版本是没见过的那一版 —— 必须提示。
    await prefs(
      lastSyncedAt: remote.add(const Duration(days: 30)),
      knownVersion: 'v0',
    );
    probe.modified = DateTime.utc(2020, 1, 1);

    expect(await auto.check(), isNotNull);
  });
}
