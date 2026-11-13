import 'package:flutter_secure_storage/flutter_secure_storage.dart';

/// Minimal read/write surface over the platform secure store, kept as an
/// interface so tests can substitute an in-memory fake instead of driving a
/// MethodChannel.
///
/// `delete` is intentionally not part of the surface: this app only ever
/// rotates a key by overwriting it, and every fake in `test/` implements just
/// these two methods.
abstract interface class SecureKeyStorage {
  Future<String?> read(String key);
  Future<void> write(String key, String value);
}

/// Default backend on every platform except Linux: `flutter_secure_storage`
/// (Android Keystore / EncryptedSharedPreferences, iOS Keychain, Windows
/// DPAPI, macOS login keychain). The raw key bytes never touch
/// SharedPreferences or any other plaintext store.
class FlutterSecureKeyStorage implements SecureKeyStorage {
  const FlutterSecureKeyStorage([this._storage = _defaultStorage]);

  /// `useDataProtectionKeyChain: false` is mandatory on macOS. The plugin
  /// defaults to `true`, which requires a `keychain-access-groups`-style
  /// entitlement; the macOS build in this repo is ad-hoc signed, so every
  /// `SecItemAdd` would fail with
  /// `-34018 A required entitlement is not present` and every key would be
  /// lost on restart - the Hive boxes would then look empty. The legacy login
  /// keychain has no such requirement (verified with `codesign -s -`).
  /// Ignored on other platforms.
  static const _defaultStorage = FlutterSecureStorage(
    mOptions: MacOsOptions(useDataProtectionKeyChain: false),
  );

  final FlutterSecureStorage _storage;

  @override
  Future<String?> read(String key) => _storage.read(key: key);

  @override
  Future<void> write(String key, String value) =>
      _storage.write(key: key, value: value);
}

/// In-memory fake for tests and for environments without a platform channel.
class InMemorySecureKeyStorage implements SecureKeyStorage {
  final Map<String, String> _values = {};

  @override
  Future<String?> read(String key) async => _values[key];

  @override
  Future<void> write(String key, String value) async {
    _values[key] = value;
  }
}
