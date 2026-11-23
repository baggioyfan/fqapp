import 'package:flutter_lucide/flutter_lucide.dart';
import 'package:material_ui/material_ui.dart';

import '../models/media_item.dart';
import 'home/home_design.dart';

class DesktopChapterSidebar extends StatefulWidget {
  const DesktopChapterSidebar({
    super.key,
    required this.chapters,
    required this.currentIndex,
    required this.onSelected,
    this.width = 248,
    this.chapterUnit = '章',
    this.backgroundColor,
    this.borderColor,
    this.textColor,
    this.mutedColor,
    this.accentColor,
    this.inputFillColor,
    this.hoverColor,
    this.eink,
    this.collapseTooltip = '收起目录',
    this.onCollapse,
    this.showBorder = true,
  });

  final double width;
  final String chapterUnit;
  final List<Chapter> chapters;
  final int currentIndex;
  final ValueChanged<int> onSelected;
  final Color? backgroundColor;
  final Color? borderColor;
  final Color? textColor;
  final Color? mutedColor;
  final Color? accentColor;
  final Color? inputFillColor;
  final Color? hoverColor;
  final bool? eink;
  final String collapseTooltip;
  final VoidCallback? onCollapse;
  final bool showBorder;

  @override
  State<DesktopChapterSidebar> createState() => _DesktopChapterSidebarState();
}

class _DesktopChapterSidebarState extends State<DesktopChapterSidebar> {
  static const double _rowExtent = 38.0;

  final _scroll = ScrollController();
  final _searchCtrl = TextEditingController();
  String _query = '';

  @override
  void initState() {
    super.initState();
    _scrollToCurrent();
  }

