import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;

import 'package:fqapp/services/webdav_client.dart';
import 'package:fqapp/services/webdav_config.dart';

/// A WebDAV server with only the four methods the client uses.
///
/// It records what it was asked for, so the headers and bodies the client sends
/// can be asserted, and it can be told to misbehave the ways real servers do.
class _FakeServer {
  late final HttpServer _server;
  final methods = <String>[];
  final headers = <String, Map<String, String>>{};
  final files = <String, List<int>>{};
  final errors = <String>[];

  bool collectionExists = true;
  bool allowCreate = true;
  bool allowCreateFile = true;
  bool requireCredentials = true;
  int? forcedStatus;
  String? redirectLocation;
  int largeBodyBytes = 0;
  String? propfindBody;
  Uint8List lastPutBody = Uint8List(0);

  /// 每个路径当前的 ETag。真实服务端（坚果云）把它当内容指纹：同一内容
  /// 同一个值，内容变了值就变了。这里用递增计数模拟同样的事实。
  final etags = <String, String>{};
  var _etagCounter = 0;

  String _nextEtag() => 'etag-${++_etagCounter}';

  /// PUT 是否因为 `If-Match` 不匹配被拒 —— 用来断言「条件写真的发出去了」。
  int rejectedByIfMatch = 0;

  /// 真实坚果云在 PUT 响应里不给 ETag；打开这个开关才模拟「会回 ETag」的服务端。
  bool sendEtagOnPut = false;

  static final credentials =
      'Basic ${base64Encode(utf8.encode('reader:secret'))}';

  Future<void> start() async {
    _server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
    _server.listen((request) async {
      try {
        await _handle(request);
      } catch (error) {
        // Refusing an oversized response closes the socket mid-write, which
        // the server sees as an error; that is the expected path there.
        errors.add('$error');
      }
    });
  }

  Future<void> stop() => _server.close(force: true);

  String get origin => 'http://127.0.0.1:${_server.port}';

  String get path => '/dav/fqapp-sync.json';

