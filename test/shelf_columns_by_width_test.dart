// 书架列数的回归守卫 —— 列数只能由「可用宽度」决定，不能看平台。
//
// 事故链（两次返工）：
//   2026-11-10 a7de14c0 / 70140cc1：书架宫格原来用 isDesktopHost（只认
//     Windows/macOS）决定是否按宽度加列，Android 平板恒 3 列，而隔壁短剧页
//     早已按宽度铺开。当时改成窗口宽度阈值，并收敛到 appIsWideLayout。
//   2026-11-23 6d1efa5b（桌面 Fluent 重构）：这个文件按上游语义整份重写，
//     列数条件又变回 `isDesktopHost ? 按宽度 : 固定 3`，11-10 的修复被静默
//     覆盖 —— 平板上书架回到 3 列，直到 11-24 用户发现。
//   2026-11-24 55b64efd / 77f52838：两条线各自改回纯宽度公式（宫格一格
//     168dp、双列一格 340dp，原固定值当下限），最终收敛成现在这版。
//
// 这里钉的是行为而不是实现：**列数只由可用宽度决定，不挂任何平台判据**。
// 只要有人再把列数绑到 isDesktopHost / defaultTargetPlatform，平板尺寸那几档
// 就会退回 3 列（双列退回 2 列），本用例立刻红。
//
// 期望值按公式手算后写死（不用公式再算一遍，否则改错公式也照样「通过」）：
//   宫格 floor((W-32)/168) 夹 3–8；双列 floor((W-32)/340) 夹 2–4。

import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:hive_ce/hive.dart';
import 'package:material_ui/material_ui.dart';

import 'package:fqapp/models/media_item.dart';
import 'package:fqapp/pages/library_page.dart';
import 'package:fqapp/services/app_style_tokens.dart';
import 'package:fqapp/services/classic_shelf_layout.dart';
import 'package:fqapp/services/library_store.dart';
import 'package:fqapp/services/shelf_group_store.dart';
import 'package:fqapp/services/shelf_store.dart';
import 'package:fqapp/services/shelf_view_store.dart';
import 'package:fqapp/widgets/shelf/shelf_design.dart';

