import 'package:material_ui/material_ui.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:fqapp/models/book_comment.dart';
import 'package:fqapp/models/book_detail.dart';
import 'package:fqapp/models/comment_reply.dart';
import 'package:fqapp/models/media_item.dart';
import 'package:fqapp/models/series_detail.dart';
import 'package:fqapp/pages/detail_page.dart';
import 'package:fqapp/widgets/detail/detail_comment_tile.dart';
import 'package:fqapp/widgets/detail/detail_description.dart';
import 'package:fqapp/widgets/detail/detail_hero.dart';
import 'package:fqapp/widgets/home/home_design.dart';
import 'package:fqapp/widgets/series_detail/series_detail_hero.dart';
import 'package:fqapp/widgets/series_detail/series_detail_info.dart';

import 'support/fakes.dart';

const _title = '开局废弃宗门，我召唤了大帝长老';
const _author = '香瓜贼甜';
const _description =
    '苏狂身穿玄幻世界，激活无敌宗门系统，开局就召唤出了大帝境强者！\n'
    '只要招收天才进宗，还能继续抽取各类强者！\n'
    '而且弟子的修为精进，也能百倍返还给苏狂！\n'
    '于是，一段关于宗门、成长与奇遇的故事，就这样开始。';

const _review = '我有件事不明白，那些郁南郡的几个豪族是怎么敢把郁南郡的人抢完的。';
const _reply = '服软的带走，不服的杀了，那明年怎么办。';

