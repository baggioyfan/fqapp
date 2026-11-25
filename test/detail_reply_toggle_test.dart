import 'package:material_ui/material_ui.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:fqapp/models/book_comment.dart';
import 'package:fqapp/models/comment_reply.dart';
import 'package:fqapp/widgets/detail/detail_comment_tile.dart';

void main() {
  Future<void> pump(WidgetTester tester, Widget child) async {
    await tester.pumpWidget(MaterialApp(home: Scaffold(body: child)));
    await tester.pumpAndSettle();
  }

  testWidgets('回复加载成功时显示上游总数', (tester) async {
    await pump(
      tester,
      DetailCommentTile(
        comment: const BookComment(id: 'c1', text: '书评正文', replyCount: 48),
        replyLoader: (_) async => const CommentReplyPage(
          replies: [CommentReply(id: 'r1', text: '第一条回复')],
          totalCount: 2,
        ),
      ),
    );

    expect(find.text('回复 48'), findsOneWidget);
    await tester.tap(find.byKey(const ValueKey('detail_reply_toggle_c1')));
    await tester.pumpAndSettle();

    expect(find.text('回复 2'), findsOneWidget);
    expect(find.text('第一条回复'), findsOneWidget);
  });

  testWidgets('上游回空列表时保留原计数，并给出可重试的失败回执', (tester) async {
    await pump(
      tester,
      DetailCommentTile(
        comment: const BookComment(id: 'c1', text: '书评正文', replyCount: 48),
        replyLoader: (_) async => CommentReplyPage.empty,
      ),
    );

    await tester.tap(find.byKey(const ValueKey('detail_reply_toggle_c1')));
    await tester.pumpAndSettle();

    // 不能把「回复 48」改写成「回复 0」，也不该谎报「暂无回复」。
    expect(find.text('回复 48'), findsOneWidget);
    expect(find.byKey(const ValueKey('detail_reply_error_c1')), findsOneWidget);
    expect(find.text('暂无回复'), findsNothing);
  });
}
