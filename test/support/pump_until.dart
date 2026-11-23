import 'package:flutter_test/flutter_test.dart';

/// 有界推进到 [finder] 命中为止(最多 [maxPumps] 帧),不依赖界面静止。
///
/// 启动态(`AppBootstrap` 的本地数据闸门)画的是首页骨架,而骨架自带
/// `repeat(reverse: true)` 的无限脉动:只要它还在位,`pumpAndSettle()` 就永远
/// 等不到静止,会一路卡到默认超时。等待启动闸门放行时必须用这里的有界推进。
///
/// 单次 `pump()` 也不够:本地数据就绪的回调是微任务,而 `pump()` 只在有帧被
/// 调度时才重建界面,那一次 pump 只会把微任务跑掉、把重建排到下一帧。
///
/// 不能等真实文件 I/O:两帧之间只推进微任务与帧调度,真实 I/O 要的是
/// wall-clock 时间。那种场景先用 `runAsync` 备好数据,或继续用
/// `pumpAndSettle()` 等启动闸门放行。
///
/// 命中即返回;调用方随后用 `expect(finder, findsOneWidget)` 给出失败信息。
Future<void> pumpUntilFound(
  WidgetTester tester,
  Finder finder, {
  int maxPumps = 10,
}) async {
  for (var i = 0; i < maxPumps && finder.evaluate().isEmpty; i++) {
    await tester.pump();
  }
}
