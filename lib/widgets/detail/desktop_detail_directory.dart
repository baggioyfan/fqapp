import 'package:material_ui/material_ui.dart';
import 'package:flutter_lucide/flutter_lucide.dart';

import '../../models/media_item.dart';
import '../home/home_design.dart';
import 'detail_chapter_row.dart';
import 'detail_states.dart';

/// Desktop 目录 card shown beside the synopsis on the wide Windows layout.
///
/// A display-only shell: the caller keeps the full catalogue, the saved order
/// and the navigation. Search and the 正序/倒序 toggle only reshape the visible
/// rows, so [onSelected] always reports an index into the unmodified
/// [chapters] list and the caller can reuse its own chapter lookup.
class DesktopDetailDirectory extends StatefulWidget {
  const DesktopDetailDirectory({
    super.key,
    required this.chapters,
    required this.countLabel,
    required this.reversed,
    required this.orderSaving,
    required this.onToggleOrder,
    required this.onSelected,
    required this.onOpenAll,
    this.currentIndex,
    this.error,
    this.onRetry,
    this.retrying = false,
  });

  /// Rows shown at once; the full catalogue stays behind [onOpenAll].
  static const int previewCount = 5;

  /// The untransformed catalogue that callback indexes refer to.
  final List<Chapter> chapters;

  /// Preformatted `5 卷 · 146 章` / `暂无目录` line owned by the page.
  final String countLabel;

  /// Persisted catalogue order; `true` lists the newest chapter first.
  final bool reversed;

  /// True while the page persists an order change; the toggle stays locked.
  final bool orderSaving;

  /// Index of the saved chapter in [chapters]; null when unread.
  final int? currentIndex;

  /// Directory load failure; null on success. [onRetry] drives the retry.
  final String? error;
  final VoidCallback? onRetry;
  final bool retrying;

  final VoidCallback onToggleOrder;

  /// Fires with the tapped chapter's index in [chapters].
  final ValueChanged<int> onSelected;

  /// Opens the existing searchable full-directory sheet.
  final VoidCallback onOpenAll;

  @override
  State<DesktopDetailDirectory> createState() => _DesktopDetailDirectoryState();
}

class _DesktopDetailDirectoryState extends State<DesktopDetailDirectory> {
  String _query = '';

  /// Catalogue indexes that pass the search, kept in the supplied order.
  List<int> get _matchingIndexes {
    final total = widget.chapters.length;
    final query = _query;
    final indexes = <int>[];
    for (var step = 0; step < total; step++) {
      final index = widget.reversed ? total - 1 - step : step;
      if (query.isNotEmpty && !widget.chapters[index].title.contains(query)) {
        continue;
      }
      indexes.add(index);
    }
    return indexes;
  }

  /// Up to [DesktopDetailDirectory.previewCount] matches, in supplied order.
  ///
  /// A visible current chapter anchors the window so its highlight is not lost
  /// in a long book; when the current chapter is filtered out, the window
  /// falls back to the first matches.
  List<int> get _visibleIndexes {
    final matches = _matchingIndexes;
    const count = DesktopDetailDirectory.previewCount;
    if (matches.length <= count) return matches;
    final currentIndex = widget.currentIndex;
    final position = currentIndex == null ? -1 : matches.indexOf(currentIndex);
    if (position < count) return matches.sublist(0, count);
    final start = (position - count ~/ 2)
        .clamp(0, matches.length - count)
        .toInt();
    return matches.sublist(start, start + count);
  }

