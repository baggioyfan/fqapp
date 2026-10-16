import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:hive/hive.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:fqapp/models/library_backup.dart';
import 'package:fqapp/models/media_item.dart';
import 'package:fqapp/pages/webdav_sync_page.dart';
import 'package:fqapp/services/library_store.dart';
import 'package:fqapp/services/shelf_store.dart';
import 'package:fqapp/services/webdav_client.dart';
import 'package:fqapp/services/webdav_config.dart';
import 'package:fqapp/services/webdav_sync_service.dart';

/// The settings page is the only way in, so these cover the wiring end to end:
/// what a save stores, what a failed sync shows, and what a successful one
/// leaves in the cloud file.
class _FakeTransport implements WebdavTransport {
  Uint8List? remote;
  WebdavException? failure;
  Uint8List? uploaded;

  @override
  Future<void> ensureCollection() async {
    if (failure case final error?) throw error;
  }

  @override
  Future<({Uint8List bytes, DateTime? modified})?> download() async =>
      remote == null ? null : (bytes: remote!, modified: DateTime.utc(2026, 1, 2));

  @override
  Future<void> upload(Uint8List bytes) async => uploaded = bytes;

  @override
  void close() {}
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  const channel = MethodChannel('fqapp/secrets');
  final messenger =
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
  final configStore = WebdavConfigStore.instance;
  final encryptCalls = <String>[];

  late Directory directory;
  late _FakeTransport transport;

  setUp(() async {
    SharedPreferences.setMockInitialValues({});
    encryptCalls.clear();
    messenger.setMockMethodCallHandler(channel, (call) async {
      final value = (call.arguments as Map)['value'] as String;
      if (call.method == 'encrypt') {
        encryptCalls.add(value);
        return 'sealed:$value';
      }
      if (value.startsWith('sealed:')) return value.substring('sealed:'.length);
      throw PlatformException(code: 'SECRET_UNAVAILABLE', message: 'rejected');
    });
    directory = await Directory.systemTemp.createTemp('fqapp-webdav-page-');
    Hive.init(directory.path);
    await LibraryStore.instance.init();
    await ShelfStore.instance.init();
    transport = _FakeTransport();
  });

  tearDown(() async {
    messenger.setMockMethodCallHandler(channel, null);
    await Hive.close();
    await directory.delete(recursive: true);
  });

  Future<void> pumpPage(WidgetTester tester) async {
    await tester.pumpWidget(
      MaterialApp(
        home: WebdavSyncPage(
          service: WebdavSyncService(
            transport: (config, password) => transport,
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();
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
    transport.failure = const WebdavException('认证失败：请检查用户名和密码');
    await pumpPage(tester);

    await tester.tap(find.text('立即同步'));
    await tester.pumpAndSettle();

    expect(find.text('认证失败：请检查用户名和密码'), findsOneWidget);
    expect(await configStore.lastSyncedAt(), isNull);
    expect(transport.uploaded, isNull);
  });

  testWidgets('merges the cloud copy and writes the union back', (tester) async {
    SharedPreferences.setMockInitialValues({
      WebdavConfigStore.urlKey: 'https://dav.example.com/dav/',
    });
    await ShelfStore.instance.add(_item('local-1'));
    transport.remote = LibraryBackup.capture(
      shelf: [
        ShelfRecord(
          item: _item('remote-1'),
          addedAt: DateTime.fromMillisecondsSinceEpoch(1000),
        ),
      ],
      history: const [],
      watched: const {},
      readTime: const [],
      searchHistory: const [],
    ).encode();
    await pumpPage(tester);

    // The merge runs in a worker isolate, so the widget test has to let the
    // real event loop turn; the loop is bounded and the assertion below fails
    // with the page still on screen if the result never arrives.
    await tester.runAsync(() async {
      await tester.tap(find.text('立即同步'));
      await tester.pump();
      for (var attempt = 0; attempt < 100; attempt++) {
        await Future<void>.delayed(const Duration(milliseconds: 20));
        await tester.pump();
        if (find.textContaining('已从云端合并').evaluate().isNotEmpty) return;
      }
    });
    await tester.pumpAndSettle();

    expect(find.textContaining('已从云端合并'), findsOneWidget);
    expect(await configStore.lastSyncedAt(), isNotNull);
    expect(
      LibraryBackup.decode(transport.uploaded!).shelf
          .map((record) => record.item.id)
          .toSet(),
      {'local-1', 'remote-1'},
    );
  });
}

MediaItem _item(String id) => MediaItem(
  id: id,
  title: id,
  cover: '',
  author: '测试作者',
  badge: '',
  ep: '120',
  kind: 'book',
);
