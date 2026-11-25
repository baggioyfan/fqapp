import 'dart:async';

import 'package:material_ui/material_ui.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:fqapp/services/chapter_text_formatter.dart';
import 'package:fqapp/services/reader_preferences.dart';
import 'package:fqapp/widgets/reader/reader_chapter_layout.dart';
import 'package:fqapp/widgets/reader/reader_paged_view.dart';
import 'package:fqapp/widgets/reader/reader_text_selection.dart';

void main() {
  testWidgets('unmarked adjacent pages skip selection painters', (
    tester,
  ) async {
    final geometry = ReaderSelectionGeometry();
    await _pumpPager(
      tester,
      ReaderPageTurnStyle.slide,
      selectionScope: ReaderSelectionScope(
        geometry: geometry,
        washColor: Colors.yellow,
        handleColor: Colors.black,
        underlineColor: Colors.black,
        narrationColor: Colors.yellow,
      ),
    );
    expect(find.byType(ReaderBlockMarkLayer), findsWidgets);
    expect(
      find.byWidgetPredicate(
        (widget) =>
            widget is CustomPaint && widget.painter is ReaderBlockMarkPainter,
      ),
      findsNothing,
    );
    final layer = tester.widget<ReaderBlockMarkLayer>(
      find.byType(ReaderBlockMarkLayer).first,
    );
    final entry = geometry.entryFor(layer.block.index);
    expect(entry, isNotNull);
    expect(entry!.painter.height, greaterThan(0));
  });

  for (final style in [ReaderPageTurnStyle.slide, ReaderPageTurnStyle.cover]) {
    for (final direction in [1, -1]) {
      for (final startX in [40.0, 140.0, 280.0, 360.0]) {
        testWidgets('$style 翻页从屏幕边沿滑入，与触点无关（direction $direction x=$startX）', (
          tester,
        ) async {
          await _pumpPager(tester, style);
          final viewport = tester.getRect(find.byType(PageView));
          final seamPage = direction > 0 ? 2 : 1;
          final gesture = await tester.startGesture(
            viewport.topLeft + Offset(startX, 300),
          );
          // 位移从「起手点以来的手指位移」算，因此接缝位置只跟拖了多远
          // 有关，跟手指按在屏幕哪个位置无关：下一页的左缘从右缘进入、
          // 上一页的右缘从左缘进入，中途反向也按位移退回去。
          for (final distance in [24.0, 60.0, 40.0]) {
            await gesture.moveTo(
              viewport.topLeft + Offset(startX - direction * distance, 300),
            );
            await tester.pump();
            final seam = tester.getTopLeft(
              find.byKey(ValueKey('reader-text-page-$seamPage')),
            );
            final expected = direction > 0
                ? viewport.right - distance
                : viewport.left + distance;
            expect(seam.dx, closeTo(expected, 0.1));
          }
          // 拖过屏宽一半以上再松手，翻页完成。
          await gesture.moveTo(
            viewport.topLeft + Offset(startX - direction * 320, 300),
          );
          await tester.pump();
          await gesture.up();
          await tester.pumpAndSettle();
          final controller = tester
              .widget<PageView>(find.byType(PageView))
              .controller!;
          expect(controller.page, (direction > 0 ? 2 : 0).toDouble());
          expect(tester.takeException(), isNull);
        });
      }
    }

    testWidgets('$style drag cancellation allows another page turn', (
      tester,
    ) async {
      await _pumpPager(tester, style);
      final viewport = tester.getRect(find.byType(PageView));
      final gesture = await tester.startGesture(viewport.center);
      await gesture.moveBy(const Offset(-40, 0));
      await tester.pump();
      await gesture.moveTo(Offset(viewport.right - 40, viewport.center.dy));
      await tester.pump();
      await gesture.cancel();
      await tester.pumpAndSettle();
      final controller = tester
          .widget<PageView>(find.byType(PageView))
          .controller!;
      expect(controller.page, 1);
      unawaited(
        tester
            .state<ReaderPagedViewState>(find.byType(ReaderPagedView))
            .turnPage(1),
      );
      await tester.pumpAndSettle();
      expect(controller.page, 2);
      expect(tester.takeException(), isNull);
    });

    testWidgets('$style dragging outside the viewport cannot skip a page', (
      tester,
    ) async {
      await _pumpPager(tester, style);
      final gesture = await tester.startGesture(
        tester.getCenter(find.byType(PageView)),
      );
      await gesture.moveBy(const Offset(-40, 0));
      await tester.pump();
      await gesture.moveBy(const Offset(-900, 0));
      await tester.pump();
      final controller = tester
          .widget<PageView>(find.byType(PageView))
          .controller!;
      expect(controller.page, 2);
      await tester
          .state<ReaderPagedViewState>(find.byType(ReaderPagedView))
          .turnPage(1);
      await tester.pump();
      expect(controller.page, 2);
      await gesture.up();
      await tester.pumpAndSettle();
      expect(controller.page, 2);
      expect(tester.takeException(), isNull);
    });

    testWidgets('$style can unmount during a drag', (tester) async {
      await _pumpPager(tester, style);
      final gesture = await tester.startGesture(
        tester.getCenter(find.byType(PageView)),
      );
      await gesture.moveBy(const Offset(-40, 0));
      await tester.pump();
      await tester.pumpWidget(const SizedBox.shrink());
      await gesture.up();
      await tester.pumpAndSettle();
      expect(tester.takeException(), isNull);
    });

    for (final direction in [1, -1]) {
      testWidgets('$style fast release $direction never reveals a third page', (
        tester,
      ) async {
        await _pumpPager(tester, style);
        final controller = tester
            .widget<PageView>(find.byType(PageView))
            .controller!;
        final from = direction > 0 ? 1 : 2;
        controller.jumpToPage(from);
        await tester.pump();
        final positions = <double>[];
        controller.addListener(() => positions.add(controller.page!));

        // Release before reaching the edge so the fling still has velocity.
        await tester.fling(
          find.byType(PageView),
          Offset(-direction * 150, 0),
          8000,
        );
        await tester.pumpAndSettle(const Duration(milliseconds: 8));

        expect(positions, isNotEmpty);
        expect(positions, everyElement(inInclusiveRange(1.0, 2.0)));
        expect(controller.page, from + direction);
        expect(tester.takeException(), isNull);
      });

      testWidgets('$style fast drag $direction turns only one page', (
        tester,
      ) async {
        await _pumpPager(tester, style);
        final controller = tester
            .widget<PageView>(find.byType(PageView))
            .controller!;
        final from = direction > 0 ? 1 : 2;
        controller.jumpToPage(from);
        await tester.pump();
        await tester.fling(
          find.byType(PageView),
          Offset(-direction * 600, 0),
          1500,
        );
        await tester.pumpAndSettle();
        expect(controller.page, from + direction);
        expect(tester.takeException(), isNull);
      });
    }
  }
}