  @override
  void didUpdateWidget(covariant DesktopChapterSidebar oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.currentIndex != widget.currentIndex && _query.isEmpty) {
      _scrollToCurrent();
    }
  }

  void _scrollToCurrent() {
    if (widget.currentIndex <= 0) return;
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted || !_scroll.hasClients) return;
      final position = _scroll.position;
      if (!position.hasContentDimensions) return;
      final target = (widget.currentIndex * _rowExtent - 80.0).clamp(
        0.0,
        position.maxScrollExtent,
      );
      _scroll.jumpTo(target);
    });
  }

  @override
  void dispose() {
    _scroll.dispose();
    _searchCtrl.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final palette = HomePalette.of(context);
    final effectiveEink = widget.eink ?? palette.eink;
    final bg = widget.backgroundColor ?? palette.surface;
    final border = widget.borderColor ?? palette.line;
    final ink = widget.textColor ?? palette.ink;
    final muted = widget.mutedColor ?? palette.muted;
    final accent =
        widget.accentColor ?? (effectiveEink ? ink : HomePalette.accent);
    final isDarkBg = !effectiveEink && bg.computeLuminance() <= 0.179;
    final effectiveHover =
        widget.hoverColor ?? ink.withValues(alpha: isDarkBg ? 0.08 : 0.05);
    final effectiveInputFill =
        widget.inputFillColor ??
        (effectiveEink
            ? Colors.white
            : (widget.backgroundColor != null
                  ? Color.alphaBlend(
                      ink.withValues(alpha: isDarkBg ? 0.07 : 0.045),
                      bg,
                    )
                  : palette.canvas.withValues(alpha: 0.55)));
    final indices = [
      for (var i = 0; i < widget.chapters.length; i++)
        if (_query.isEmpty || widget.chapters[i].title.contains(_query)) i,
    ];
    return SizedBox(
      width: widget.width,
      child: DecoratedBox(
        decoration: BoxDecoration(
          color: bg,
          border: widget.showBorder
              ? Border(right: BorderSide(color: border))
              : null,
        ),
        child: Material(
          color: Colors.transparent,
          child: Column(
            children: [
              Padding(
                padding: const EdgeInsets.fromLTRB(14, 10, 8, 6),
                child: Row(
                  children: [
                    Text(
                      '目录',
                      style: TextStyle(
                        fontSize: 13.5,
                        fontWeight: FontWeight.w700,
                        color: ink,
                      ),
                    ),
                    const SizedBox(width: 8),
                    Expanded(
                      child: Text(
                        '共 ${widget.chapters.length} ${widget.chapterUnit}',
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: TextStyle(fontSize: 11.5, color: muted),
                      ),
                    ),
                    if (widget.onCollapse != null)
                      IconButton(
                        tooltip: widget.collapseTooltip,
                        visualDensity: VisualDensity.compact,
                        constraints: const BoxConstraints.tightFor(
                          width: 30,
                          height: 30,
                        ),
                        padding: EdgeInsets.zero,
                        hoverColor: effectiveHover,
                        onPressed: widget.onCollapse,
                        icon: Icon(
                          LucideIcons.panel_left_close,
                          size: 16,
                          color: muted,
                        ),
                      ),
                  ],
                ),
              ),
              Padding(
                padding: const EdgeInsets.fromLTRB(12, 0, 12, 10),
                child: SizedBox(
                  height: 34,
                  child: TextField(
                    controller: _searchCtrl,
                    cursorColor: accent,
                    style: TextStyle(fontSize: 12.5, color: ink),
                    decoration: InputDecoration(
                      hintText: '搜索目录',
                      hintStyle: TextStyle(fontSize: 12.5, color: muted),
                      isDense: true,
                      filled: true,
                      fillColor: effectiveInputFill,
                      contentPadding: const EdgeInsets.symmetric(
                        horizontal: 8,
                        vertical: 0,
                      ),
                      prefixIcon: Icon(
                        LucideIcons.search,
                        size: 14,
                        color: muted,
                      ),
                      prefixIconConstraints: const BoxConstraints.tightFor(
                        width: 30,
                        height: 34,
                      ),
                      suffixIcon: _query.isEmpty
                          ? null
                          : IconButton(
                              tooltip: '清空',
                              padding: EdgeInsets.zero,
                              constraints: const BoxConstraints.tightFor(
                                width: 28,
                                height: 34,
                              ),
                              icon: Icon(LucideIcons.x, size: 13, color: muted),
                              onPressed: () {
                                _searchCtrl.clear();
                                setState(() => _query = '');
                              },
                            ),
                      enabledBorder: OutlineInputBorder(
                        borderRadius: BorderRadius.circular(8),
                        borderSide: BorderSide(color: border),
                      ),
                      focusedBorder: OutlineInputBorder(
                        borderRadius: BorderRadius.circular(8),
                        borderSide: BorderSide(color: accent, width: 1.2),
                      ),
                      border: OutlineInputBorder(
                        borderRadius: BorderRadius.circular(8),
                        borderSide: BorderSide(color: border),
                      ),
                    ),
                    onChanged: (value) => setState(() => _query = value.trim()),
                  ),
                ),
              ),
              Divider(height: 1, thickness: 1, color: border),
              Expanded(
                child: indices.isEmpty
                    ? Center(
                        child: Text(
                          '未找到匹配章节',
                          style: TextStyle(fontSize: 12.5, color: muted),
                        ),
                      )
                    : ListView.builder(
                        controller: _scroll,
                        padding: const EdgeInsets.symmetric(
                          horizontal: 6,
                          vertical: 6,
                        ),
                        itemExtent: _rowExtent,
                        itemCount: indices.length,
                        itemBuilder: (context, index) {
                          final i = indices[index];
                          final selected = i == widget.currentIndex;
                          return _ChapterRowTile(
                            title: widget.chapters[i].title,
                            selected: selected,
                            eink: effectiveEink,
                            ink: ink,
                            accent: accent,
                            hoverColor: effectiveHover,
                            onTap: () => widget.onSelected(i),
                          );
                        },
                      ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

class _ChapterRowTile extends StatelessWidget {
  const _ChapterRowTile({
    required this.title,
    required this.selected,
    required this.eink,
    required this.ink,
    required this.accent,
    required this.hoverColor,
    required this.onTap,
  });

  final String title;
  final bool selected;
  final bool eink;
  final Color ink;
  final Color accent;
  final Color hoverColor;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final fill = selected
        ? (eink ? ink.withValues(alpha: 0.10) : accent.withValues(alpha: 0.12))
        : Colors.transparent;
    return Material(
      color: fill,
      borderRadius: BorderRadius.circular(7),
      child: InkWell(
        borderRadius: BorderRadius.circular(7),
        hoverColor: hoverColor,
        onTap: onTap,
        child: Stack(
          alignment: Alignment.centerLeft,
          children: [
            if (selected)
              Positioned(
                left: 0,
                child: Container(
                  width: 3,
                  height: 16,
                  decoration: BoxDecoration(
                    color: accent,
                    borderRadius: BorderRadius.circular(2),
                  ),
                ),
              ),
            Padding(
              padding: const EdgeInsets.symmetric(horizontal: 10),
              child: Text(
                title,
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: TextStyle(
                  fontSize: 13,
                  fontWeight: selected ? FontWeight.w600 : FontWeight.w400,
                  color: selected ? accent : ink,
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }
}
