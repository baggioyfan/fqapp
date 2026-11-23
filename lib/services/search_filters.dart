import '../models/media_item.dart';

/// 搜索结果与分类结果的二次筛选(状态 / 字数 / 分类词)。
///
/// 这些筛选只作用于**已加载**的结果:上游没有把这些条件下推到接口,
/// 所以继续加载更多时会带进新条目一起筛。抽成一个小对象是为了让页面
/// 有一个明确的判定入口,也避免同样的判断散落在多处。
class SearchFilters {
  const SearchFilters({this.status = -1, this.wordCount = 0, this.tag});

  /// -1 全部、0 完结、1 连载中、4 停更,与上游 `creation_status` 一致。
  final int status;

  /// 0 全部、1 <30 万、2 30–100 万、3 100–300 万、4 >300 万。
  final int wordCount;

  /// 分类入口带进来的分类词。命中作品的分类标签;只有作品没有分类标签
  /// 时才回退到标题匹配,避免标题里恰好出现同一个词却被分类判定排除。
  final String? tag;

  bool get isActive =>
      status >= 0 || wordCount > 0 || (tag != null && tag!.isNotEmpty);

  SearchFilters copyWith({
    int? status,
    int? wordCount,
    String? tag,
    bool clearTag = false,
  }) => SearchFilters(
    status: status ?? this.status,
    wordCount: wordCount ?? this.wordCount,
    tag: clearTag ? null : (tag ?? this.tag),
  );

  bool matches(MediaItem item) {
    if (status >= 0 && item.creationStatus != status) return false;
    if (wordCount > 0 && !_matchesWordCount(item.wordNumber)) return false;
    final key = tag;
    if (key != null && key.isNotEmpty) {
      // 分类标签是权威来源;标题兜底只针对完全没有分类标签的作品。
      final hit = item.categories.isNotEmpty
          ? item.categories.any((category) => category.contains(key))
          : item.title.contains(key);
      if (!hit) return false;
    }
    return true;
  }

  bool _matchesWordCount(int words) => switch (wordCount) {
    1 => words > 0 && words < 300000,
    2 => words >= 300000 && words < 1000000,
    3 => words >= 1000000 && words < 3000000,
    4 => words >= 3000000,
    _ => true,
  };
}
