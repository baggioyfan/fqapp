import 'dart:convert';
import 'dart:ffi';
import 'dart:io';
import 'dart:isolate';
import 'package:ffi/ffi.dart';

typedef _OpenNative = Pointer<Utf8> Function(Pointer<Utf8>);
typedef _Open = Pointer<Utf8> Function(Pointer<Utf8>);
typedef _FreeNative = Void Function(Pointer<Utf8>);
typedef _Free = void Function(Pointer<Utf8>);

/// The core ships beside the executable on every desktop host: `fqapp.exe`
/// next to `fqapi_core.dll` on Windows, `Contents/MacOS/fqapp` next to
/// `libfqapi_core.dylib` inside the macOS bundle.
String desktopCoreLibraryPath() {
  final name = Platform.isMacOS ? 'libfqapi_core.dylib' : 'fqapi_core.dll';
  final bundled = File(
    '${File(Platform.resolvedExecutable).parent.path}/$name',
  );
  if (bundled.existsSync()) return bundled.path;
  return File('rust/target/release/$name').absolute.path;
}

class DesktopMedia {
  DesktopMedia._(this.id, this.url, this.libraryPath);
  final String id;
  final String url;
  final String libraryPath;
  bool _closed = false;

  static Future<DesktopMedia> open(String url, String key) async {
    final path = desktopCoreLibraryPath();
    // Metadata probing performs synchronous native I/O, away from the UI isolate.
    final result = await Isolate.run(() {
      final lib = DynamicLibrary.open(path);
      final open = lib.lookupFunction<_OpenNative, _Open>(
        'fq_desktop_media_open',
      );
      final free = lib.lookupFunction<_FreeNative, _Free>(
        'fq_desktop_media_free',
      );
      final request = jsonEncode({'url': url, 'key': key}).toNativeUtf8();
      try {
        final response = open(request);
        if (response == nullptr) throw StateError('无法创建媒体会话');
        try {
          return jsonDecode(response.toDartString()) as Map<String, dynamic>;
        } finally {
          free(response);
        }
      } finally {
        calloc.free(request);
      }
    });
    if (result['error'] case final String error) throw StateError(error);
    return DesktopMedia._(
      result['id'] as String,
      result['url'] as String,
      path,
    );
  }

  void close() {
    if (_closed) return;
    _closed = true;
    final lib = DynamicLibrary.open(libraryPath);
    final close = lib.lookupFunction<_FreeNative, _Free>(
      'fq_desktop_media_close',
    );
    final value = id.toNativeUtf8();
    try {
      close(value);
    } finally {
      calloc.free(value);
    }
  }
}
