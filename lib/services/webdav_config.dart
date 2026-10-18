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

  /// 同一目录下的另一个分片（`progress.json` 等）。
  ///
  /// 分片是按**时机**拆的，不是按体积：进度秒级变化、其余分钟~天级，所以
  /// 它们必须是两个文件，才能各自用不同的闸门和触发条件。
  Uri fileUriNamed(String name) => Uri.parse('$collectionUrl$name');

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

  /// 进度分片自己的同步时刻。和整包分开记：分片是两个文件，闸门也必须
  /// 各算各的，否则「刚同步过整包」会把进度分片误判成「云端没变」。
  static const lastProgressSyncKey = 'webdav_last_progress_sync_v1';

  /// 用户点过「忽略」的那一版云端时间戳。只用来避免同一个版本反复追问，
  /// 不影响 [lastSyncedAt]（那是真的同步过才算）。
  static const dismissedKey = 'webdav_dismissed_remote_v1';

  /// 上次见到/写下的云端版本标识（ETag，服务器不给时是 `getlastmodified`
  /// 原始字符串）。
  ///
  /// 闸门判断从「时间先后」改成「版本是否相同」，是为了躲开时钟偏移：
  /// 本机快 5 分钟就永远认为云端更旧，于是盲写覆盖另一台设备的进度，而且
  /// 日志里一切正常；服务器快 5 分钟则每次回前台都弹「云端有更新」。
  /// 字符串相等没有这两种失效方式。
  static const fullVersionKey = 'webdav_version_full_v1';
  static const progressVersionKey = 'webdav_version_progress_v1';

  /// 上一次写到云端的进度分片的**内容指纹**（不是服务端 etag）。
  ///
  /// etag 只有服务端算得出来，而写操作不回传它，所以「刚写出去的是哪一版」
  /// 以前只能再问一次服务端。内容指纹本机算得出来：下次 GET 回来算一遍，
  /// 一样就说明云端还是自己写的那份，不必为了确认版本多跑一个往返。
  static const progressDigestKey = 'webdav_digest_progress_v1';

  /// 用户忽略过的那一版（版本标识，不是时间）。
  static const dismissedVersionKey = 'webdav_dismissed_version_v1';

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
    await preferences.remove(lastProgressSyncKey);
    await preferences.remove(dismissedKey);
    await preferences.remove(fullVersionKey);
    await preferences.remove(progressVersionKey);
    await preferences.remove(progressDigestKey);
    await preferences.remove(dismissedVersionKey);
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

  Future<DateTime?> progressSyncedAt() async {
    final preferences = await SharedPreferences.getInstance();
    final value = preferences.getInt(lastProgressSyncKey);
    return value == null ? null : DateTime.fromMillisecondsSinceEpoch(value);
  }

  Future<void> markProgressSynced(DateTime at) async {
    final preferences = await SharedPreferences.getInstance();
    await preferences.setInt(
      lastProgressSyncKey,
      at.millisecondsSinceEpoch,
    );
  }

  /// 上次见到（或写下）的整包版本标识。null 表示「不知道」，闸门会走保守
  /// 路径：先读回来合并，而不是假设云端没变。
  Future<String?> fullVersion() async {
    final preferences = await SharedPreferences.getInstance();
    final value = preferences.getString(fullVersionKey);
    return value == null || value.isEmpty ? null : value;
  }

  Future<void> markFullVersion(String? key) async {
    final preferences = await SharedPreferences.getInstance();
    if (key == null || key.isEmpty) {
      await preferences.remove(fullVersionKey);
    } else {
      await preferences.setString(fullVersionKey, key);
    }
  }

  /// 上次写到云端的进度分片内容指纹。null 表示「不知道」——闸门会走保守
  /// 路径：把云端内容读回来合并。
  Future<String?> progressDigest() async {
    final preferences = await SharedPreferences.getInstance();
    final value = preferences.getString(progressDigestKey);
    return value == null || value.isEmpty ? null : value;
  }
  Future<void> markProgressDigest(String? digest) async {
    final preferences = await SharedPreferences.getInstance();
    if (digest == null || digest.isEmpty) {
      await preferences.remove(progressDigestKey);
    } else {
      await preferences.setString(progressDigestKey, digest);
    }
  }

  /// 用户忽略过的那一版。存版本标识而不是时间：同一个版本可能被忽略多次，
  /// 而「哪一版」比「什么时候」更不容易被时钟搞错。
  Future<String?> dismissedVersion() async {
    final preferences = await SharedPreferences.getInstance();
    final value = preferences.getString(dismissedVersionKey);
    return value == null || value.isEmpty ? null : value;
  }

  Future<void> markDismissedVersion(String? key) async {
    final preferences = await SharedPreferences.getInstance();
    if (key == null || key.isEmpty) {
      await preferences.remove(dismissedVersionKey);
    } else {
      await preferences.setString(dismissedVersionKey, key);
    }
  }
}
