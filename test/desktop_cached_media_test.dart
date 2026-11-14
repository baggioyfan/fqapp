import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

import 'package:fqapp/services/desktop_media.dart';
import 'package:fqapp/services/drama_download_store.dart';

// 由 scripts/verify_windows_media.py 生成 CENC 样本后，靠环境变量显式开启；
// 只在 Windows 上跑（其它平台没有那套原生解密桥）。
void main() {
  final encryptedPath = Platform.environment['FQAPP_TEST_ENCRYPTED_MEDIA'];
  final decryptedPath = Platform.environment['FQAPP_TEST_DECRYPTED_MEDIA'];

  test(
    'Windows 缓存的同剧多集都能经原生 CENC 桥完整读取与按段 seek',
    () async {
      final root = await Directory.systemTemp.createTemp('fqapp-缓存 #100%-');
      final client = HttpClient()
        ..connectionTimeout = const Duration(seconds: 5);
      try {
        final encrypted = await File(encryptedPath!).readAsBytes();
        final expected = await File(decryptedPath!).readAsBytes();
        final sources = <CachedEpisode>[];
        for (var index = 0; index < 6; index++) {
          final file = File('${root.path}/第 ${index + 1} 集.mp4');
          await file.writeAsBytes(encrypted);
          sources.add(
            CachedEpisode(
              seriesId: 'windows-cached-media',
              itemId: 'episode-$index',
              title: '第 ${index + 1} 集',
              index: index,
              keyHex: '00112233445566778899aabbccddeeff',
              height: 96,
              variantName: 'fixture',
              bytes: encrypted.length,
              filePath: file.path,
              cachedAt: 0,
              auto: true,
            ),
          );
        }
        // 乱序取，确认每集拼出的 file URI 都指回自己那份文件（盘符/反斜杠/
        // 空格/`#`/中文都在路径里，任何一处没编码都会串集）。
        for (final index in [1, 4, 0, 5, 2, 3, 1]) {
          final source = sources[index].toSource();
          final session = await DesktopMedia.open(source.url, source.keyHex);
          try {
            final request = await client.getUrl(Uri.parse(session.url));
            final response = await request.close();
            expect(response.statusCode, HttpStatus.ok);
            final bytes = await response.fold<List<int>>(
              <int>[],
              (bytes, chunk) => bytes..addAll(chunk),
            );
            expect(bytes, expected, reason: 'cached episode $index');
            final seek = await client.getUrl(Uri.parse(session.url));
            seek.headers.set(HttpHeaders.rangeHeader, 'bytes=1024-2047');
            final partial = await seek.close();
            expect(partial.statusCode, HttpStatus.partialContent);
            final range = await partial.fold<List<int>>(
              <int>[],
              (bytes, chunk) => bytes..addAll(chunk),
            );
            expect(range, expected.sublist(1024, 2048));
          } finally {
            session.close();
          }
        }
      } finally {
        client.close(force: true);
        await root.delete(recursive: true);
      }
    },
    skip: !Platform.isWindows || encryptedPath == null || decryptedPath == null
        ? 'Set FQAPP_TEST_ENCRYPTED_MEDIA and FQAPP_TEST_DECRYPTED_MEDIA on Windows'
        : false,
    timeout: const Timeout(Duration(seconds: 60)),
  );
}
