import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'app_log.dart';

/// Raised when the keystore cannot protect or recover a secret.
class SecretStoreException implements Exception {
  const SecretStoreException(this.message);

  /// Already user-facing: the settings page shows it as it is.
  final String message;

  @override
  String toString() => 'SecretStoreException($message)';
}

/// Keeps one credential per name, encrypted by the platform secure store.
///
/// Two backends, chosen once per process:
///
/// - **`fqapp/secrets` platform channel** — `SecretStorePlugin` on Android. The
///   AES key never leaves the Android keystore, so SharedPreferences holds only
///   ciphertext, and a copied preferences file is useless on another device.
/// - **`flutter_secure_storage`** — macOS and Windows, which have no native
///   implementation of that channel (the runner is stock `flutter create`
///   output). The password goes straight into the system keychain / Credential
///   Manager, which is at least as strong as the Android split and needs no
///   custom native code per platform.
///
/// A key the keystore no longer accepts - the app was restored from another
/// device, or its keystore entry was dropped - comes back as
/// [SecretStoreException] instead of silently degrading to plain text storage:
/// the caller asks for the password again.
class SecretStore {
  SecretStore._();

  static final SecretStore instance = SecretStore._();

  static const _channel = MethodChannel('fqapp/secrets');
  static const _prefix = 'secret_v1_';
  static const _tag = 'webdav-secret';

  /// Name of the stored WebDAV password. Kept here so the settings page and the
  /// sync service cannot drift apart on the literal.
  static const webdavPassword = 'webdav_password';

  /// `useDataProtectionKeyChain: false` is required on macOS: the plugin's
  /// default is `true`, and the data protection keychain demands a
  /// `keychain-access-groups`-style entitlement. The macOS build here is
  /// ad-hoc signed, so `SecItemAdd` fails with
  /// `-34018 A required entitlement is not present`. The legacy login keychain
  /// works for ad-hoc signed apps (verified on macOS 27 with `codesign -s -`).
  /// The option is ignored on every other platform.
  static const _keychain = FlutterSecureStorage(
    mOptions: MacOsOptions(useDataProtectionKeyChain: false),
  );

  static String _keychainKey(String name) => 'fqapp.secret.$name';

  /// Whether the `fqapp/secrets` channel answers. `null` until probed; the
  /// probe result is cached because a missing channel never appears later.
  static bool? _channelReady;

  /// Returns false when nothing was stored under [name].
  Future<bool> has(String name) async {
    if (!await _usesPlatformChannel()) {
      try {
        return await _keychain.read(key: _keychainKey(name)) != null;
      } catch (error) {
        AppLog.w(_tag, '钥匙串不可读: $name', error: error);
        return false;
      }
    }
    final preferences = await SharedPreferences.getInstance();
    final blob = preferences.getString('$_prefix$name');
    return blob != null && blob.isNotEmpty;
  }

  Future<void> write(String name, String value) async {
    if (!await _usesPlatformChannel()) {
      await _writeKeychain(name, value);
      return;
    }
    final blob = await _invoke('encrypt', value, name);
    final preferences = await SharedPreferences.getInstance();
    await preferences.setString('$_prefix$name', blob);
  }

  /// Null when nothing was stored. A stored value that cannot be decrypted
  /// throws, because the caller has to re-ask instead of continuing with an
  /// empty password.
  Future<String?> read(String name) async {
    if (!await _usesPlatformChannel()) {
      return _readKeychain(name);
    }
    final preferences = await SharedPreferences.getInstance();
    final blob = preferences.getString('$_prefix$name');
    if (blob == null || blob.isEmpty) return null;
    return _invoke('decrypt', blob, name);
  }

  Future<void> delete(String name) async {
    final preferences = await SharedPreferences.getInstance();
    await preferences.remove('$_prefix$name');
    if (await _usesPlatformChannel()) return;
    try {
      await _keychain.delete(key: _keychainKey(name));
    } catch (error) {
      // Nothing to delete, or the keychain is unavailable: the preference side
      // is already clean, so the password cannot be read back either way.
      AppLog.w(_tag, '钥匙串删除失败: $name', error: error);
    }
  }

  static Future<bool> _usesPlatformChannel() async =>
      _channelReady ??= await _probeChannel();

  /// Probes the channel, once per process.
  ///
  /// A deliberately hopeless `decrypt('')` is the cheapest way to ask "is
  /// anyone listening?": the Android plugin rejects it with
  /// `SECRET_UNAVAILABLE` *before* touching the keystore (the payload-size
  /// check comes first), which proves the channel is there; on macOS and
  /// Windows nobody is registered, so the invocation itself throws
  /// [MissingPluginException]. Probing with `encrypt` instead would be a real
  /// keystore operation, and the widget tests count those calls.
  static Future<bool> _probeChannel() async {
    try {
      await _channel.invokeMethod<String>('decrypt', {'value': ''});
      return true;
    } on MissingPluginException {
      AppLog.w(_tag, 'fqapp/secrets 通道不存在，改用系统钥匙串');
      return false;
    } on PlatformException catch (error) {
      // Channel present, keystore itself unhappy. Let the real call surface
      // the code instead of silently switching backends on a transient error.
      AppLog.d(_tag, '通道探测收到 ${error.code}，按可用处理');
      return true;
    }
  }

  Future<void> _writeKeychain(String name, String value) async {
    try {
      await _keychain.write(key: _keychainKey(name), value: value);
    } on MissingPluginException catch (error) {
      AppLog.w(_tag, '系统钥匙串不可用: $name', error: error);
      throw const SecretStoreException('当前环境不支持系统密钥库，无法保存密码');
    } on PlatformException catch (error) {
      AppLog.w(_tag, '钥匙串写入失败: ${error.code}', error: error);
      throw const SecretStoreException('无法用系统钥匙串保护密码，请重试');
    }
  }

  Future<String?> _readKeychain(String name) async {
    try {
      return await _keychain.read(key: _keychainKey(name));
    } on MissingPluginException catch (error) {
      // No keychain on this platform at all: nothing can have been stored
      // there, so "no password yet" is the truthful answer. A later [write]
      // is where the missing backend turns into a visible error.
      AppLog.w(_tag, '系统钥匙串不可用: $name', error: error);
      return null;
    } on PlatformException catch (error) {
      AppLog.w(_tag, '钥匙串读取失败: ${error.code}', error: error);
      throw const SecretStoreException('保存的密码已失效（系统钥匙串拒绝读取），请重新输入');
    }
  }

  Future<String> _invoke(String method, String value, String name) async {
    try {
      final result = await _channel.invokeMethod<String>(method, {
        'value': value,
      });
      if (result == null) throw const SecretStoreException('系统密钥库没有返回结果');
      return result;
    } on PlatformException catch (error) {
      AppLog.w(
        _tag,
        '密钥库 $method 失败: ${error.code}',
        error: error,
      );
      throw SecretStoreException(
        method == 'encrypt'
            ? '无法用系统密钥库保护密码，请重试'
            : '保存的密码已失效（系统密钥库拒绝解密），请重新输入',
      );
    } on MissingPluginException catch (error) {
      AppLog.w(_tag, '密钥库通道不可用: $name', error: error);
      throw const SecretStoreException('当前环境不支持系统密钥库，无法保存密码');
    }
  }

  @visibleForTesting
  static void resetChannelProbeForTest() => _channelReady = null;
}
