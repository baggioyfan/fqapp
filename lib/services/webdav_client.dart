import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:http/http.dart' as http;

import '../models/library_backup.dart';
import 'webdav_config.dart';

/// Carries text that is already safe to show in the settings page.
class WebdavException implements Exception {
  const WebdavException(this.message, {this.statusCode});

  final String message;
  final int? statusCode;

  @override
  String toString() => 'WebdavException($statusCode: $message)';
}

/// The part of a WebDAV server the sync service needs.
///
/// Narrow on purpose: the tests substitute an in-memory implementation instead
/// of standing up a server twice.
abstract interface class WebdavTransport {
  /// Creates the collection when the address points at a folder that is not
  /// there yet, and reports a usable error when the address is not a WebDAV
  /// collection at all.
  Future<void> ensureCollection();

  /// Null when the remote file does not exist yet.
  Future<({Uint8List bytes, DateTime? modified})?> download();

  /// 只问「云端那份快照什么时候改过」，不取正文 —— 打开应用时的检查用它，
  /// 不必为了看一眼时间戳就把整份备份下载下来。
  ///
  /// Null 表示云端还没有这个文件（首次同步前）。
  Future<DateTime?> remoteModified();

  Future<void> upload(Uint8List bytes);

  void close();
}

/// Small WebDAV client over the `http` package.
///
/// It speaks only what a snapshot sync needs: PROPFIND to prove the collection
/// exists and to read the snapshot's timestamp, GET to read the file, PUT to
/// replace it and MKCOL to create a missing folder. Responses are parsed with
/// the status code, the `Last-Modified` header and — for PROPFIND, which is the
/// only reliable way to ask some servers for a timestamp — the single
/// `getlastmodified` element, so no general XML parsing is involved.
///
/// Redirects are not followed. A 3xx on PUT would otherwise be replayed as a
/// different method by the underlying HTTP stack, which turns a failed upload
/// into an apparent success; the redirect target is reported instead.
class WebdavClient implements WebdavTransport {
  WebdavClient({
    required this.config,
    required this.password,
    http.Client? client,
    this.timeout = const Duration(seconds: 30),
  }) : _client = client ?? http.Client(),
       _ownsClient = client == null;

  final WebdavConfig config;
  final String password;
  final Duration timeout;

  final http.Client _client;
  final bool _ownsClient;

  /// Control responses carry a few hundred bytes; capping them keeps a hostile
  /// or misconfigured server from being buffered without limit.
  static const _controlLimit = 256 * 1024;

  static const _propfindBody =
      '<?xml version="1.0" encoding="utf-8"?>'
      '<d:propfind xmlns:d="DAV:"><d:prop><d:getlastmodified/>'
      '<d:getcontentlength/></d:prop></d:propfind>';

  /// Appended to a 404 or 409 on the snapshot file itself.
  ///
  /// The configured address is a folder and the snapshot is created inside it,
  /// so those two statuses have one meaning: the folder is not there, or the
  /// server will not put a file in it. Nutstore answers 404 for a PUT that
  /// would create a file at its WebDAV root and allows it only inside a folder,
  /// which is the first-run failure easiest to misread as a wrong password.
  /// The URL that was refused is printed with the advice, so the answer is in
  /// the message instead of a log.
  String get _createHereHint =>
      '（被拒绝的地址是 ${config.fileUri}）。请确认地址指向一个已存在的文件夹：'
      '有的网盘（如坚果云）不允许在根目录下新建文件，需要先在网页端建一个文件夹，'
      '再把地址改成这个文件夹';

  @override
  Future<void> ensureCollection() async {
    final response = await _read(
      await _open(
        'PROPFIND',
        config.collectionUri,
        depth: '0',
        body: utf8.encode(_propfindBody),
        contentType: 'application/xml; charset=utf-8',
      ),
      limit: _controlLimit,
    );
    switch (response.statusCode) {
      case 404:
        await _createCollection();
      case 405:
      case 501:
        throw const WebdavException(
          '这个地址不支持 WebDAV（服务器拒绝了目录查询），请确认填的是 WebDAV 目录地址',
        );
      default:
        _requireSuccess(response, '无法访问云端目录');
    }
  }

  Future<void> _createCollection() async {
    final response = await _read(
      await _open('MKCOL', config.collectionUri),
      limit: _controlLimit,
    );
    // 405 means the folder appeared between the two requests.
    if (response.statusCode == 201 || response.statusCode == 405) return;
    throw _statusError(
      response,
      '云端目录不存在，且无法创建（WebDAV 地址需要指向一个已存在的目录）',
    );
  }

  @override
  Future<({Uint8List bytes, DateTime? modified})?> download() async {
    final response = await _read(
      await _open('GET', config.fileUri),
      limit: LibraryBackup.maxBytes,
    );
    if (response.statusCode == 404) return null;
    _requireSuccess(response, '无法读取云端备份');
    return (bytes: response.bodyBytes, modified: _lastModified(response));
  }

  @override
  Future<DateTime?> remoteModified() async {
    final response = await _read(
      await _open(
        'PROPFIND',
        config.fileUri,
        depth: '0',
        body: utf8.encode(_propfindBody),
        contentType: 'application/xml; charset=utf-8',
      ),
      limit: _controlLimit,
    );
    // 文件还不存在：首次同步前是正常状态，不算错误。
    if (response.statusCode == 404) return null;
    if (response.statusCode == 207 || response.statusCode == 200) {
      return _lastModified(response) ?? _propfindModified(response.bodyBytes);
    }
    _requireSuccess(response, '无法读取云端备份信息');
    return _lastModified(response);
  }

