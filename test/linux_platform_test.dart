import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:hive_ce/hive.dart';

import 'package:fqapp/services/desktop_platform.dart';
import 'package:fqapp/services/encrypted_hive.dart';
import 'package:fqapp/services/linux_libsecret_key_store.dart';
import 'package:fqapp/services/secure_key_provider.dart';

/// P8/L1: the Linux desktop branch, exercised from any host CI.
///
/// `flutter test` forces `defaultTargetPlatform` to android (FLUTTER_TEST), so
/// the only way to reach the Linux branches here is
/// `debugDefaultTargetPlatformOverride`. What this proves is the *policy*:
/// Linux is a desktop host, it defaults to libsecret, and it refuses to open a
/// box in plaintext when the keyring gives nothing. Actual libsecret FFI needs
/// a real Linux box and is covered by the Arch container build, not here.
void main() {
  tearDown(() {
    debugDefaultTargetPlatformOverride = null;
  });

  group('desktop host detection', () {
    test('Linux counts as a desktop host', () {
      debugDefaultTargetPlatformOverride = TargetPlatform.linux;
      expect(isLinuxDesktop, isTrue);
      expect(isDesktopHost, isTrue);
    });

    test('Android is not a desktop host', () {
      debugDefaultTargetPlatformOverride = TargetPlatform.android;
      expect(isLinuxDesktop, isFalse);
      expect(isDesktopHost, isFalse);
    });

    test('isLinuxHost follows the real host OS, not the override', () {
      debugDefaultTargetPlatformOverride = TargetPlatform.linux;
      // The override must never be trusted for "which native library to load":
      // it would send a macOS test run looking for a .so.
      expect(isLinuxHost, Platform.isLinux);
    });
  });

  group('secure key storage default', () {
    test('Linux defaults to the libsecret backend', () {
      debugDefaultTargetPlatformOverride = TargetPlatform.linux;
      // Only the type is asserted: constructing the store does not touch FFI,
      // the dynamic libraries are opened lazily on the first read/write.
      expect(defaultSecureKeyStorage(), isA<LinuxLibsecretKeyStore>());
    });

    test('other platforms keep the plugin backend', () {
      debugDefaultTargetPlatformOverride = TargetPlatform.macOS;
      expect(defaultSecureKeyStorage(), isA<FlutterSecureKeyStorage>());
    });
  });

  group('fail closed without a key', () {
    late Directory dir;

    setUp(() async {
      dir = await Directory.systemTemp.createTemp('fqapp-linux-key-');
      Hive.init(dir.path);
    });

    tearDown(() async {
      await Hive.close();
      await dir.delete(recursive: true);
    });

    test('Linux refuses to open a box in plaintext', () async {
      debugDefaultTargetPlatformOverride = TargetPlatform.linux;
      final keys = SecureKeyProvider(storage: _ThrowingStorage());

      await expectLater(
        EncryptedHive.openBox<dynamic>(Hive, 'chapter_cache_v1', keys: keys),
        throwsA(isA<StateError>()),
      );

      // The whole point of failing closed: no plaintext box was created while
      // the caller was told the open failed.
      expect(Hive.isBoxOpen('chapter_cache_v1'), isFalse);
      final leftovers = dir
          .listSync()
          .where((e) => e.path.contains('chapter_cache_v1'))
          .toList();
      expect(leftovers, isEmpty);
    });
  });
}

class _ThrowingStorage implements SecureKeyStorage {
  @override
  Future<String?> read(String key) async =>
      throw StateError('keyring unavailable');

  @override
  Future<void> write(String key, String value) async =>
      throw StateError('keyring unavailable');
}
