import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:fqapp/models/media_item.dart';
import 'package:fqapp/pages/reader_page.dart';
import 'package:fqapp/services/reader_device.dart';
import 'package:fqapp/widgets/reader/reader_brightness_hud.dart';

import 'support/fakes.dart';

/// 翻页模式下的「上下滑调亮度」。
///
/// 这里钉的是接线而不是手感：上滑必须下发更亮的窗口亮度、下滑必须变暗、
/// 轻点（没有位移）不能顺手改掉偏好。滚动模式不挂这条手势（那里竖滑是
/// 滚正文），见实现里的 `_paged` 条件。
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  setUp(() {
    SharedPreferences.setMockInitialValues({});
  });

  testWidgets('翻页模式上滑变亮，拖动期间有亮度浮层', (tester) async {
    final device = _RecordingDevice();
    await _mount(tester, device);

    await tester.dragFrom(_surfaceCenter(tester), const Offset(0, -160));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 200));

    expect(device.brightness, isNotEmpty, reason: '上滑必须下发亮度');
    expect(
      device.brightness.last,
      greaterThan(.45),
      reason: '上滑是变亮：起手系统亮度 .45',
    );
    final hud = tester.widget<AnimatedOpacity>(
      find.descendant(
        of: find.byType(ReaderBrightnessHud),
        matching: find.byType(AnimatedOpacity),
      ),
    );
    expect(hud.opacity, 1, reason: '拖动时要显示亮度浮层');

    await tester.pumpWidget(const SizedBox.shrink());
  });

  testWidgets('翻页模式下滑变暗', (tester) async {
    final device = _RecordingDevice();
    await _mount(tester, device);

    await tester.dragFrom(_surfaceCenter(tester), const Offset(0, 160));
    await tester.pump();

    expect(device.brightness, isNotEmpty, reason: '下滑也要下发亮度');
    expect(
      device.brightness.last,
      lessThan(.45),
      reason: '下滑是变暗：起手系统亮度 .45',
    );
    expect(
      device.brightness.last,
      greaterThan(0),
      reason: '短距离下滑只走一段，不该一碰就掉到最暗',
    );

    // 一路拖到底：屏高六成的量程（这里 480*.6=288）之外继续下滑必须夹在下限上。
    // 以前跌到 2% 就停，暗环境里仍然刺眼；现在要能真正压到 0（面板最暗）。
    await tester.dragFrom(_surfaceCenter(tester), const Offset(0, 600));
    await tester.pump();

    expect(
      device.brightness.last,
      0,
      reason: '下滑到底要能压到 0（面板最暗）：以前夹在 2%，暗环境里仍然刺眼',
    );

    await tester.pumpWidget(const SizedBox.shrink());
  });

  testWidgets('轻点不碰亮度', (tester) async {
    final device = _RecordingDevice();
    await _mount(tester, device);

    await tester.tapAt(_surfaceCenter(tester));
    await tester.pump(const Duration(milliseconds: 400));

    expect(device.brightness, isEmpty, reason: '没有位移的手势不算调亮度');

    await tester.pumpWidget(const SizedBox.shrink());
  });

  testWidgets('浮层收到亮度后自行淡出', (tester) async {
    final value = ValueNotifier<double?>(null);
    addTearDown(value.dispose);
    await _mountHud(tester, value);

    value.value = .6;
    await tester.pump();

    expect(find.text('60%'), findsOneWidget);

    await tester.pump(const Duration(milliseconds: 320));
    await tester.pump(const Duration(milliseconds: 200));
    expect(
      tester.widget<AnimatedOpacity>(find.byType(AnimatedOpacity)).opacity,
      0,
      reason: '到时必须淡出，否则会一直挡着正文',
    );

    await tester.pumpWidget(const SizedBox.shrink());
  });

  testWidgets('挂载时亮度已非空，浮层同样会自己淡出', (tester) async {
    // 回归：initState 里只设「可见」不排计时，页面重建后浮层会永久留着。
    final value = ValueNotifier<double?>(.6);
    addTearDown(value.dispose);
    await _mountHud(tester, value);

    expect(find.text('60%'), findsOneWidget);

    await tester.pump(const Duration(milliseconds: 320));
    await tester.pump(const Duration(milliseconds: 200));
    expect(
      tester.widget<AnimatedOpacity>(find.byType(AnimatedOpacity)).opacity,
      0,
      reason: '挂载路径也要排自动隐藏，否则浮层永远消不掉',
    );

    await tester.pumpWidget(const SizedBox.shrink());
  });
}

final _surface = find.byKey(const ValueKey('reader-page-surface'));

/// 单独挂浮层：不牵整页，只钉「显示 / 自动隐藏」这一层时序。
Future<void> _mountHud(WidgetTester tester, ValueNotifier<double?> value) async {
  await tester.pumpWidget(
    MaterialApp(
      home: Stack(
        children: [
          Positioned.fill(
            child: ReaderBrightnessHud(
              value: value,
              autoHide: const Duration(milliseconds: 300),
            ),
          ),
        ],
      ),
    ),
  );
  await tester.pump();
}

Offset _surfaceCenter(WidgetTester tester) => tester.getRect(_surface).center;

const _body =
    '清晨的风从窗边吹来，带着山间草木的清香。林舟推开木窗，看见远处的云正慢慢越过山脊。'
    '他想起许多年前也是这样的天气，父亲背着猎枪出门，回来时带着一身露水。'
    '那时候他还不懂什么叫告别，只觉得山里的春天太长，长到可以浪费。';

final _chapters = [
  Chapter(itemId: 'c1', title: '第一章 山间来信', volumeName: '正文'),
];

String _text() =>
    '<header><div class="tt-title">第一章 山间来信</div></header><article>'
    '<p idx="0">$_body</p>'
    '</article>';

Future<void> _mount(WidgetTester tester, ReaderDevice device) async {
  await tester.binding.setSurfaceSize(const Size(320, 480));
  addTearDown(() => tester.binding.setSurfaceSize(null));
  await tester.pumpWidget(
    MaterialApp(
      home: ReaderPage(
        bookId: 'b1',
        title: '山川来信',
        chapters: _chapters,
        startIndex: 0,
        localOnly: true,
        readerStore: MemoryReaderStore(),
        chapterCache: MemoryChapterCache(),
        chapterLoader: (chapter) async => _text(),
        readerDevice: device,
      ),
    ),
  );
  await tester.pumpAndSettle();
}

/// 记录亮度下发的假设备：`start` 返回非空状态，页面才会认为原生桥可用。
class _RecordingDevice extends ReaderDevice {
  final List<double> brightness = [];

  @override
  Stream<ReaderDeviceStatus> get changes => const Stream.empty();

  @override
  Future<ReaderDeviceStatus?> start({
    required bool followSystem,
    required double brightness,
  }) async => ReaderDeviceStatus(
    time: DateTime(2026, 11, 10),
    battery: 64,
    systemBrightness: .45,
  );

  @override
  Future<bool> setBrightness({
    required bool followSystem,
    required double brightness,
  }) async {
    this.brightness.add(brightness);
    return true;
  }

  @override
  Future<void> keepScreenOn(bool on) async {}

  @override
  Future<void> setImmersive(
    bool enabled, {
    bool showStatusBar = false,
    bool showNavigationBar = false,
  }) async {}

  @override
  Future<void> suspend() async {}

  @override
  Future<void> close() async {}
}
