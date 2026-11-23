part of '../reader_page.dart';

/// Reader scaffold: desktop chrome, surface, toolbar and error view.
extension _ReaderPageBuild on _ReaderPageState {
  ({
    bool isDark,
    bool isEink,
    Color barBackground,
    Color surface,
    Color hoverBackground,
    Color border,
    Color ink,
    Color muted,
    Color accent,
  })
  _desktopChromePalette() {
    final preset = _effectivePreset;
    final bg = _effectiveBackgroundColor;
    if (preset.isEink) {
      return (
        isDark: false,
        isEink: true,
        barBackground: Colors.white,
        surface: Colors.white,
        hoverBackground: Colors.black.withValues(alpha: 0.08),
        border: Colors.black,
        ink: Colors.black,
        muted: Colors.black,
        accent: Colors.black,
      );
    }
    if (preset.isOled) {
      return (
        isDark: true,
        isEink: false,
        barBackground: preset.panelColor,
        surface: preset.fieldColor,
        hoverBackground: const Color(0xFF1F1F23),
        border: preset.borderColor,
        ink: preset.textColor,
        muted: preset.mutedTextColor,
        accent: preset.accentColor,
      );
    }
    final customBg = _displayPreferences.customBackgroundColor != null;
    final isDarkSurface = preset.isDark || bg.computeLuminance() <= 0.179;
    if (isDarkSurface) {
      final ink = customBg && !preset.isDark
          ? const Color(0xFFD6D6D6)
          : preset.textColor;
      return (
        isDark: true,
        isEink: false,
        barBackground: Color.alphaBlend(ink.withValues(alpha: 0.04), bg),
        surface: Color.alphaBlend(ink.withValues(alpha: 0.08), bg),
        hoverBackground: ink.withValues(alpha: 0.09),
        border: ink.withValues(alpha: 0.11),
        ink: ink,
        muted: ink.withValues(alpha: 0.65),
        accent: customBg && !preset.isDark
            ? ReaderThemePreset.dark.accentColor
            : preset.accentColor,
      );
    }
    final ink = customBg ? const Color(0xFF292724) : preset.textColor;
    return (
      isDark: false,
      isEink: false,
      barBackground: Color.alphaBlend(ink.withValues(alpha: 0.03), bg),
      surface: Color.alphaBlend(const Color(0x80FFFFFF), bg),
      hoverBackground: ink.withValues(alpha: 0.06),
      border: ink.withValues(alpha: 0.11),
      ink: ink,
      muted: ink.withValues(alpha: 0.62),
      accent: preset.accentColor,
    );
  }

  void _syncDesktopShell({bool? canToggleSidebar, bool? canToggleFullscreen}) {
    if (!isDesktopHost) return;
    if (canToggleSidebar != null) {
      _desktopCanToggleSidebar = canToggleSidebar;
    }
    if (canToggleFullscreen != null) {
      _desktopCanToggleFullscreen = canToggleFullscreen;
    }
    if (!_ownsDesktopShell) {
      DesktopShellState.clearReaderChrome(_desktopShellOwner);
      return;
    }
    final colors = _desktopChromePalette();
    DesktopShellState.setReaderChrome(
      DesktopReaderChrome(
        owner: _desktopShellOwner,
        title: widget.title,
        isDark: colors.isDark,
        isEink: colors.isEink,
        barBackground: colors.barBackground,
        surface: colors.surface,
        hoverBackground: colors.hoverBackground,
        border: colors.border,
        ink: colors.ink,
        muted: colors.muted,
        accent: colors.accent,
        canToggleSidebar: _desktopCanToggleSidebar,
        sidebarOpen: _preferences.desktopSidebarOpen,
        canToggleFullscreen: _desktopCanToggleFullscreen,
        onToggleSidebar: _toggleDesktopSidebar,
      ),
    );
  }

