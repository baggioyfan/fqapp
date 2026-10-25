import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:fqapp/models/media_item.dart';
import 'package:fqapp/services/platform_channel.dart';
import 'package:fqapp/services/player_style_config.dart';
import 'package:fqapp/widgets/video_player_chrome.dart';

import 'support/fakes.dart';

/// 全屏竖滑：左半屏亮度、右半屏音量。
///
/// 亮度走 `fqapp/player/display` 通道（只有 Android 实现），所以这里用
/// `debugDefaultTargetPlatformOverride` 假装成 Android，并把
/// `PlatformChannels.invoke` 换成记录用的假实现——不必碰 binary messenger。
void main() {
  late List<double> brightnessWrites;
  late List<String> channelCalls;

  setUp(() {
    SharedPreferences.setMockInitialValues({});
    brightnessWrites = <double>[];
    channelCalls = <String>[];
    debugDefaultTargetPlatformOverride = TargetPlatform.android;
    PlatformChannels.invoke = (channel, method, args) async {
      channelCalls.add('$channel#$method');
      switch (method) {
        case 'begin':
          return 0.4;
        case 'setBrightness':
          brightnessWrites.add((args as Map)['brightness'] as double);
          return true;
      }
      return null;
    };
  });

  tearDown(() {
    debugDefaultTargetPlatformOverride = null;
    PlatformChannels.invoke = null;
    PlayerStyleConfig.instance = PlayerStyleConfig.defaults;
  });

  testWidgets('全屏左半屏向上滑提亮，值从原生给的起点累加', (tester) async {
    tester.view.physicalSize = const Size(800, 400);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);

    final player = FakeNativePlayer();
    await tester.pumpWidget(_app(player, openFullScreen: true));
    await tester.pumpAndSettle();
    expect(
      channelCalls,
      contains('fqapp/player/display#begin'),
      reason: '进全屏要读一次系统亮度当起点',
    );

    // 左半屏、向上 150px：0.4 + 150/400 = 0.775
    await _slide(tester, const Offset(120, 300), -150);
    expect(brightnessWrites, isNotEmpty);
    expect(brightnessWrites.last, closeTo(0.775, 0.01));
    // 「满屏高 = 满量程」：位移到终点就停在上限，不会越过 1。
    expect(brightnessWrites.every((value) => value <= 1 && value >= 0.02), isTrue);

    await _teardown(tester);
  });

  testWidgets('全屏右半屏向下滑降音量', (tester) async {
    tester.view.physicalSize = const Size(800, 400);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);

    double? volume;
    final player = FakeNativePlayer();
    await tester.pumpWidget(
      _app(
        player,
        openFullScreen: true,
        volume: 0.5,
        onVolumeChanged: (value) => volume = value,
      ),
    );
    await tester.pumpAndSettle();

    // 右半屏、向下 100px：0.5 - 100/400 = 0.25
    await _slide(tester, const Offset(680, 150), 100);
    expect(volume, isNotNull);
    expect(volume, closeTo(0.25, 0.01));

    await _teardown(tester);
  });

  testWidgets('非全屏时竖滑不碰亮度，也不报音量', (tester) async {
    tester.view.physicalSize = const Size(400, 800);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);

    double? volume;
    final player = FakeNativePlayer();
    await tester.pumpWidget(
      _app(player, volume: 0.5, onVolumeChanged: (value) => volume = value),
    );
    await tester.pumpAndSettle();

    await _slide(tester, const Offset(100, 600), -200);
    expect(brightnessWrites, isEmpty);
    expect(volume, isNull);
    // 没进全屏就不该开亮度会话（那会把窗口亮度从系统值接管过来）。
    expect(channelCalls, isEmpty);

    await _teardown(tester);
  });
}

/// 竖直滑动 [dy] 像素。
///
/// 先用一次 25px 的位移吃掉 touch slop（drag start 记录的是越过 slop 之后的
/// 位置），之后的 [dy] 才完整计入，这样「满屏高 = 100%」的换算才能精确断言。
Future<void> _slide(WidgetTester tester, Offset start, double dy) async {
  final gesture = await tester.startGesture(start);
  await gesture.moveBy(Offset(0, dy.sign * 25));
  await tester.pump();
  await gesture.moveBy(Offset(0, dy));
  await tester.pump();
  await gesture.up();
  await tester.pump(const Duration(milliseconds: 700));
}

/// 测完拆掉组件树，让 chrome 的提示条/收起计时器随 dispose 一起取消；
/// 顺手把平台覆盖复位——组件测试在**测试体结束时**校验 foundation 的 debug
/// 变量，tearDown 在断言之后，来不及。
Future<void> _teardown(WidgetTester tester) async {
  await tester.pumpWidget(const SizedBox.shrink());
  await tester.pump(const Duration(milliseconds: 700));
  debugDefaultTargetPlatformOverride = null;
}

Widget _app(
  FakeNativePlayer player, {
  bool openFullScreen = false,
  double volume = 1,
  ValueChanged<double>? onVolumeChanged,
}) {
  final callback = onVolumeChanged;
  return MaterialApp(
    home: StreamBuilder<bool>(
      stream: player.playingStream,
      initialData: player.playing,
      builder: (context, playing) => VideoPlayerChrome(
        player: player,
        volume: volume,
        onPlaybackVolumeChanged: callback == null
            ? null
            : (value) async => callback(value),
        openFullScreen: openFullScreen,
        episodes: [
          Chapter(itemId: '1', title: '第一集', volumeName: ''),
          Chapter(itemId: '2', title: '第二集', volumeName: ''),
        ],
        currentIndex: 0,
        duration: player.duration,
        playing: playing.data!,
        onSelectEpisode: (_) async {},
        onError: (error) => throw error,
        child: const ColoredBox(color: Colors.black),
      ),
    ),
  );
}
