import 'dart:async';
import 'dart:io';

import 'package:material_ui/material_ui.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:fqapp/main.dart' as app;
import 'package:fqapp/services/app_log.dart';
import 'package:fqapp/services/library_store.dart';
import 'package:fqapp/widgets/home/home_skeleton.dart';
import 'package:hive_ce/hive.dart';
import 'package:shared_preferences/shared_preferences.dart';

/// 推进到 [text] 出现为止：每次「走过一小段模拟时间」再「给一小段真实时间」。
///
/// 两样缺一不可：
/// - `pump(Duration)` 才推进模拟时钟，启动闸门等的那批定时器/预算才不会永远不动
///   （裸 `pump()` 只重建、不推时钟，闸门会一直卡着）；
/// - `runAsync` 才给真实的 Hive I/O 一点 wall-clock。
///
/// 也不能用 `pumpAndSettle`：闸门挂起时在位的是首页骨架，它自带
/// `repeat(reverse: true)` 的无限脉动，永远等不到静止，直接撞 10 分钟超时。
Future<void> _waitForText(WidgetTester tester, String text) async {
  final finder = find.text(text);
  for (var i = 0; i < 80; i++) {
    if (finder.evaluate().isNotEmpty) return;
    await tester.pump(const Duration(milliseconds: 100));
    await tester.runAsync(
      () => Future<void>.delayed(const Duration(milliseconds: 10)),
    );
  }
  // 走完还没出现就再 pump 一次，交给调用方的 expect 给出可读的失败信息。
  await tester.pump();
}

