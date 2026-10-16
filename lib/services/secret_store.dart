import 'package:flutter/services.dart';
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

/// Keeps one credential per name, encrypted by the Android keystore.
///
/// SharedPreferences holds only the ciphertext; the AES key never leaves the
/// keystore, so a copied preferences file is useless on another device. The
/// native side is `SecretStorePlugin`.
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

  /// Returns false when nothing was stored under [name].
  Future<bool> has(String name) async {
    final preferences = await SharedPreferences.getInstance();
    final blob = preferences.getString('$_prefix$name');
    return blob != null && blob.isNotEmpty;
  }

  Future<void> write(String name, String value) async {
    final blob = await _invoke('encrypt', value, name);
    final preferences = await SharedPreferences.getInstance();
    await preferences.setString('$_prefix$name', blob);
  }

  /// Null when nothing was stored. A stored value that cannot be decrypted
  /// throws, because the caller has to re-ask instead of continuing with an
  /// empty password.
  Future<String?> read(String name) async {
    final preferences = await SharedPreferences.getInstance();
    final blob = preferences.getString('$_prefix$name');
    if (blob == null || blob.isEmpty) return null;
    return _invoke('decrypt', blob, name);
  }

  Future<void> delete(String name) async {
    final preferences = await SharedPreferences.getInstance();
    await preferences.remove('$_prefix$name');
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
}
