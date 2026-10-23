import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:fqapp/services/secret_store.dart';

/// The password is the only credential the app stores, so these cover the two
/// things that matter: the plaintext never reaches SharedPreferences, and an
/// unusable keystore entry surfaces as an error instead of a silent empty
/// password.
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  const channel = MethodChannel('fqapp/secrets');
  // macOS/Windows 没有 `fqapp/secrets` 通道，退化成这个插件的系统钥匙串。
  const keychainChannel = MethodChannel(
    'plugins.it_nomads.com/flutter_secure_storage',
  );
  final messenger =
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
  final store = SecretStore.instance;
  final preferenceKey = 'secret_v1_${SecretStore.webdavPassword}';
  final keychainKey = 'fqapp.secret.${SecretStore.webdavPassword}';

  setUp(() {
    SharedPreferences.setMockInitialValues({});
    // 后端选择在进程内缓存，测试之间必须重置，否则先跑的用例决定后跑的。
    SecretStore.resetChannelProbeForTest();
  });

  tearDown(() {
    messenger.setMockMethodCallHandler(channel, null);
    messenger.setMockMethodCallHandler(keychainChannel, null);
  });

  /// Stands in for the keystore: a reversible marker that no one could confuse
  /// with the plaintext.
  void useFakeKeystore() {
    messenger.setMockMethodCallHandler(channel, (call) async {
      final value = (call.arguments as Map)['value'] as String;
      if (call.method == 'encrypt') return 'sealed:$value';
      if (value.startsWith('sealed:')) return value.substring('sealed:'.length);
      throw PlatformException(code: 'SECRET_UNAVAILABLE', message: 'rejected');
    });
  }

  test('stores ciphertext and reads the password back', () async {
    useFakeKeystore();
    expect(await store.has(SecretStore.webdavPassword), isFalse);
    expect(await store.read(SecretStore.webdavPassword), isNull);

    await store.write(SecretStore.webdavPassword, 'hunter2');
    final preferences = await SharedPreferences.getInstance();
    expect(preferences.getString(preferenceKey), 'sealed:hunter2');
    expect(preferences.getString(preferenceKey), isNot('hunter2'));
    expect(await store.has(SecretStore.webdavPassword), isTrue);
    expect(await store.read(SecretStore.webdavPassword), 'hunter2');

    await store.delete(SecretStore.webdavPassword);
    expect(await store.has(SecretStore.webdavPassword), isFalse);
    expect(preferences.getString(preferenceKey), isNull);
  });

  test('an empty password is still stored as ciphertext', () async {
    useFakeKeystore();
    await store.write(SecretStore.webdavPassword, '');
    final preferences = await SharedPreferences.getInstance();
    expect(preferences.getString(preferenceKey), 'sealed:');
    expect(await store.read(SecretStore.webdavPassword), '');
  });

  test('an entry the keystore refuses asks for the password again', () async {
    SharedPreferences.setMockInitialValues({preferenceKey: 'stale-blob'});
    useFakeKeystore();
    await expectLater(
      store.read(SecretStore.webdavPassword),
      throwsA(
        isA<SecretStoreException>().having(
          (error) => error.message,
          'message',
          contains('重新输入'),
        ),
      ),
    );
  });

  test('a failing encrypt stores nothing', () async {
    messenger.setMockMethodCallHandler(channel, (call) async {
      throw PlatformException(code: 'SECRET_UNAVAILABLE', message: 'rejected');
    });
    await expectLater(
      store.write(SecretStore.webdavPassword, 'hunter2'),
      throwsA(isA<SecretStoreException>()),
    );
    final preferences = await SharedPreferences.getInstance();
    expect(preferences.getString(preferenceKey), isNull);
  });

  test('a missing platform channel never falls back to plain text', () async {
    await expectLater(
      store.write(SecretStore.webdavPassword, 'hunter2'),
      throwsA(isA<SecretStoreException>()),
    );
    final preferences = await SharedPreferences.getInstance();
    expect(preferences.getString(preferenceKey), isNull);
  });

  // 桌面端（macOS/Windows）的 runner 是 `flutter create` 的原样输出，没有
  // `SecretStorePlugin`。此前这种环境直接报「当前环境不支持系统密钥库」，
  // WebDAV 密码存不下来；现在改为走系统钥匙串。
  test('without the channel the password goes to the system keychain', () async {
    final keychain = <String, String>{};
    messenger.setMockMethodCallHandler(keychainChannel, (call) async {
      final arguments = call.arguments as Map;
      final key = arguments['key'] as String;
      switch (call.method) {
        case 'write':
          keychain[key] = arguments['value'] as String;
          return null;
        case 'read':
          return keychain[key];
        case 'delete':
          keychain.remove(key);
          return null;
      }
      return null;
    });

    expect(await store.has(SecretStore.webdavPassword), isFalse);
    expect(await store.read(SecretStore.webdavPassword), isNull);

    await store.write(SecretStore.webdavPassword, 'hunter2');
    expect(keychain[keychainKey], 'hunter2');
    final preferences = await SharedPreferences.getInstance();
    expect(
      preferences.getString(preferenceKey),
      isNull,
      reason: '钥匙串后端不该把任何东西写进偏好设置',
    );
    expect(await store.has(SecretStore.webdavPassword), isTrue);
    expect(await store.read(SecretStore.webdavPassword), 'hunter2');

    await store.delete(SecretStore.webdavPassword);
    expect(keychain.containsKey(keychainKey), isFalse);
    expect(await store.has(SecretStore.webdavPassword), isFalse);
  });

  test('a keychain write failure is reported, nothing is stored', () async {
    messenger.setMockMethodCallHandler(keychainChannel, (call) async {
      throw PlatformException(code: 'Unexpected security result code');
    });
    await expectLater(
      store.write(SecretStore.webdavPassword, 'hunter2'),
      throwsA(
        isA<SecretStoreException>().having(
          (error) => error.message,
          'message',
          contains('钥匙串'),
        ),
      ),
    );
    final preferences = await SharedPreferences.getInstance();
    expect(preferences.getString(preferenceKey), isNull);
  });
}