  Widget _buildReader(BuildContext context) {
    if (!isDesktopHost) return _buildReaderSurface(context);
    final chromeColors = _desktopChromePalette();
    final hasFrame = DesktopShellScope.hasFrameOf(context);
    return ValueListenableBuilder<bool>(
      valueListenable: DesktopPlatform.fullscreen,
      builder: (context, fullscreen, _) => LayoutBuilder(
        builder: (context, bounds) {
          const sidebarWidth = 248.0;
          final columnMode = _displayPreferences.columnMode;
          final automaticSpreadWithoutSidebar =
              _paged &&
              columnMode == ReaderColumnMode.auto &&
              columnMode.resolveColumns(
                    Size(bounds.maxWidth, bounds.maxHeight),
                  ) >
                  1;
          final sidebarWouldDisableAutomaticSpread =
              automaticSpreadWithoutSidebar &&
              columnMode.resolveColumns(
                    Size(bounds.maxWidth - sidebarWidth, bounds.maxHeight),
                  ) ==
                  1;
          final canDockSidebar =
              !fullscreen &&
              bounds.maxWidth >= 1000 &&
              !sidebarWouldDisableAutomaticSpread;
          final canToggleFullscreen = !fullscreen && bounds.maxWidth >= 700;
          final showSidebar = canDockSidebar && _preferences.desktopSidebarOpen;
          _syncDesktopShell(
            canToggleSidebar: canDockSidebar,
            canToggleFullscreen: canToggleFullscreen,
          );
          final viewport = Size(
            bounds.maxWidth - (showSidebar ? sidebarWidth : 0),
            bounds.maxHeight,
          );
          final wideSpread =
              _paged &&
              _displayPreferences.columnMode.resolveColumns(viewport) > 1;
          return ColoredBox(
            color: _effectiveBackgroundColor,
            child: Focus(
              autofocus: true,
              onKeyEvent: (node, event) {
                if (event is! KeyDownEvent) return KeyEventResult.ignored;
                final key = event.logicalKey;
                final keyboard = HardwareKeyboard.instance;
                if (key == LogicalKeyboardKey.keyB &&
                    keyboard.isControlPressed &&
                    !keyboard.isAltPressed &&
                    !keyboard.isMetaPressed &&
                    !keyboard.isShiftPressed) {
                  if (canDockSidebar) {
                    _toggleDesktopSidebar();
                  } else if (!fullscreen) {
                    unawaited(_showDirectory());
                  }
                  return KeyEventResult.handled;
                }
                if (FocusManager.instance.primaryFocus?.context
                        ?.findAncestorWidgetOfExactType<EditableText>() !=
                    null) {
                  return KeyEventResult.ignored;
                }
                if (key == LogicalKeyboardKey.f11) {
                  unawaited(
                    DesktopPlatform.instance.setFullscreen(!fullscreen),
                  );
                  return KeyEventResult.handled;
                }
                if (key == LogicalKeyboardKey.escape && fullscreen) {
                  unawaited(DesktopPlatform.instance.setFullscreen(false));
                  return KeyEventResult.handled;
                }
                if ([
                  LogicalKeyboardKey.arrowRight,
                  LogicalKeyboardKey.pageDown,
                ].contains(key)) {
                  unawaited(_turnPage(1));
                  return KeyEventResult.handled;
                }
                if ([
                  LogicalKeyboardKey.arrowLeft,
                  LogicalKeyboardKey.pageUp,
                ].contains(key)) {
                  unawaited(_turnPage(-1));
                  return KeyEventResult.handled;
                }
                return KeyEventResult.ignored;
              },
              child: Row(
                children: [
                  if (showSidebar)
                    DesktopChapterSidebar(
                      key: const ValueKey('reader-desktop-chapter-sidebar'),
                      width: sidebarWidth,
                      chapters: widget.chapters,
                      currentIndex: _index,
                      backgroundColor: chromeColors.barBackground,
                      borderColor: chromeColors.border,
                      textColor: chromeColors.ink,
                      mutedColor: chromeColors.muted,
                      accentColor: chromeColors.accent,
                      inputFillColor: chromeColors.surface,
                      hoverColor: chromeColors.hoverBackground,
                      eink: chromeColors.isEink,
                      collapseTooltip: '收起目录 (Ctrl+B)',
                      onCollapse: () => _setDesktopSidebarOpen(false),
                      onSelected: (index) => unawaited(_jumpToChapter(index)),
                    ),
                  Expanded(
                    child: Stack(
                      fit: StackFit.expand,
                      children: [
                        Center(
                          child: ConstrainedBox(
                            constraints: BoxConstraints(
                              maxWidth: wideSpread
                                  ? math.max(1440.0, bounds.maxHeight + 1)
                                  : 880,
                            ),
                            child: Stack(
                              fit: StackFit.expand,
                              children: [
                                Listener(
                                  onPointerSignal: _desktopScroll,
                                  child: _buildReaderSurface(context),
                                ),
                                Positioned.fill(
                                  child: IgnorePointer(
                                    child: ValueListenableBuilder<double>(
                                      valueListenable:
                                          DesktopPlatform.readerBrightness,
                                      builder: (_, brightness, _) => ColoredBox(
                                        color: Colors.black.withValues(
                                          alpha: 1 - brightness,
                                        ),
                                      ),
                                    ),
                                  ),
                                ),
                              ],
                            ),
                          ),
                        ),
                        if (bounds.maxWidth >= 700 && (fullscreen || !hasFrame))
                          ValueListenableBuilder<bool>(
                            valueListenable: _controlsVisibility,
                            builder: (context, controls, _) {
                              final showUtilityPill =
                                  !showSidebar || controls || fullscreen;
                              if (!showUtilityPill) {
                                return const SizedBox.shrink();
                              }
                              return Positioned(
                                top: 12,
                                left: 12,
                                child: DecoratedBox(
                                  decoration: BoxDecoration(
                                    color: chromeColors.barBackground
                                        .withValues(alpha: 0.92),
                                    borderRadius: BorderRadius.circular(8),
                                    border: Border.all(
                                      color: chromeColors.border,
                                    ),
                                  ),
                                  child: Row(
                                    mainAxisSize: MainAxisSize.min,
                                    children: [
                                      if (canDockSidebar)
                                        IconButton(
                                          key: const Key(
                                            'reader-desktop-sidebar-toggle',
                                          ),
                                          tooltip:
                                              _preferences.desktopSidebarOpen
                                              ? '收起目录 (Ctrl+B)'
                                              : '展开目录 (Ctrl+B)',
                                          visualDensity: VisualDensity.compact,
                                          constraints:
                                              const BoxConstraints.tightFor(
                                                width: 34,
                                                height: 32,
                                              ),
                                          padding: EdgeInsets.zero,
                                          onPressed: _toggleDesktopSidebar,
                                          icon: Icon(
                                            _preferences.desktopSidebarOpen
                                                ? LucideIcons.panel_left_close
                                                : LucideIcons.panel_left_open,
                                            size: 16,
                                            color: chromeColors.ink,
                                          ),
                                        ),
                                      IconButton(
                                        key: const Key(
                                          'reader-desktop-fullscreen-toggle',
                                        ),
                                        tooltip: fullscreen
                                            ? '退出全屏 (F11)'
                                            : '全屏阅读 (F11)',
                                        visualDensity: VisualDensity.compact,
                                        constraints:
                                            const BoxConstraints.tightFor(
                                              width: 34,
                                              height: 32,
                                            ),
                                        padding: EdgeInsets.zero,
                                        onPressed: () => unawaited(
                                          DesktopPlatform.instance
                                              .setFullscreen(!fullscreen),
                                        ),
                                        icon: Icon(
                                          fullscreen
                                              ? LucideIcons.minimize_2
                                              : LucideIcons.maximize_2,
                                          size: 15,
                                          color: chromeColors.ink,
                                        ),
                                      ),
                                    ],
                                  ),
                                ),
                              );
                            },
                          ),
                      ],
                    ),
                  ),
                ],
              ),
            ),
          );
        },
      ),
    );
  }

