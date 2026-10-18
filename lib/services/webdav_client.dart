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
  ///
  /// [name] 指向同一目录下的另一个分片；null 表示配置里那个整包文件。
  ///
  /// `versionKey` 是下载到的这一版的标识（响应头带的 ETag，没有就是 null），
  /// 写回时拿它做 `If-Match`。
  Future<({Uint8List bytes, DateTime? modified, String? versionKey})?> download({
    String? name,
  });

  /// 只问「云端那份文件是哪一版、多大、什么时候改的」，不取正文 —— 打开
  /// 应用时的检查和热路径闸门都靠它，不必为了看一眼时间戳就把整份备份
  /// 下载下来。
  ///
  /// Null 表示云端还没有这个文件（首次同步前）。
  Future<RemoteFile?> remoteFile({String? name});

  /// 写入成功时返回新版本标识 —— 有 `ETag` 响应头就取它，没有则 null，
  /// 调用方自己决定要不要回读。
  ///
  /// [ifMatch] 非 null 时带上 `If-Match`，让服务器在「我读到的版本已经
  /// 不是最新」时拒绝这次写。值**原样透传** [RemoteFile.versionKey]，
  /// 不补引号：坚果云只认裸 token，按 RFC 加引号会一律 412。
  Future<String?> upload(Uint8List bytes, {String? name, String? ifMatch});

  /// 把同一目录下的 [from] 挪到 [to]。
  ///
  /// 目标必须不存在：坚果云对「覆盖已存在目标」的 MOVE 一律回 409，`Overwrite`
  /// 头也不认。所以调用方要先删目标 —— 原子替换的顺序正是按这一点排的。
  Future<void> move({String? from, required String? to});

  /// 删除一个文件。目标不存在算成功（幂等）。
  ///
  /// 只能删文件：坚果云对目录的 DELETE 一律 403，空目录也一样，所以「清理
  /// 云端」必须逐个文件来，目录留给用户在网页端删。
  Future<void> delete({String? name});

  void close();
}

/// 云端一个文件的状态。
///
/// [versionKey] 是这里唯一用来判断「是不是同一版」的东西，而且**只做字符串
/// 相等比较，绝不解析成时间**。把本机时钟和服务器时间相减来判断新旧，会在
/// 任何一方时间不准时静默失效 —— 手机快 5 分钟就永远认为云端更旧，于是盲写
/// 覆盖；服务器快 5 分钟就每次回前台都弹窗。字符串比较没有这个失效方式。
class RemoteFile {
  const RemoteFile({
    this.etag,
    this.lastModifiedRaw,
    this.size,
    this.modified,
  });

  /// 服务器给的 ETag，**原样保留**（可能带引号，可能带 `W/`）。
  final String? etag;

  /// `getlastmodified` 或 `Last-Modified` 的原始字符串。
  final String? lastModifiedRaw;

  final int? size;

  /// 解析出来的时间，只用于页面显示（「云端更新于 …」），不参与任何判断。
  final DateTime? modified;

  /// 判断「是不是同一版」的键。
  ///
  /// 优先 ETag：它是内容指纹，同一内容必然同值，重复上传不会制造假冲突。
  /// 服务器不给 ETag 时退回 `getlastmodified` 原始字符串 —— 精度只到秒，
  /// 但至少是「服务器自己的时间」，不受本机时钟影响。
  ///
  /// 两者都没有时为 null，调用方应视为「无法判断版本」，走保守路径。
  String? get versionKey {
    final tag = etag;
    if (tag != null && tag.isNotEmpty) return tag;
    final stamp = lastModifiedRaw;
    if (stamp != null && stamp.isNotEmpty) return stamp;
    return null;
  }
}

