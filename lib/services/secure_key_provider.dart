import 'dart:convert';

import 'package:flutter/foundation.dart';
import 'package:hive_ce/hive.dart';

import 'app_log.dart';
import 'linux_libsecret_key_store.dart';
import 'secure_key_storage.dart';

export 'secure_key_storage.dart';

/// Platform default for the secure store.
///
/// Linux goes straight to libsecret instead of `flutter_secure_storage`:
/// same Secret Service backend, but the plugin reports "no key" when the
/// keyring is locked or missing, and this app must fail closed there (see
/// `EncryptedHive`). Every other platform keeps the plugin.
SecureKeyStorage defaultSecureKeyStorage() {
  if (defaultTargetPlatform == TargetPlatform.linux) {
    return LinuxLibsecretKeyStore();
  }
  return const FlutterSecureKeyStorage();
}

/// Owns the random 256-bit keys that encrypt local data at rest.
///
/// One key per purpose, all base64-encoded in secure storage:
/// - [hiveBoxKeyName]: the Hive `HiveAesCipher` key for every encrypted box
///   (see `EncryptedHive`);
/// - [devicePoolKeyName]: the Rust device-pool file key, handed to the core
///   via the `set_device_pool_key` FRB call at startup (P1-2). Sharing the
///   infrastructure but not the key material: compromising one store must not
///   open the other.
///
/// A missing entry is created once (random 256-bit via
/// `Hive.generateSecureKey`) and persisted; a present-but-malformed entry is
/// treated as a lost key and replaced, which makes the boxes encrypted under
/// the old key unreadable — `EncryptedHive` then treats those boxes as empty
/// rather than falling back to plaintext. When secure storage itself throws
/// (no platform channel, Keystore failure), `null` is returned and callers
/// degrade per their own policy instead of failing startup.
class SecureKeyProvider {
  SecureKeyProvider({
    SecureKeyStorage? storage,
    this.storageTimeout = const Duration(seconds: 10),
  }) : _storage = storage ?? defaultSecureKeyStorage();

  static final SecureKeyProvider instance = SecureKeyProvider();

  /// Hive box encryption key (base64 of 32 random bytes).
  static const hiveBoxKeyName = 'fqapp_hive_encryption_key_v1';

  /// Rust device-pool file encryption key (base64 of 32 random bytes).
  static const devicePoolKeyName = 'fqapp_device_pool_key_v1';

  /// How long a single secure-storage read/write may take before it is
  /// treated as unavailable. The platform channel normally answers in
  /// milliseconds; without a bound, a wedged Keystore — or, in widget tests,
  /// an unmocked channel whose Future never resolves — would hang startup
  /// forever instead of letting callers degrade.
  final Duration storageTimeout;

  /// Cooldown after a failed key load: lookups within one startup return the
  /// cached failure instead of each waiting out the full storage timeout.
  /// A later retry (e.g. the bootstrap retry button after the cooldown)
  /// attempts the platform channel again.
  static const _failureCooldown = Duration(seconds: 30);

  final SecureKeyStorage _storage;
  final Map<String, Uint8List> _cache = {};
  final Map<String, Future<Uint8List?>> _pending = {};
  final Map<String, DateTime> _failedAt = {};

  Future<Uint8List?> getOrCreateKey({String name = hiveBoxKeyName}) {
    final cached = _cache[name];
    if (cached != null) return Future.value(cached);
    final failedAt = _failedAt[name];
    if (failedAt != null &&
        DateTime.now().difference(failedAt) < _failureCooldown) {
      return Future.value(null);
    }
    return _pending[name] ??= _loadOrCreate(name).then((key) {
      _pending.remove(name);
      return key;
    });
  }

  Future<Uint8List?> _loadOrCreate(String name) async {
    try {
      final stored = await _storage.read(name).timeout(storageTimeout);
      if (stored != null) {
        try {
          final decoded = base64Decode(stored);
          if (decoded.length == 32) {
            final bytes = Uint8List.fromList(decoded);
            _cache[name] = bytes;
            return bytes;
          }
        } catch (_) {
          // Malformed entry: fall through and replace it (key lost).
        }
      }
      final fresh = Uint8List.fromList(Hive.generateSecureKey());
      await _storage.write(name, base64Encode(fresh)).timeout(storageTimeout);
      _cache[name] = fresh;
      return fresh;
    } catch (error) {
      // Secure storage unavailable (or wedged past the timeout): record the
      // failure so the rest of this startup degrades immediately instead of
      // each caller waiting out another timeout. Callers decide how to
      // degrade. The generated-but-unpersisted key is deliberately NOT
      // returned: persisting it is what makes it usable next launch.
      //
      // Logged because the visible symptom is not an error but *missing local
      // data*: without a key those encrypted boxes open empty, so a broken
      // keychain looks like a wiped library rather than a permission problem.
      AppLog.w('secure-key', '取不到 $name，本次启动按无密钥降级', error: error);
      _failedAt[name] = DateTime.now();
      return null;
    }
  }

  /// Device-pool file key for the P1-2 FRB handoff. Same infrastructure as
  /// the Hive key, separate key material.
  Future<Uint8List?> devicePoolKey() => getOrCreateKey(name: devicePoolKeyName);

  @visibleForTesting
  void resetForTest() {
    _cache.clear();
    _pending.clear();
    _failedAt.clear();
  }
}
