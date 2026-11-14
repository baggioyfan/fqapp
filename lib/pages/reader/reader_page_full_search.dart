part of '../reader_page.dart';

/// Full-book lookup uses the chapter cache/loader without changing the active
/// chapter, history or progress. Only choosing a hit enters reader navigation.
extension _ReaderPageFullSearch on _ReaderPageState {
  Future<void> _showFullSearch() async {
    if (widget.chapters.isEmpty) return;
    final generation = ++_readerNavigationGeneration;
    _stopAutoTurn();
    _takeOverListening();
    _readerPanelOpen = true;
    _setControlsVisible(false);
    try {
      await _replacementStore.load();
    } catch (_) {
      if (mounted && generation == _readerNavigationGeneration) {
        _showMessage('替换设置暂时无法读取，请重试');
      }
      return;
    }
    if (!mounted || generation != _readerNavigationGeneration) return;
    final snapshot = _replacementStore.snapshot;
    final preset = _effectivePreset;
    var active = true;
    ReaderFullSearchHit? hit;
    try {
      hit = await showJellySheet<ReaderFullSearchHit>(
        context: context,
        reduceMotion: _reduceReaderMotion,
        surfaceWrapper: (child) => _readerOverlay(preset, child),
        builder: (_) => ReaderFullSearchPanel(
          chapters: widget.chapters,
          preset: preset,
          loadChapter: (chapter) async =>
              throw StateError('Search requires cancellation context'),
          loadChapterForSearch: (chapter, cancellation) async {
            if (!mounted || !active) throw StateError('Search closed');
            final loaded = await _chapterTextForSearch(chapter, cancellation);
            cancellation.throwIfCancelled();
            if (!mounted || !active) throw StateError('Search closed');
            final content = ChapterContent.fromCacheText(loaded.text);
            // 与正文同一条替换管线（`TextReplacementEngine.transform`）：
            // 全文搜索要搜的是用户实际看到的文字，但这里不能碰当前章的
            // 排版/替换状态，所以只算一份结果，不走 `_replaceContent`
            // （那个方法持有正在显示章节的取消状态）。
            final replacement =
                await (widget.replacementEngine ??
                        TextReplacementEngine.instance)
                    .transform(
                      source: content,
                      chapterTitle: chapter.title,
                      snapshot: snapshot,
                    );
            cancellation.throwIfCancelled();
            return replacement;
          },
        ),
      );
    } finally {
      active = false;
    }
    if (!mounted || hit == null || generation != _readerNavigationGeneration) {
      return;
    }
    final selected = hit;
    // Serialize with bookmarks as both use the same chapter navigation path.
    final previous = _bookmarkNavigationTask;
    final task = () async {
      try {
        await previous;
      } catch (_) {
        // A failed earlier navigation must not prevent the newest selection.
      }
      if (!mounted || generation != _readerNavigationGeneration) return;
      await _navigateFullSearchHit(selected, generation);
    }();
    _bookmarkNavigationTask = task;
    try {
      await task;
    } catch (_) {
      if (mounted && generation == _readerNavigationGeneration) {
        _showMessage('搜索结果暂时无法打开，请重试');
      }
    } finally {
      if (identical(_bookmarkNavigationTask, task)) {
        _bookmarkNavigationTask = null;
      }
    }
  }

  Future<void> _navigateFullSearchHit(
    ReaderFullSearchHit hit,
    int generation,
  ) async {
    final target = widget.chapters.indexWhere((c) => c.itemId == hit.chapterId);
    if (target < 0) {
      _showMessage('目录中已找不到这条结果的章节');
      return;
    }
    // Ordinary next/previous navigation is independent of the bookmark queue.
    // Wait for it before taking the lock, even if its destination is this hit.
    while (_chapterNavigationCompletion != null) {
      await _chapterNavigationCompletion!.future;
      if (!mounted || generation != _readerNavigationGeneration) return;
    }
    if (!mounted || generation != _readerNavigationGeneration) return;
    _takeOverListening();
    if (target != _index) {
      await _jumpToChapter(target, navigationGeneration: generation);
    }
    if (!mounted || generation != _readerNavigationGeneration) return;
    if (_chapter.itemId != hit.chapterId || _error != null) {
      _showMessage(_error != null ? '目标章节加载失败，请重试' : '搜索结果暂时无法打开，请重试');
      return;
    }
    // Wait for chapter restore before positioning the selected hit.
    await WidgetsBinding.instance.endOfFrame;
    if (!mounted ||
        generation != _readerNavigationGeneration ||
        _chapter.itemId != hit.chapterId) {
      return;
    }
    final layout = _chapterLayout;
    if (layout == null || !_progressReady || _loading) {
      _showMessage('正文尚未就绪，请稍后重新搜索');
      return;
    }
    if (!hit.matchesSource(_replacement?.source ?? _chapterContent)) {
      _showMessage('正文已更新，请重新搜索');
      return;
    }
    final anchor = layout.displayOffsetForSource(hit.sourceParagraphStart);
    final block = layout.blockAtOffset(anchor);
    // Use the source anchor to locate the paragraph, then its exact local
    // display range. A lossy source round trip of the hit itself can expand an
    // in-replacement match to the entire replacement, even thousands of words.
    final range = block == null || block.isTitle || block.isImage
        ? null
        : hit.displayRange(block.text, block.start);
    if (range == null) {
      _showMessage('正文已更新，请重新搜索');
      return;
    }
    await _landAtOffset(range.start, end: range.end);
  }
}
