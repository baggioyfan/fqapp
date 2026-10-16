import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

/// Guards the name Android shows for the launcher icon, the recents card and
/// the system app-info screen.
///
/// Nothing else in the suite reads it, so the previous release shipped as the
/// placeholder `fqapp`: a Dart test cannot see a resource reference, and the
/// APK checks only compare package, version and SDK levels. Pinning the
/// manifest wiring and the shipped value here is what makes the next rename a
/// deliberate edit instead of a silent regression.
void main() {
  const displayName = '番茄小铺';

  test('manifest resolves the launcher label from app_name', () {
    final manifest = File(
      'android/app/src/main/AndroidManifest.xml',
    ).readAsStringSync();
    expect(manifest, contains('android:label="@string/app_name"'));
    expect(
      manifest,
      isNot(contains('android:label="fqapp"')),
      reason: 'a literal label stops tracking the resource',
    );
  });

  test('app_name is the shipping display name', () {
    final strings = File(
      'android/app/src/main/res/values/strings.xml',
    ).readAsStringSync();
    expect(
      strings,
      contains('<string name="app_name">$displayName</string>'),
      reason: 'this is the name the launcher shows after install',
    );
  });
}