  Widget _buildReaderSurface(BuildContext context) {
    final preset = _effectivePreset;
    // One decision per build, from the live scope, never from the animated
    // theme tokens. Archive keeps the Wenku8/glass chrome untouched.
    final classic = AppUiScope.isClassic(context);
    final windowPadding = MediaQuery.paddingOf(context);
    final overlayStyle = preset.isDark
        ? SystemUiOverlayStyle.light
        : SystemUiOverlayStyle.dark;
    final surface = PopScope<Object?>(
      canPop: !_controlsVisible,
      onPopInvokedWithResult: (didPop, _) {
        if (!didPop && _controlsVisible) _toggleControls();
      },
      child: AnnotatedRegion<SystemUiOverlayStyle>(
        value: overlayStyle.copyWith(
          statusBarColor: _effectiveBackgroundColor,
          systemNavigationBarColor: _effectiveBackgroundColor,
        ),
        child: Theme(
          data: preset.theme(Theme.of(context)),
          child: Scaffold(
            resizeToAvoidBottomInset: false,
            backgroundColor: _effectiveBackgroundColor,
            body: Stack(
              fit: StackFit.expand,
              children: [
                SafeArea(
                  child: Column(
                    children: [
                      if (_preferences.readingInfoMode ==
                          ReaderInfoMode.detailed)
                        GestureDetector(
                          onTap: _toggleControls,
                          behavior: HitTestBehavior.opaque,
                          child: Padding(
                            padding: const EdgeInsets.fromLTRB(20, 10, 20, 8),
                            child: Row(
                              children: [
                                Expanded(
                                  child: Text(
                                    widget.title,
                                    maxLines: 1,
                                    overflow: TextOverflow.ellipsis,
                                    style: TextStyle(
                                      color: preset.mutedTextColor,
                                      fontSize: 11,
                                    ),
                                  ),
                                ),
                                const SizedBox(width: 16),
                                Flexible(
                                  child: Text(
                                    _chapter.title,
                                    maxLines: 1,
                                    overflow: TextOverflow.ellipsis,
                                    textAlign: TextAlign.end,
                                    style: TextStyle(
                                      color: preset.mutedTextColor,
                                      fontSize: 11,
                                    ),
                                  ),
                                ),
                              ],
                            ),
                          ),
                        ),
                      Expanded(
                        child: ReaderPlayerPillHost(
                          bookId: widget.bookId,
                          preset: preset,
                          animate: !einkModeNotifier.value,
                          controlsVisible: _controlsVisible,
                          highlightOnScreen: () => readerNarrationOnScreen(
                            layout: _chapterLayout,
                            range: _narrationRange,
                            paged: _paged,
                            pageIndex: _pageIndex,
                            scrollController: _scrollController,
                            scrollOffset: _joined
                                ? _joinedKey.currentState?.position?.scroll
                                : null,
                          ),
                          normalPage: () => readerSyncPillNormalPage(
                            layout: _chapterLayout,
                            paged: _paged,
                            pageIndex: _pageIndex,
                          ),
                          onReturnOriginalProgress: _returnToOriginalProgress,
                          // 「从本页听」= 从当前页第一段重新起播，引擎跟圆钮
                          // 听书同一个默认值（系统朗读时留在阅读页念，不再
                          // 硬吃作品音频），由 `_openListening` 统一分派。
                          onListenFromPage: () =>
                              unawaited(_openListening(fromPage: true)),
                          viewportChanges: _scrollController,
                          footerBuilder: _preferences.showReadingInfo
                              ? (player) => ListenableBuilder(
                                  listenable: _scrollController,
                                  builder: (context, _) => ReaderStatusBar(
                                    playerControl: player,
                                    key: const ValueKey('reader-status-bar'),
                                    preset: preset,
                                    compact:
                                        _preferences.readingInfoMode ==
                                        ReaderInfoMode.compact,
                                    showProgress: !_controlsVisible,
                                    status: _deviceStatus,
                                    progress: _chapterProgress(),
                                    chapterIndex: _index,
                                    chapterCount: widget.chapters.length,
                                    paged: _paged,
                                    pageIndex: _chapterLayout == null
                                        ? null
                                        : _pageIndex,
                                    pageCount: _chapterLayout?.pages.length,
                                  ),
                                )
                              : null,
                          child: SizedBox.expand(
                            key: _viewportKey,
                            child: AnimatedBuilder(
                              animation: _scrollController,
                              child: _buildContent(preset, windowPadding),
                              builder: (context, content) => ReaderBookmarkPull(
                                enabled:
                                    classic &&
                                    !_loading &&
                                    _error == null &&
                                    _progressReady &&
                                    _selection == null &&
                                    !_controlsVisible,
                                paged: _paged,
                                preset: preset,
                                showSavedRibbon: !_paged,
                                ribbonTextInset:
                                    _chapterLayout?.spec.horizontalPadding ??
                                    _preferences.horizontalPadding,
                                locationKey: (
                                  widget.bookId,
                                  _chapter.itemId,
                                  _paged ? _pageIndex : _textOffset,
                                ),
                                isBookmarked: classic && _currentPageBookmarked,
                                onAdd: _addCurrentBookmark,
                                onRemove: _removeVisiblePageBookmarks,
                                child: content!,
                              ),
                            ),
                          ),
                        ),
                      ),
                    ],
                  ),
                ),
                if (!classic &&
                    !_settingsPreviewActive &&
                    !_progressPreviewActive)
                  ReaderEdgeBlur(animation: _chrome)
                // The empty slot keeps the chrome elements in place across a
                // style switch, so the pager/menu subtree is never recreated.
                else
                  const SizedBox.shrink(),
                _menuEdge(
                  top: true,
                  child: _buildToolbar(preset, classic: classic),
                ),
                Positioned(
                  bottom: 0,
                  left: 0,
                  right: 0,
                  child: AnimatedBuilder(
                    animation: _chrome,
                    child: _buildReaderControls(preset, classic: classic),
                    builder: (context, child) => Offstage(
                      offstage: _chrome.value == 0 || _settingsPreviewActive,
                      child: child,
                    ),
                  ),
                ),
                if (classic)
                  ReaderToast(
                    message: _readerToastMessage,
                    immediateDismiss: _readerToastImmediateDismiss,
                    reduceMotion: preset.isEink || _reduceReaderMotion,
                  ),
                // 墨水屏软件白闪：盖全屏白帧，迫使 EPD 控制器全量刷新。
                if (_einkFlashVisible)
                  const Positioned.fill(child: ColoredBox(color: Colors.white)),
              ],
            ),
          ),
        ),
      ),
    );
    // Keep ancestry stable when paper changes while a panel is open: only the
    // performance policy changes, not the pager/scroll controller identity.
    return PerformanceScope(
      preferences: preset.isEink
          ? const PerformancePreferences(enabled: true)
          : PerformanceScope.of(context),
      explicitReduceMotion: preset.isEink || _reduceReaderMotion,
      child: surface,
    );
  }

