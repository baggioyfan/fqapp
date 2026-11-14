import 'package:material_ui/material_ui.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:fqapp/services/app_breakpoints.dart';

/// `appIsWideLayout` 是全站唯一宽屏判定（首页 / 短剧 / 书架 / 搜索都走它）。
/// 这里钉住断点位置，避免以后又被某个页面写回自己的 840。
void main() {
  Future<bool> wideAt(
    WidgetTester tester,
    double width, {
    double? override,
  }) async {
    bool? wide;
    await tester.pumpWidget(
      MediaQuery(
        data: MediaQueryData(size: Size(width, 800)),
        child: Builder(
          builder: (context) {
            wide = appIsWideLayout(context, width: override);
            return const SizedBox.shrink();
          },
        ),
      ),
    );
    return wide ?? false;
  }

  // flutter test 里 defaultTargetPlatform 被固定成 android，所以
  // isWindowsDesktop 恒假 —— 这几条量的是纯宽度分支。
  testWidgets('窗口宽度到 840 才算宽屏', (tester) async {
    expect(await wideAt(tester, 360), isFalse, reason: '手机竖屏');
    expect(await wideAt(tester, 411), isFalse, reason: '大屏手机');
    expect(await wideAt(tester, 800), isFalse, reason: '平板竖屏');
    expect(await wideAt(tester, 839), isFalse, reason: '断点前一像素');
    expect(await wideAt(tester, 840), isTrue, reason: '断点本身');
    expect(await wideAt(tester, 1280), isTrue, reason: '桌面窗口');
  });

  testWidgets('width 覆盖口优先于窗口宽度', (tester) async {
    // 窗口够宽，但局部容器只有 700 —— 以局部为准，别拿整窗误判。
    expect(await wideAt(tester, 1920, override: 700), isFalse);
    // 反过来也一样。
    expect(await wideAt(tester, 400, override: 1000), isTrue);
  });

  test('断点常量与各页面曾经写死的 840 一致', () {
    expect(appWideBreakpoint, 840);
  });
}
