import 'package:material_ui/material_ui.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:fqapp/services/app_style_tokens.dart';
import 'package:fqapp/services/app_theme_style.dart';

/// 界面只留经典一套：档案版式（纸张底色 / 档案编号 / 留白排版）已从 fork 移除。
///
/// 上游仓库仍保留双版式，而 `lib/services/app_theme_style.dart` 并不在上游的
/// 改动清单里 —— 任何一次「整文件取上游」或「冲突选 theirs」都会把
/// `_ => archive` 的默认值带回来，且**不会有任何报错**，界面只是悄悄变成档案皮。
/// 把这条硬约束钉成测试，让那种回归在 CI 里直接红。
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  setUp(() {
    SharedPreferences.resetStatic();
    SharedPreferences.setMockInitialValues({});
  });

  group('fromStorage 只认经典', () {
    test('任何历史值都落到 classic', () {
      for (final value in const <Object?>[
        null,
        'archive',
        'classic',
        'unknown',
        42,
      ]) {
        expect(
          AppThemeStyle.fromStorage(value),
          AppThemeStyle.classic,
          reason: 'fromStorage($value) 把档案版式放回来了',
        );
      }
    });

    test('预置 archive 的旧存档加载后仍是 classic', () async {
      SharedPreferences.setMockInitialValues(const {
        AppThemeStyleStore.storageKey: 'archive',
      });
      final store = AppThemeStyleStore();
      addTearDown(store.dispose);

      await store.load();

      expect(store.value, AppThemeStyle.classic);
    });

    test('加载失败不抛错，保持经典', () async {
      final store = AppThemeStyleStore(
        preferences: () async => throw StateError('prefs 不可用'),
      );
      addTearDown(store.dispose);

      await store.load();

      expect(store.value, AppThemeStyle.classic);
    });
  });

  testWidgets('主题挂上经典 token 后，页面读到的是经典度量', (tester) async {
    late AppStyleTokens tokens;
    await tester.pumpWidget(
      MaterialApp(
        theme: ThemeData(extensions: const [AppStyleTokens.classic()]),
        home: Builder(
          builder: (context) {
            tokens = AppStyleTokens.of(context);
            return const SizedBox.shrink();
          },
        ),
      ),
    );

    expect(tokens.style, AppThemeStyle.classic);
    // 经典度量：12 / 16 / 8；档案是 16 / 24 / 14。
    expect(tokens.panelPadding, 12);
    expect(tokens.pageGutter, 16);
    expect(tokens.entryGap, 8);
    expect(tokens.showDecorativeCodes, isFalse);
  });
}
