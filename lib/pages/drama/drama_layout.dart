part of '../drama_page.dart';

/// 搜索行高度（首页 `fua` 的 51dp）：6dp 上留白 + 36dp 框体 + 9dp 下留白。
/// 原先沿用 `ap4.xml` 的 38dp，上下只剩 1dp，频道标签几乎贴着搜索框。
const _dramaSearchRowHeight = 51.0;

/// 频道条基础高度；大字号下由 [_dramaStripHeightFor] 抬高。
const _dramaStripBaseHeight = 38.0;

/// 频道条在大字号下随选中字号一起长高：24sp 放大后若仍锁死 38dp，会和
/// 3dp 指示条一起撞破条带。思路同首页 tab 条的 textScale 补偿。
///
/// 与 [_dramaSearchRowHeight] 一样放在文件顶层：顶栏是两处（悬浮层本身与
/// 依赖它的列表留白）共用的布局契约，不该藏在页面 State 里。
double _dramaStripHeightFor(BuildContext context) {
  final text = MediaQuery.textScalerOf(context).scale(24) * 1.1 + 6;
  return text > _dramaStripBaseHeight ? text + 4 : _dramaStripBaseHeight;
}

/// 悬浮顶栏（搜索行 + 频道条）在状态栏下方占的高度。
///
/// 顶栏是 `Stack` 里的悬浮层，不占页面布局：feed 的下拉提示、网格的顶部
/// 留白、最近/收藏的筛选行都得自己让出这段高度。桌面端不渲染搜索行
/// （搜索入口收敛到频道条右端图标），比手机端少一个 [_dramaSearchRowHeight]。
double dramaTopChromeHeight(BuildContext context) =>
    (isWindowsDesktop ? 0.0 : _dramaSearchRowHeight) +
    _dramaStripHeightFor(context);

/// 频道条的定位锚点：条数变化时只增删尾部，保留已有 index 的 `GlobalKey`。
///
/// 全部重建会让每个标签的 Element 换新：大字号选中过渡动画被打断，整条
/// 频道条闪一下（服务端频道表替换本地表时就能看到）。抽成纯函数也让这条
/// 规则可被单测直接钉住。
@visibleForTesting
List<GlobalKey> syncChannelTabKeys(List<GlobalKey> current, int count) {
  if (current.length == count) return current;
  return [
    for (var index = 0; index < count; index++)
      index < current.length
          ? current[index]
          : GlobalKey(debugLabel: 'drama_channel_$index'),
  ];
}

/// 桌面端海报格列数：一格 190dp 宽、钳在 3–9 列。
///
/// 看剧/漫剧的瀑布格与最近/收藏的双列格共用这一个口径，改动只在这里。
/// 手机端不走它——那边是官方的固定两列。
int dramaDesktopColumns(BuildContext context) =>
    (MediaQuery.sizeOf(context).width / 190).floor().clamp(3, 9);