  @override
  Widget build(BuildContext context) {
    final palette = HomePalette.of(context);
    return Material(
      key: const Key('desktop_detail_directory'),
      color: palette.surface,
      clipBehavior: Clip.antiAlias,
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(12),
        side: BorderSide(color: palette.line),
      ),
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            _header(palette),
            const SizedBox(height: 12),
            _searchField(palette),
            const SizedBox(height: 8),
            _body(palette),
            const SizedBox(height: 12),
            _openAll(palette),
          ],
        ),
      ),
    );
  }

  Widget _header(HomePalette palette) {
    return Row(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Expanded(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(
                '目录',
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: TextStyle(
                  color: palette.ink,
                  fontSize: 15,
                  height: 1.5,
                  fontWeight: FontWeight.w700,
                ),
              ),
              const SizedBox(height: 2),
              Text(
                widget.countLabel,
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: TextStyle(
                  color: palette.muted,
                  fontSize: 12,
                  height: 1.5,
                ),
              ),
            ],
          ),
        ),
        const SizedBox(width: 12),
        _orderToggle(palette),
      ],
    );
  }

  Widget _orderToggle(HomePalette palette) {
    final enabled = !widget.orderSaving && widget.chapters.length >= 2;
    final color = enabled ? palette.ink : palette.muted;
    return _control(
      key: const Key('desktop_detail_directory_order'),
      semanticLabel: '目录顺序',
      semanticValue: widget.reversed ? '倒序' : '正序',
      enabled: enabled,
      onTap: widget.onToggleOrder,
      child: Container(
        padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 4),
        decoration: BoxDecoration(
          borderRadius: BorderRadius.circular(999),
          border: Border.all(color: palette.line),
        ),
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(LucideIcons.arrow_up_down, size: 14, color: color),
            const SizedBox(width: 4),
            Text(
              widget.reversed ? '倒序' : '正序',
              style: TextStyle(color: color, fontSize: 12, height: 1.5),
            ),
          ],
        ),
      ),
    );
  }

  Widget _searchField(HomePalette palette) {
    final border = OutlineInputBorder(
      borderRadius: BorderRadius.circular(8),
      borderSide: BorderSide(color: palette.line),
    );
    return TextField(
      key: const Key('desktop_detail_directory_search'),
      onChanged: (value) => setState(() => _query = value.trim()),
      style: TextStyle(color: palette.ink, fontSize: 13, height: 1.5),
      decoration: InputDecoration(
        labelText: '搜索目录',
        hintText: '搜索目录',
        hintStyle: TextStyle(color: palette.muted, fontSize: 13),
        prefixIcon: Icon(LucideIcons.search, size: 18, color: palette.muted),
        prefixIconConstraints: const BoxConstraints(
          minWidth: 38,
          minHeight: 36,
        ),
        isDense: true,
        filled: true,
        fillColor: palette.soft,
        contentPadding: const EdgeInsets.symmetric(vertical: 10),
        border: border,
        enabledBorder: border,
        focusedBorder: border.copyWith(
          borderSide: BorderSide(color: palette.mark, width: 1.4),
        ),
      ),
    );
  }

  Widget _body(HomePalette palette) {
    final error = widget.error;
    if (error != null) {
      if (widget.retrying) {
        return Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            _message(palette, error),
            const SizedBox(height: 10),
            const LinearProgressIndicator(),
          ],
        );
      }
      return widget.onRetry == null
          ? _message(palette, error)
          : DetailInlineError(message: error, onRetry: widget.onRetry!);
    }
    if (widget.chapters.isEmpty) return _message(palette, '暂无目录');
    final indexes = _visibleIndexes;
    if (indexes.isEmpty) return _message(palette, '没有匹配的章节');
    final currentIndex = widget.currentIndex;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        for (var row = 0; row < indexes.length; row++)
          DetailChapterRow(
            key: Key('desktop_detail_directory_row_${indexes[row]}'),
            chapter: widget.chapters[indexes[row]],
            current: indexes[row] == currentIndex,
            read: currentIndex != null && indexes[row] < currentIndex,
            divider: row < indexes.length - 1,
            onTap: () => widget.onSelected(indexes[row]),
          ),
      ],
    );
  }

  Widget _message(HomePalette palette, String text) {
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 6),
      child: Text(
        text,
        style: TextStyle(color: palette.muted, fontSize: 13, height: 1.5),
      ),
    );
  }

  Widget _openAll(HomePalette palette) {
    final enabled = widget.chapters.isNotEmpty && widget.error == null;
    final color = enabled ? palette.ink : palette.muted;
    return _control(
      key: const Key('desktop_detail_directory_all'),
      semanticLabel: '查看完整目录',
      enabled: enabled,
      onTap: widget.onOpenAll,
      child: Container(
        alignment: Alignment.center,
        padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
        decoration: BoxDecoration(
          borderRadius: BorderRadius.circular(999),
          border: Border.all(color: palette.line),
        ),
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            Text(
              '查看完整目录',
              style: TextStyle(color: color, fontSize: 13, height: 1.5),
            ),
            const SizedBox(width: 4),
            Icon(LucideIcons.chevron_right, size: 15, color: color),
          ],
        ),
      ),
    );
  }

  /// A capsule control that carries its disabled state in both hit testing and
  /// the semantics tree, so a locked control is not announced as actionable.
  Widget _control({
    required Key key,
    required String semanticLabel,
    String? semanticValue,
    required bool enabled,
    required VoidCallback onTap,
    required Widget child,
  }) {
    return Semantics(
      key: key,
      enabled: enabled,
      button: true,
      label: semanticLabel,
      value: semanticValue,
      onTap: enabled ? onTap : null,
      child: ExcludeSemantics(
        child: IgnorePointer(
          ignoring: !enabled,
          child: HomePressable(
            onTap: onTap,
            borderRadius: BorderRadius.circular(999),
            child: child,
          ),
        ),
      ),
    );
  }
}
