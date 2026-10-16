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
  final messenger =
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
  final store = SecretStore.instance;
  final preferenceKey = 'secret_v1_${SecretStore.webdavPassword}';

  setUp(() => SharedPreferences.setMockInitialValues({}));

  tearDown(() => messenger.setMockMethodCallHandler(channel, null));

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
}
