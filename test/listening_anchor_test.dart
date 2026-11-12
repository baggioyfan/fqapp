import 'package:flutter_test/flutter_test.dart';

import 'package:fqapp/services/listening_anchor.dart';

/// 「从哪里开始听」的回归网。
///
/// 这条规则被上游合并顶掉过不止一次（系统朗读每次都从章首开口、没有
/// `<span start_time>` 的书从本段听落到章首），而它原本藏在 reading page 的
/// private extension 里，test/ 里没有任何断言能碰到。这里把行为钉死：
/// 合并上游后只要 `flutter test` 红了，就知道起点判定又被整份覆盖回去了。
void main() {
  group('当前页锚点', () {
    test('页首就是新的一段时，用它当起点', () {
      final anchor = currentPageListeningAnchor(const [
        ListeningAnchorCandidate(firstLine: 0, textId: 7, startMs: 1200),
        ListeningAnchorCandidate(firstLine: 0, textId: 8, startMs: 5600),
      ]);
      expect(anchor.startMs, 1200);
      expect(anchor.textId, 7);
    });

    test('页首是上一页跨过来的段落尾巴时，不拿它当起点', () {
      // 第一段 firstLine=3 是上一页那段的后半截；用户眼前的新段落在第二行块。
      final anchor = currentPageListeningAnchor(const [
        ListeningAnchorCandidate(firstLine: 3, textId: 7, startMs: 1000),
        ListeningAnchorCandidate(firstLine: 0, textId: 8, startMs: 9000),
      ]);
      expect(anchor.textId, 8, reason: '从眼前这段开口，别退回上一页那段的开头');
      expect(anchor.startMs, 9000);
    });

    test('标题、插图、空段都不是能开口的正文', () {
      final anchor = currentPageListeningAnchor(const [
        ListeningAnchorCandidate(firstLine: 0, isTitle: true, textId: 1),
        ListeningAnchorCandidate(firstLine: 0, isImage: true, textId: 2),
        ListeningAnchorCandidate(firstLine: 0, isEmpty: true, textId: 3),
        ListeningAnchorCandidate(firstLine: 0, textId: 4, startMs: 300),
      ]);
      expect(anchor.textId, 4);
      expect(anchor.startMs, 300);
    });

    test('整页都是同一段的续行时，退回页首那段', () {
      // 超长段落跨多页：这一页所有片段 firstLine 都 > 0，没有更合适的锚点。
      final anchor = currentPageListeningAnchor(const [
        ListeningAnchorCandidate(firstLine: 2, textId: 11, startMs: 4200),
        ListeningAnchorCandidate(firstLine: 9, textId: 11, startMs: 4200),
      ]);
      expect(anchor.textId, 11, reason: '宁可退回续行，也不能一路 null 落到章首');
      expect(anchor.startMs, 4200);
    });

    test('一个能读的段落都没有时给出空锚点，由调用方兜底', () {
      final anchor = currentPageListeningAnchor(const [
        ListeningAnchorCandidate(firstLine: 0, isImage: true),
      ]);
      expect(anchor.startMs, isNull);
      expect(anchor.textId, isNull);
      expect(
        currentPageListeningAnchor(const <ListeningAnchorCandidate>[]),
        emptyListeningAnchor,
      );
    });
  });

  group('起播段落 id', () {
    test('长按「从本段听」显式传入的段落优先', () {
      expect(
        resolveListeningTextId(explicit: 42, pageAnchor: 7),
        42,
        reason: '用户按住的是哪段，就读哪段',
      );
    });

    test('菜单进来没有段落 id 时回落到当前页第一段', () {
      // 9d9aa0c9 的回归点：上游把这里写成 `if (textId != null)`，
      // 菜单进来的系统朗读一路 null，offset 停在 0 —— 每次都从章节开头开口。
      expect(
        resolveListeningTextId(explicit: null, pageAnchor: 7),
        7,
        reason: '没有显式段落时必须用页锚点，否则起点退回章首',
      );
    });

    test('两边都没有才返回 null', () {
      expect(resolveListeningTextId(explicit: null, pageAnchor: null), isNull);
    });
  });

  group('起播毫秒', () {
    test('长按段落算好的毫秒优先于页锚点时间轴', () {
      expect(resolveListeningStartMs(explicit: 66000, pageAnchor: 1200), 66000);
    });

    test('没有显式毫秒时用页锚点时间轴', () {
      expect(resolveListeningStartMs(explicit: null, pageAnchor: 1200), 1200);
    });

    test('章节不带时间轴时留给 /timepoints 兜底', () {
      // 不能在这里补一个 0 当成「章首」——那会让「正在获取本段音频…」这条
      // 段落映射路径永远走不到。
      expect(resolveListeningStartMs(explicit: null, pageAnchor: null), isNull);
    });
  });
}