/// Small WebDAV client over the `http` package.
///
/// It speaks only what a snapshot sync needs: PROPFIND to prove the collection
/// exists and to read the file's version, GET to read the file, PUT to replace
/// it (conditionally, with `If-Match`) and MKCOL to create a missing folder.
/// Responses are parsed with the status code, the `Last-Modified` header and —
/// for PROPFIND, which is the only reliable way to ask some servers for a
/// version — the `getetag`/`getlastmodified`/`getcontentlength` elements, so no
/// general XML parsing is involved.
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
    this.readIdleTimeout = defaultReadIdleTimeout,
    this.readDeadline = defaultReadDeadline,
  }) : _client = client ?? http.Client(),
       _ownsClient = client == null;

  final WebdavConfig config;
  final String password;

  /// 等到响应头（`_client.send` 那一刻）的上限。正文另算，见 [_read]。
  final Duration timeout;

  /// 正文分块之间的间隔上限。
  final Duration readIdleTimeout;

  /// 一次响应正文读到底的总时长上限。
  final Duration readDeadline;

  final http.Client _client;
  final bool _ownsClient;

  /// 服务器把响应头发完就沉默时，最多等这么久。
  ///
  /// [timeout] 只包住「等到响应头」。头到了、正文一个字节都不来，`await for`
  /// 没有自己的超时，同步会永远挂在待办队列里：之后每一次同步都排在它后面，
  /// 页面上就是一直转圈，而且没有任何错误可显示。分块计时是唯一能发现
  /// 「连接还在、但对面不说话了」的手段。
  static const defaultReadIdleTimeout = Duration(seconds: 20);

  /// 慢速滴流的兜底：每块都没超时、总量却可以拖几个小时。
  static const defaultReadDeadline = Duration(minutes: 2);

  /// Control responses carry a few hundred bytes; capping them keeps a hostile
  /// or misconfigured server from being buffered without limit.
  static const _controlLimit = 256 * 1024;

  /// 四个属性一个都不能少。
  ///
  /// `getetag` 是版本判断的全部依据；`getlastmodified` 是它的备用键，也用于
  /// 页面显示；`getcontentlength` 用来校验上传是否被截断。
  ///
  /// **`resourcetype` 看着没用，但坚果云少了它就完全不返回 `getetag`** ——
  /// 不是报错，是在 207 正文里把 `getetag` 整个省掉，于是客户端只会看到
  /// 「这个文件没有版本」并安静地退化成无保护写入。实测确认：只请求
  /// `getetag` 时它回 `<prop/>` 加 propstat 404，三属性（缺 resourcetype）
  /// 时静默省略，四属性齐全才正常返回。
  static const _propfindBody =
      '<?xml version="1.0" encoding="utf-8"?>'
      '<d:propfind xmlns:d="DAV:"><d:prop><d:getetag/>'
      '<d:getlastmodified/><d:getcontentlength/><d:resourcetype/>'
      '</d:prop></d:propfind>';

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

  /// 分片文件名给 null 时就是配置里的整包文件。
  Uri _uriFor(String? name) =>
      name == null ? config.fileUri : config.fileUriNamed(name);

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
  Future<({Uint8List bytes, DateTime? modified, String? versionKey})?> download({
    String? name,
  }) async {
    final response = await _read(
      await _open('GET', _uriFor(name)),
      limit: LibraryBackup.maxBytes,
    );
    if (response.statusCode == 404) return null;
    _requireSuccess(response, '无法读取云端备份');
    final tag = response.headers['etag'];
    return (
      bytes: response.bodyBytes,
      modified: _lastModified(response),
      versionKey: tag == null || tag.isEmpty ? null : tag,
    );
  }

  @override
  Future<RemoteFile?> remoteFile({String? name}) async {
    final response = await _read(
      await _open(
        'PROPFIND',
        _uriFor(name),
        depth: '0',
        body: utf8.encode(_propfindBody),
        contentType: 'application/xml; charset=utf-8',
      ),
      limit: _controlLimit,
    );
    // 文件还不存在：首次同步前是正常状态，不算错误。
    if (response.statusCode == 404) return null;
    if (response.statusCode == 207 || response.statusCode == 200) {
      final parsed = _propfindFile(response.bodyBytes);
      // 207 的正文里没有时间戳时，`Last-Modified` 头是最后的来源；两处都
      // 没有就返回一个 versionKey 为 null 的 RemoteFile —— 调用方据此走
      // 保守路径，而不是把「有文件但无法判断版本」当成「没有文件」。
      final stamp = parsed.lastModifiedRaw ?? _lastModifiedRaw(response);
      return RemoteFile(
        etag: parsed.etag,
        lastModifiedRaw: stamp,
        size: parsed.size,
        // 时间只用于显示，解析不出来不影响同步。
        modified: _parseHttpDate(stamp) ?? _lastModified(response),
      );
    }
    _requireSuccess(response, '无法读取云端备份信息');
    return RemoteFile(
      etag: response.headers['etag'],
      lastModifiedRaw: _lastModifiedRaw(response),
      modified: _lastModified(response),
    );
  }

  @override
  Future<String?> upload(
    Uint8List bytes, {
    String? name,
    String? ifMatch,
  }) async {
    final response = await _read(
      await _open(
        'PUT',
        _uriFor(name),
        body: bytes,
        contentType: 'application/json; charset=utf-8',
        ifMatch: ifMatch,
      ),
      limit: _controlLimit,
    );
    switch (response.statusCode) {
      case 200:
      case 201:
      case 204:
        final tag = response.headers['etag'];
        return tag == null || tag.isEmpty ? null : tag;
      case 412:
        // 唯一的「合法失败」：不是网络问题，是别人先写了。
        // 单独成一类，重试循环只对这一个状态码重来。
        throw const WebdavException(
          '云端文件已被其它设备更新，本次写入已取消，稍后会自动重试',
          statusCode: 412,
        );
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
        return null;
    }
  }

  @override
  Future<void> move({String? from, required String? to}) async {
    final response = await _read(
      await _open('MOVE', _uriFor(from), destination: _uriFor(to)),
      limit: _controlLimit,
    );
    switch (response.statusCode) {
      case 200:
      case 201:
      case 204:
        return;
      case 409:
        throw _statusError(
          response,
          '无法重命名云端文件',
          hint: '（目标文件已存在，需要先删掉它）',
        );
      default:
        _requireSuccess(response, '无法重命名云端文件');
    }
  }

  @override
  Future<void> delete({String? name}) async {
    final response = await _read(
      await _open('DELETE', _uriFor(name)),
      limit: _controlLimit,
    );
    // 已经在的删除请求（重试、或另一台设备先删了）不该算失败。
    if (response.statusCode == 404) return;
    _requireSuccess(response, '无法删除云端文件');
  }

  /// Buffers a response, refusing anything above [limit] instead of letting a
  /// wrong URL pull an unbounded body into memory.
  ///
  /// 两把超时锁住「连接还在但不说话」：
  /// - [readIdleTimeout] 管相邻两块之间的空档（`Stream.timeout`）；
  /// - [readDeadline] 管整段正文的总时长（慢速滴流每块都不超时）。
  ///
  /// 任何一条触发都会取消订阅并抛 [WebdavException]：宁可让这次同步失败，
  /// 也不能让一个半死的连接把后面所有同步都堵在队列里。
  Future<http.Response> _read(
    http.StreamedResponse streamed, {
    required int limit,
  }) {
    final body = BytesBuilder(copy: false);
    final done = Completer<http.Response>();

    void fail(Object error) {
      if (done.isCompleted) return;
      done.completeError(_asWebdav(error));
    }

    late final StreamSubscription<List<int>> subscription;
    final deadline = Timer(readDeadline, () {
      if (done.isCompleted) return;
      fail(
        WebdavException(
          '读取云端数据超过 ${readDeadline.inSeconds} 秒仍未完成，已中断，请稍后重试',
        ),
      );
    });

    subscription = streamed.stream.timeout(readIdleTimeout).listen(
      (chunk) {
        if (body.length + chunk.length > limit) {
          fail(
            WebdavException(
              '服务器返回的内容超过 ${(limit / (1024 * 1024)).toStringAsFixed(1)} MB，'
              '已停止读取',
            ),
          );
          return;
        }
        body.add(chunk);
      },
      onError: fail,
      onDone: () {
        if (done.isCompleted) return;
        done.complete(
          http.Response.bytes(
            body.takeBytes(),
            streamed.statusCode,
            headers: streamed.headers,
            request: streamed.request,
          ),
        );
      },
      cancelOnError: true,
    );

    return done.future.whenComplete(() {
      deadline.cancel();
      // 错误路径上 `cancelOnError` 已经取消过订阅，重复取消是安全的；
      // 成功路径上这一句让底层连接有机会释放。
      unawaited(subscription.cancel());
    });
  }

  /// 把读正文时才冒出来的异常翻译成 [WebdavException]。
  ///
  /// 这些异常在 `_open` 里已经处理过一轮，但那时只覆盖「建立连接」这一段；
  /// 连接在中途断掉是另一条路径，原始 `SocketException` 直接冒到页面上只会
  /// 显示成一行看不清的英文。
  WebdavException _asWebdav(Object error) {
    if (error is WebdavException) return error;
    if (error is TimeoutException) {
      return WebdavException(
        '服务器超过 ${readIdleTimeout.inSeconds} 秒没有返回数据，连接已断开，'
        '请检查网络或稍后重试',
      );
    }
    if (error is SocketException) {
      final detail = error.osError?.message ?? error.message;
      return WebdavException('与服务器的连接中断（$detail）');
    }
    if (error is http.ClientException) {
      return WebdavException('请求失败：${error.message}');
    }
    if (error is HttpException) {
      return const WebdavException('与服务器的连接中断，请稍后重试');
    }
    return const WebdavException('读取云端数据时连接中断，请稍后重试');
  }

  Future<http.StreamedResponse> _open(
    String method,
    Uri uri, {
    String? depth,
    List<int>? body,
    String? contentType,
    String? ifMatch,
    Uri? destination,
  }) async {
    final request = http.Request(method, uri)
      // See the class comment: a replayed PUT is worse than a clear error.
      ..followRedirects = false
      ..headers.addAll(_authHeaders);
    if (depth != null) request.headers['Depth'] = depth;
    if (contentType != null) request.headers['Content-Type'] = contentType;
    // 原样透传，不补引号 —— 见 WebdavTransport.upload 的说明。
    if (ifMatch != null) request.headers['If-Match'] = ifMatch;
    if (destination != null) {
      // MOVE 的 Destination 必须是绝对 URL，即使同一个目录也一样。
      request.headers['Destination'] = destination.toString();
      request.headers['Overwrite'] = 'T';
    }
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

  static String? _lastModifiedRaw(http.Response response) {
    final value = response.headers['last-modified'];
    return value == null || value.isEmpty ? null : value;
  }

  static DateTime? _lastModified(http.Response response) =>
      _parseHttpDate(_lastModifiedRaw(response));

  static DateTime? _parseHttpDate(String? value) {
    if (value == null || value.isEmpty) return null;
    try {
      return HttpDate.parse(value);
    } on Exception {
      // A server may send a date no HTTP parser accepts; the timestamp is only
      // shown in the page, so a missing one is not a sync failure.
      return null;
    }
  }

  /// PROPFIND 的 207 正文里那三个属性。
  ///
  /// 只认这三个元素：WebDAV 服务器一定会回它们，而 `Last-Modified` 头在 207
  /// 上不是必须的（坚果云就不保证）。解析失败按「没有这个属性」处理 ——
  /// 那只会让闸门走保守路径，不该让同步失败。
  ///
  /// 用正则而不是完整 XML 解析是既有取舍：只取三个叶子元素，正文由服务端
  /// 生成、结构固定。`([^<]+)` 保证自闭合标签（`<d:getetag/>`）不会被误读成
  /// 有值 —— 那正是坚果云在属性不被响应时的写法。
  static ({String? etag, String? lastModifiedRaw, int? size}) _propfindFile(
    Uint8List body,
  ) {
    final text = utf8.decode(body, allowMalformed: true);
    String? pick(String element) {
      final match = RegExp(
        '<[^>]*$element[^>]*>([^<]+)<',
        caseSensitive: false,
      ).firstMatch(text);
      final value = match?.group(1)?.trim();
      return value == null || value.isEmpty ? null : value;
    }

    final lengthRaw = pick('getcontentlength');
    return (
      etag: pick('getetag'),
      lastModifiedRaw: pick('getlastmodified'),
      size: int.tryParse(lengthRaw ?? ''),
    );
  }

  @override
  void close() {
    if (_ownsClient) _client.close();
  }
}
