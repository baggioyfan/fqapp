import 'package:flutter/foundation.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:fqapp/services/desktop_platform.dart';
import 'package:fqapp/services/platform_channel.dart';

/// 守的是「macOS / Linux 的在线播放有没有被换基底顺手砍掉」。
///
/// 2026-11-23 的 `6d1efa5b`（桌面端整体换上游 Fluent 基底）把
/// `DesktopPlatform.initialize` 的首行守卫从 `isDesktopHost` 改成了
/// `isWindowsDesktop`：macOS 与 Linux 从此不再装配 `PlatformChannels`，
/// `NativePlayer.create` 退回真正的 MethodChannel 并抛
/// `MissingPluginException`（create 1 ms 内失败），表现就是「每一集都播不起来」。
/// 而全量 `flutter test` 依然全绿 —— 没有任何用例盯着这段装配。
void main() {
  // `DesktopPlatform.instance` 首次构造时会 new FlutterTts()，它内部立刻
  // `setMethodCallHandler`，没有 binding 会直接断言失败 —— 这不是被测逻辑的
  // 问题，纯属取单例前的环境准备。
  TestWidgetsFlutterBinding.ensureInitialized();

  group('桌面平台通道装配', () {
    setUp(() {
      PlatformChannels.invoke = null;
      PlatformChannels.events = null;
    });

    tearDown(() {
      debugDefaultTargetPlatformOverride = null;
      PlatformChannels.invoke = null;
      PlatformChannels.events = null;
    });

    test('macOS 必须装配 —— 播放与听书都挂在这两个回调上', () {
      debugDefaultTargetPlatformOverride = TargetPlatform.macOS;

      expect(
        DesktopPlatform.instance.installPlatformChannels(),
        isTrue,
        reason: 'macOS 被跳过了：NativePlayer 会退回真 MethodChannel，每集都播不起来',
      );
      expect(PlatformChannels.invoke, isNotNull);
      expect(PlatformChannels.events, isNotNull);
    });

    test('Linux 同样必须装配', () {
      debugDefaultTargetPlatformOverride = TargetPlatform.linux;

      expect(DesktopPlatform.instance.installPlatformChannels(), isTrue);
      expect(PlatformChannels.invoke, isNotNull);
      expect(PlatformChannels.events, isNotNull);
    });

    test('Android 不装配 —— 那边就是真 MethodChannel 的 ExoPlayer', () {
      debugDefaultTargetPlatformOverride = TargetPlatform.android;

      expect(DesktopPlatform.instance.installPlatformChannels(), isFalse);
      expect(PlatformChannels.invoke, isNull);
      expect(PlatformChannels.events, isNull);
    });
  });
}
