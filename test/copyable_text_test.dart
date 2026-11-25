import 'package:material_ui/material_ui.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:fqapp/widgets/comment_emoji.dart';
import 'package:fqapp/widgets/copyable_text.dart';

void main() {
  late List<String> copied;

  void mockClipboard(WidgetTester tester) {
    copied = <String>[];
    tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(
      SystemChannels.platform,
      (call) async {
        if (call.method == 'Clipboard.setData') {
          copied.add((call.arguments as Map)['text'] as String);
        }
        return null;
      },
    );
    addTearDown(
      () => tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(
        SystemChannels.platform,
        null,
      ),
    );
  }

  Future<void> pump(WidgetTester tester, Widget child) async {
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(body: Center(child: child)),
      ),
    );
    await tester.pumpAndSettle();
  }

  testWidgets('长按弹出系统选择菜单，默认整段选中后复制全文', (tester) async {
    mockClipboard(tester);
    await pump(
      tester,
      const CopyableText('开局废弃宗门，我召唤了大帝长老', textKey: Key('copyable_title')),
    );

    final l10n = MaterialLocalizations.of(
      tester.element(find.byType(Scaffold)),
    );
    await tester.longPress(find.byKey(const Key('copyable_title')));
    await tester.pumpAndSettle();

    // 系统菜单（复制 / 全选）出现，而不是应用自己弹的提示条。
    expect(find.text(l10n.copyButtonLabel), findsOneWidget);
    expect(find.byType(SnackBar), findsNothing);

    await tester.tap(find.text(l10n.copyButtonLabel));
    await tester.pumpAndSettle();

    // 默认选区是整段，不是一个汉字。
    expect(copied, ['开局废弃宗门，我召唤了大帝长老']);
    expect(tester.takeException(), isNull);
  });

  testWidgets('key 仍落在内部 Text 上，样式与截断行为不变', (tester) async {
    await pump(
      tester,
      const CopyableText(
        '三行折叠的简介',
        textKey: Key('copyable_body'),
        maxLines: 3,
        overflow: TextOverflow.ellipsis,
        style: TextStyle(fontSize: 13, height: 1.5),
      ),
    );

    final text = tester.widget<Text>(find.byKey(const Key('copyable_body')));
    expect(text.data, '三行折叠的简介');
    expect(text.maxLines, 3);
    expect(text.overflow, TextOverflow.ellipsis);
    expect(text.style?.fontSize, 13);
  });

  testWidgets('空文本不加选择区', (tester) async {
    mockClipboard(tester);
    await pump(tester, const CopyableText('   '));

    expect(find.byType(SelectionArea), findsNothing);
    await tester.longPress(find.text('   '));
    await tester.pumpAndSettle();
    expect(copied, isEmpty);
  });

  testWidgets('自定义渲染体（表情句）也能整段复制', (tester) async {
    mockClipboard(tester);
    await pump(
      tester,
      CopyableText(
        '[微笑]这是一条书评',
        child: const CommentEmojiText(
          text: '[微笑]这是一条书评',
          style: TextStyle(fontSize: 13),
        ),
      ),
    );

    final l10n = MaterialLocalizations.of(
      tester.element(find.byType(Scaffold)),
    );
    await tester.longPress(find.byType(CommentEmojiText));
    await tester.pumpAndSettle();
    await tester.tap(find.text(l10n.copyButtonLabel).last);
    await tester.pumpAndSettle();

    // 表情是内嵌图片（WidgetSpan），选区只能覆盖文字部分，所以复制结果不含
    // `[微笑]` 这个占位符——比把占位符原样抄进剪贴板更符合用户预期。
    expect(copied, ['这是一条书评']);
    expect(tester.takeException(), isNull);
  });

  testWidgets('按压回弹跟随指针，长按转选区后自动回落', (tester) async {
    await pump(
      tester,
      const CopyableText(
        '香瓜贼甜 ›',
        textKey: Key('copyable_author'),
        pressFeedback: true,
      ),
    );

    double scale() => tester
        .widget<Transform>(
          find.descendant(
            of: find.byType(CopyableText),
            matching: find.byType(Transform),
          ),
        )
        .transform
        .storage[0];

    final gesture = await tester.startGesture(
      tester.getCenter(find.byKey(const Key('copyable_author'))),
    );
    // 先走一帧启动 ticker，再推进 250ms 让弹簧落下。
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 250));
    expect(scale(), lessThan(0.99), reason: '按下应缩小');

    // 持续按住越过长按阈值：选区和菜单接管，文字不能一直缩着。
    await tester.pump(const Duration(milliseconds: 600));
    await tester.pumpAndSettle();
    expect(scale(), closeTo(1, 0.01), reason: '长按后应回落');

    await gesture.up();
    await tester.pumpAndSettle();
  });
}
