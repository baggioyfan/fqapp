// 桌面端首页两处「形状」的守护：
// 1. 顶栏分类在桌面是等字号胶囊，手机仍是官方 SlidingTabLayout 的 24/16sp
//    （`alx.xml`），两边都不能被对方顺手改掉；
// 2. 「猜你喜欢」书卡流在桌面按书架宫格几何排（官方 `us3.a.q()` 桌面恒 2 列，
//    1280 窗口下两张卡吃掉一整屏）。

import 'package:flutter/foundation.dart';
import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:fqapp/models/media_item.dart';
import 'package:fqapp/pages/home_page.dart';
import 'package:fqapp/pages/home_provider.dart';
import 'package:fqapp/services/api_client.dart';
import 'package:fqapp/widgets/bookshelf_card.dart';
import 'package:fqapp/widgets/home/home_cell_blocks.dart';
import 'package:fqapp/widgets/home/home_design.dart';
import 'package:fqapp/widgets/home/home_media_card.dart';
import 'package:fqapp/widgets/home/home_tab_bar.dart';

Widget _host(Widget child) => MaterialApp(home: Scaffold(body: child));

/// 顶栏分类的实际字号：手机/桌面两套形态都靠 AnimatedDefaultTextStyle
/// 下传，所以这里取的是渲染时生效的那一份。
double? _fontSize(WidgetTester tester, int index) {
  final animated = tester.widget<AnimatedDefaultTextStyle>(
    find
        .descendant(
          of: find.byKey(ValueKey('home_category_$index')),
          matching: find.byType(AnimatedDefaultTextStyle),
        )
        .first,
  );
  return animated.style.fontSize;
}

BoxDecoration _pill(WidgetTester tester, int index) {
  final container = tester.widget<AnimatedContainer>(
    find
        .descendant(
          of: find.byKey(ValueKey('home_category_$index')),
          matching: find.byType(AnimatedContainer),
        )
        .first,
  );
  return container.decoration! as BoxDecoration;
}

