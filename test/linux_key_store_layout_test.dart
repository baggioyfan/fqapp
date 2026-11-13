import 'dart:ffi';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:fqapp/services/linux_libsecret_key_store.dart';

/// The Linux backend talks to libsecret through hand-written FFI. A wrong
/// struct layout or a symbol loaded from the wrong library breaks key access.
void main() {
  test('SecretSchema matches the libsecret 64-bit ABI', () {
    expect(LinuxLibsecretKeyStore.debugSecretSchemaSize, 592);
    expect(
      LinuxLibsecretKeyStore.debugSecretSchemaAttributeSize,
      16,
    );
  });

  test(
    'Linux libraries provide all production FFI bindings',
    () => expect(
      LinuxLibsecretKeyStore.debugValidateNativeBindings,
      returnsNormally,
    ),
    // Being on Linux is not the same as having the libraries: the Dart checks
    // run on a bare ubuntu runner (no libsecret) while the Arch container is
    // where the real bindings are exercised. Probing first keeps this test
    // honest instead of failing on a missing system package.
    skip: !Platform.isLinux || !_hasLibsecret,
  );
}

bool get _hasLibsecret {
  for (final name in const [
    'libsecret-1.so.0',
    'libglib-2.0.so.0',
    'libgobject-2.0.so.0',
  ]) {
    try {
      DynamicLibrary.open(name);
    } catch (_) {
      return false;
    }
  }
  return true;
}
