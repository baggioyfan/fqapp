import 'package:material_ui/material_ui.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:fqapp/services/app_theme.dart';
import 'package:fqapp/widgets/reader/reader_theme.dart';

/// 阅读页主题与软件主题的隔离约束。
///
/// 来源是上游 `theme_selection_test.dart` 里随 #411 一起加的三段用例：本项目
/// 在 `c2adb229` 锁定经典主题后删掉了那份双主题选择的测试，但「阅读配色不能
/// 漏软件主题色」这条约束与双主题无关，仍然成立，所以单独落在这里。
///
/// 背景：`ReaderThemePreset.theme()` 由软件基底 `ThemeData.copyWith` 派生，而
/// ThemeData 的 chip / dialog / card / popup / divider 子主题在构造时就按软件
/// 明暗解析成了具体色值，copyWith 只换 colorScheme 不会重算它们 —— 于是深色
/// 软件 + 浅色阅读时，这些弹层和 chip 会漏出深色。
void main() {
  setUp(() {
    SharedPreferences.setMockInitialValues({});
    einkModeNotifier.value = false;
    oledModeNotifier.value = false;
    themeModeNotifier.value = ThemeMode.light;
  });
  tearDown(() {
    einkModeNotifier.value = false;
    oledModeNotifier.value = false;
    themeModeNotifier.value = ThemeMode.system;
  });

  test('reader chip colours follow the preset, not the app theme', () {
    final darkBase = AppTheme.createTheme(Brightness.dark);
    final lightBase = AppTheme.createTheme(Brightness.light);
    for (final preset in ReaderThemePreset.values) {
      // 浅色阅读预设叠在深色软件主题上，chip 配色必须来自阅读预设本身。
      final onDarkApp = preset.theme(darkBase);
      // 反向：深色阅读预设叠在浅色软件主题上。
      final onLightApp = preset.theme(lightBase);
      for (final theme in [onDarkApp, onLightApp]) {
        expect(theme.chipTheme.backgroundColor, preset.fieldColor);
        expect(
          theme.chipTheme.selectedColor,
          preset.accentColor.withValues(alpha: 0.12),
        );
        // ChoiceChip 选中背景读的是 secondarySelectedColor（不是
        // selectedColor），必须单独断言，否则会漏回深色。
        expect(
          theme.chipTheme.secondarySelectedColor,
          preset.accentColor.withValues(alpha: 0.12),
        );
        expect(theme.chipTheme.labelStyle?.color, preset.textColor);
        // 同一类泄漏的其余子主题：对话框 / 卡片 / 菜单 / 分隔线都必须
        // 跟随阅读预设，不能落在软件基色的深色上。
        expect(theme.dialogTheme.backgroundColor, preset.sheetColor);
        expect(theme.dialogTheme.titleTextStyle?.color, preset.textColor);
        expect(
          theme.dialogTheme.contentTextStyle?.color,
          preset.mutedTextColor,
        );
        expect(theme.cardTheme.color, preset.panelColor);
        expect(theme.popupMenuTheme.color, preset.panelColor);
        expect(theme.dividerTheme.color, preset.borderColor);
      }
      // 与软件主题无关：两种基底下派生出的 chip 配色完全一致。
      expect(onDarkApp.chipTheme.backgroundColor, preset.fieldColor);
      expect(onLightApp.chipTheme.backgroundColor, preset.fieldColor);
    }
  });

  // 字段设了不等于渲染对了：chip bug 的根因正是 secondarySelectedColor 没被
  // ChoiceChip 消费。这里在阅读预设子树里实渲染 Card / Dialog / 选中
  // ChoiceChip，直读绘制出来的 Material / Ink 颜色；Divider / PopupMenu 目前
  // 阅读无消费方（均显式传色或走自绘控件），改在真实 widget 的 element
  // context 上解析子主题，锁定「经嵌套 Theme 传到渲染 context」这一契约。
  testWidgets('reader subthemes reach the rendered widgets', (tester) async {
    final darkBase = AppTheme.createTheme(Brightness.dark);
    for (final preset in [ReaderThemePreset.light, ReaderThemePreset.dark]) {
      Color? dividerColor;
      Color? popupColor;
      await tester.pumpWidget(
        MaterialApp(
          theme: darkBase,
          home: Theme(
            data: preset.theme(darkBase),
            child: Builder(
              builder: (context) => Scaffold(
                body: Column(
                  children: [
                    const Card(
                      key: ValueKey('probe-card'),
                      child: SizedBox(height: 24),
                    ),
                    const Dialog(
                      key: ValueKey('probe-dialog'),
                      child: SizedBox(height: 24),
                    ),
                    const Divider(key: ValueKey('probe-divider')),
                    const ChoiceChip(
                      key: ValueKey('probe-chip'),
                      label: Text('选中'),
                      selected: true,
                    ),
                    Builder(
                      builder: (context) {
                        dividerColor = DividerTheme.of(context).color;
                        popupColor = PopupMenuTheme.of(context).color;
                        return const SizedBox.shrink();
                      },
                    ),
                  ],
                ),
              ),
            ),
          ),
        ),
      );
      await tester.pumpAndSettle();
      Material painted(String key) =>
          tester.widget<Material>(
            find
                .descendant(
                  of: find.byKey(ValueKey(key)),
                  matching: find.byType(Material),
                )
                .first,
          );
      // 卡片 / 对话框：实渲染 Material 的底色必须来自阅读预设。
      expect(painted('probe-card').color, preset.panelColor);
      expect(painted('probe-dialog').color, preset.sheetColor);
      // 选中 chip 真正画在 Ink 上的底色（本轮 bug 的载体），不能退回纯黑。
      final chipInk = tester.widget<Ink>(
        find
            .descendant(
              of: find.byKey(const ValueKey('probe-chip')),
              matching: find.byType(Ink),
            )
            .first,
      );
      expect(
        (chipInk.decoration! as ShapeDecoration).color,
        preset.accentColor.withValues(alpha: 0.12),
      );
      expect(
        (chipInk.decoration! as ShapeDecoration).color,
        isNot(Colors.black),
      );
      // 分隔线 / 弹出菜单：在当前渲染 context 解析到的子主题即预设色。
      expect(dividerColor, preset.borderColor);
      expect(popupColor, preset.panelColor);
      await tester.pumpWidget(const SizedBox.shrink());
    }
  });

  // 阅读 SnackBar 有意保持跟随软件主题（深色吐司叠在白底阅读上才看得
  // 见），preset.theme 不接管 snackBarTheme。把该设计约束钉死：一旦有人给
  // theme() 补上 snackBarTheme 覆盖，本测试立即红。
  test('reader leaves the snackbar theme to the app', () {
    for (final base in [
      AppTheme.createTheme(Brightness.dark),
      AppTheme.createTheme(Brightness.light),
    ]) {
      for (final preset in ReaderThemePreset.values) {
        // copyWith 没动 snackBarTheme，派生主题的该子主题应与软件基底同一实例。
        expect(preset.theme(base).snackBarTheme, same(base.snackBarTheme));
      }
    }
  });
}