void main() {
  group('home tab bar', () {
    Future<void> pumpBar(
      WidgetTester tester, {
      required bool desktop,
      required ValueChanged<int> onSelect,
    }) async {
      await tester.pumpWidget(
        _host(
          CustomScrollView(
            slivers: [
              SliverPersistentHeader(
                pinned: true,
                delegate: HomeTabBarDelegate(
                  selectedIndex: 0,
                  onSelect: onSelect,
                  desktop: desktop,
                  extent: HomeTabBarDelegate.extentFor(1, desktop: desktop),
                ),
              ),
            ],
          ),
        ),
      );
    }

    testWidgets('phone keeps the official 24/16sp pair', (tester) async {
      await pumpBar(tester, desktop: false, onSelect: (_) {});

      // `alx.xml`：选中 `av5` = 24sp、未选中 `avq` = 16sp，都没有底色。
      expect(_fontSize(tester, 0), 24);
      expect(_fontSize(tester, 1), 16);
      expect(find.byType(AnimatedContainer), findsNothing);
    });

    testWidgets('desktop uses one font size with an accent pill', (
      tester,
    ) async {
      await pumpBar(tester, desktop: true, onSelect: (_) {});

      // 两态同字号：点一下整行不重排。
      expect(_fontSize(tester, 0), 14);
      expect(_fontSize(tester, 1), 14);
      // 选中项 accent 11% 淡底，未选中透明。
      expect(_pill(tester, 0).color, HomePalette.accent.withValues(alpha: 0.11));
      expect(_pill(tester, 1).color, Colors.transparent);
      expect(
        _pill(tester, 0).borderRadius,
        BorderRadius.circular(HomeTabBarDelegate.desktopPillRadius),
      );
    });

    testWidgets('desktop pills light up on hover and stay tappable', (
      tester,
    ) async {
      int? tapped;
      await pumpBar(tester, desktop: true, onSelect: (i) => tapped = i);

      final mouse = await tester.createGesture(kind: PointerDeviceKind.mouse);
      await mouse.addPointer(location: Offset.zero);
      addTearDown(mouse.removePointer);
      await mouse.moveTo(
        tester.getCenter(find.byKey(const ValueKey('home_category_2'))),
      );
      await tester.pumpAndSettle();
      // 悬停给中性浅底，别让用户只能靠字色猜「这里能点」。
      expect(_pill(tester, 2).color, const HomePalette(false).soft);

      await tester.tap(find.byKey(const ValueKey('home_category_2')));
      await tester.pumpAndSettle();
      expect(tapped, 2);
    });
  });

  group('desktop book stream', () {
    testWidgets('columns follow the shelf target width', (tester) async {
      late BuildContext context;
      await tester.pumpWidget(
        _host(
          Builder(
            builder: (inner) {
              context = inner;
              return const SizedBox();
            },
          ),
        ),
      );

      int columns(double width) =>
          homeShelfGridMetrics(context, availableWidth: width).columns;

      expect(columns(1280), 7);
      expect(columns(1204), 7);
      expect(columns(800), 4);
      // 书架宫格的下限 3：窄窗口也不退回官方那 2 列。
      expect(columns(300), 3);
      // 上限 10：5K 全屏不再继续加列。
      expect(columns(5000), 10);
    });

    testWidgets('cells keep the shelf width, gutter and run spacing', (
      tester,
    ) async {
      await tester.binding.setSurfaceSize(const Size(1280, 900));
      addTearDown(() => tester.binding.setSurfaceSize(null));

      await tester.pumpWidget(
        _host(
          Builder(
            builder: (context) => CustomScrollView(
              slivers: [
                SliverPadding(
                  padding: const EdgeInsets.symmetric(
                    horizontal: homeShelfSidePadding,
                  ),
                  sliver: homeBookShelfGrid(
                    context,
                    availableWidth: 1280,
                    childCount: 14,
                    itemBuilder: (context, index) => ColoredBox(
                      key: ValueKey('cell-$index'),
                      color: const Color(0xFF000000),
                    ),
                  ),
                ),
              ],
            ),
          ),
        ),
      );

      final first = tester.getRect(find.byKey(const ValueKey('cell-0')));
      final second = tester.getRect(find.byKey(const ValueKey('cell-1')));
      // (1280 - 16*2 - 12*6) / 7 = 168
      expect(first.width, closeTo(168, 0.5));
      expect(second.left - first.right, closeTo(12, 0.5));
      expect(first.left, closeTo(16, 0.5));
      // 第二行在第一行下方一个格高 + 20dp 行距处。
      final eighth = tester.getRect(find.byKey(const ValueKey('cell-7')));
      expect(eighth.top - first.bottom, closeTo(20, 0.5));
      // 格高 = 封面 1.4 + 两行标题 + 一行副信息（书架那套公式）。
      expect(first.height, closeTo(168 * 1.4 + 2 + 32.5 + 4 + 14.95 + 4, 1));
    });

    testWidgets('每个分类 tab 的卡片流在桌面都是同一套书架宫格', (tester) async {
      // 旧管线（这个分类没下发区块）也要走书架几何——官方 `us3.a.q()` 在
      // 桌面恒 2 列，只有区块管线自己改还不够，换个 tab 就会退回去。
      debugDefaultTargetPlatformOverride = TargetPlatform.windows;
      await tester.binding.setSurfaceSize(const Size(1280, 900));
      addTearDown(() => tester.binding.setSurfaceSize(null));
      addTearDown(() => tester.pumpWidget(const SizedBox.shrink()));
      // foundation 的 debug 变量在测试体结束前必须复位，否则触发
      // debugAssertAllFoundationVarsUnset（addTearDown 来不及）。
      try {
        await _pumpDesktopHome(tester);
      } finally {
        debugDefaultTargetPlatformOverride = null;
      }
    });
  });
}

/// 桌面平台下渲染一版首页（无区块数据 → 旧管线），并断言书卡流是书架宫格。
Future<void> _pumpDesktopHome(WidgetTester tester) async {
  await tester.pumpWidget(
    ProviderScope(
      overrides: [
        homeProvider.overrideWith(
          () => HomeNotifier(
            homepageLoader:
                ({
                  int tabType = 2,
                  int offset = 0,
                  String? sessionId,
                }) async => HomepagePage(
                  items: [
                    for (var i = 0; i < 24; i++)
                      MediaItem(
                        id: 'i$i',
                        title: '作品 $i',
                        cover: '',
                        author: '作者',
                        badge: '',
                        ep: '',
                        kind: 'book',
                      ),
                  ],
                  nextOffset: null,
                  sessionId: null,
                ),
            searchLoader: (query, {int page = 1}) async => [],
          ),
        ),
      ],
      child: const MaterialApp(home: HomePage()),
    ),
  );
  await tester.pumpAndSettle();

  // 旧管线的 HomeMediaCard 不该再出现在桌面；卡片统一是书架宫格卡。
  expect(find.byType(HomeMediaCard), findsNothing);
  final cards = find.byType(BookshelfGridCard);
  expect(cards, findsWidgets);
  final first = tester.getRect(cards.first);
  final second = tester.getRect(cards.at(1));
  // 1280 整宽 → 7 列、每颗 (1280-32-72)/7 = 168。
  expect(first.width, closeTo(168, 1));
  expect(second.left - first.right, closeTo(12, 1));
  expect(second.top, closeTo(first.top, 0.5));
}
