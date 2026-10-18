import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:fqapp/pages/webdav_sync_page.dart';
import 'package:fqapp/services/webdav_client.dart';
import 'package:fqapp/services/webdav_config.dart';
import 'package:fqapp/services/webdav_sync_service.dart';

/// The settings page is the only way in, so these cover the wiring: what a save
/// stores, what a failed sync shows, and what the report says after one runs.
///
/// The service is faked on purpose. The real one writes to Hive and encodes the
/// snapshot in a worker isolate, and neither finishes inside a `testWidgets`
/// body: that body runs in a fake async zone, where real I/O only completes
/// when `WidgetTester.runAsync` hands the event loop a turn. Driving it here
/// would mean waiting on the very thing under test, so the data path is covered
/// by `webdav_sync_service_test.dart`, which runs as an ordinary test.
class _SpySync implements WebdavSyncService {
  _SpySync({WebdavSyncReport? report, this.failure})
    : report = report ?? _noopReport;

  final WebdavSyncReport report;
  final WebdavException? failure;

  WebdavConfig? receivedConfig;
  String? receivedPassword;

  /// 同步被调了几次。用来断言「重试」真的又跑了一遍，而不是只换个文案。
  int syncCalls = 0;

  @override
  Future<WebdavSyncReport> sync(
    WebdavConfig config, {
    required String password,
    SyncPriority priority = SyncPriority.manual,
  }) async {
    syncCalls++;
    receivedConfig = config;
    receivedPassword = password;
    if (failure case final error?) throw error;
    return report;
  }

  /// 设置页只走整包那条路；热路径分片由 `progress_shard_test.dart` 覆盖。
  @override
  Future<ProgressSyncReport> syncProgress(
    WebdavConfig config, {
    required String password,
    required bool localDirty,
    SyncPriority priority = SyncPriority.manual,
  }) async => (history: 0, uploadedBytes: 0);

  /// 「用本机覆盖云端」是逃生口，页面上只按钮到方法的一跳，真正的写入由
  /// `webdav_sync_service_test.dart` 覆盖。这里记录调用即可。
  @override
  Future<WebdavSyncReport> overwriteRemote(
    WebdavConfig config, {
    required String password,
  }) async {
    overwriteCalls++;
    receivedConfig = config;
    receivedPassword = password;
    if (failure case final error?) throw error;
    return report;
  }

  int overwriteCalls = 0;

  /// 页面不关心预算；实现接口时把它交回去即可（同步逻辑由
  /// `webdav_sync_service_test.dart` 覆盖）。
  @override
  Duration get budget => WebdavSyncService.defaultBudget;

  /// 页面在 dispose 里放开复用的连接；假 service 没有连接可放。
  @override
  void close() {}
}