Future<ValueNotifier<ReaderPageTurnStyle>> _pumpPager(
  WidgetTester tester,
  ReaderPageTurnStyle initialStyle, {
  ReaderSelectionScope? selectionScope,
}) async {
  final style = ValueNotifier(initialStyle);
  addTearDown(style.dispose);
  await tester.binding.setSurfaceSize(const Size(600, 800));
  addTearDown(() => tester.binding.setSurfaceSize(null));
  final layout = ReaderChapterLayout(
    title: '第一章 测试',
    content: ChapterContent(
      blocks: [
        for (var i = 0; i < 60; i++)
          ChapterParagraph('清晨的风从窗边吹来，带着山间草木的清香。林舟推开木窗。'),
      ],
    ),
    spec: ReaderLayoutSpec(
      viewport: const Size(400, 800),
      textScaler: TextScaler.noScaling,
      preferences: const ReaderPreferences(),
      fontFamily: null,
    ),
  );
  expect(layout.pages.length, greaterThan(2));
  await tester.pumpWidget(
    MaterialApp(
      home: Scaffold(
        body: Padding(
          padding: const EdgeInsets.symmetric(horizontal: 100),
          child: ValueListenableBuilder(
            valueListenable: style,
            builder: (context, value, _) => ReaderPagedView(
              layout: layout,
              pageIndex: 1,
              hasPreviousChapter: true,
              hasNextChapter: true,
              onPageChanged: (_) {},
              onBoundary: (_) async {},
              onDragStart: () {},
              turnStyle: value,
              backgroundColor: Colors.white,
              selectionScope: selectionScope,
            ),
          ),
        ),
      ),
    ),
  );
  return style;
}