  Widget _menuEdge({required bool top, required Widget child}) => Positioned(
    top: top ? 0 : null,
    bottom: top ? null : 0,
    left: 0,
    right: 0,
    child: ReaderChromeLayer(
      animation: _settingsPreviewActive || _progressPreviewActive
          ? const AlwaysStoppedAnimation(0)
          : _chrome,
      interactionThreshold: 0,
      slide: Offset(0, top ? -1 : 1),
      child: child,
    ),
  );

  /// Wenku8's transparent header rides above the progressive edge; fqapp-only
  /// actions move to a real overflow menu instead of squeezing the book title.
  /// The classic style gets its own solid, two-line header.
  Widget _buildToolbar(ReaderThemePreset preset, {required bool classic}) =>
      classic
      ? _buildClassicToolbar(preset)
      : Material(
          key: const ValueKey('reader-toolbar'),
          color: preset.isEink || MediaQuery.highContrastOf(context)
              ? preset.panelColor
              : Colors.transparent,
          child: SafeArea(
            bottom: false,
            child: Padding(
              padding: const EdgeInsets.fromLTRB(12, 6, 12, 12),
              child: Row(
                children: [
                  SizedBox(
                    width: 88,
                    child: Align(
                      alignment: Alignment.centerLeft,
                      child: GlassIconButton(
                        key: const ValueKey('reader-back-entry'),
                        icon: CupertinoIcons.back,
                        label: '返回书籍',
                        onPressed: () => Navigator.of(context).pop(),
                      ),
                    ),
                  ),
                  Expanded(
                    child: Text(
                      widget.title,
                      key: const ValueKey('reader-header-book-title'),
                      textAlign: TextAlign.center,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: TextStyle(
                        color: preset.textColor,
                        fontSize: 16,
                        height: 1.25,
                        fontWeight: FontWeight.w700,
                      ),
                    ),
                  ),
                  SizedBox(
                    width: 44,
                    child: GlassIconButton(
                      key: const ValueKey('reader-header-listen'),
                      icon: CupertinoIcons.headphones,
                      label: '听书',
                      onPressed: _loading || _error != null
                          ? null
                          : () => unawaited(_openListening(fromPage: true)),
                    ),
                  ),
                  SizedBox(
                    width: 44,
                    child: GlassMenuAnchor(
                      child: Builder(
                        builder: (anchor) => GlassIconButton(
                          key: const ValueKey('reader-header-more'),
                          icon: CupertinoIcons.ellipsis,
                          label: '更多阅读操作',
                          onPressed: () =>
                              unawaited(_showReaderActions(anchor)),
                        ),
                      ),
                    ),
                  ),
                ],
              ),
            ),
          ),
        );

