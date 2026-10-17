import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';

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
    for (final name in ['authorization', 'depth', 'content-type']) {
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
        // 针对快照文件本身的 PROPFIND：只回时间戳，正文里带 getlastmodified。
        if (files[request.uri.path] == null) {
          response.statusCode = 404;
        } else {
          response.statusCode = 207;
          response.headers.contentType = ContentType(
            'application',
            'xml',
            charset: 'utf-8',
          );
          response.write(
            '<?xml version="1.0" encoding="utf-8"?>'
            '<d:multistatus xmlns:d="DAV:"><d:response><d:propstat><d:prop>'
            '<d:getlastmodified>'
            '${HttpDate.format(DateTime.utc(2026, 1, 2, 3, 4, 5))}'
            '</d:getlastmodified>'
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
      if (!allowCreateFile) {
        // What Nutstore answers for a PUT that would create a file at its
        // WebDAV root: the collection exists, the file is still refused.
        response.statusCode = 404;
      } else {
        files[request.uri.path] = lastPutBody;
        response.statusCode = 201;
      }
    } else {
      response.statusCode = 405;
    }
    await response.close();
  }
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

  WebdavClient clientFor({String password = 'secret'}) {
    final client = WebdavClient(
      config: configFor(),
      password: password,
      timeout: const Duration(seconds: 5),
    );
    // Left open, an idle connection outlives the assertions it belongs to.
    addTearDown(client.close);
    return client;
  }

  group('collection', () {
    test('accepts an existing collection', () async {
      await clientFor().ensureCollection();
      expect(server.methods, ['PROPFIND']);
      expect(server.headers['PROPFIND']!['depth'], '0');
      expect(server.propfindBody, contains('propfind'));
      expect(server.propfindBody, contains('DAV:'));
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

    test('remoteModified reads the timestamp without downloading', () async {
      // 打开应用时的检查只该问一句「什么时候改的」，不该把整份备份拉下来。
      server.files[server.path] = utf8.encode('{"version":3}');
      expect(
        await clientFor().remoteModified(),
        DateTime.utc(2026, 1, 2, 3, 4, 5),
      );
      expect(server.methods, ['PROPFIND']);
      expect(server.methods, isNot(contains('GET')));
    });

    test('remoteModified reports a missing file as absent', () async {
      expect(await clientFor().remoteModified(), isNull);
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
