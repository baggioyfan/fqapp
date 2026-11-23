part of 'library_page.dart';

/// 书架 tab 的媒介类型筛选行:全部 / 小说 / 漫画 / 短剧 / 漫剧 / 听书。
///
/// 书架原本按「收藏」是否视频源把条目分到两个 tab(`_isVideoKind`),现在
/// 书架 tab 收全部条目,靠这一行区分媒介。键值与既有的收藏筛选
/// (`library-collection-filter-*`)保持同一命名规则,互不冲突。
class _ShelfKindFilter extends StatelessWidget {
  const _ShelfKindFilter({required this.selected, required this.onChanged});

  final String? selected;
  final ValueChanged<String?> onChanged;

  static const _options = <({String key, String label, String? value})>[
    (key: 'all', label: '全部', value: null),
    (key: 'book', label: '小说', value: 'book'),
    (key: 'manga', label: '漫画', value: 'manga'),
    (key: 'video', label: '短剧', value: 'video'),
    (key: 'manju', label: '漫剧', value: 'manju'),
    (key: 'audio', label: '听书', value: 'audio'),
  ];

  @override
  Widget build(BuildContext context) => SingleChildScrollView(
    scrollDirection: Axis.horizontal,
    child: Row(
      children: [
        for (final option in _options)
          Padding(
            padding: const EdgeInsets.only(right: 8),
            child: Semantics(
              key: Key('library-shelf-kind-${option.key}'),
              selected: selected == option.value,
              inMutuallyExclusiveGroup: true,
              child: GlassTextButton(
                compact: true,
                selected: selected == option.value,
                onPressed: () => onChanged(option.value),
                child: AppText(option.label),
              ),
            ),
          ),
      ],
    ),
  );
}

/// 收藏 tab 的 video/manju 类型筛选行。
///
/// 类型筛选是 fqapp 专有行为（官方收藏页按类型分频道），Key 与文案保持
/// 不变；视觉换成上游 `GlassTextButton` 选中态。
class _CollectionTypeFilter extends StatelessWidget {
  const _CollectionTypeFilter({
    required this.selected,
    required this.onChanged,
  });

  final String? selected;
  final ValueChanged<String?> onChanged;

  static const _options = <({String key, String label, String? value})>[
    (key: 'all', label: '全部', value: null),
    (key: 'video', label: '短剧', value: 'video'),
    (key: 'manju', label: '漫剧', value: 'manju'),
  ];

  @override
  Widget build(BuildContext context) => Row(
    children: [
      for (final option in _options)
        Padding(
          padding: const EdgeInsets.only(right: 8),
          child: Semantics(
            key: Key('library-collection-filter-${option.key}'),
            selected: selected == option.value,
            inMutuallyExclusiveGroup: true,
            child: GlassTextButton(
              compact: true,
              selected: selected == option.value,
              onPressed: () => onChanged(option.value),
              child: AppText(option.label),
            ),
          ),
        ),
    ],
  );
}
