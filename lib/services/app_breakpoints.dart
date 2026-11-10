import 'package:flutter/foundation.dart';
import 'package:flutter/widgets.dart';

/// 全应用统一的宽屏断点（窗口宽度）。
///
/// 首页、短剧、书架、搜索共用这一个数字：窄于它按手机排版（内容压到
/// [appWideBreakpoint] 的阅读宽度），宽于它铺满并加列。改这里等于改全站，
/// 不要再在页面里写 `840` 字面量。
const double appWideBreakpoint = 840;

/// 是否按宽屏排版。
///
/// 口径 = **窗口**宽度 ≥ [appWideBreakpoint]，或 Windows 桌面（窗口可被
/// 拉成任意大小，且用户习惯小窗，一律按宽屏排以免退化成手机两列）。
///
/// [width] 留了覆盖口：嵌在受限容器里、手里已经拿到更准确的局部宽度时
/// 传进来，免得拿整窗宽度误判（短剧 feed 的单页就是这样）。
///
/// 这个判断全校准一处，别再各写一遍：书架曾用 `isDesktopHost`（只认
/// Windows/macOS），导致 Android 平板书架恒 3 列而短剧页已按宽度铺开。
///
/// 注意分工：本函数只回答「是不是宽屏」；需要按可用宽度反推列数的地方
/// （书架宫格、短剧网格）仍各自用 `constraints.maxWidth` /
/// `MediaQuery.sizeOf(context).width` 算格数。
bool appIsWideLayout(BuildContext context, {double? width}) =>
    _isWindowsDesktopHost ||
    (width ?? MediaQuery.sizeOf(context).width) >= appWideBreakpoint;

/// 与 `services/desktop_platform.dart` 的 `isWindowsDesktop` 同义。
///
/// 刻意不 import 那个文件：它把 media_kit / ffi / smtc / window_manager
/// 全拖进来，一次纯布局判定不该背这堆依赖。
bool get _isWindowsDesktopHost =>
    !kIsWeb && defaultTargetPlatform == TargetPlatform.windows;
