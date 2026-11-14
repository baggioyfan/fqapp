import 'package:flutter/foundation.dart';

import 'desktop_platform.dart';

/// 视频播放是否可用。
///
/// 视频依赖原生播放器：Android 走 ExoPlayer 平台通道（`fqapp/native_player`），
/// 桌面走 media_kit（`DesktopPlatform.invoke` 的 `fqapp/native_player` 分支，
/// Windows / macOS / Linux 共用）。iOS 首版没有播放器实现，直接进入播放页会抛
/// `MissingPluginException`，所以入口整体降级为「暂不支持」。
///
/// 上游这里只写了 [isWindowsDesktop]（上游没有 macOS 端）；fork 的 macOS 与
/// Windows 走同一套实现，必须按 [isDesktopHost] 判断，否则 macOS 的视频入口
/// 会被误判为「暂不支持」。
bool get supportsVideoPlayback =>
    !kIsWeb &&
    (defaultTargetPlatform == TargetPlatform.android || isDesktopHost);