/// An empty merge, for the cases that only care about the failure path.
const WebdavSyncReport _noopReport = (
  remoteExisted: false,
  remoteModified: null,
  uploadedBytes: 0,
  shelf: 0,
  history: 0,
  episodes: 0,
  readTime: 0,
  searchHistory: 0,
);

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  const channel = MethodChannel('fqapp/secrets');
  final messenger =
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
  final configStore = WebdavConfigStore.instance;
  final encryptCalls = <String>[];

  setUp(() {
    SharedPreferences.setMockInitialValues({});
    encryptCalls.clear();
    // Stands in for the Android keystore: a value only comes back out of the
    // "decrypt" call when it went in through "encrypt" first.
    messenger.setMockMethodCallHandler(channel, (call) async {
      final value = (call.arguments as Map)['value'] as String;
      if (call.method == 'encrypt') {
        encryptCalls.add(value);
        return 'sealed:$value';
      }
      if (value.startsWith('sealed:')) return value.substring('sealed:'.length);
      throw PlatformException(code: 'SECRET_UNAVAILABLE', message: 'rejected');
    });
  });

  tearDown(() => messenger.setMockMethodCallHandler(channel, null));

  Future<_SpySync> pumpPage(
    WidgetTester tester, {
    WebdavSyncReport? report,
    WebdavException? failure,
  }) async {
    // The form is taller than the default 800x600 test surface. A tap on a
    // widget outside the viewport only warns and then misses, and a widget far
    // enough down the list is never built, so both the buttons and the message
    // at the bottom would be invisible to the assertions below. A tall surface
    // keeps the whole page on screen and leaves scrolling out of the test.
    tester.view.physicalSize = const Size(1000, 1800);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);

    final service = _SpySync(report: report, failure: failure);
    await tester.pumpWidget(
      MaterialApp(home: WebdavSyncPage(service: service)),
    );
    await tester.pumpAndSettle();
    return service;
  }

  /// 0 地址、1 用户名、2 密码、3 文件名，与页面里的排列一致。
  Finder fieldAt(int index) => find.byType(TextField).at(index);

  String textOf(WidgetTester tester, int index) =>
      tester.widget<TextField>(fieldAt(index)).controller!.text;

  testWidgets('refuses to save without an address', (tester) async {
    await pumpPage(tester);
    expect(tester.widget<TextField>(fieldAt(0)).enabled, isTrue);

    await tester.tap(find.text('保存配置'));
    await tester.pumpAndSettle();

    expect(find.text('请填写 WebDAV 地址'), findsOneWidget);
    expect(encryptCalls, isEmpty);
    expect(await configStore.load(), isNull);
  });

  testWidgets('saves a normalized address and the encrypted password', (
    tester,
  ) async {
    await pumpPage(tester);
    await tester.enterText(fieldAt(0), 'https://dav.example.com/dav');
    await tester.enterText(fieldAt(1), 'reader');
    await tester.enterText(fieldAt(2), 'hunter2');

    await tester.tap(find.text('保存配置'));
    await tester.pumpAndSettle();

    final stored = await configStore.load();
    expect(stored, isNotNull);
    expect(stored!.collectionUrl, 'https://dav.example.com/dav/');
    expect(stored.username, 'reader');
    expect(stored.fileName, WebdavConfig.defaultFileName);
    expect(encryptCalls, ['hunter2']);
    // The normalized address is shown back, including the added slash.
    expect(textOf(tester, 0), 'https://dav.example.com/dav/');
  });

  testWidgets('restores the stored address and decrypts the password', (
    tester,
  ) async {
    SharedPreferences.setMockInitialValues({
      WebdavConfigStore.urlKey: 'https://dav.example.com/dav/',
      WebdavConfigStore.userKey: 'reader',
      WebdavConfigStore.fileKey: 'phone.json',
      'secret_v1_webdav_password': 'sealed:hunter2',
    });
    await pumpPage(tester);

    expect(textOf(tester, 0), 'https://dav.example.com/dav/');
    expect(textOf(tester, 1), 'reader');
    expect(textOf(tester, 2), 'hunter2');
    expect(textOf(tester, 3), 'phone.json');
  });

  testWidgets('a stored password the keystore rejects asks for it again', (
    tester,
  ) async {
    SharedPreferences.setMockInitialValues({
      WebdavConfigStore.urlKey: 'https://dav.example.com/dav/',
      'secret_v1_webdav_password': 'stale-blob',
    });
    await pumpPage(tester);

    expect(find.textContaining('重新输入'), findsOneWidget);
    expect(textOf(tester, 2), isEmpty);
    final preferences = await SharedPreferences.getInstance();
    expect(preferences.getString('secret_v1_webdav_password'), isNull);
  });

  testWidgets('reports a failed sync and records no sync time', (tester) async {
    SharedPreferences.setMockInitialValues({
      WebdavConfigStore.urlKey: 'https://dav.example.com/dav/',
    });
    final service = await pumpPage(
      tester,
      failure: const WebdavException('认证失败：请检查用户名和密码'),
    );

    await tester.tap(find.text('立即同步'));
    await tester.pumpAndSettle();

    expect(find.text('认证失败：请检查用户名和密码'), findsOneWidget);
    expect(await configStore.lastSyncedAt(), isNull);
    // The failing attempt still reached the service with the stored address.
    expect(
      service.receivedConfig!.collectionUrl,
      'https://dav.example.com/dav/',
    );
    // 密码错了，再点一次结果一样 —— 不该摆一个只能得到同样结果的按钮。
    expect(find.text('重试'), findsNothing);
  });

  testWidgets('offers a retry for a transient failure and runs it again', (
    tester,
  ) async {
    SharedPreferences.setMockInitialValues({
      WebdavConfigStore.urlKey: 'https://dav.example.com/dav/',
    });
    final service = await pumpPage(
      tester,
      failure: const WebdavException(
        '与服务器的连接中断，请稍后重试',
        retryable: true,
        kind: WebdavErrorKind.network,
      ),
    );

    await tester.tap(find.text('立即同步'));
    await tester.pumpAndSettle();
    expect(service.syncCalls, 1);

    await tester.tap(find.text('重试'));
    await tester.pumpAndSettle();
    expect(service.syncCalls, 2);
  });

  testWidgets('syncs with the stored address and the decrypted password', (
    tester,
  ) async {
    SharedPreferences.setMockInitialValues({
      WebdavConfigStore.urlKey: 'https://dav.example.com/dav',
      WebdavConfigStore.userKey: 'reader',
      'secret_v1_webdav_password': 'sealed:hunter2',
    });
    final service = await pumpPage(
      tester,
      report: (
        remoteExisted: true,
        remoteModified: DateTime.utc(2026, 1, 2),
        uploadedBytes: 3072,
        shelf: 1,
        history: 2,
        episodes: 0,
        readTime: 0,
        searchHistory: 0,
      ),
    );

    await tester.tap(find.text('立即同步'));
    await tester.pumpAndSettle();

    expect(find.textContaining('已从云端合并'), findsOneWidget);
    expect(find.textContaining('收藏 1 条'), findsOneWidget);
    expect(find.textContaining('3.0 KB'), findsOneWidget);
    expect(await configStore.lastSyncedAt(), isNotNull);
    // The address reached the service normalized, and the password is the one
    // the keystore handed back rather than the blob that was stored.
    expect(
      service.receivedConfig!.collectionUrl,
      'https://dav.example.com/dav/',
    );
    expect(service.receivedConfig!.username, 'reader');
    expect(service.receivedPassword, 'hunter2');
  });

  testWidgets('reports a first upload without the merge counts', (
    tester,
  ) async {
    SharedPreferences.setMockInitialValues({
      WebdavConfigStore.urlKey: 'https://dav.example.com/dav/',
    });
    await pumpPage(
      tester,
      // The shape a first sync really has: nothing was merged, only uploaded,
      // so every count is zero.
      report: (
        remoteExisted: false,
        remoteModified: null,
        uploadedBytes: 2048,
        shelf: 0,
        history: 0,
        episodes: 0,
        readTime: 0,
        searchHistory: 0,
      ),
    );

    await tester.tap(find.text('立即同步'));
    await tester.pumpAndSettle();

    expect(find.textContaining('云端还没有备份文件'), findsOneWidget);
    expect(find.textContaining('2.0 KB'), findsOneWidget);
    // "已把本机数据上传（收藏 0 条…）" would read as "nothing was uploaded".
    expect(find.textContaining('收藏 0 条'), findsNothing);
    expect(await configStore.lastSyncedAt(), isNotNull);
  });

  testWidgets('overwriting the cloud copy asks first, then replaces it', (
    tester,
  ) async {
    SharedPreferences.setMockInitialValues({
      WebdavConfigStore.urlKey: 'https://dav.example.com/dav/',
      'secret_v1_webdav_password': 'sealed:hunter2',
    });
    final service = await pumpPage(
      tester,
      report: (
        remoteExisted: true,
        remoteModified: DateTime.utc(2026, 1, 2),
        uploadedBytes: 4096,
        shelf: 0,
        history: 0,
        episodes: 0,
        readTime: 0,
        searchHistory: 0,
      ),
    );

    await tester.tap(find.text('用本机覆盖云端'));
    await tester.pumpAndSettle();
    // 覆盖是单向的，弹窗必须先把代价说清楚，并且此时的「取消」真的取消。
    expect(find.text('用本机数据覆盖云端？'), findsOneWidget);
    expect(find.textContaining('.bak'), findsWidgets);

    await tester.tap(find.text('取消'));
    await tester.pumpAndSettle();
    expect(service.overwriteCalls, 0);

    await tester.tap(find.text('用本机覆盖云端'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('覆盖'));
    await tester.pumpAndSettle();

    expect(service.overwriteCalls, 1);
    expect(find.textContaining('已用本机数据覆盖云端'), findsOneWidget);
    expect(find.textContaining('4.0 KB'), findsOneWidget);
    expect(service.receivedPassword, 'hunter2');
  });
}