  Future<void> _handle(HttpRequest request) async {
    final response = request.response;
    methods.add(request.method);
    final recorded = <String, String>{};
    for (final name in [
      'authorization',
      'depth',
      'content-type',
      'if-match',
      'destination',
    ]) {
      final value = request.headers.value(name);
      if (value != null) recorded[name] = value;
    }
    headers[request.method] = recorded;
    if (redirectLocation case final location?) {
      response.statusCode = 301;
      response.headers.set('location', location);
      await response.close();
      return;
    }
    if (requireCredentials &&
        request.headers.value('authorization') != credentials) {
      response.statusCode = 401;
      await response.close();
      return;
    }
    if (forcedStatus case final status?) {
      response.statusCode = status;
      await response.close();
      return;
    }
    if (request.method == 'PROPFIND') {
      propfindBody = await utf8.decoder.bind(request).join();
      if (request.uri.path == path) {
        // 针对快照文件本身的 PROPFIND：时间戳 + ETag + 大小，正文里给全。
        final bytes = files[request.uri.path];
        if (bytes == null) {
          response.statusCode = 404;
        } else {
          final tag = etags[request.uri.path] ??= _nextEtag();
          response.statusCode = 207;
          response.headers.contentType = ContentType(
            'application',
            'xml',
            charset: 'utf-8',
          );
          response.write(
            '<?xml version="1.0" encoding="utf-8"?>'
            '<d:multistatus xmlns:d="DAV:"><d:response><d:propstat><d:prop>'
            '<d:getetag>$tag</d:getetag>'
            '<d:getlastmodified>'
            '${HttpDate.format(DateTime.utc(2026, 1, 2, 3, 4, 5))}'
            '</d:getlastmodified>'
            '<d:getcontentlength>${bytes.length}</d:getcontentlength>'
            '<d:resourcetype/>'
            '</d:prop></d:propstat></d:response></d:multistatus>',
          );
        }
      } else if (largeBodyBytes > 0) {
        response.statusCode = 207;
        response.add(Uint8List(largeBodyBytes));
      } else {
        response.statusCode = collectionExists ? 207 : 404;
      }
    } else if (request.method == 'MKCOL') {
      if (allowCreate) {
        collectionExists = true;
        response.statusCode = 201;
      } else {
        response.statusCode = 403;
      }
    } else if (request.method == 'GET') {
      final bytes = files[request.uri.path];
      if (bytes == null) {
        response.statusCode = 404;
      } else {
        response.statusCode = 200;
        response.headers.set(
          'last-modified',
          HttpDate.format(DateTime.utc(2026, 1, 2, 3, 4, 5)),
        );
        response.add(bytes);
      }
    } else if (request.method == 'PUT') {
      final builder = BytesBuilder(copy: false);
      await for (final chunk in request) {
        builder.add(chunk);
      }
      lastPutBody = builder.takeBytes();
      final ifMatch = request.headers.value('if-match');
      final current = etags[request.uri.path];
      if (!allowCreateFile) {
        // What Nutstore answers for a PUT that would create a file at its
        // WebDAV root: the collection exists, the file is still refused.
        response.statusCode = 404;
      } else if (ifMatch != null && current != null && ifMatch != current) {
        // 条件写被拒：客户端读到的版本已经不是最新。目标文件保持原样，
        // 这正是「另一台设备的改动不会被盖掉」的全部机制。
        rejectedByIfMatch++;
        response.statusCode = 412;
      } else {
        files[request.uri.path] = lastPutBody;
        final tag = _nextEtag();
        etags[request.uri.path] = tag;
        response.statusCode = 201;
        // 坚果云不回 ETag 头；默认也不回，只有显式打开时才给，用来覆盖
        // 「服务端主动告知新版本」那条分支。
        if (sendEtagOnPut) response.headers.set('etag', tag);
      }
    } else if (request.method == 'MOVE') {
      final source = files[request.uri.path];
      final destination = request.headers.value('destination');
      if (source == null) {
        response.statusCode = 404;
      } else if (destination == null) {
        response.statusCode = 400;
      } else {
        final target = Uri.parse(destination).path;
        // 坚果云的真实行为：目标已存在一律 409，`Overwrite: T` 不认。
        // 三步替换之所以是「先删 .bak、再把主文件挪过去」，就是因为这一点。
        if (files[target] != null) {
          response.statusCode = 409;
        } else {
          files[target] = source;
          etags[target] = _nextEtag();
          files.remove(request.uri.path);
          etags.remove(request.uri.path);
          response.statusCode = 201;
        }
      }
    } else if (request.method == 'DELETE') {
      if (files.remove(request.uri.path) == null) {
        response.statusCode = 404;
      } else {
        etags.remove(request.uri.path);
        response.statusCode = 204;
      }
    } else {
      response.statusCode = 405;
    }
    await response.close();
  }
}

/// 头发回来了、正文一个字节都不来的连接。
///
/// 用真 `HttpServer` 摆出这个状态要赌「不写正文也不关响应」能被稳定复现，
/// 而这里要测的恰恰是客户端自己有没有读超时 —— 直接给一条只发头、不发正文
/// 的流，比赌服务端行为可靠得多。
class _SilentClient extends http.BaseClient {
  final _body = StreamController<List<int>>();

  @override
  Future<http.StreamedResponse> send(http.BaseRequest request) async =>
      http.StreamedResponse(
        _body.stream,
        200,
        headers: const {'content-length': '4096'},
        request: request,
      );

  Future<void> dispose() => _body.close();
}

