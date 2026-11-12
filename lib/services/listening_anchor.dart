/// 「从哪里开始听」的唯一判定。
///
/// 合并上游时这段逻辑被覆盖过不止一次：
///   * 2026-11-01 合并（35534e9）把 `final ttsTextId = textId ?? anchor.textId;`
///     换成了上游的 `if (textId != null)`，菜单进来的系统朗读一路 null 回落到
///     offset 0 —— 也就是章节开头。修复见 9d9aa0c9。
///   * `c9f3702e` 修复「没有 <span start_time> 的书从本段听落到章首」。
///
/// 之所以抽到这里：它是 private extension 方法时，test/ 里没有任何断言能碰到，
/// 上游每次把结构性冲突按整份落地，回归都只能靠人肉发现。抽成纯函数后
/// test/listening_anchor_test.dart 直接锁住行为，合并上游后一跑就知道有没有被顶掉。
library;

import 'package:flutter/foundation.dart';

/// 页内一段正文的锚点信息。
///
/// 刻意不依赖 `ReaderContentBlock`：那个类要排版、要 TextPainter，测试里构造
/// 一页的成本远高于它承载的三个字段。这里只留判定需要的输入。
@immutable
class ListeningAnchorCandidate {
  const ListeningAnchorCandidate({
    required this.firstLine,
    this.textId,
    this.startMs,
    this.isEmpty = false,
    this.isTitle = false,
    this.isImage = false,
  });

  /// 该段在本页从第几行开始。`0` 表示为这一页新起的一段；大于 `0` 说明是
  /// 上一页跨过来的段落尾巴。
  final int firstLine;

  /// 上游段落 id（`<p idx>`），没有时是排版算出的序数 id。
  final int? textId;

  /// 章节自带的朗读时间轴（`<span start_time>`）里的起点毫秒。
  final int? startMs;

  /// 正文为空（图片段、分隔符段等）。
  final bool isEmpty;
  final bool isTitle;
  final bool isImage;

  /// 标题、插图、空段都不是「能开口读的正文」，一律跳过。
  bool get skipForListening => isTitle || isImage || isEmpty;
}

/// 一个起播锚点：秒级起点与段落 id，两种坐标各自可能为空。
typedef ListeningAnchor = ({int? startMs, int? textId});

const ListeningAnchor emptyListeningAnchor = (startMs: null, textId: null);

/// 当前页的起播锚点。
///
/// 页首常常是上一页跨过来的段落尾巴（[ListeningAnchorCandidate.firstLine] >
/// 0）：拿它当锚点，播放会退到上一页那段正文的开头，用户听到的就不是眼前
/// 这段了。所以优先取 `firstLine == 0` 的段落；整页都是同一段的续行（超长
/// 段落跨多页）时才退回页首那段。
///
/// 一个能读的段落都没有（纯图页、空章）时返回 [emptyListeningAnchor]，由调用
/// 方各自兜底。
ListeningAnchor currentPageListeningAnchor(
  Iterable<ListeningAnchorCandidate> fragments,
) {
  ListeningAnchor? carried;
  for (final fragment in fragments) {
    if (fragment.skipForListening) continue;
    final anchor = (startMs: fragment.startMs, textId: fragment.textId);
    if (fragment.firstLine == 0) return anchor;
    carried ??= anchor;
  }
  return carried ?? emptyListeningAnchor;
}

/// 起播用的段落 id：**显式传入优先，否则用当前页第一段**。
///
/// 「显式传入」只有长按段落菜单的「从本段听」——它按住的那一刻就决定了读哪段。
/// 菜单进来的系统朗读不带段落 id，必须回落到页锚点，否则一路 null 落到 offset 0，
/// 也就是每次从章节开头开口。这正是 9d9aa0c9 修的那个回归，别把 `??` 丢掉。
int? resolveListeningTextId({int? explicit, int? pageAnchor}) =>
    explicit ?? pageAnchor;

/// 起播毫秒：调用方给的（长按段落算好的）优先，否则用页锚点的时间轴起点。
///
/// 两者都为空不是错误：章节可能不带 `<span start_time>`，此时由
/// `_openUpstreamListening` 退一步走 `/timepoints` 的段落映射。
int? resolveListeningStartMs({int? explicit, int? pageAnchor}) =>
    explicit ?? pageAnchor;
