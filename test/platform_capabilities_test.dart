import 'package:flutter/foundation.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:fqapp/services/desktop_platform.dart';
import 'package:fqapp/services/platform_capabilities.dart';

/// 视频入口的平台白名单（`supportsVideoPlayback`）。
///
/// 这份用例的由来：v1.0.204-fq1 的 macOS 包点视频只弹「当前平台暂不支持
/// 视频播放」，短剧 tab 整页变成占位页。根因不是播放器缺失（media_kit +
/// libmpv 都在包里），而是这个判断直接继承了上游那份——上游只有 Android
/// 与 Windows 两个平台，fork 合进来时没把 macOS 补进白名单。
///
/// 当时 `test/detail_page_test.dart` 的平台矩阵只跑 linux / android /
/// windows，`supportsVideoPlayback` 本身一条用例都没有，所以这次回归
/// 没有任何测试会红。下面的矩阵就是补这个洞：白名单三端必须为真，
/// iOS / Linux 必须为假，且不能退化成 `isDesktopHost`（那会把 Linux
/// 一起放进来，撞上游 `8022c8cd` 的 Linux 门禁用例）。
void main() {
  tearDown(() => debugDefaultTargetPlatformOverride = null);

  for (final platform in [
    TargetPlatform.android,
    TargetPlatform.windows,
    TargetPlatform.macOS,
  ]) {
    test('${platform.name} 放行视频播放', () {
      debugDefaultTargetPlatformOverride = platform;
      expect(supportsVideoPlayback, isTrue);
    });
  }

  for (final platform in [
    TargetPlatform.iOS,
    TargetPlatform.linux,
    TargetPlatform.fuchsia,
  ]) {
    test('${platform.name} 不放行视频播放', () {
      debugDefaultTargetPlatformOverride = platform;
      expect(supportsVideoPlayback, isFalse);
    });
  }

  test('macOS 与 Windows 走同一套桌面实现，必须一起放行', () {
    debugDefaultTargetPlatformOverride = TargetPlatform.macOS;
    expect(isMacDesktop, isTrue);
    expect(isDesktopHost, isTrue);
    expect(supportsVideoPlayback, isTrue);

    debugDefaultTargetPlatformOverride = TargetPlatform.windows;
    expect(isWindowsDesktop, isTrue);
    expect(supportsVideoPlayback, isTrue);
  });

  test('桌面端不等于全部放行：Linux 仍是桌面端但不在白名单', () {
    // 这条专门挡住「图省事写成 isDesktopHost」的改法：那样 Linux 会跟着
    // 放行，而上游 `8022c8cd` 的用例明确要求 Linux 在跳转前就拒绝。
    debugDefaultTargetPlatformOverride = TargetPlatform.linux;
    expect(isDesktopHost, isTrue);
    expect(supportsVideoPlayback, isFalse);
  });

  test('Android 不是桌面端，但仍靠原生播放器在名单里', () {
    debugDefaultTargetPlatformOverride = TargetPlatform.android;
    expect(isDesktopHost, isFalse);
    expect(supportsVideoPlayback, isTrue);
  });
}
