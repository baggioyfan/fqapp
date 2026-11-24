// issue #478：上下两条栏收窄，让书架宫格多露一截。
//
// 这一组用例只锁“高度账”，不锁像素外观：底部胶囊 56 + 8 间隙 + 16 呼吸
// 必须等于 ShelfTokens.contentBottomInset；书架一级 tab 用的 dense 段控件
// 必须比默认档矮 6dp（胶囊 48 → 44、外留白 4 → 3）。
import 'package:material_ui/material_ui.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:fqapp/services/app_theme.dart';
import 'package:fqapp/services/app_theme_style.dart';
import 'package:fqapp/widgets/shelf/shelf_design.dart';
import 'package:fqapp/widgets/wenku/wenku_segments.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  test('内容区底部留白 = 底栏胶囊 56 + 间隙 8 + 呼吸 16', () {
    // 与 lib/pages/library_classic_views.dart 的 _classicRootDock* 同源：
    // 胶囊 64 → 56 后留白从 88 收到 80，最后一行与底栏的视觉间距不变。
    expect(ShelfTokens.contentBottomInset, 80);
  });

  testWidgets('dense 段控件比默认档矮 6dp（书架一级 tab 走这一档）', (tester) async {
    await tester.binding.setSurfaceSize(const Size(400, 800));
    addTearDown(() => tester.binding.setSurfaceSize(null));

    Future<double> pumpSegments({required Key key, required bool dense}) async {
      await tester.pumpWidget(
        MaterialApp(
          theme: AppTheme.createTheme(
            Brightness.light,
            style: AppThemeStyle.archive,
          ),
          home: Scaffold(
            body: Center(
              child: SizedBox(
                width: 320,
                child: Builder(
                  builder: (context) => WenkuControls.segments<int>(
                    context,
                    key: key,
                    dense: dense,
                    groupValue: 0,
                    children: const {
                      0: Text('书架'),
                      1: Text('浏览历史'),
                      2: Text('收藏'),
                    },
                    onValueChanged: (_) {},
                  ),
                ),
              ),
            ),
          ),
        ),
      );
      await tester.pumpAndSettle();
      return tester.getSize(find.byKey(key)).height;
    }

    const baseKey = ValueKey('segments-base');
    const denseKey = ValueKey('segments-dense');

    final base = await pumpSegments(key: baseKey, dense: false);
    final dense = await pumpSegments(key: denseKey, dense: true);

    // 默认 48 胶囊 + 上下各 4 留白 = 56；dense 44 + 3 = 50。
    expect(base, 56);
    expect(dense, 50);
    expect(base - dense, 6);
  });
}
