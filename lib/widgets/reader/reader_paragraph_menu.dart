// Ported from Wenku8_Flutter (revision ebcd7f1):
//   lib/reader_selection.dart -> _selectionAction / the glass selection bar
//
// The action set, anchor resolution and selection lifecycle stay fqapp's own
// (复制 / 划线, anchored to the touched paragraph). The upstream
// dark #303030 PopupWindow styling is replaced by one live glass bar with
// horizontal icon + label actions, matching upstream's context menu.
//
// Mechanical substitutions:
// - `app_ui.dart` AppText/ArchiveIcon/JellyTapSurface/LiquidGlass -> the
//   shared `lib/widgets/wenku` exports.
// - The upstream `GlassOverlaySurface` is not part of the shared slice yet;
//   the bar uses `LiquidGlass` with the reader's paper/night tint.
// - Arrow tips are dropped: upstream's glass bar sits 8dp from the anchor and
//   has no pointer.
import 'package:flutter/cupertino.dart';

import '../wenku/wenku_ui.dart';

/// What the reader can do with a long-pressed paragraph.
enum ReaderParagraphAction { copy, underline, removeUnderline }

/// Floating action bar for a long-pressed paragraph or a dragged selection.
///
/// Upstream Wenku8 shows its selection actions in a single glass bar with a
/// leading icon and a label. The fqapp reader keeps the action set it can
/// actually perform: 复制 / 划线, both for a long-pressed paragraph and for a
/// dragged character range.
///
/// 听书不在这里：听书只有一个起点（当前页第一段），所以入口也只有一个
/// （阅读工具栏那个按钮），长按段落不再单独给一个「从本段听」。
///
/// Note: 官方长按工具的版式与颜色取自反编译 m.java / wt.xml / wr.xml，见
/// .agents/notes/implemented/feature/2026-09-18-reader-paragraph-actions.md
class ReaderParagraphMenu extends StatelessWidget {
  /// Width reserved for one action in the anchor maths. The item itself is
  /// centred inside this slot so the bar width matches [resolvePosition].
  static const _itemWidth = 100.0;
  static const _itemHeight = 44.0;
  static const _iconSize = 20.0;
  static const _labelSize = 14.0;

  /// Upstream action padding: 12dp horizontal and vertical.
  static const _multiPadding = 6.0;

  /// The bar floats 8dp away from the anchor (upstream `anchorAbove - 8`).
  static const _arrowHeight = 8.0;

  static const _margin = 10.0;

  final bool underlined;
  final bool isDark;

  /// True for a whole-paragraph selection (long press). Both surfaces render
  /// the same two actions; the flag only decides the underline label.
  final bool paragraphScoped;

  /// True when the bar sits below the touched line. Kept because the reader
  /// page's anchor maths decides the flip side; the Wenku8 glass bar has no
  /// arrow tip of its own.
  final bool belowAnchor;

  /// Fired when an item is tapped. The bar is a plain overlay child of the
  /// reader page (the official one is a non-modal PopupWindow), so there is
  /// no route result to pop — the page owns the selection lifecycle.
  final ValueChanged<ReaderParagraphAction> onAction;

  const ReaderParagraphMenu({
    super.key,
    required this.onAction,
    this.underlined = false,
    this.isDark = false,
    this.paragraphScoped = true,
    this.belowAnchor = true,
  });

  /// Number of items the bar will render; the caller sizes the anchor with it.
  static const int itemCount = 2;

  /// Clamped top-left for the bar anchored at [anchor] (window coordinates),
  /// plus which side of the anchor it ended up on.
  ///
  /// [anchor] sits at the selection's last line bottom (plus clearance for
  /// the end caret's dot); [topAnchor] is the selection's first line top.
  /// The flip places the whole bar above [topAnchor], so a tall selection is
  /// never covered by its own bar; without a top anchor the flip falls back to
  /// the anchor point.
  ///
  /// The reader page calls this per build, so the bar never sits on the
  /// system bars or on the reader's own bottom toolbar ([avoidBottom]).
  static (Offset, bool) resolvePosition({
    required Offset anchor,
    Offset? topAnchor,
    required bool paragraphScoped,
    required Size view,
    required EdgeInsets safeArea,
    required bool underlined,
    double avoidBottom = 0,
  }) {
    const flipClearance = 10.0;
    final count = itemCount;
    final barWidth = count * _itemWidth + _multiPadding * 2;
    final barHeight = _itemHeight + _arrowHeight;

    final minLeft = _margin;
    final maxLeft = (view.width - barWidth - _margin).clamp(
      minLeft,
      double.infinity,
    );
    final left = (anchor.dx - barWidth / 2).clamp(minLeft, maxLeft);

    final minTop = safeArea.top + _margin;
    final bottomLimit = view.height - safeArea.bottom - avoidBottom - _margin;
    final maxTop = (bottomLimit - barHeight).clamp(minTop, double.infinity);
    final belowTop = anchor.dy + _arrowHeight;
    final below = belowTop + barHeight <= bottomLimit;
    final flippedTop =
        (topAnchor?.dy ?? anchor.dy) -
        barHeight -
        _arrowHeight -
        (topAnchor == null ? 0 : flipClearance);
    final top = (below ? belowTop : flippedTop).clamp(minTop, maxTop);
    return (Offset(left, top), below);
  }

  @override
  Widget build(BuildContext context) => LiquidGlass(
    key: const ValueKey('reader-selection-glass-bar'),
    radius: _radius,
    tintColor: _tint,
    padding: const EdgeInsets.symmetric(horizontal: _multiPadding, vertical: 0),
    child: Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        _Item(
          key: const ValueKey('reader-action-copy'),
          icon: CupertinoIcons.doc_on_doc,
          label: '复制',
          onTap: () => onAction(ReaderParagraphAction.copy),
        ),
        _Item(
          key: const ValueKey('reader-action-underline'),
          icon: underlined ? CupertinoIcons.delete : CupertinoIcons.pencil,
          label: underlined ? (paragraphScoped ? '取消划线' : '删除划线') : '划线',
          onTap: () => onAction(
            underlined
                ? ReaderParagraphAction.removeUnderline
                : ReaderParagraphAction.underline,
          ),
        ),
      ),
    ),
  );
}

/// One icon + label action in the upstream glass bar; the fixed slot keeps the
/// bar width equal to the anchor maths above.
class _Item extends StatelessWidget {
  final IconData icon;
  final String label;
  final VoidCallback onTap;

  const _Item({
    super.key,
    required this.icon,
    required this.label,
    required this.onTap,
  });

  @override
  Widget build(BuildContext context) => Semantics(
    button: true,
    label: label,
    child: JellyTapSurface(
      onTap: onTap,
      child: SizedBox(
        width: ReaderParagraphMenu._itemWidth,
        height: ReaderParagraphMenu._itemHeight,
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: 8),
          child: Row(
            mainAxisAlignment: MainAxisAlignment.center,
            children: [
              ArchiveIcon(icon, size: ReaderParagraphMenu._iconSize),
              const SizedBox(width: 8),
              Flexible(
                child: FittedBox(
                  fit: BoxFit.scaleDown,
                  child: Text(
                    label,
                    maxLines: 1,
                    style: const TextStyle(
                      fontSize: ReaderParagraphMenu._labelSize,
                      fontWeight: FontWeight.w600,
                    ),
                  ),
                ),
              ),
            ],
          ),
        ),
      ),
    ),
  );
}