  @override
  Future<void> upload(Uint8List bytes) async {
    final response = await _read(
      await _open(
        'PUT',
        config.fileUri,
        body: bytes,
        contentType: 'application/json; charset=utf-8',
      ),
      limit: _controlLimit,
    );
    switch (response.statusCode) {
      case 200:
      case 201:
      case 204:
        return;
      case 404:
      case 409:
      case 507:
        // Only 404 and 409 use the hint; the mapping below ignores it for the
        // other status in this group, so 507 needs no branch of its own.
        throw _statusError(
          response,
          '上传云端备份失败',
          hint: _createHereHint,
        );
      default:
        _requireSuccess(response, '上传云端备份失败');
    }
  }

  /// Buffers a response, refusing anything above [limit] instead of letting a
  /// wrong URL pull an unbounded body into memory.
  Future<http.Response> _read(
    http.StreamedResponse streamed, {
    required int limit,
  }) async {
    final body = BytesBuilder(copy: false);
    await for (final chunk in streamed.stream) {
      if (body.length + chunk.length > limit) {
        throw WebdavException(
          '服务器返回的内容超过 ${(limit / (1024 * 1024)).toStringAsFixed(1)} MB，'
          '已停止读取',
        );
      }
      body.add(chunk);
    }
    return http.Response.bytes(
      body.takeBytes(),
      streamed.statusCode,
      headers: streamed.headers,
      request: streamed.request,
    );
  }

  Future<http.StreamedResponse> _open(
    String method,
    Uri uri, {
    String? depth,
    List<int>? body,
    String? contentType,
  }) async {
    final request = http.Request(method, uri)
      // See the class comment: a replayed PUT is worse than a clear error.
      ..followRedirects = false
      ..headers.addAll(_authHeaders);
    if (depth != null) request.headers['Depth'] = depth;
    if (contentType != null) request.headers['Content-Type'] = contentType;
    if (body != null) request.bodyBytes = body;
    try {
      return await _client.send(request).timeout(timeout);
    } on TimeoutException {
      throw const WebdavException('连接服务器超时，请检查地址、网络和服务器状态');
    } on HandshakeException {
      throw const WebdavException('安全连接失败：服务器证书不被信任');
    } on SocketException catch (error) {
      final detail = error.osError?.message ?? error.message;
      throw WebdavException('无法连接服务器（$detail）');
    } on http.ClientException catch (error) {
      throw WebdavException('请求失败：${error.message}');
    } on HttpException {
      throw const WebdavException('与服务器的连接中断，请稍后重试');
    }
  }

  Map<String, String> get _authHeaders => {
    // A server that allows anonymous writes needs no header at all.
    if (config.username.isNotEmpty || password.isNotEmpty)
      'Authorization': 'Basic ${base64Encode(utf8.encode('${config.username}:$password'))}',
    'User-Agent': 'fqapp-webdav-sync/1.0',
    'Accept': '*/*',
  };

  void _requireSuccess(http.Response response, String what) {
    final status = response.statusCode;
    if (status >= 200 && status < 300) return;
    throw _statusError(response, what);
  }

  WebdavException _statusError(
    http.Response response,
    String what, {
    String hint = '',
  }) {
    final status = response.statusCode;
    if (status >= 300 && status < 400) {
      final location = response.headers['location'];
      return WebdavException(
        location == null || location.isEmpty
            ? '$what：服务器要求跳转，请确认地址以 / 结尾'
            : '$what：服务器要求跳转到 $location，请把地址改成它',
        statusCode: status,
      );
    }
    return WebdavException(
      switch (status) {
        401 => '认证失败：请检查用户名和密码',
        403 => '服务器拒绝访问：请确认该账号对该目录有读写权限',
        404 => '$what：云端路径不存在$hint',
        405 => '$what：服务器不允许这个操作',
        409 => '$what：云端目录不存在$hint',
        423 => '$what：云端文件被锁定，请稍后重试',
        507 => '云端空间不足，无法写入备份',
        _ => '$what：服务器返回 $status',
      },
      statusCode: status,
    );
  }

  static DateTime? _lastModified(http.Response response) {
    final value = response.headers['last-modified'];
    if (value == null) return null;
    try {
      return HttpDate.parse(value);
    } on Exception {
      // A server may send a date no HTTP parser accepts; the timestamp is only
      // shown in the page, so a missing one is not a sync failure.
      return null;
    }
  }

  /// PROPFIND 的 207 正文里的 `<d:getlastmodified>`。
  ///
  /// 只认这一个元素：WebDAV 服务器一定会回它，而 `Last-Modified` 头在 207 上
  /// 不是必须的（坚果云就不保证）。解析失败按「没有时间戳」处理 —— 那只会让
  /// 应用少提示一次，不该让同步失败。
  static DateTime? _propfindModified(Uint8List body) {
    final text = utf8.decode(body, allowMalformed: true);
    final match = RegExp(
      r'<[^>]*getlastmodified[^>]*>([^<]+)<',
      caseSensitive: false,
    ).firstMatch(text);
    if (match == null) return null;
    try {
      return HttpDate.parse(match.group(1)!.trim());
    } on Exception {
      return null;
    }
  }

  @override
  void close() {
    if (_ownsClient) _client.close();
  }
}
