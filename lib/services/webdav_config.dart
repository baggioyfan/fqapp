import 'package:shared_preferences/shared_preferences.dart';

/// Where WebDAV sync points, without the credential.
///
/// The password never lives here: it goes through `SecretStore` into the
/// Android keystore. The rest is ordinary configuration and stays in
/// SharedPreferences next to the app's other preferences.
class WebdavConfig {
  const WebdavConfig({
    required this.collectionUrl,
    required this.username,
    required this.fileName,
  });

  static const defaultFileName = 'fqapp-sync.json';

  /// Always ends with `/`, so a child URL is the collection plus one segment
  /// and the server does not answer with a redirect to the same path.
  final String collectionUrl;
  final String username;
  final String fileName;

  Uri get collectionUri => Uri.parse(collectionUrl);

  Uri get fileUri => Uri.parse('$collectionUrl$fileName');

  @override
  String toString() =>
      'WebdavConfig($collectionUrl, user: $username, file: $fileName)';
}

/// Returns null when [input] can be used as the collection URL, otherwise the
/// message to show. Both schemes are accepted because a home NAS usually serves
/// WebDAV over plain HTTP: Dart's own HTTP stack is outside the Android network
/// security config, so cleartext is not blocked there, and the page still
/// recommends HTTPS.
String? validateWebdavUrl(String input) {
  final value = input.trim();
  if (value.isEmpty) return '请填写 WebDAV 地址';
  final uri = Uri.tryParse(value);
  if (uri == null || uri.host.isEmpty) {
    return '地址格式不正确，例如 https://dav.example.com/dav/我的目录/';
  }
  if (uri.scheme != 'https' && uri.scheme != 'http') {
    return '地址需要以 http:// 或 https:// 开头';
  }
  if (uri.userInfo.isNotEmpty) return '请把账号密码填在下面的输入框，不要写进地址';
  if (uri.hasQuery || uri.hasFragment) return '地址里不要带 ? 或 #';
  if (uri.path.endsWith('.json')) return '这里填目录地址，不要带文件名';
  return null;
}

/// Trims the input and makes sure the path reads as a directory.
String normalizeWebdavUrl(String input) {
  final value = input.trim();
  return value.endsWith('/') ? value : '$value/';
}

final _fileNamePattern = RegExp(r'^[A-Za-z0-9][A-Za-z0-9._-]*$');

/// Returns null when [input] can be used as the remote file name.
String? validateWebdavFileName(String input) {
  final value = input.trim();
  if (value.isEmpty) return '请填写云端文件名';
  if (value.length > 64) return '文件名最长 64 个字符';
  if (!_fileNamePattern.hasMatch(value)) {
    return '文件名只能用字母、数字、点、下划线和减号';
  }
  if (!value.endsWith('.json')) return '文件名需要以 .json 结尾';
  return null;
}

/// Persists [WebdavConfig] and the last successful sync time.
///
/// The password is not part of this store: `SecretStore.write` keeps the
/// encrypted copy under its own key, so removing the configuration here cannot
/// leave a usable secret behind.
class WebdavConfigStore {
  WebdavConfigStore._();

  static final WebdavConfigStore instance = WebdavConfigStore._();

  /// Exposed so tests and the settings UI name the same preferences instead of
  /// repeating the literals.
  static const urlKey = 'webdav_collection_url_v1';
  static const userKey = 'webdav_username_v1';
  static const fileKey = 'webdav_file_name_v1';
  static const lastSyncKey = 'webdav_last_sync_v1';

  /// Null until the user saves a usable address; the page then shows the form
  /// instead of the sync state.
  Future<WebdavConfig?> load() async {
    final preferences = await SharedPreferences.getInstance();
    final url = preferences.getString(urlKey);
    if (url == null || validateWebdavUrl(url) != null) return null;
    final fileName = preferences.getString(fileKey) ?? WebdavConfig.defaultFileName;
    return WebdavConfig(
      collectionUrl: url,
      username: preferences.getString(userKey) ?? '',
      fileName: validateWebdavFileName(fileName) == null
          ? fileName
          : WebdavConfig.defaultFileName,
    );
  }

  Future<void> save(WebdavConfig config) async {
    final preferences = await SharedPreferences.getInstance();
    await preferences.setString(urlKey, config.collectionUrl);
    await preferences.setString(userKey, config.username);
    await preferences.setString(fileKey, config.fileName);
  }

  Future<void> clear() async {
    final preferences = await SharedPreferences.getInstance();
    await preferences.remove(urlKey);
    await preferences.remove(userKey);
    await preferences.remove(fileKey);
    await preferences.remove(lastSyncKey);
  }

  Future<DateTime?> lastSyncedAt() async {
    final preferences = await SharedPreferences.getInstance();
    final value = preferences.getInt(lastSyncKey);
    return value == null ? null : DateTime.fromMillisecondsSinceEpoch(value);
  }

  Future<void> markSynced(DateTime at) async {
    final preferences = await SharedPreferences.getInstance();
    await preferences.setInt(lastSyncKey, at.millisecondsSinceEpoch);
  }
}
