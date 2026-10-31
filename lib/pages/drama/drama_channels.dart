part of '../drama_page.dart';

/// One entry of the 短剧 tab's channel strip.
///
/// The official strip is server-driven (`BookstoreTabData.tabItem[]`, rendered
/// by `m0.java:3051-3106`). The server only returns the *seriesmall* strip
/// (推荐/看剧/漫剧/最近/收藏) when the request carries the seriesmall context:
/// `bottom_tab_type=VideoSeriesFeedTab(7)` + `client_req_type=Open(3)`
/// (`SeriesMallVM.java:141-176`). With the bookstore context the same route
/// returns the bookstore strip, whose mappable entries collapse to
/// 看剧(8)/视频(16) — that was the "channel strip shrinks to two tabs" bug.
/// Our proxy now sends the seriesmall context (rust `channel_tabs`), and the
/// five channels below are both the offline fallback and the name backstop for
/// empty server titles. The two the official client fills from the device —
/// 最近 (recent=18, `r73/m2.java:100-103`) and 收藏 (follow=30,
/// `td4/o1.java:179-193`) — are served from our own history and shelf.
/// 预约 (28) has no data source here and is deliberately absent.
///
/// Note: 频道映射与取证的完整理由 — 见
/// .agents/notes/implemented/feature/2026-09-20-official-drama-tab.md
enum DramaChannelSource { feed, history, shelf }

class DramaChannel {
  final String label;

  /// Index into [HomeNotifier.tabs] for [DramaChannelSource.feed].
  final int tabIndex;
  final String kind;
  final DramaChannelSource source;

  /// 官方 `BookstoreTabType` 里这条频道的 `tab_type`。
  ///
  /// 本地表也按官方同义类型标注（即 [ChannelTab.typeOf] 的映射）。两个用途：
  /// 服务端表到达后**按类型续接**当前频道（title 是服务端文案会变，类型才是
  /// 身份），以及换表请求上报 `tab_type` / `last_tab_type`（官方
  /// `SeriesMallVM` 行为）。
  final int? serverType;

  const DramaChannel({
    required this.label,
    required this.tabIndex,
    required this.kind,
    this.source = DramaChannelSource.feed,
    this.serverType,
  });

  bool get isFeed => source == DramaChannelSource.feed;

  // Note: 海报格曾在背后起播，播放资格按渲染形态收口 — 见
  // .agents/notes/implemented/bug-fix/2026-09-28-drama-grid-background-audio.md
  bool get playsInline =>
      isFeed &&
      kind != 'manju' &&
      serverType != kChannelVideoEpisode &&
      serverType != kChannelVideo;
}

final dramaChannels = <DramaChannel>[
  DramaChannel(
    label: '推荐',
    tabIndex: HomeNotifier.tabs.indexOf('视频'),
    kind: 'video',
    serverType: kChannelVideoFeed,
  ),
  DramaChannel(
    label: '看剧',
    tabIndex: HomeNotifier.tabs.indexOf('短剧'),
    kind: 'video',
    serverType: kChannelVideoEpisode,
  ),
  DramaChannel(
    label: '漫剧',
    tabIndex: HomeNotifier.tabs.indexOf('漫剧'),
    kind: 'manju',
    serverType: kChannelDynamicComic,
  ),
  const DramaChannel(
    label: '最近',
    tabIndex: 0,
    kind: 'video',
    source: DramaChannelSource.history,
    serverType: kChannelRecent,
  ),
  const DramaChannel(
    label: '收藏',
    tabIndex: 0,
    kind: 'video',
    source: DramaChannelSource.shelf,
    serverType: kChannelFollow,
  ),
];

/// 当前短剧频道是不是浅色页（看剧 / 漫剧 / 最近 / 收藏）。
///
/// 壳层的悬浮 dock 与系统导航栏跟着它换肤：推荐频道压在全屏视频流上，
/// 保持深色玻璃；浅色页则回到主题画布，否则浅色外观下页面是奶白、
/// dock 还是一条黑的。
final ValueNotifier<bool> dramaLightPageNotifier = ValueNotifier<bool>(false);

/// 服务端 `tab_type` -> 本地频道（F08：频道表由服务端下发）。
///
/// 官方 `m0.java:3051-3089` 把 `tab_item` 逐条转成频道：名字用服务端 `title`、
/// 类型用 `tab_type`。本地只保留**能真正打开内容**的那些类型；映射不到的类型
/// 返回 null（宁可不显示，也不要放一个点了没反应的频道）。
DramaChannel? serverChannelOf(ChannelTab tab) {
  // 服务端没给名字时用官方同义的中文兜底，避免出现空标签。
  String label(String fallback) =>
      tab.title.trim().isEmpty ? fallback : tab.title;
  switch (tab.type) {
    case kChannelVideoFeed:
      return DramaChannel(
        label: label('推荐'),
        tabIndex: HomeNotifier.tabs.indexOf('视频'),
        kind: 'video',
        serverType: tab.type,
      );
    case kChannelVideoEpisode:
    case kChannelVideo:
      return DramaChannel(
        label: label('看剧'),
        tabIndex: HomeNotifier.tabs.indexOf('短剧'),
        kind: 'video',
        serverType: tab.type,
      );
    case kChannelDynamicComic:
      return DramaChannel(
        label: label('漫剧'),
        tabIndex: HomeNotifier.tabs.indexOf('漫剧'),
        kind: 'manju',
        serverType: tab.type,
      );
    case kChannelRecent:
      return DramaChannel(
        label: label('最近'),
        tabIndex: 0,
        kind: 'video',
        source: DramaChannelSource.history,
        serverType: tab.type,
      );
    case kChannelFollow:
      return DramaChannel(
        label: label('收藏'),
        tabIndex: 0,
        kind: 'video',
        source: DramaChannelSource.shelf,
        serverType: tab.type,
      );
    default:
      return null;
  }
}
