import 'dart:convert';

import 'package:material_ui/material_ui.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:fqapp/pages/reader_page.dart';
import 'package:fqapp/pages/shuqi_detail_page.dart';
import 'package:fqapp/services/secure_key_provider.dart';

import 'support/fakes.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  const secureKeys = MethodChannel('fqapp/secure_keys');
  setUp(() {
    SecureKeyProvider.instance.resetForTest();
    // Opening Shuqi now initializes the encrypted chapter catalogue. Resolve
    // its platform dependency instead of leaving a native-key timeout pending.
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(secureKeys, (call) async {
          if (call.method == 'read') return base64Encode(List.filled(32, 7));
          return null;
        });
  });
  tearDown(() {
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(secureKeys, null);
    SecureKeyProvider.instance.resetForTest();
  });
  testWidgets('a toc failure keeps the book detail and offers a retry', (
    tester,
  ) async {
    var tocCalls = 0;
    await tester.pumpWidget(
      MaterialApp(
        home: ShuqiDetailPage(
          bookId: '34078',
          // 详情页现在会读本机历史判「继续阅读」，同样不能碰加密 Hive。
          readerStore: MemoryReaderStore(),
          bookLoader: (_) async => {
            'data': {
              'bookId': '34078',
              'name': '凡人修仙传',
              'author': '忘语',
              'intro': '一个普通山村小子',
              'kind': '玄幻',
              'coverUrl': '',
              'wordCount': '2451万字',
              'lastChapter': '第2451章',
              'status': '完结',
              'chapterTotalNum': 2451,
            },
          },
          tocLoader: (_) async {
            tocCalls++;
            if (tocCalls == 1) throw StateError('toc down');
            return {
              'data': {
                'path': 'h5',
                'total': 1,
                'chapters': [
                  {'chapterId': '2180322', 'title': '第1章 山边小村', 'isVip': false},
                ],
              },
            };
          },
        ),
      ),
    );
    await tester.pumpAndSettle();

    // 详情已经拿到，不能因为目录失败而整页报错。
    expect(find.text('忘语'), findsOneWidget);
    expect(find.text('一个普通山村小子'), findsOneWidget);
    expect(find.text('加载失败，请稍后重试'), findsOneWidget);
    // 「开始阅读」在目录为空时禁用，但详情本身仍然可见。
    expect(find.text('目录未加载'), findsOneWidget);

    await tester.tap(find.widgetWithText(OutlinedButton, '重试'));
    await tester.pumpAndSettle();

    expect(tocCalls, 2);
    expect(find.text('加载失败，请稍后重试'), findsNothing);
    expect(find.text('第1章 山边小村'), findsOneWidget);
    expect(find.text('共 1 章'), findsOneWidget);
  });

  testWidgets('opening a chapter gives the reader the shuqi history store', (
    tester,
  ) async {
    await tester.pumpWidget(
      MaterialApp(
        home: ShuqiDetailPage(
          bookId: '34078',
          // 详情页现在会读本机历史判「继续阅读」，同样不能碰加密 Hive。
          readerStore: MemoryReaderStore(),
          // 阅读页默认打开加密的目录缓存，测试进程里没有平台密钥会让
          // SecureKeyProvider 挂满 10 秒超时；这里注内存实现隔离掉。
          chapterCache: MemoryChapterCache(),
          bookLoader: (_) async => {
            'data': {
              'bookId': '34078',
              'name': '凡人修仙传',
              'author': '忘语',
              'coverUrl': '',
            },
          },
          tocLoader: (_) async => {
            'data': {
              'path': 'h5',
              'total': 1,
              'chapters': [
                {'chapterId': '2180322', 'title': '第1章 山边小村', 'isVip': false},
              ],
            },
          },
        ),
      ),
    );
    await tester.pumpAndSettle();

    await tester.tap(find.text('开始阅读'));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 300));

    final reader = tester.widget<ReaderPage>(find.byType(ReaderPage));
    expect(reader.localOnly, isTrue);
    final store = reader.readerStore;
    expect(
      store,
      isNotNull,
      reason: 'the reader must not fall back to the global history store',
    );

    // 书旗现在把进度写进本机历史（`shuqi:` 作用域，与番茄同名 id 隔离）；
    // 阅读时长另由 ReaderPage 的书旗分支排除，不进番茄的统计表。
    await store!.addHistory({
      'id': 'shuqi:34078',
      'kind': 'book',
      'bookId': 'shuqi:34078',
    });
    expect(await store.historyEntry('shuqi:34078'), isNotNull);
    await store.updateProgress('shuqi:34078', 0, 0.5);
    expect((await store.historyEntry('shuqi:34078'))!['progress'], 0.5);

    // 撤掉阅读器，别让还在跑的正文请求把 setState 带出测试。
    await tester.pumpWidget(const SizedBox.shrink());
    await tester.pumpAndSettle();
  });
}