  Widget _buildClassicToolbar(ReaderThemePreset preset) {
    // The shelf icon must follow shelf writes without rebuilding the page.
    return ValueListenableBuilder<int>(
      valueListenable: ShelfStore.instance.listenable,
      builder: (context, _, _) => ReaderClassicToolbar(
        preset: preset,
        showCache: !widget.localOnly && !_readerBookIsImported,
        showComments:
            !_readerBookIsImported &&
            !_loading &&
            _error == null &&
            _ideas.total > 0 &&
            _chapterEndParagraph() != null,
        inShelf: inShelf(_shelfEntry),
        onBack: () => Navigator.of(context).pop(),
        onCache: () => unawaited(_showCache()),
        onComments: () =>
            unawaited(_showIdeas(focusParaIndex: _chapterEndParagraph())),
        onShelf: () => unawaited(
          toggleShelf(context, _shelfEntry, onMessage: _showMessage),
        ),
        onShare: widget.localOnly || _readerBookIsImported
            ? null
            : () => unawaited(_shareBook()),
        onMore: () => unawaited(_showClassicMore()),
      ),
    );
  }

  /// [keyPrefix] keeps the classic overflow menu's keys distinct from the
  /// toolbar's direct entries, which stay visible while the menu is open.
  /// [includeBookmarks] adds the classic-only 书签 entry; the archive glass
  /// dock already exposes it directly. [includeDisplayEntries] keeps
  /// 阅读设置/专注阅读·隐藏控件 in the menu for the archive toolbar; the
  /// classic chrome already exposes both (底板 设置 / 点正文中央).
  /// [compactWidth] shrinks the card to its labels for the classic reader.
  Future<void> _showReaderActions(
    BuildContext anchor, {
    String keyPrefix = '',
    bool preferBelow = false,
    bool compactWidth = false,
    bool includeBookmarks = false,
    bool includeDisplayEntries = true,
  }) async {
    _readerPanelOpen = true;
    final action = await showGlassMenu<String>(
      context: anchor,
      reduceMotion: _reduceReaderMotion,
      preferBelow: preferBelow,
      compactWidth: compactWidth,
      builder: (menu) {
        final column = Column(
          mainAxisSize: MainAxisSize.min,
          // Compact classic menus hug their widest label; stretching every row
          // to that width keeps the icons/labels on one left edge.
          crossAxisAlignment: compactWidth
              ? CrossAxisAlignment.stretch
              : CrossAxisAlignment.center,
          children: [
            if (!widget.localOnly && !_readerBookIsImported)
              GlassMenuItem(
                key: ValueKey('${keyPrefix}reader-cache'),
                icon: CupertinoIcons.tray_arrow_down,
                label: '缓存',
                onPressed: () => Navigator.pop(menu, 'cache'),
              ),
            if (!_loading &&
                _error == null &&
                _ideas.total > 0 &&
                _chapterEndParagraph() != null)
              GlassMenuItem(
                key: ValueKey('${keyPrefix}reader-toolbar-chapter-comments'),
                icon: CupertinoIcons.chat_bubble,
                label: '本章评论',
                order: 1,
                onPressed: () => Navigator.pop(menu, 'comments'),
              ),
            GlassMenuItem(
              key: ValueKey('${keyPrefix}reader-shelf-button'),
              icon: inShelf(_shelfEntry)
                  ? CupertinoIcons.bookmark_fill
                  : CupertinoIcons.bookmark,
              label: inShelf(_shelfEntry) ? '已在书架' : '加入书架',
              order: 2,
              onPressed: () => Navigator.pop(menu, 'shelf'),
            ),
            // 经典主题把底部动作行的 书签 移到这里；档案主题的玻璃坞仍直接
            // 提供，不重复。
            if (includeBookmarks)
              GlassMenuItem(
                key: ValueKey('${keyPrefix}reader-bookmarks-entry'),
                icon: CupertinoIcons.bookmark,
                label: '书签',
                order: 3,
                onPressed: () => Navigator.pop(menu, 'bookmarks'),
              ),
            // 经典主题的菜单只保留动作项；阅读设置与隐藏控件分别由底板“设置”
            // 和点击正文中央承担，菜单里不再重复。
            if (includeDisplayEntries)
              GlassMenuItem(
                key: ValueKey('${keyPrefix}reader-more-settings'),
                icon: CupertinoIcons.textformat,
                label: '阅读设置',
                order: 4,
                onPressed: () => Navigator.pop(menu, 'settings'),
              ),
            if (includeDisplayEntries)
              GlassMenuItem(
                key: ValueKey('${keyPrefix}reader-more-hide'),
                icon: CupertinoIcons.chevron_up,
                label: '专注阅读 · 隐藏控件',
                order: 5,
                onPressed: () => Navigator.pop(menu, 'hide'),
              ),
          ],
        );
        // IntrinsicWidth resolves the widest row, then stretch fills exactly
        // that width; without it stretch would take the whole 248dp cap.
        return compactWidth ? IntrinsicWidth(child: column) : column;
      },
    );
    if (!mounted) return;
    switch (action) {
      case 'cache':
        await _showCache();
      case 'comments':
        await _showIdeas(focusParaIndex: _chapterEndParagraph());
      case 'shelf':
        await toggleShelf(context, _shelfEntry);
      case 'bookmarks':
        await _showBookmarks();
      case 'settings':
        await _showAppearanceSettings();
      case 'hide':
        _setControlsVisible(false);
    }
  }

