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
  const displayName = '什锦铺';

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
    // 上游 1995d74 把首页顶栏（home_hero）的品牌标题整块换成了搜索行，那里
    // 已经没有应用名，继续断言会让每次合并都红一次、然后被人顺手删掉整组。
    // 换成 desktop_app_frame：左侧导航栏顶部那块是 macOS 上用户实际看到的
    // 品牌位，比首页顶栏更该被守住。
    for (final path in const [
      'lib/main.dart',
      'lib/pages/about_page.dart',
      'lib/widgets/desktop_app_frame.dart',
    ]) {
      expect(
        File(path).readAsStringSync(),
        contains(displayName),
        reason: '$path shows the app name to the user',
      );
    }
  });
}