void main() {
  testWidgets('retrying initialization retains existing Hive history', (
    tester,
  ) async {
    SharedPreferences.setMockInitialValues({});
    final tempRoot = Directory.systemTemp.absolute;
    late Directory directory;
    late Box<dynamic> history;
    final record = {
      'id': 'kept',
      'kind': 'book',
      'title': '已保存作品',
      'chapterId': 'chapter-7',
      'episode': 6,
      'position': 73.5,
    };
    await tester.runAsync(() async {
      directory = await tempRoot.createTemp('fqapp-bootstrap-');
      Hive.init(directory.path);
      history = await Hive.openBox<dynamic>('history');
      await Hive.openBox<dynamic>('read_time');
      // 已看集 box 也在 LibraryStore.init 里开箱（F07），同样要预开，
      // 否则 openBox 落在 widget 测试的 fake-async 路径上不会完成。
      await Hive.openBox<dynamic>('watched_episodes');
      await history.put('kept', record);
    });
    addTearDown(() async {
      await tester.pumpWidget(const SizedBox.shrink());
      await tester.runAsync(() async {
        // 用例失败时初始化可能还挂着，Hive 的 in-flight 写入会让 close 永不返回；
        // 收尾卡死会把一次失败放大成两次 10 分钟超时（同文件后续用例一起红）。
        await Hive.close().timeout(
          const Duration(seconds: 10),
          onTimeout: () => const <void>[],
        );
        if (directory.absolute.parent.path != tempRoot.path) {
          throw StateError('Temporary directory escaped its parent');
        }
        await directory.delete(recursive: true);
      });
    });
    var attempts = 0;
    await tester.pumpWidget(
      MaterialApp(
        home: app.AppBootstrap(
          initializer: () async {
            attempts++;
            await LibraryStore.instance.init();
            if (attempts == 1) throw StateError('transient startup failure');
          },
          child: const Text('ready'),
        ),
      ),
    );
    // 闸门挂起时在位的是首页骨架，它自带 repeat(reverse: true) 的无限脉动，
    // pumpAndSettle 永远等不到静止；而这次初始化走的是真实 Hive I/O，要的是
    // wall-clock 而不是帧。所以两头交替：给一小段真实时间让 I/O 跑，再 pump
    // 一帧让微任务落地并重建界面。
    await _waitForText(tester, '无法读取本地数据');
    expect(find.text('无法读取本地数据'), findsOneWidget);
    expect(history.get('kept'), record);
    await tester.tap(find.text('重试'));
    await _waitForText(tester, 'ready');
    expect(find.text('ready'), findsOneWidget);
    expect(attempts, 2);
    expect(history.get('kept'), record);
    expect(
      (await LibraryStore.instance.historyEntry('kept'))?['position'],
      73.5,
    );
  });

  testWidgets('bootstrap mounts business pages only after a successful retry', (
    tester,
  ) async {
    final first = Completer<void>();
    final retry = Completer<void>();
    var attempts = 0;
    await tester.pumpWidget(
      MaterialApp(
        home: app.AppBootstrap(
          initializer: () => ++attempts == 1 ? first.future : retry.future,
          child: const Text('ready'),
        ),
      ),
    );
    expect(find.text('ready'), findsNothing);
    expect(attempts, 1);
    // 成功路径不再整屏「转圈 + 文案」：本地数据就绪前只有首页骨架，等待
    // 提示只留给失败路径（#318）。
    expect(find.text('正在读取本地数据…'), findsNothing);
    expect(find.byType(CircularProgressIndicator), findsNothing);
    expect(find.byType(HomeSkeleton), findsOneWidget);
    first.completeError(StateError('cannot open stored data'));
    await tester.pump();
    expect(find.text('无法读取本地数据'), findsOneWidget);
    final button = tester.widget<OutlinedButton>(find.byType(OutlinedButton));
    button.onPressed!();
    button.onPressed!();
    await tester.pump();
    expect(attempts, 2);
    expect(find.text('ready'), findsNothing);
    retry.complete();
    await tester.pump();
    expect(find.text('ready'), findsOneWidget);
    expect(find.byType(CircularProgressIndicator), findsNothing);
  });

  testWidgets('disposing a pending bootstrap ignores its late completion', (
    tester,
  ) async {
    final initialized = Completer<void>();
    await tester.pumpWidget(
      MaterialApp(
        home: app.AppBootstrap(
          initializer: () => initialized.future,
          child: const Text('ready'),
        ),
      ),
    );
    await tester.pumpWidget(const SizedBox.shrink());
    initialized.completeError(StateError('late initialization error'));
    await tester.pump();
    expect(tester.takeException(), isNull);
  });

  testWidgets('backend starts before local data init completes', (
    tester,
  ) async {
    final localInit = Completer<void>();
    var backendStarted = false;
    await tester.pumpWidget(
      MaterialApp(
        home: app.AppBootstrap(
          initializer: () => localInit.future,
          backendStarter: () async {
            backendStarted = true;
          },
          child: const Text('ready'),
        ),
      ),
    );
    await tester.pump();
    expect(backendStarted, isTrue);
    expect(find.text('ready'), findsNothing);
    localInit.complete();
    await tester.pump();
    expect(find.text('ready'), findsOneWidget);
  });

  testWidgets('backend failure does not fail the bootstrap gate', (
    tester,
  ) async {
    await tester.pumpWidget(
      MaterialApp(
        home: app.AppBootstrap(
          initializer: () async {},
          backendStarter: () async {
            throw StateError('backend down');
          },
          child: const Text('ready'),
        ),
      ),
    );
    // No pumpAndSettle: it advances the fake clock past the next test's
    // AnimationController start and trips its elapsed-time assertion.
    await tester.pump();
    await tester.pump();
    // Backend errors are owned by RootShell's UI, not the bootstrap gate.
    expect(find.text('ready'), findsOneWidget);
    expect(tester.takeException(), isNull);
  });

  testWidgets('main renders a retryable screen when the data directory fails', (
    tester,
  ) async {
    const channel = MethodChannel('plugins.flutter.io/path_provider');
    var attempts = 0;
    final messenger =
        TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
    messenger.setMockMethodCallHandler(channel, (call) async {
      // 只统计引导用的文档目录（Hive.initFlutter）；应用日志落盘会另探一次
      // 支持目录（getApplicationSupportDirectory），与本用例的「重试一次」无关。
      if (call.method == 'getApplicationDocumentsDirectory') attempts++;
      throw PlatformException(
        code: 'unavailable',
        message: 'private-storage-path',
      );
    });
    addTearDown(() => messenger.setMockMethodCallHandler(channel, null));
    addTearDown(() => tester.pumpWidget(const SizedBox.shrink()));
    app.main();
    // main() 接管了 debugPrint 与 FlutterError.onError，把应用日志收进缓冲。
    // flutter_test 会在测试体结束时断言这两个 foundation 调试变量未被改动，
    // 所以必须在**测试体内**还原（addTearDown 跑在不变量检查之后，太晚）。
    try {
      await tester.pump();
      await tester.pump();
      expect(tester.takeException(), isNull);
      expect(find.text('无法读取本地数据'), findsOneWidget);
      expect(find.textContaining('private-storage-path'), findsNothing);
      expect(attempts, 1);
      await tester.tap(find.text('重试'));
      await tester.pump();
      await tester.pump();
      expect(attempts, 2);
      expect(find.text('无法读取本地数据'), findsOneWidget);
      expect(tester.takeException(), isNull);
    } finally {
      // 组件测试里 await 版会永久挂住（见 AppLog.resetForTest 的注释）：
      // 模拟时钟只在 pump 时清微任务，测试体最后一句之后不再有 pump。
      AppLog.instance.resetForTestSync();
    }
  });
}