  Widget _buildReaderControls(
    ReaderThemePreset preset, {
    required bool classic,
  }) => Column(
    key: _bottomControlsKey,
    mainAxisSize: MainAxisSize.min,
    crossAxisAlignment: CrossAxisAlignment.stretch,
    children: [
      Visibility(
        visible: !_settingsPreviewActive && !_progressPreviewActive,
        maintainSize: true,
        maintainState: true,
        maintainAnimation: true,
        child: ReaderChromeLayer(
          animation: _chrome,
          interactionThreshold: 0,
          maintainSize: true,
          slide: const Offset(0, 1),
          clip: false,
          child: _buildReaderMenuPlayers(preset),
        ),
      ),
      ListenableBuilder(
        listenable: _scrollController,
        builder: (context, _) => classic
            // The archive dock runs its own chrome layers; the classic sheet is
            // one Material panel, so the same `_chrome` drives it from outside.
            // `maintainSize` keeps the measured height (and the selection bar's
            // clearance) identical while it slides, and reduce-motion/e-ink
            // already jump `_chrome` straight to its end value.
            ? ReaderChromeLayer(
                key: _classicControlsKey,
                animation: _chrome,
                interactionThreshold: 0,
                maintainSize: true,
                slide: const Offset(0, 1),
                clip: false,
                child: ReaderClassicControls(
                  key: const ValueKey('reader-classic-controls'),
                  preset: preset,
                  chapterIndex: _index,
                  chapterCount: widget.chapters.length,
                  chapterTitleAt: (index) => widget
                      .chapters[index.clamp(0, widget.chapters.length - 1)]
                      .title,
                  onPrevious: _index > 0 && !_loading ? _prev : null,
                  onNext: _index < widget.chapters.length - 1 && !_loading
                      ? _next
                      : null,
                  onSeekEnd: (index) => unawaited(_jumpToChapter(index)),
                  onDirectory: _showDirectory,
                  onNight: _toggleNightTheme,
                  onAppearance: _showAppearanceSettings,
                ),
              )
            : ReaderControls(
                key: const ValueKey('reader-controls'),
                preferences: _displayPreferences,
                chapterIndex: _index,
                chapterTitle: _chapter.title,
                fraction: _chapterLocalFraction,
                animation: _settingsPreviewActive
                    ? const AlwaysStoppedAnimation(0)
                    : _chrome,
                previewing: _progressPreviewActive,
                onPrevious: _index > 0 && !_loading ? _prev : null,
                onNext: _index < widget.chapters.length - 1 && !_loading
                    ? _next
                    : null,
                onPreview: _previewChapterFraction,
                onCommitted: _commitChapterFraction,
                onPreviewChanged: _setChapterPreview,
                onDirectory: _showDirectory,
                onBookmarks: _showBookmarks,
                onNight: _toggleNightTheme,
                onAppearance: () => _showAppearanceSettings(
                  section: ReaderSettingsSection.appearance,
                ),
                onOperations: () => _showAppearanceSettings(
                  section: ReaderSettingsSection.operations,
                ),
                onFind: _loading || !_progressReady ? null : _showFind,
              ),
      ),
    ],
  );

  Widget _errorView({Color? textColor}) => Center(
    child: SingleChildScrollView(
      padding: const EdgeInsets.all(24),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          Text(
            _error ?? '加载失败',
            textAlign: TextAlign.center,
            style: TextStyle(
              color: textColor ?? Theme.of(context).colorScheme.error,
            ),
          ),
          const SizedBox(height: 12),
          OutlinedButton(
            onPressed: () => _load(startAtEnd: _requestedStartAtEnd),
            child: const Text('重试'),
          ),
          // 空版权页和暂不可用章节不应把整本书困在重试页。
          Wrap(
            alignment: WrapAlignment.center,
            spacing: 12,
            children: [
              if (_index > 0)
                TextButton(onPressed: _prev, child: const Text('上一章')),
              TextButton(onPressed: _showDirectory, child: const Text('目录')),
              if (_index < widget.chapters.length - 1)
                TextButton(onPressed: _next, child: const Text('下一章')),
            ],
          ),
        ],
      ),
    ),
  );
}
