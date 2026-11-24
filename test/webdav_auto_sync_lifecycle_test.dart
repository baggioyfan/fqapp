// WebDAV 自动同步的触发点守卫。
//
// 2026-11-23 的 6d1efa5b（桌面端换上游 Fluent 基底）把 main.dart 整份按上游
// 语义重写，连带删掉了三处 fork 自有接线：
//   1. beforeClose 里的 `WebdavAutoSync.instance.flush()`（关窗口前最后一次上云）
//   2. `_RootShellState` 的 WidgetsBindingObserver 与 didChangeAppLifecycleState
//      （退后台静默推、回前台问云端）
//   3. 首帧后的 `_checkRemoteUpdate()` 与「云端有更新 / 忽略 / 立即同步」弹窗
// 结果：同步的代码一行没少，但**没有任何人再调用它**，自动同步彻底静默，只剩
// 手动点「立即同步」。全量测试当时依然全绿 —— 因为没有一条用例从壳层这一侧
// 检查过「生命周期事件有没有真的打到 WebdavAutoSync 上」。
//
// 这里就钉这一件事：壳层挂上来之后，生命周期变化必须真的落到同步单例上。
// 谁再把观察者或 didChangeAppLifecycleState 弄丢，本用例立刻红。

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:material_ui/material_ui.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:fqapp/main.dart';
import 'package:fqapp/services/webdav_auto_sync.dart';

/// 只记账、不碰网络的替身。
///
/// 父类的方法会排 Timer、读 Hive、连服务器 —— 在 widget 测试的 fake async 里
/// 既跑不通也没必要，这里全部换成计数与空实现。
class _RecordingAutoSync extends WebdavAutoSync {
  int flushCalls = 0;
  int checkCalls = 0;

  @override
  Future<bool> flush() async {
    flushCalls++;
    return true;
  }

  @override
  Future<WebdavRemoteUpdate?> check() async {
    checkCalls++;
    return null; // 没有云端更新：不弹窗，用例只看调用次数。
  }

  @override
  Future<bool> syncOnLeave() async => true;

  @override
  void markDirty({
    Duration delay = WebdavAutoSync.debounceWindow,
    bool full = false,
  }) {}

  @override
  void markPlaybackWrite() {}

  @override
  void markPlaybackPaused() {}

  @override
  void cancelPlaybackPause() {}
}

void main() {
  late _RecordingAutoSync fake;
  late WebdavAutoSync original;

  setUp(() {
    SharedPreferences.setMockInitialValues({});
    original = WebdavAutoSync.instance;
    fake = _RecordingAutoSync();
    WebdavAutoSync.instance = fake;
  });

  tearDown(() {
    WebdavAutoSync.instance = original;
  });

  /// 挂上壳层。后端 starter 给个立即完成的空实现，避免真去拉本地服务。
  Future<void> pumpShell(WidgetTester tester) async {
    await tester.pumpWidget(
      ProviderScope(
        child: MaterialApp(home: RootShell(backendStarter: () async {})),
      ),
    );
    // 首帧结束才会跑 initState 里挂的 post-frame 回调，再 pump 一次让
    // `check()` 的 Future 走完。
    await tester.pump();
    await tester.pump();
  }

  testWidgets('壳层挂上后自己问一次云端', (tester) async {
    await pumpShell(tester);
    expect(
      fake.checkCalls,
      1,
      reason: '启动后没有检查云端更新：首帧的 _checkRemoteUpdate 接线丢了',
    );
    expect(tester.takeException(), isNull);
  });

  testWidgets('退到后台推一次，回到前台再问一次云端', (tester) async {
    await pumpShell(tester);
    final checksOnStart = fake.checkCalls;
    expect(fake.flushCalls, 0, reason: '刚启动不该退后台同步');

    tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.paused);
    expect(
      fake.flushCalls,
      1,
      reason: '退到后台没有推同步：didChangeAppLifecycleState 或观察者丢了',
    );

    tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.resumed);
    await tester.pump();
    expect(
      fake.checkCalls,
      checksOnStart + 1,
      reason: '回到前台没有复查云端更新',
    );
  });

  testWidgets('窗口被隐藏（hidden）也算退到后台', (tester) async {
    await pumpShell(tester);

    // 桌面端最小化只到 hidden，移动端也可能先 hidden 再 paused；
    // 这条路径同样要把待发的进度推上去。
    tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.hidden);
    expect(
      fake.flushCalls,
      1,
      reason: 'hidden 没有推同步：桌面最小化后就再没机会上云了',
    );

    tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.resumed);
    await tester.pump();
  });
}
