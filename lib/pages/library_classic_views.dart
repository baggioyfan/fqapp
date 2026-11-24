part of 'library_page.dart';

// Keep these in sync with ClassicShellDock's 56dp capsule, 8dp bottom gap,
// and the shared 24dp breathing room. RootShell only uses that dock outside
// Windows, where the standalone desktop shell has no bottom bar.
// The capsule shrank 64 → 56 for issue #478 (narrower top/bottom bars, more
// room for the shelf grid); the clearance shrinks with it so the empty state
// keeps the same breathing room above the dock.
const double _classicRootDockHeight = 56;
const double _classicRootDockBottomGap = 8;
const double _classicRootDockBreathingRoom = 24;

/// 一级 tab 行收起/展开的尺寸动画时长（issue #478 第二步）。比页面横滑的
/// 260ms 略短，避免收起动画与邻页入场抢节奏；墨水屏与系统减动效直接落位。
const Duration _classicTabRowCollapseDuration = Duration(milliseconds: 220);

/// Old three-layout presentation, sharing the current page's entries, actions
/// and edit state. No archive mode/density/3D preference participates here.
mixin _LibraryClassicViews on _LibraryClassicChrome {
  /// 一级 tab 行是否已收起（issue #478 第二步：下滑收起、上滑露出）。
  ///
  /// 只监听 **用户拖动**（[UserScrollNotification]）：`jumpTo`、布局变化
  /// 引起的 ScrollUpdate 都不会翻转它，因此收起后视口变高、宫格重排也不会
  /// 形成“收起→变高→又收起”的振荡。横轴通知（[TabSwipeArea] 翻页）天然
  /// 被滤掉，左右滑切 tab 不会把条子收起来。
  final ValueNotifier<bool> _tabRowCollapsed = ValueNotifier<bool>(false);

  /// 只跟随拖动方向（与底栏 `DockAutoHide` 同一状态机）：下滚收起、
  /// 上滚露出，回到列表顶部自然会走 forward 分支。
  ///
  /// 不用 `extentBefore` 做门槛：从顶部开始上推时，第一条
  /// [UserScrollNotification] 带回的 metrics 还是 offset 0（方向通知只在
  /// 方向变化时发），按位移判会永远收不起来。
  ///
  /// 墨水屏整层短路（同 `DockAutoHide.disabledProbe` 口径）：高度变动
  /// 意味着全屏重绘，局部刷新的残影代价比多露一行书封更大。
  bool _handleClassicUserScroll(UserScrollNotification notification) {
    if (einkModeNotifier.value) return false;
    if (notification.metrics.axis == Axis.horizontal) return false;
    switch (notification.direction) {
      case ScrollDirection.reverse:
        _tabRowCollapsed.value = true;
      case ScrollDirection.forward:
        _tabRowCollapsed.value = false;
      case ScrollDirection.idle:
        break;
    }
    return false;
  }

  /// 切 tab 是“回到入口”的明确动作，收起状态下用户看不到三个标签，
  /// 所以与底栏的 reveal 同约定：换页必定把条子带回来。
  @override
  void _selectTab(int tab) {
    _tabRowCollapsed.value = false;
    super._selectTab(tab);
  }

  @override
  void dispose() {
    _tabRowCollapsed.dispose();
    super.dispose();
  }

  /// 可收起的一级 tab 槽位：收起时高度归零（不是只平移），真正把 40dp
  /// 还给宫格。`ClipRect` 保证收起过程中标签不会被画到状态栏区域；
  /// 墨水屏与系统「减弱动态效果」直接落位，不跑 220ms 的尺寸动画。
  /// 同时监听 [einkModeNotifier]：切到墨水屏立即展开（抽屉里的旧状态
  /// 不能残留成一条 0 高的条子）。
  Widget _classicTabRowSlot(HomePalette palette) => AnimatedBuilder(
    animation: Listenable.merge([_tabRowCollapsed, einkModeNotifier]),
    builder: (context, _) {
      final collapsed = _tabRowCollapsed.value && !einkModeNotifier.value;
      final duration =
          MediaQuery.disableAnimationsOf(context) || einkModeNotifier.value
          ? Duration.zero
          : _classicTabRowCollapseDuration;
      final content = collapsed
          ? const SizedBox(width: double.infinity, height: 0)
          // The sliding underline needs the measured tab centres, which only
          // exist after the layout.
          : Builder(
              builder: (context) {
                _scheduleClassicMeasure();
                return _classicTabRow(palette);
              },
            );
      return ClipRect(
        key: const Key('classic-tab-row-slot'),
        // 零时长不进 AnimatedSize：RenderAnimatedSize 在 duration 为 0 时
        // 会在自己的 performLayout 里把控制器瞬完并 markNeedsLayout，
        // 触发“re-dirty itself while being laid out”。减动效/墨水屏直接
        // 换子树，本来就是想要的结果。
        child: duration == Duration.zero
            ? content
            : AnimatedSize(
                duration: duration,
                curve: Curves.easeOutCubic,
                alignment: Alignment.topCenter,
                child: content,
              ),
      );
    },
  );

  Widget _classicPage(BuildContext context) {
    final palette = HomePalette.of(context);
    return Scaffold(
      backgroundColor: palette.canvas,
      body: SafeArea(
        bottom: false,
        child: NotificationListener<UserScrollNotification>(
          onNotification: _handleClassicUserScroll,
          child: Column(
            children: [
              if (_editing)
                _classicEditBar(palette)
              else
                _classicTabRowSlot(palette),
              Expanded(
                child: TabSwipeArea.pages(
                  index: _tab,
                  count: _tabTitles.length,
                  onSelect: _selectTab,
                  onProgress: (value) {
                    if (_tabProgress.value != value) {
                      _tabProgress.value = value;
                    }
                  },
                  enabled: !_editing,
                  pageBuilder: (context, target) =>
                      _classicTabBody(context, target),
                ),
              ),
            ],
          ),
        ),
      ),
      bottomNavigationBar: _editing ? _classicEditBottomBar(palette) : null,
    );
  }

  /// 工具栏与内容作为同一张邻页滑动，切历史时不再改变滑动视口高度。
  Widget _classicTabBody(BuildContext context, int tab) {
    final palette = HomePalette.of(context);
    return Column(
      children: [
        if (!_editing && tab != 1) _classicToolbar(palette, tab),
        if (_classicHasFiltersForTab(tab)) _classicFilterStatus(palette, tab),
        if (tab != 1 &&
            ShelfViewStore.instance.state.source == ShelfSourceFilter.cached)
          Padding(
            padding: const EdgeInsets.symmetric(
              horizontal: ShelfTokens.screenPadding,
            ),
            child: _cacheStatus(),
          ),
        Expanded(
          child: RefreshIndicator(
            onRefresh: () => _refreshUpdates(force: true),
            child: _classicContent(context, tab),
          ),
        ),
      ],
    );
  }

  Widget _classicContent(BuildContext context, int tab) {
    final entries = _visibleEntriesForTab(tab);
    if (entries.isEmpty) {
      // Shrink the scroll viewport itself so its clipped content cannot paint
      // behind the root dock. The inner sliver remains scrollable for large
      // text and keeps pull-to-refresh working when filters hide every entry.
      return Padding(
        padding: EdgeInsets.only(bottom: _classicEmptyBottomClearance),
        child: CustomScrollView(
          physics: const AlwaysScrollableScrollPhysics(),
          slivers: [
            SliverFillRemaining(
              hasScrollBody: false,
              child: _classicEmptyState(tab),
            ),
          ],
        ),
      );
    }
    // All three old-style tabs share this independent three-layout choice.
    // The archive's fixed history list and four-mode setting are untouched.
    final layout = _classicLayout.value;
    return switch (layout) {
      BookshelfLayout.grid => _classicGrid(entries, tab),
      BookshelfLayout.doubleColumn => _classicDoubleGrid(entries, tab),
      BookshelfLayout.list => _classicList(entries, tab),
    };
  }

  /// 空态锚点补偿用的动态头部总高：筛选状态栏定高（行内文字已钳制
  /// 1.3 倍内，定高恒成立）；缓存扫描行只在扫描未完成时占高（完成后
  /// 是 SizedBox.shrink），高度随 textScaler 与实际渲染同源计算。
  double _classicDynamicHeaderHeight(int tab) {
    var height = 0.0;
    if (_classicHasFiltersForTab(tab)) height += ShelfTokens.filterStatusHeight;
    if (tab != 1 &&
        ShelfViewStore.instance.state.source == ShelfSourceFilter.cached &&
        !_cacheScanComplete) {
      height += shelfCacheStatusHeight(context);
    }
    return height;
  }

  Widget _classicEmptyState(int tab) {
    final headerHeight = _classicDynamicHeaderHeight(tab);
    final category = tab == 0 ? _categoryForTab(tab) : ShelfCategory.all;
    // A selected group is empty only when no shelf entry belongs to it at all.
    // Other active filters must keep the generic "没有符合筛选" copy: the
    // group itself still has books, they are just hidden by source/reading.
    final groupEmpty =
        tab == 0 &&
        category != ShelfCategory.all &&
        !_shelf.any(
          (entry) => ShelfGroupStore.instance.matchesKey(
            entry.contentKey,
            entry.author,
            category,
          ),
        );
    if (tab == 0 && _shelf.isEmpty && !groupEmpty) {
      return _ClassicEmptyNotice(
        icon: LucideIcons.book_open,
        title: '书架暂无书籍',
        message: '去书城发现海量故事，随时随地畅读',
        actionLabel: '去书城找书',
        actionKey: const Key('shelf-browse-button'),
        onAction: widget.onBrowse,
        onCachedBooks: _openCachedBooks,
        headerHeight: headerHeight,
      );
    }
    if (tab == 2 &&
        (_collection.isEmpty ||
            (_activeFiltersForTab(tab) == 0 &&
                _categoryForTab(tab) == ShelfCategory.all))) {
      return _ClassicEmptyNotice(
        icon: LucideIcons.clapperboard,
        title: switch (_collectionFilter) {
          'video' => '暂无短剧',
          'manju' => '暂无漫剧',
          _ => '暂无收藏内容',
        },
        actionLabel: widget.onFindDrama == null
            ? null
            : _collectionFilter == 'manju'
            ? '找漫剧'
            : '找短剧',
        actionKey: const Key('collection-find-drama-button'),
        onAction: widget.onFindDrama,
        headerHeight: headerHeight,
      );
    }
    final filtered = _classicHasFiltersForTab(tab);
    final groupEmptyTitle = groupEmpty
        ? '「${ShelfGroupStore.instance.nameOf(category)}」暂无书籍'
        : null;
    return _ClassicEmptyNotice(
      icon: LucideIcons.search_x,
      title:
          groupEmptyTitle ??
          (!filtered
              ? '未找到相关内容'
              : switch (tab) {
                  0 => '没有符合筛选的书籍',
                  2 => '没有符合筛选的收藏',
                  _ => '没有符合筛选的记录',
                }),
      actionLabel: filtered ? '清除筛选' : null,
      actionKey: const Key('shelf-clear-filters'),
      onAction: _clearFilters,
      headerHeight: headerHeight,
    );
  }

  /// The classic root shell has a 56dp dock plus an 8dp gap and safe-area inset.
  /// Only Windows uses the standalone desktop tabs without [ShellDock]; other
  /// platforms retain the root dock. Edit mode also has its own bottom bar.
  double get _classicEmptyBottomClearance {
    if (_editing) return 0;
    final hasRootDock =
        kIsWeb || defaultTargetPlatform != TargetPlatform.windows;
    if (!hasRootDock) return 0;
    return _classicRootDockHeight +
        _classicRootDockBottomGap +
        MediaQuery.viewPaddingOf(context).bottom +
        _classicRootDockBreathingRoom;
  }

  Widget _classicGrid(List<_ShelfEntry> entries, int tab) => LayoutBuilder(
    builder: (context, constraints) {
      // 列数一律按可用宽度算：一格 168dp，最少 [ShelfTokens.gridColumns] 列。
      // 以前只有 `isDesktopHost` 才按宽度加列，Android 平板再宽也固定 3 列
      // （1440dp 横屏同样 3 列，卡片被拉成 469dp 宽）。手机按这个公式算出来
      // 本来就 ≤3，下限兜回 3 列，视觉不变。
      //
      // 刻意不设平台判据：这个坑 2026-11 修过两次都被换基底时改回去，
      // `test/classic_shelf_ui_test.dart` 里的 1024dp 平板用例守着。
      final columns =
          ((constraints.maxWidth - ShelfTokens.screenPadding * 2) / 168)
              .floor()
              .clamp(ShelfTokens.gridColumns, 8);
      return GridView.builder(
        physics: const AlwaysScrollableScrollPhysics(),
        key: PageStorageKey('classic-shelf-grid-$tab'),
        padding: EdgeInsets.fromLTRB(
          ShelfTokens.screenPadding,
          ShelfTokens.spaceXS,
          ShelfTokens.screenPadding,
          isDesktopHost ? 24.0 : ShelfTokens.contentBottomInset,
        ),
        gridDelegate: SliverGridDelegateWithFixedCrossAxisCount(
          crossAxisCount: columns,
          crossAxisSpacing: ShelfTokens.gridSpacing,
          mainAxisSpacing: ShelfTokens.gridRunSpacing,
          childAspectRatio: shelfGridChildAspectRatio(
            context,
            availableWidth: constraints.maxWidth,
            columns: columns,
          ),
        ),
        itemCount: entries.length,
        itemBuilder: (context, index) {
          final entry = entries[index];
          return BookshelfGridCard(
            key: ValueKey('shelf-grid-${entry.selectionKey}'),
            item: entry.item,
            badgeText: entry.badgeText,
            infoText: entry.infoText,
            editing: _editing,
            selected: _selected.contains(entry.selectionKey),
            onTap: () => _tap(entry),
            onLongPress: () => _longPress(entry),
          );
        },
      );
    },
  );

  Widget _classicDoubleGrid(List<_ShelfEntry> entries, int tab) =>
      LayoutBuilder(
        builder: (context, constraints) {
          // 双列版同口径：一格 340dp，最低 2 列。平板横屏从固定 2 列变成
          // 按宽度铺到 4 列，手机仍是 2 列。
          final columns =
              ((constraints.maxWidth - ShelfTokens.screenPadding * 2) / 340)
                  .floor()
                  .clamp(2, 4);
          return GridView.builder(
            physics: const AlwaysScrollableScrollPhysics(),
            key: PageStorageKey('classic-shelf-double-$tab'),
            padding: EdgeInsets.fromLTRB(
              ShelfTokens.screenPadding,
              ShelfTokens.spaceXS,
              ShelfTokens.screenPadding,
              isDesktopHost ? 24.0 : ShelfTokens.contentBottomInset,
            ),
            gridDelegate: SliverGridDelegateWithFixedCrossAxisCount(
              crossAxisCount: columns,
              crossAxisSpacing: ShelfTokens.gridSpacing,
              mainAxisSpacing: ShelfTokens.gridSpacing,
              childAspectRatio: shelfDoubleChildAspectRatio(
                context,
                availableWidth: constraints.maxWidth,
                columns: columns,
              ),
            ),
            itemCount: entries.length,
            itemBuilder: (context, index) {
              final entry = entries[index];
              return BookshelfDoubleCard(
                key: ValueKey('shelf-double-${entry.selectionKey}'),
                item: entry.item,
                badgeText: entry.badgeText,
                subtitleText: entry.subtitleText,
                editing: _editing,
                selected: _selected.contains(entry.selectionKey),
                onTap: () => _tap(entry),
                onLongPress: () => _longPress(entry),
              );
            },
          );
        },
      );

  Widget _classicList(List<_ShelfEntry> entries, int tab) {
    final list = ListView.separated(
      physics: const AlwaysScrollableScrollPhysics(),
      key: PageStorageKey('classic-shelf-list-$tab'),
      padding: EdgeInsets.only(
        left: isDesktopHost ? 16 : 0,
        right: isDesktopHost ? 16 : 0,
        top: ShelfTokens.spaceXS,
        bottom: isDesktopHost ? 24.0 : ShelfTokens.contentBottomInset,
      ),
      itemCount: entries.length,
      separatorBuilder: (context, index) => Divider(
        height: .5,
        thickness: .5,
        color: HomePalette.of(context).line,
      ),
      itemBuilder: (context, index) {
        final entry = entries[index];
        return BookshelfListCard(
          key: ValueKey('shelf-list-${entry.selectionKey}'),
          item: entry.item,
          progressText: entry.readingText,
          metaText: entry.metaText,
          progress: entry.progress,
          editing: _editing,
          selected: _selected.contains(entry.selectionKey),
          onTap: () => _tap(entry),
          onLongPress: () => _longPress(entry),
        );
      },
    );
    if (!isDesktopHost) return list;
    return Align(
      alignment: Alignment.topCenter,
      child: ConstrainedBox(
        constraints: const BoxConstraints(maxWidth: 1080),
        child: list,
      ),
    );
  }
}
