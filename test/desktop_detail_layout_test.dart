import 'dart:io';
import 'dart:convert';
import 'dart:ui' as ui;

import 'package:flutter/foundation.dart';
import 'package:material_ui/material_ui.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:fqapp/models/media_item.dart';
import 'package:fqapp/pages/detail_page.dart';
import 'package:fqapp/pages/reader_page.dart';
import 'package:fqapp/services/desktop_platform.dart';
import 'package:fqapp/widgets/desktop_app_frame.dart';
import 'package:fqapp/widgets/desktop_shell_scope.dart';
import 'support/fakes.dart';

const _capture = bool.fromEnvironment('FQAPP_CAPTURE_LAYOUT');
const _boundary = Key('desktop-detail-capture');

void _testWindows(String name, Future<void> Function(WidgetTester) body) {
  testWidgets(name, (tester) async {
    debugDefaultTargetPlatformOverride = TargetPlatform.windows;
    try {
      await body(tester);
    } finally {
      await tester.pumpWidget(const SizedBox.shrink());
      DesktopShellState.reset();
      debugDefaultTargetPlatformOverride = null;
    }
  });
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  setUpAll(() async {
    if (_capture) {
      final fonts =
          jsonDecode(await rootBundle.loadString('FontManifest.json')) as List;
      for (final family in fonts) {
        final loader = FontLoader(family['family'] as String);
        for (final font in family['fonts'] as List) {
          loader.addFont(rootBundle.load(font['asset'] as String));
        }
        await loader.load();
      }
      final file = File(r'C:\Windows\Fonts\msyh.ttc');
      if (file.existsSync()) {
        await (FontLoader(
          'DesktopQA',
        )..addFont(file.readAsBytes().then(ByteData.sublistView))).load();
      }
    }
  });
  setUp(() {
    SharedPreferences.setMockInitialValues({});
    DesktopPlatform.fullscreen.value = false;
    DesktopShellState.reset();
    desktopTab.value = 0;
  });

  for (final sample
      in <({double width, double height, double scale, String layout})>[
        (width: 600, height: 768, scale: 1, layout: 'mobile'),
        (width: 700, height: 768, scale: 1, layout: 'compact'),
        (width: 999, height: 768, scale: 1, layout: 'compact'),
        (width: 1000, height: 768, scale: 1, layout: 'compact'),
        (width: 1100, height: 768, scale: 1, layout: 'workspace'),
        (width: 1399, height: 768, scale: 1, layout: 'workspace'),
        (width: 1400, height: 768, scale: 1, layout: 'workspace'),
        (width: 1366, height: 768, scale: 1, layout: 'workspace'),
        (width: 1920, height: 1080, scale: 1, layout: 'workspace'),
        // 1366x768 and 1920x1080 physical screens at 150% Windows DPI.
        (width: 910, height: 512, scale: 1, layout: 'compact'),
        (width: 910, height: 512, scale: 2, layout: 'compact'),
        (width: 1280, height: 720, scale: 1, layout: 'workspace'),
        (width: 1366, height: 768, scale: 1.5, layout: 'workspace'),
      ]) {
    _testWindows(
      'Windows detail ${sample.width}x${sample.height} text ${sample.scale}',
      (tester) async {
        await _pump(
          tester,
          Size(sample.width, sample.height),
          scale: sample.scale,
        );
        expect(tester.takeException(), isNull);
        if (sample.layout == 'mobile') {
          // The ported phone page uses the shared glass action dock.
          expect(find.byKey(const Key('detail_read_button')), findsOneWidget);
        } else {
          expect(find.byType(AppBar), findsNothing);
          // The desktop workspace keeps its own side card/buttons; the phone
          // dock must not leak into it.
          expect(find.byKey(const Key('detail_read_button')), findsNothing);
          expect(
            find.byKey(Key('desktop-detail-${sample.layout}')),
            findsOneWidget,
          );
          expect(
            find.byKey(const Key('detail_read_button_desktop')),
            findsOneWidget,
          );
          if (sample.layout == 'workspace') {
            expect(
              find.byKey(const Key('desktop_detail_masthead')),
              findsOneWidget,
            );
            expect(
              find.byKey(const Key('desktop_detail_actions')),
              findsOneWidget,
            );
            expect(
              find.byKey(const Key('desktop_detail_synopsis')),
              findsOneWidget,
            );
            expect(
              find.byKey(const Key('desktop_detail_directory')),
              findsOneWidget,
            );
            expect(
              find.byKey(const Key('desktop_detail_workspace_columns')),
              sample.width - 200 - 48 >= 900 ? findsOneWidget : findsNothing,
            );
          }
          expect(
            tester
                .getSize(find.byKey(const Key('detail_read_button_desktop')))
                .height,
            greaterThanOrEqualTo(44),
          );
          expect(find.byKey(const Key('detail_id_copy')), findsOneWidget);
          expect(find.byKey(const Key('desktop-window-bar')), findsOneWidget);
          expect(find.byKey(const Key('desktop-nav-pane')), findsOneWidget);
          expect(
            tester.getSize(find.byKey(const Key('desktop-nav-pane'))).width,
            sample.width >= 1100 ? 200 : 68,
          );
          expect(find.byKey(const Key('desktop-settings')), findsOneWidget);
        }
        if (_capture && sample.width >= 700) {
          await tester.runAsync(() async {
            final boundary = tester.renderObject<RenderRepaintBoundary>(
              find.byKey(_boundary),
            );
            final image = await boundary.toImage(pixelRatio: 1);
            final bytes = await image.toByteData(
              format: ui.ImageByteFormat.png,
            );
            final file = File(
              'build/validation/desktop-detail/${sample.width.toInt()}-${sample.scale}.png',
            );
            await file.parent.create(recursive: true);
            await file.writeAsBytes(bytes!.buffer.asUint8List());
            image.dispose();
          });
        }
        await tester.pumpWidget(const SizedBox.shrink());
      },
    );
  }

  _testWindows('desktop workspace searches chapters and opens their index', (
    tester,
  ) async {
    final semantics = tester.ensureSemantics();
    final observer = _Observer();
    await _pump(
      tester,
      const Size(1366, 768),
      observer: observer,
      readerStore: MemoryReaderStore(
        entry: {
          'id': _book.id,
          'kind': _book.kind,
          'episode': 204,
          'chapterId': 'chapter-204',
        },
      ),
    );
    expect(find.byKey(const Key('detail_description_text')), findsOneWidget);
    expect(
      find.byKey(const Key('desktop_detail_directory_row_204')),
      findsOneWidget,
    );
    expect(find.text('读到这里'), findsOneWidget);
    expect(find.byKey(const Key('detail_progress_bar')), findsOneWidget);
    final heading = find.descendant(
      of: find.byKey(const Key('desktop_detail_synopsis')),
      matching: find.text('作品简介'),
    );
    expect(heading, findsOneWidget);
    expect(
      tester.getTopLeft(heading).dx,
      closeTo(
        tester.getTopLeft(find.byKey(const Key('detail_description_text'))).dx,
        0.5,
      ),
    );
    // 评分只在横向作品信息中出现一次。
    expect(find.byKey(const Key('detail_rating_line')), findsOneWidget);
    expect(find.text('9.5'), findsOneWidget);
    expect(find.byKey(const Key('detail_score_card')), findsNothing);
    expect(find.text('还没有读者评论'), findsOneWidget);
    expect(
      tester
          .getSemantics(find.byKey(const Key('desktop_detail_directory_order')))
          .value,
      '正序',
    );
    await tester.tap(find.byKey(const Key('desktop_detail_directory_order')));
    await tester.pumpAndSettle();
    expect(find.text('倒序'), findsOneWidget);
    expect(
      tester
          .getSemantics(find.byKey(const Key('desktop_detail_directory_order')))
          .value,
      '倒序',
    );
    expect(find.bySemanticsLabel('搜索目录'), findsOneWidget);
    await tester.enterText(find.widgetWithText(TextField, '搜索目录'), '第 205 章');
    await tester.pumpAndSettle();
    expect(find.text('第 205 章 故事继续'), findsNWidgets(2));
    await tester.tap(find.byKey(const Key('desktop_detail_directory_order')));
    await tester.pumpAndSettle();
    expect(find.text('正序'), findsOneWidget);
    final context = tester.element(find.byType(DetailPage));
    await tester.tap(find.byKey(const Key('desktop_detail_directory_row_204')));
    await tester.idle();
    final page =
        (observer.route! as MaterialPageRoute).builder(context) as ReaderPage;
    expect(page.startIndex, 204);
    expect(page.shelfItem?.id, _book.id);
    await tester.pumpWidget(const SizedBox.shrink());
    semantics.dispose();
  });

  _testWindows('manga workspace uses 話 units and hides book-only actions', (
    tester,
  ) async {
    await _pump(tester, const Size(1366, 768), item: _manga);
    expect(find.byKey(const Key('desktop_detail_directory')), findsOneWidget);
    expect(
      find.descendant(
        of: find.byKey(const Key('desktop_detail_directory')),
        matching: find.text('1 卷 · 240 话'),
      ),
      findsOneWidget,
    );
    expect(find.byKey(const Key('detail_read_button_desktop')), findsOneWidget);
    expect(find.byKey(const Key('detail_listen_button_desktop')), findsNothing);
    expect(
      find.byKey(const Key('detail_download_button_desktop')),
      findsNothing,
    );
    expect(tester.takeException(), isNull);
    if (_capture) {
      await tester.runAsync(() async {
        final boundary = tester.renderObject<RenderRepaintBoundary>(
          find.byKey(_boundary),
        );
        final image = await boundary.toImage(pixelRatio: 1);
        final bytes = await image.toByteData(format: ui.ImageByteFormat.png);
        final file = File(
          'build/validation/desktop-detail/manga-workspace.png',
        );
        await file.parent.create(recursive: true);
        await file.writeAsBytes(bytes!.buffer.asUint8List());
        image.dispose();
      });
    }
    await tester.pumpWidget(const SizedBox.shrink());
  });

  _testWindows('workspace retries only the failed chapter directory', (
    tester,
  ) async {
    var detailRequests = 0;
    var directoryRequests = 0;
    await _pump(
      tester,
      const Size(1366, 768),
      detailLoader: (id, {String tab = '小说'}) async {
        detailRequests++;
        return {
          'data': {'book_name': _book.title, 'abstract': '简介'},
        };
      },
      directoryLoader: (id, {String tab = '小说'}) async {
        directoryRequests++;
        if (directoryRequests == 1) throw Exception('暂时不可用');
        return [
          [
            Chapter(
              itemId: 'recovered-chapter',
              title: '第 1 章 重试成功',
              volumeName: '',
            ),
          ],
        ];
      },
    );
    expect(find.byKey(const Key('detail_inline_error')), findsOneWidget);
    expect(directoryRequests, 1);
    await tester.tap(find.widgetWithText(OutlinedButton, '重试'));
    await tester.pumpAndSettle();
    expect(directoryRequests, 2);
    expect(detailRequests, 1);
    expect(
      find.byKey(const Key('desktop_detail_directory_row_0')),
      findsOneWidget,
    );
    expect(tester.takeException(), isNull);
    await tester.pumpWidget(const SizedBox.shrink());
  });
}