import 'support/fakes.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  group('书架列数只跟宽度走', () {
    late Directory directory;

    setUp(() async {
      setSingleChapterPrefs({
        'shelfLayout': 'shelfGrid',
        'shelfGridDensity': '3x4',
      });
      ShelfViewStore.instance.resetForTest();
      ClassicShelfLayout.instance.resetForTest();
      directory = await Directory.systemTemp.createTemp('fqapp-shelf-columns-');
      Hive.init(directory.path);
      await LibraryStore.instance.init();
      await ShelfStore.instance.init();
      await ShelfGroupStore.instance.init();
    });

    tearDown(() async {
      debugDefaultTargetPlatformOverride = null;
      await ClassicShelfLayout.instance.whenIdle();
      await ShelfViewStore.instance.whenIdle();
      await ShelfGroupStore.instance.whenIdle();
      await Hive.close();
      await directory.delete(recursive: true);
      ClassicShelfLayout.instance.resetForTest();
      ShelfViewStore.instance.resetForTest();
    });

    testWidgets('宫格：平板横屏按宽度加列（Android / iOS 都一样）', (tester) async {
      final style = ValueNotifier<AppStyleTokens>(const AppStyleTokens.classic());
      addTearDown(style.dispose);
      addTearDown(() => tester.binding.setSurfaceSize(null));
      addTearDown(() => tester.pumpWidget(const SizedBox.shrink()));

      await tester.runAsync(() async {
        for (var i = 1; i <= 6; i++) {
          await ShelfStore.instance.add(_item('$i'));
        }
      });

      // 每一档都手算过的期望值。平板的三档（760 / 1024 / 1280 / 1440）
      // 正是 11-23 那次返工后变回 3 列的地方。
      final expected = <double, int>{
        400: 3, // 手机竖屏：(368)/168=2 → 下限 3
        760: 4, // (728)/168=4.33
        1024: 5, // (992)/168=5.90
        1280: 7, // 1248/168=7.42
        1440: 8, // 1408/168=8.38 → 上限 8
      };

      for (final platform in [TargetPlatform.android, TargetPlatform.iOS]) {
        debugDefaultTargetPlatformOverride = platform;
        var previous = 0;
        for (final entry in expected.entries) {
          final size = Size(entry.key, 900);
          await tester.binding.setSurfaceSize(size);
          await tester.pumpWidget(_app(style, size: size));
          await tester.pumpAndSettle();

          expect(
            find.byType(GridView),
            findsOneWidget,
            reason: '书架宫格应当只有一个 GridView（$platform / ${entry.key}dp）',
          );
          final columns = _columns(tester);
          expect(
            columns,
            entry.value,
            reason:
                '${entry.key}dp 宽（$platform）时宫格应为 ${entry.value} 列。'
                '若这里退回 3，说明列数又被绑到了 isDesktopHost 之类的平台判定 —— '
                '那正是 2026-11-23 的返工（平板恒 3 列）。',
          );
          expect(
            columns,
            greaterThanOrEqualTo(previous),
            reason: '列数必须随宽度单调不减（${entry.key}dp）',
          );
          previous = columns;
          expect(tester.takeException(), isNull);
        }
      }
    });

    testWidgets('双列：平板横屏同样按宽度加列', (tester) async {
      final style = ValueNotifier<AppStyleTokens>(const AppStyleTokens.classic());
      addTearDown(style.dispose);
      addTearDown(() => tester.binding.setSurfaceSize(null));
      addTearDown(() => tester.pumpWidget(const SizedBox.shrink()));
      debugDefaultTargetPlatformOverride = TargetPlatform.android;

      await tester.runAsync(() async {
        for (var i = 1; i <= 6; i++) {
          await ShelfStore.instance.add(_item('$i'));
        }
        await ClassicShelfLayout.instance.setLayout(
          BookshelfLayout.doubleColumn,
        );
        await ClassicShelfLayout.instance.whenIdle();
      });

      final expected = <double, int>{
        400: 2, // 368/340=1.08 → 下限 2
        1024: 2, // 992/340=2.91
        1280: 3, // 1248/340=3.67
        1440: 4, // 1408/340=4.14
      };

      for (final entry in expected.entries) {
        final size = Size(entry.key, 900);
        await tester.binding.setSurfaceSize(size);
        await tester.pumpWidget(_app(style, size: size));
        await tester.pumpAndSettle();

        expect(
          find.byType(GridView),
          findsOneWidget,
          reason: '双列版也只有一个 GridView（${entry.key}dp）',
        );
        expect(
          _columns(tester),
          entry.value,
          reason:
              '${entry.key}dp 宽时双列版应为 ${entry.value} 列（平板横屏从固定 2 列铺到 4 列）',
        );
        expect(tester.takeException(), isNull);
      }
    });
  });
}

int _columns(WidgetTester tester) {
  final grid = tester.widget<GridView>(find.byType(GridView));
  final delegate = grid.gridDelegate as SliverGridDelegateWithFixedCrossAxisCount;
  return delegate.crossAxisCount;
}

Widget _app(ValueNotifier<AppStyleTokens> style, {required Size size}) =>
    ValueListenableBuilder<AppStyleTokens>(
      valueListenable: style,
      child: LibraryPage(cacheStore: MemoryChapterCache()),
      builder: (context, tokens, child) => MaterialApp(
        themeAnimationDuration: Duration.zero,
        theme: ThemeData(extensions: [tokens]),
        home: MediaQuery(
          data: MediaQueryData(size: size, disableAnimations: true),
          child: child!,
        ),
      ),
    );

MediaItem _item(String id) => MediaItem(
  id: id,
  title: '测试书籍 $id',
  cover: '',
  author: '测试作者',
  badge: '',
  ep: '20',
  kind: 'book',
);