void main() {
  late _FakeServer server;

  setUp(() async {
    server = _FakeServer();
    await server.start();
  });

  tearDown(() => server.stop());

  WebdavConfig configFor({
    String username = 'reader',
    String fileName = 'fqapp-sync.json',
  }) => WebdavConfig(
    collectionUrl: '${server.origin}/dav/',
    username: username,
    fileName: fileName,
  );

  WebdavClient clientFor({
    String password = 'secret',
    http.Client? client,
    Duration readIdleTimeout = WebdavClient.defaultReadIdleTimeout,
    Duration readDeadline = WebdavClient.defaultReadDeadline,
  }) {
    final webdav = WebdavClient(
      config: configFor(),
      password: password,
      client: client,
      timeout: const Duration(seconds: 5),
      readIdleTimeout: readIdleTimeout,
      readDeadline: readDeadline,
    );
    // Left open, an idle connection outlives the assertions it belongs to.
    addTearDown(webdav.close);
    return webdav;
  }

  group('collection', () {
    test('accepts an existing collection', () async {
      await clientFor().ensureCollection();
      expect(server.methods, ['PROPFIND']);
      expect(server.headers['PROPFIND']!['depth'], '0');
      expect(server.propfindBody, contains('propfind'));
      expect(server.propfindBody, contains('DAV:'));
      // 坚果云在 prop 里少了 resourcetype 就完全不返回 getetag，而且不报错 ——
      // 客户端只会安静地退化成无保护写入。这条断言把它钉住。
      expect(server.propfindBody, contains('getetag'));
      expect(server.propfindBody, contains('resourcetype'));
      expect(server.headers['PROPFIND']!['authorization'], _FakeServer.credentials);
    });

    test('creates a collection that is not there yet', () async {
      server.collectionExists = false;
      await clientFor().ensureCollection();
      expect(server.methods, ['PROPFIND', 'MKCOL']);
      expect(server.collectionExists, isTrue);
    });

    test('reports a server that does not speak WebDAV', () async {
      server.forcedStatus = 405;
      await expectLater(
        clientFor().ensureCollection(),
        throwsA(
          isA<WebdavException>().having(
            (error) => error.message,
            'message',
            contains('不支持 WebDAV'),
          ),
        ),
      );
    });

    test('reports a refused directory creation', () async {
      server.collectionExists = false;
      server.allowCreate = false;
      await expectLater(
        clientFor().ensureCollection(),
        throwsA(
          isA<WebdavException>().having(
            (error) => error.message,
            'message',
            contains('拒绝访问'),
          ),
        ),
      );
    });

    test('sends no credentials when the account is empty', () async {
      server.requireCredentials = false;
      final client = WebdavClient(
        config: configFor(username: ''),
        password: '',
        timeout: const Duration(seconds: 5),
      );
      addTearDown(client.close);
      await client.ensureCollection();
      expect(server.headers['PROPFIND']!.containsKey('authorization'), isFalse);
    });
  });

  group('credentials', () {
    test('a wrong password is reported as an authentication failure', () async {
      await expectLater(
        clientFor(password: 'wrong').ensureCollection(),
        throwsA(
          isA<WebdavException>()
              .having((error) => error.statusCode, 'statusCode', 401)
              .having((error) => error.message, 'message', contains('认证失败')),
        ),
      );
    });
  });

  group('snapshot file', () {
    test('download reports a missing file as absent', () async {
      expect(await clientFor().download(), isNull);
      expect(server.methods, ['GET']);
    });

    test('download returns the bytes and the server timestamp', () async {
      server.files[server.path] = utf8.encode('{"format":"fqapp.library-backup"}');
      final remote = await clientFor().download();
      expect(remote, isNotNull);
      expect(
        utf8.decode(remote!.bytes),
        '{"format":"fqapp.library-backup"}',
      );
      expect(remote.modified, DateTime.utc(2026, 1, 2, 3, 4, 5));
    });

    test('remoteFile reads the version without downloading the body', () async {
      // 打开应用时的检查只该问一句「是哪一版」，不该把整份备份拉下来。
      server.files[server.path] = utf8.encode('{"version":3}');
      final remote = await clientFor().remoteFile();
      expect(remote, isNotNull);
      expect(remote!.etag, 'etag-1');
      expect(remote.versionKey, 'etag-1');
      expect(remote.size, '{"version":3}'.length);
      expect(remote.modified, DateTime.utc(2026, 1, 2, 3, 4, 5));
      expect(server.methods, ['PROPFIND']);
      expect(server.methods, isNot(contains('GET')));
    });

    test('remoteFile reports a missing file as absent', () async {
      expect(await clientFor().remoteFile(), isNull);
      expect(server.methods, ['PROPFIND']);
    });

    test('upload sends the snapshot the server then stores', () async {
      final bytes = Uint8List.fromList(utf8.encode('{"version":2}'));
      await clientFor().upload(bytes);
      expect(server.lastPutBody, bytes);
      expect(server.files[server.path], bytes);
      expect(
        server.headers['PUT']!['content-type'],
        contains('application/json'),
      );
    });

    test('a server that refuses a file here points at the folder', () async {
      // The collection exists and the credentials are accepted, so the 404 is
      // about where the file would go. Nutstore answers exactly this for a PUT
      // at its WebDAV root, and the message has to name the fix rather than
      // leave the user re-checking a password that is already correct.
      server.allowCreateFile = false;
      await expectLater(
        clientFor().upload(Uint8List.fromList(utf8.encode('{"version":2}'))),
        throwsA(
          isA<WebdavException>()
              .having((error) => error.statusCode, 'statusCode', 404)
              .having((error) => error.message, 'message', contains('坚果云'))
              // The refused address travels with the advice, so the root of
              // the drive is visible as the cause without reading a log.
              .having(
                (error) => error.message,
                'message',
                contains('${server.origin}${server.path}'),
              ),
        ),
      );
    });

    test('an oversized response is refused instead of buffered', () async {
      server.largeBodyBytes = 300 * 1024;
      await expectLater(
        clientFor().ensureCollection(),
        throwsA(
          isA<WebdavException>().having(
            (error) => error.message,
            'message',
            contains('已停止读取'),
          ),
        ),
      );
    });

    test('a body that stalls is abandoned instead of hanging forever', () async {
      // 服务器把响应头发完就沉默。没有自己的读超时，这条请求会永远挂着，
      // 而同步队列是串行的 —— 之后每一次同步都排在它后面，页面上只剩转圈。
      final silent = _SilentClient();
      addTearDown(silent.dispose);
      await expectLater(
        clientFor(
          client: silent,
          readIdleTimeout: const Duration(milliseconds: 150),
        ).remoteFile(),
        throwsA(
          isA<WebdavException>().having(
            (error) => error.message,
            'message',
            contains('没有返回数据'),
          ),
        ),
      );
    });

    test('a body that drips too slowly hits the read deadline', () async {
      // 每块都不超时，但整段拖得太久：分块计时发现不了，只有总时长能。
      final silent = _SilentClient();
      addTearDown(silent.dispose);
      await expectLater(
        clientFor(
          client: silent,
          readIdleTimeout: const Duration(seconds: 30),
          readDeadline: const Duration(milliseconds: 150),
        ).remoteFile(),
        throwsA(
          isA<WebdavException>().having(
            (error) => error.message,
            'message',
            contains('仍未完成'),
          ),
        ),
      );
    });
  });

  group('conditional write', () {
    Uint8List body(String text) => Uint8List.fromList(utf8.encode(text));

    test('sends the version it read as If-Match, verbatim', () async {
      // 原样透传：坚果云只认裸 token，按 RFC 补引号会一律 412。
      server.files[server.path] = body('{"v":1}');
      final tag = (await clientFor().remoteFile())!.versionKey!;

      await clientFor().upload(body('{"v":2}'), ifMatch: tag);

      expect(server.headers['PUT']!['if-match'], tag);
      expect(server.headers['PUT']!['if-match'], isNot(startsWith('"')));
    });

    test('an outdated version is refused with 412 and changes nothing', () async {
      server.files[server.path] = body('{"v":1}');
      final stale = (await clientFor().remoteFile())!.versionKey!;

      // 另一台设备先写了一版：云端内容与版本都前进了。
      await clientFor().upload(body('{"v":2}'));
      final before = server.files[server.path]!;

      await expectLater(
        clientFor().upload(body('{"v":3}'), ifMatch: stale),
        throwsA(
          isA<WebdavException>()
              .having((error) => error.statusCode, 'statusCode', 412)
              .having((error) => error.message, 'message', contains('已被其它设备更新')),
        ),
      );

      expect(server.rejectedByIfMatch, 1);
      expect(server.files[server.path], before, reason: '被拒的写不能落盘');
    });

    test('the current version is accepted', () async {
      server.files[server.path] = body('{"v":1}');
      final tag = (await clientFor().remoteFile())!.versionKey!;

      await clientFor().upload(body('{"v":2}'), ifMatch: tag);

      expect(server.rejectedByIfMatch, 0);
      expect(server.files[server.path], body('{"v":2}'));
    });

    test('returns the new version when the server sends one', () async {
      server.sendEtagOnPut = true;

      final returned = await clientFor().upload(body('{"v":1}'));

      expect(returned, isNotNull);
      expect(returned, server.etags[server.path]);
    });

    test('returns null when the server sends no ETag on PUT', () async {
      // 坚果云就是这样：写完必须回读一次才知道新版本，调用方据此决定。
      expect(await clientFor().upload(body('{"v":1}')), isNull);
    });

    test('uploads without If-Match when the caller has no version', () async {
      await clientFor().upload(body('{"v":1}'));
      expect(server.headers['PUT']!.containsKey('if-match'), isFalse);
    });
  });

  group('rename and delete', () {
    Uint8List body(String text) => Uint8List.fromList(utf8.encode(text));

    test('move renames the file and removes the source', () async {
      server.files[server.path] = body('payload');

      await clientFor().move(from: null, to: 'fqapp-sync.json.bak');

      expect(server.files[server.path], isNull);
      expect(server.files['/dav/fqapp-sync.json.bak'], body('payload'));
      expect(
        server.headers['MOVE']!['destination'],
        endsWith('/dav/fqapp-sync.json.bak'),
      );
    });

    test('move onto an existing file is refused, not silently merged', () async {
      // 坚果云回 409，Overwrite 头不认。三步替换必须先删掉上一轮的 .bak，
      // 否则每次同步都会在这里失败。
      server.files[server.path] = body('current');
      server.files['/dav/fqapp-sync.json.bak'] = body('stale');

      await expectLater(
        clientFor().move(from: null, to: 'fqapp-sync.json.bak'),
        throwsA(
          isA<WebdavException>().having(
            (error) => error.message,
            'message',
            contains('目标文件已存在'),
          ),
        ),
      );
      expect(server.files[server.path], body('current'), reason: '源文件不该动');
    });

    test('delete removes the file and tolerates a missing one', () async {
      server.files['/dav/fqapp-sync.json.tmp'] = body('junk');

      await clientFor().delete(name: 'fqapp-sync.json.tmp');
      expect(server.files['/dav/fqapp-sync.json.tmp'], isNull);

      // 重试或另一台设备先删了：404 不该变成失败。
      await expectLater(
        clientFor().delete(name: 'fqapp-sync.json.tmp'),
        completes,
      );
    });
  });

  group('redirects', () {
    test('are reported with the target instead of being followed', () async {
      // Following a 301 replays PUT as another method, which would look like a
      // successful upload; the message has to name the address to use.
      server.redirectLocation = 'https://dav.example.com/dav/';
      await expectLater(
        clientFor().download(),
        throwsA(
          isA<WebdavException>()
              .having((error) => error.message, 'message', contains('跳转'))
              .having(
                (error) => error.message,
                'message',
                contains('https://dav.example.com/dav/'),
              ),
        ),
      );
      expect(server.methods, ['GET']);
    });
  });
}
