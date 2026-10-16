import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:fqapp/services/webdav_config.dart';

/// The address the user pastes decides whether the sync can work at all, so the
/// refusals matter as much as the accepted forms.
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  group('collection url', () {
    test('accepts the shapes a WebDAV server hands out', () {
      expect(validateWebdavUrl('https://dav.jianguoyun.com/dav/'), isNull);
      expect(validateWebdavUrl('https://cloud.example.com/remote.php/dav'), isNull);
      // A home NAS usually serves plain HTTP on a LAN address.
      expect(validateWebdavUrl('http://192.168.31.10:5005/fqapp'), isNull);
    });

    test('refuses anything that cannot be a collection', () {
      expect(validateWebdavUrl(''), '请填写 WebDAV 地址');
      expect(validateWebdavUrl('   '), isNotNull);
      expect(validateWebdavUrl('dav.example.com/dav'), isNotNull);
      expect(validateWebdavUrl('ftp://example.com/dav'), isNotNull);
      expect(validateWebdavUrl('https://'), isNotNull);
      expect(validateWebdavUrl('https://user:pw@example.com/dav/'), isNotNull);
      expect(validateWebdavUrl('https://example.com/dav/?share=1'), isNotNull);
      expect(validateWebdavUrl('https://example.com/dav/#top'), isNotNull);
      expect(validateWebdavUrl('https://example.com/dav/fqapp-sync.json'), isNotNull);
    });

    test('normalizes to a directory path', () {
      expect(
        normalizeWebdavUrl(' https://example.com/dav '),
        'https://example.com/dav/',
      );
      expect(
        normalizeWebdavUrl('https://example.com/dav/'),
        'https://example.com/dav/',
      );
      expect(normalizeWebdavUrl('https://example.com'), 'https://example.com/');
    });
  });

  group('file name', () {
    test('accepts a plain json name', () {
      expect(validateWebdavFileName('fqapp-sync.json'), isNull);
      expect(validateWebdavFileName('a_1.2-.json'), isNull);
    });

    test('refuses names that break the joined URL', () {
      expect(validateWebdavFileName(''), isNotNull);
      expect(validateWebdavFileName('fqapp.txt'), isNotNull);
      expect(validateWebdavFileName('sub/fqapp.json'), isNotNull);
      expect(validateWebdavFileName('.json'), isNotNull);
      expect(validateWebdavFileName('两个手机.json'), isNotNull);
      expect(validateWebdavFileName('${'a' * 60}.json'), isNotNull);
    });
  });

  group('store', () {
    test('round-trips the configuration and the last sync time', () async {
      SharedPreferences.setMockInitialValues({});
      final store = WebdavConfigStore.instance;
      expect(await store.load(), isNull);
      expect(await store.lastSyncedAt(), isNull);

      await store.save(
        const WebdavConfig(
          collectionUrl: 'https://example.com/dav/',
          username: 'reader',
          fileName: 'a.json',
        ),
      );
      final loaded = await store.load();
      expect(loaded, isNotNull);
      expect(loaded!.collectionUrl, 'https://example.com/dav/');
      expect(loaded.username, 'reader');
      expect(loaded.fileName, 'a.json');
      expect(loaded.collectionUri.toString(), 'https://example.com/dav/');
      expect(loaded.fileUri.toString(), 'https://example.com/dav/a.json');

      await store.markSynced(DateTime.fromMillisecondsSinceEpoch(1700000000000));
      expect((await store.lastSyncedAt())!.millisecondsSinceEpoch, 1700000000000);

      await store.clear();
      expect(await store.load(), isNull);
      expect(await store.lastSyncedAt(), isNull);
    });

    test('treats a stored address that no longer validates as unset', () async {
      SharedPreferences.setMockInitialValues({
        WebdavConfigStore.urlKey: 'not a url',
      });
      expect(await WebdavConfigStore.instance.load(), isNull);
    });

    test('falls back to the default file name when the stored one is unusable', () async {
      SharedPreferences.setMockInitialValues({
        WebdavConfigStore.urlKey: 'https://example.com/dav/',
        WebdavConfigStore.fileKey: 'weird name.txt',
      });
      expect(
        (await WebdavConfigStore.instance.load())!.fileName,
        WebdavConfig.defaultFileName,
      );
    });

    test('defaults the file name when none was stored', () async {
      SharedPreferences.setMockInitialValues({
        WebdavConfigStore.urlKey: 'https://example.com/dav/',
      });
      expect(
        (await WebdavConfigStore.instance.load())!.fileName,
        WebdavConfig.defaultFileName,
      );
    });
  });
}