Future<void> _pump(
  WidgetTester tester,
  Size size, {
  double scale = 1,
  MediaItem? item,
  NavigatorObserver? observer,
  MemoryReaderStore? readerStore,
  Future<Map<String, dynamic>> Function(String bookId, {String tab})?
  detailLoader,
  Future<List<List<Chapter>>> Function(String bookId, {String tab})?
  directoryLoader,
}) async {
  tester.view.physicalSize = size;
  tester.view.devicePixelRatio = 1;
  addTearDown(() {
    tester.view.resetPhysicalSize();
    tester.view.resetDevicePixelRatio();
  });
  await tester.pumpWidget(
    RepaintBoundary(
      key: _boundary,
      child: MaterialApp(
        navigatorKey: DesktopPlatform.navigatorKey,
        navigatorObservers: [?observer],
        theme: ThemeData(
          useMaterial3: true,
          colorSchemeSeed: const Color(0xfff65a38),
          fontFamily: _capture ? 'DesktopQA' : null,
        ),
        builder: (context, child) => MediaQuery(
          data: MediaQuery.of(
            context,
          ).copyWith(textScaler: TextScaler.linear(scale)),
          child: DesktopAppFrame(child: child!),
        ),
        home: DetailPage(
          item: item ?? _book,
          readerStore: readerStore ?? MemoryReaderStore(),
          chapterCache: MemoryChapterCache(),
          detailLoader:
              detailLoader ??
              (id, {String tab = '小说'}) async => {
                'data': {
                  'book_name': (item ?? _book).title,
                  'abstract':
                      '少年踏上旅途，在山川与星河之间寻找新的故事。每一次相遇都带来不同的选择，也让平凡的日常有了温暖的光。' * 3,
                  'score': '9.5',
                  'read_count': '246000',
                  'word_number': '1280000',
                  'tags': '奇幻,冒险',
                  'author_info': {
                    'user_name': (item ?? _book).author,
                    'user_id': 'author',
                  },
                },
              },
          directoryLoader:
              directoryLoader ??
              (id, {String tab = '小说'}) async => [
                List.generate(
                  240,
                  (i) => Chapter(
                    itemId: 'chapter-$i',
                    title:
                        '第 ${i + 1} ${item?.kind == 'manga' ? '话' : '章'} 故事继续',
                    volumeName: '第一卷',
                  ),
                ),
              ],
        ),
      ),
    ),
  );
  await tester.pumpAndSettle();
}

final _book = MediaItem(
  id: 'desktop-detail-book',
  title: '山川与星河：一段新的旅程',
  cover: '',
  author: '测试作者',
  badge: '',
  ep: '',
  kind: 'book',
);

final _manga = MediaItem(
  id: 'desktop-detail-manga',
  title: '云上街角：漫画篇',
  cover: '',
  author: '测试漫画家',
  badge: '',
  ep: '',
  kind: 'manga',
);

class _Observer extends NavigatorObserver {
  Route<dynamic>? route;
  @override
  void didPush(Route<dynamic> route, Route<dynamic>? previousRoute) {
    this.route = route;
  }
}
