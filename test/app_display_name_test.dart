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

  test('the in-app brand strings read $displayName', () {
    // The About header is the one that slipped. Rebasing onto upstream 1.0.118
    // stopped on a version-line conflict there, and resolving that file with
    // `git checkout --ours` takes the whole file from the rebase target, so the
    // header silently went back to the placeholder `fqapp` with no conflict
    // marker to notice. No check read that header, so only a hand comparison of
    // the diff against upstream showed it was gone.
    for (final path in const [
      'lib/main.dart',
      'lib/pages/about_page.dart',
      'lib/widgets/home/home_hero.dart',
    ]) {
      expect(
        File(path).readAsStringSync(),
        contains(displayName),
        reason: '$path shows the app name to the user',
      );
    }
  });
}
