import 'package:flutter/material.dart';
import 'package:flutter_lucide/flutter_lucide.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:fqapp/widgets/home/home_media_card.dart';

/// 「值得一看」标题行右侧那个图标。
///
/// 它原来是一个没有回调的指南针（`LucideIcons.compass`）：看着像按钮、点下去
/// 什么都不会发生。现在要么是刷新按钮，要么整行不放任何东西 —— 这两种形态都
/// 由这条用例守住，别再退回「装饰性假按钮」。
void main() {
  Widget wrap(Widget child) => MaterialApp(home: Scaffold(body: child));

  testWidgets('给了回调才渲染刷新按钮，点击走同一处手动刷新', (tester) async {
    var taps = 0;
    await tester.pumpWidget(
      wrap(
        HomeSectionHeader(
          title: '值得一看',
          subtitle: '今天的故事',
          onRefresh: () async => taps++,
        ),
      ),
    );

    expect(find.text('值得一看'), findsOneWidget);
    expect(find.byKey(const Key('home_section_refresh')), findsOneWidget);
    // 换掉的是原来那个点不动的指南针，图标本身要能认出来。
    expect(find.byIcon(LucideIcons.refresh_cw), findsOneWidget);

    await tester.tap(find.byKey(const Key('home_section_refresh')));
    await tester.pump();
    expect(taps, 1);
  });

  testWidgets('没给回调就只留标题，不放点不动的图标', (tester) async {
    await tester.pumpWidget(
      wrap(const HomeSectionHeader(title: '值得一看', subtitle: '今天的故事')),
    );

    expect(find.byKey(const Key('home_section_refresh')), findsNothing);
    expect(find.byType(IconButton), findsNothing);
  });

  testWidgets('请求在途换成转圈，不给重复点击', (tester) async {
    var taps = 0;
    await tester.pumpWidget(
      wrap(
        HomeSectionHeader(
          title: '值得一看',
          subtitle: '今天的故事',
          busy: true,
          onRefresh: () async => taps++,
        ),
      ),
    );

    expect(find.byKey(const Key('home_section_refresh')), findsNothing);
    expect(find.byType(CircularProgressIndicator), findsOneWidget);
    expect(taps, 0);
  });
}