final _book = MediaItem(
  id: 'detail-copy-book',
  title: _title,
  cover: '',
  author: _author,
  badge: '玄幻脑洞',
  ep: '',
  kind: 'book',
);

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

  /// 长按目标文本，等系统选择菜单出现，点「复制」。
  Future<void> longPressAndCopy(WidgetTester tester, Finder target) async {
    final l10n = MaterialLocalizations.of(
      tester.element(find.byType(Scaffold).first),
    );
    await tester.longPress(target);
    await tester.pumpAndSettle();
    final copy = find.text(l10n.copyButtonLabel);
    expect(copy, findsWidgets, reason: '长按后应弹出系统选择菜单');
    await tester.tap(copy.last);
    await tester.pumpAndSettle();
  }

  Future<void> pumpWidgetUnderTest(WidgetTester tester, Widget child) async {
    await tester.pumpWidget(
      MaterialApp(
        theme: ThemeData(
          colorSchemeSeed: HomePalette.accent,
          useMaterial3: true,
        ),
        home: child,
      ),
    );
    await tester.pumpAndSettle();
  }

  testWidgets('详情页书名与简介走系统菜单复制', (tester) async {
    mockClipboard(tester);
    await tester.binding.setSurfaceSize(const Size(393, 852));
    addTearDown(() => tester.binding.setSurfaceSize(null));
    await tester.pumpWidget(
      MaterialApp(
        theme: ThemeData(
          colorSchemeSeed: HomePalette.accent,
          useMaterial3: true,
        ),
        home: DetailPage(
          item: _book,
          readerStore: MemoryReaderStore(),
          detailLoader: (id, {String tab = '小说'}) async => {
            'data': {
              'book_name': _title,
              'abstract': _description,
              'author_info': {'user_name': _author, 'user_id': 'author-1'},
            },
          },
          directoryLoader: (id, {String tab = '小说'}) async => const [],
        ),
      ),
    );
    await tester.pumpAndSettle();

    await longPressAndCopy(tester, find.byKey(const Key('detail_book_title')));
    expect(copied, [_title]);

    // 折叠态（3 行）选中的是完整简介，不是屏幕上截断的那一段。
    final description = tester.widget<Text>(
      find.byKey(const Key('detail_description_text')),
    );
    expect(description.maxLines, 3);
    await tester.ensureVisible(
      find.byKey(const Key('detail_description_text')),
    );
    await tester.pumpAndSettle();
    await longPressAndCopy(
      tester,
      find.byKey(const Key('detail_description_text')),
    );
    expect(copied.last, _description);
    // 应用自己不再弹提示条，回执交给系统菜单。
    expect(find.byType(SnackBar), findsNothing);
    expect(tester.takeException(), isNull);
  });

  testWidgets('作者名走系统菜单复制，点按仍进作者主页', (tester) async {
    mockClipboard(tester);
    var opened = 0;
    await pumpWidgetUnderTest(
      tester,
      Scaffold(
        body: DetailHero(
          item: _book,
          detail: BookDetail(
            title: _title,
            author: const BookAuthor(name: _author, id: 'author-1'),
          ),
          onOpenAuthor: () => opened++,
        ),
      ),
    );

    await longPressAndCopy(tester, find.byKey(const Key('detail_author_name')));
    expect(copied, ['$_author ›']);
    expect(opened, 0);

    await tester.tap(find.byKey(const Key('detail_author_name')));
    await tester.pumpAndSettle();
    expect(opened, 1);
    expect(tester.takeException(), isNull);
  });

  testWidgets('经典简介块复制后仍可展开', (tester) async {
    mockClipboard(tester);
    await pumpWidgetUnderTest(
      tester,
      const Scaffold(body: DetailDescription(text: _description)),
    );

    await longPressAndCopy(
      tester,
      find.byKey(const Key('detail_description_text')),
    );
    expect(copied, [_description]);

    await tester.tap(find.byKey(const Key('detail_description_toggle')));
    await tester.pumpAndSettle();
    expect(
      tester
          .widget<Text>(find.byKey(const Key('detail_description_text')))
          .maxLines,
      isNull,
    );
    expect(tester.takeException(), isNull);
  });

  testWidgets('短剧剧名与简介走系统菜单复制，点按简介仍展开', (tester) async {
    mockClipboard(tester);
    await pumpWidgetUnderTest(
      tester,
      Scaffold(
        body: Column(
          children: [
            SeriesDetailHero(
              title: _title,
              coverUrl: '',
              statusLine: '全80集 · 8.7万次播放',
              categories: const ['都市'],
              playLabel: '播放',
              playEnabled: false,
              onPlay: () {},
              saved: false,
              shelfEnabled: true,
              shelfBusy: false,
              onToggleShelf: () {},
            ),
            SeriesDetailIntroSection(
              loading: false,
              failed: false,
              intro: _description,
              cast: const <CastMember>[],
              onRetry: () {},
            ),
          ],
        ),
      ),
    );

    await longPressAndCopy(
      tester,
      find.byKey(const ValueKey('series-detail-title')),
    );
    expect(copied, [_title]);

    await tester.ensureVisible(
      find.byKey(const ValueKey('series-detail-intro')),
    );
    await tester.pumpAndSettle();
    await longPressAndCopy(
      tester,
      find.byKey(const ValueKey('series-detail-intro')),
    );
    expect(copied.last, _description);

    await tester.tap(find.byKey(const ValueKey('series-detail-intro')));
    await tester.pumpAndSettle();
    expect(
      tester
          .widget<Text>(find.byKey(const ValueKey('series-detail-intro')))
          .maxLines,
      isNull,
    );
    expect(tester.takeException(), isNull);
  });

  testWidgets('书评正文与回复走系统菜单复制', (tester) async {
    mockClipboard(tester);
    await pumpWidgetUnderTest(
      tester,
      Scaffold(
        body: DetailCommentTile(
          maxTextLines: null,
          comment: BookComment(
            id: 'c1',
            text: _review,
            score: 8,
            replyCount: 1,
            userName: '甲',
            readSeconds: 3600,
            createdAt: DateTime(2026, 7, 1),
          ),
          replyLoader: (_) async => const CommentReplyPage(
            replies: [CommentReply(id: 'r1', text: _reply, userName: '乙')],
            totalCount: 1,
          ),
        ),
      ),
    );

    await longPressAndCopy(
      tester,
      find.byKey(const ValueKey('detail_review_text_c1')),
    );
    expect(copied, [_review]);

    // 展开回复后，回复正文同样可复制。
    await tester.tap(find.byKey(const ValueKey('detail_reply_toggle_c1')));
    await tester.pumpAndSettle();
    await longPressAndCopy(
      tester,
      find.byKey(const ValueKey('detail_reply_text_r1')),
    );
    expect(copied.last, _reply);
    expect(tester.takeException(), isNull);
  });
}
